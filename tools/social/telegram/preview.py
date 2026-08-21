"""Parse Telegram's public web preview (https://t.me/s/<channel>).

Route 1 of the design spec: no account, no phone number. Selectors target the
tgme_widget_* classes of the server-rendered preview. If Telegram changes the
markup, the golden-fixture test fails loudly rather than collecting garbage.
"""
import random
import re
import time
from dataclasses import dataclass

import requests
from bs4 import BeautifulSoup

from tools.social.telegram.vpn_gate import VPNNotActiveError, proton_vpn_active

USER_AGENT = ("BlueX-Research-Collector/1.0 "
              "(+academic research; contact keyan.zahedi@gmail.com)")
PAGE_DELAY_SECONDS = 2.0


class NoPreviewError(Exception):
    """Channel exists but has no public web preview (or does not exist)."""


@dataclass
class Message:
    channel: str
    msg_id: int
    date: str
    text: str
    views: int | None
    fwd_from_channel: str | None
    fwd_from_msg_id: int | None
    reply_to_msg_id: int | None
    media_type: str | None
    media_ref: str | None


def parse_views(s: str) -> int:
    s = s.strip().upper()
    mult = 1
    if s.endswith("K"):
        mult, s = 1_000, s[:-1]
    elif s.endswith("M"):
        mult, s = 1_000_000, s[:-1]
    return int(float(s) * mult)


def _link_target(href: str) -> tuple[str | None, int | None]:
    """t.me/<chan>/<id> → (chan, id); anything else → (None, None)."""
    m = re.search(r"t\.me/([A-Za-z0-9_]+)/(\d+)", href or "")
    if not m:
        return None, None
    return m.group(1), int(m.group(2))


def parse_preview_html(html: str) -> list["Message"]:
    soup = BeautifulSoup(html, "html.parser")
    out = []
    for div in soup.select("div.tgme_widget_message[data-post]"):
        channel, _, msg_id = div["data-post"].partition("/")
        if not msg_id.isdigit():
            continue

        text_el = div.select_one(".tgme_widget_message_text")
        text = text_el.get_text("\n", strip=True) if text_el else ""

        time_el = div.select_one(".tgme_widget_message_date time[datetime]")
        date = time_el["datetime"] if time_el else ""

        views_el = div.select_one(".tgme_widget_message_views")
        views = parse_views(views_el.get_text()) if views_el else None

        fwd_chan = fwd_id = None
        fwd_el = div.select_one("a.tgme_widget_message_forwarded_from_name[href]")
        if fwd_el:
            fwd_chan, fwd_id = _link_target(fwd_el["href"])

        reply_id = None
        reply_el = div.select_one("a.tgme_widget_message_reply[href]")
        if reply_el:
            _, reply_id = _link_target(reply_el["href"])

        media_type = media_ref = None
        photo = div.select_one(".tgme_widget_message_photo_wrap[style]")
        video = div.select_one("video[src]")
        doc = div.select_one(".tgme_widget_message_document_title")
        if photo:
            media_type = "photo"
            m = re.search(r"url\('([^']+)'\)", photo["style"])
            media_ref = m.group(1) if m else None
        elif video:
            media_type = "video"
            src = video.get("src") or ""
            media_ref = src or None
        elif doc:
            media_type = "document"
            media_ref = doc.get_text(strip=True)

        out.append(Message(channel=channel, msg_id=int(msg_id), date=date,
                           text=text, views=views,
                           fwd_from_channel=fwd_chan, fwd_from_msg_id=fwd_id,
                           reply_to_msg_id=reply_id,
                           media_type=media_type, media_ref=media_ref))
    out.sort(key=lambda m: m.msg_id)
    return out


def fetch_page(username: str, before: int | None, session: requests.Session,
                vpn_check=None) -> str:
    """Fetch one t.me/s/<username> page.

    F2 hardening: the ProtonVPN gate is enforced HERE, at the network
    boundary, not only at call sites -- so ungated access to Telegram is
    structurally impossible rather than merely conventional. vpn_check is
    injectable for tests; production callers get the real gate
    (tools.social.telegram.vpn_gate.proton_vpn_active) by default.
    """
    check = vpn_check if vpn_check is not None else proton_vpn_active
    if not check():
        raise VPNNotActiveError(
            "ProtonVPN not active — refusing to contact Telegram")
    url = f"https://t.me/s/{username}"
    params = {"before": before} if before is not None else {}
    try:
        resp = session.get(url, params=params,
                           headers={"User-Agent": USER_AGENT}, timeout=30,
                           allow_redirects=True)
        resp.raise_for_status()
        if "tgme_widget_message_wrap" not in resp.text:
            # Channels without a preview redirect to the join page.
            raise NoPreviewError(f"{username}: no public web preview")
        return resp.text
    finally:
        # The delay must always run -- including on HTTP errors (e.g. 429s)
        # and no-preview channels -- so a caller looping over many channels
        # never hammers Telegram with zero delay on failure paths.
        time.sleep(PAGE_DELAY_SECONDS + random.uniform(0.0, 1.5))
