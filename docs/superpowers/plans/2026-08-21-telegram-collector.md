# Telegram Public-Channel Collector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collect public Telegram channels of the German far-right milieu (text, metadata, forward provenance) via the no-account `t.me/s/` web preview, with human-reviewed seed + snowball channel lists, gap-honest reconciliation, and a daily launchd job.

**Architecture:** Pure-Python pipeline under `tools/social/telegram/`, writing SQLite at `/Volumes/Eregion/bluex-data/social/telegram.db`. A parser module turns `t.me/s/<channel>` HTML into message rows; a store module owns schema/upserts/coverage; a collector walks history backwards with crash-safe resume cursors; a candidates module accumulates forward-graph evidence for user review; a launchd job runs daily incremental collection.

**Tech Stack:** Python 3 (system `python3`), `requests` + `beautifulsoup4` (only external deps), `sqlite3` stdlib, `unittest` stdlib for tests, launchd for scheduling.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-21-telegram-collector-design.md`. Read it if a requirement seems ambiguous; the spec governs.
- **Route 1 only:** all collection via `https://t.me/s/<username>`; MTProto/Telethon is NOT authorized by this plan.
- **Public channels only. No media downloads** — `media_ref` stores URLs/identifiers, never file contents.
- Data lives at `/Volumes/Eregion/bluex-data/social/` — **nothing under `/Volumes` is ever committed to git.**
- Consumers open the DB read-only with `?mode=ro` (never `?immutable=1`).
- **No message is collected from a channel whose `status` is not `seed_approved` or `snowball_approved`.**
- Politeness: ≥2s + jitter between HTTP requests, descriptive User-Agent `BlueX-Research-Collector/1.0 (+academic research; contact keyan.zahedi@gmail.com)`, back-off on 429/5xx.
- Reconciliation: a run reports success **only if** every approved channel either completed or recorded a failure reason; ID gaps are recorded in `coverage.gap_ids_json`, never silently skipped.
- Tests: `unittest`, run via `python3 -m unittest discover -s tools/social/telegram/tests -v` from repo root. **Watch every new test fail before making it pass** (TDD).
- Snowball proposal threshold: forwarded-from by **≥3 distinct tracked channels or ≥20 total forwards**.
- Do not run `tools/install-jobs.sh` — the continuous Bluesky scraper runs from installed binaries; job installation is coordinated manually by the session controller.
- Commit after each task with the trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

## File Structure

```
tools/social/telegram/
  preview.py        # fetch + parse t.me/s/ HTML → Message dataclasses
  store.py          # schema, upserts, cursors, coverage/gaps
  seeds.py          # seed CSV import CLI
  channels.py       # approve/reject/retire CLI
  candidates.py     # snowball evidence accumulation + review-queue CLI
  collect.py        # backfill/incremental collector CLI + reconciliation report
  seed_channels.csv # the researched seed list (deliverable, user-reviewed)
  tests/
    __init__.py
    fixtures/tgme_sample.html
    fixtures/tgme_sample_expected.json
    test_preview.py
    test_store.py
    test_seeds.py
    test_candidates.py
    test_collect.py
tools/jobs/bluex-telegram-daily.sh
tools/jobs/net.pulsschlag.bluex.telegram.daily.plist
```

---

### Task 1: Web-preview parser with live-captured golden fixture

**Files:**
- Create: `tools/social/telegram/__init__.py` (empty), `tools/social/telegram/preview.py`
- Create: `tools/social/telegram/tests/__init__.py` (empty), `tools/social/telegram/tests/test_preview.py`
- Create: `tools/social/telegram/tests/fixtures/tgme_sample.html`, `tools/social/telegram/tests/fixtures/tgme_sample_expected.json`

**Interfaces:**
- Produces: `Message` dataclass (fields: `channel:str, msg_id:int, date:str, text:str, views:int|None, fwd_from_channel:str|None, fwd_from_msg_id:int|None, reply_to_msg_id:int|None, media_type:str|None, media_ref:str|None`); `parse_preview_html(html: str) -> list[Message]` (ascending `msg_id`); `parse_views(s: str) -> int` ("1.2K"→1200, "3.4M"→3400000, "882"→882); `fetch_page(username: str, before: int|None, session) -> str` (raises `NoPreviewError` when the channel has no web preview); `PAGE_DELAY_SECONDS = 2.0` base delay constant.

- [ ] **Step 1: Ensure dependencies**

Run: `python3 -c "import requests, bs4" 2>/dev/null || python3 -m pip install --user requests beautifulsoup4`

- [ ] **Step 2: Capture the live fixture**

Telegram's own public channel is stable and harmless for a fixture:

```bash
curl -s -A "BlueX-Research-Collector/1.0 (+academic research; contact keyan.zahedi@gmail.com)" \
  "https://t.me/s/telegram" -o tools/social/telegram/tests/fixtures/tgme_sample.html
grep -c "tgme_widget_message_wrap" tools/social/telegram/tests/fixtures/tgme_sample.html
```

Expected: a count ≥ 10. If 0, the page layout changed — STOP and report BLOCKED with the first 50 lines of the file.

- [ ] **Step 3: Write the failing structural test**

`tools/social/telegram/tests/test_preview.py`:

```python
import json
import pathlib
import unittest

FIXTURES = pathlib.Path(__file__).parent / "fixtures"


class TestParsePreview(unittest.TestCase):
    def setUp(self):
        self.html = (FIXTURES / "tgme_sample.html").read_text(encoding="utf-8")

    def test_parses_messages_with_required_fields(self):
        from tools.social.telegram.preview import parse_preview_html
        msgs = parse_preview_html(self.html)
        self.assertGreaterEqual(len(msgs), 10)
        ids = [m.msg_id for m in msgs]
        self.assertEqual(ids, sorted(ids))          # ascending
        self.assertEqual(len(ids), len(set(ids)))   # unique
        for m in msgs:
            self.assertEqual(m.channel, "telegram")
            self.assertIsInstance(m.msg_id, int)
            # ISO-8601 with timezone, e.g. 2024-05-01T12:34:56+00:00
            self.assertRegex(m.date, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")
        self.assertTrue(any(m.views is not None for m in msgs))

    def test_matches_committed_snapshot(self):
        from tools.social.telegram.preview import parse_preview_html
        expected = json.loads((FIXTURES / "tgme_sample_expected.json").read_text())
        got = [vars(m) for m in parse_preview_html(self.html)]
        self.assertEqual(got, expected)


class TestParseViews(unittest.TestCase):
    def test_plain_k_m(self):
        from tools.social.telegram.preview import parse_views
        self.assertEqual(parse_views("882"), 882)
        self.assertEqual(parse_views("1.2K"), 1200)
        self.assertEqual(parse_views("3.4M"), 3400000)


if __name__ == "__main__":
    unittest.main()
```

(`tgme_sample_expected.json` does not exist yet; that test fails on the missing file — fine for now.)

- [ ] **Step 4: Run tests, watch them fail**

Run: `python3 -m unittest tools.social.telegram.tests.test_preview -v` (from repo root)
Expected: FAIL/ERROR with `ModuleNotFoundError` or `ImportError` (preview module absent).

- [ ] **Step 5: Implement `preview.py`**

```python
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
        video = div.select_one(".tgme_widget_message_video_player, video.tgme_widget_message_video")
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


def fetch_page(username: str, before: int | None, session: requests.Session) -> str:
    url = f"https://t.me/s/{username}"
    params = {"before": before} if before else {}
    resp = session.get(url, params=params,
                       headers={"User-Agent": USER_AGENT}, timeout=30,
                       allow_redirects=True)
    resp.raise_for_status()
    if "tgme_widget_message_wrap" not in resp.text:
        # Channels without a preview redirect to the join page.
        raise NoPreviewError(f"{username}: no public web preview")
    time.sleep(PAGE_DELAY_SECONDS + random.uniform(0.0, 1.5))
    return resp.text
```

- [ ] **Step 6: Generate and commit the snapshot**

```bash
python3 - <<'EOF'
import json, pathlib
from tools.social.telegram.preview import parse_preview_html
fx = pathlib.Path("tools/social/telegram/tests/fixtures")
msgs = parse_preview_html((fx / "tgme_sample.html").read_text(encoding="utf-8"))
(fx / "tgme_sample_expected.json").write_text(
    json.dumps([vars(m) for m in msgs], ensure_ascii=False, indent=1))
print(len(msgs), "messages snapshotted")
EOF
```

Expected: `N messages snapshotted` with N ≥ 10. Open the JSON and eyeball 2–3 entries against the HTML (ids, dates, one forward if present) before trusting it.

- [ ] **Step 7: Run tests, watch them pass**

Run: `python3 -m unittest tools.social.telegram.tests.test_preview -v`
Expected: all tests PASS.

- [ ] **Step 8: Commit**

```bash
git add tools/social/telegram
git commit -m "feat(telegram): web-preview parser with live-captured golden fixture"
```

---

### Task 2: Store — schema, upserts, cursors, coverage with gap honesty

**Files:**
- Create: `tools/social/telegram/store.py`
- Test: `tools/social/telegram/tests/test_store.py`

**Interfaces:**
- Consumes: `Message` from `preview.py`.
- Produces: `open_db(path: str) -> sqlite3.Connection` (creates schema, WAL); `upsert_messages(conn, msgs: list[Message]) -> int` (inserted count; re-runs are idempotent); `set_cursor(conn, channel: str, before: int|None)` / `get_cursor(conn, channel: str) -> int|None`; `record_coverage(conn, channel: str)` (recomputes per-day rows incl. `gap_ids_json`); `channel_status(conn, username: str) -> str|None`; `APPROVED = ("seed_approved", "snowball_approved")`.

- [ ] **Step 1: Write the failing tests**

`tools/social/telegram/tests/test_store.py`:

```python
import json
import unittest

from tools.social.telegram.preview import Message


def make_msg(msg_id, date="2026-08-01T10:00:00+00:00", fwd=None):
    return Message(channel="testchan", msg_id=msg_id, date=date, text=f"m{msg_id}",
                   views=10, fwd_from_channel=fwd, fwd_from_msg_id=None,
                   reply_to_msg_id=None, media_type=None, media_ref=None)


class TestStore(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")

    def test_upsert_is_idempotent(self):
        from tools.social.telegram.store import upsert_messages
        msgs = [make_msg(1), make_msg(2)]
        self.assertEqual(upsert_messages(self.conn, msgs), 2)
        self.assertEqual(upsert_messages(self.conn, msgs), 0)
        n, = self.conn.execute("SELECT COUNT(*) FROM messages").fetchone()
        self.assertEqual(n, 2)

    def test_cursor_roundtrip_and_clear(self):
        from tools.social.telegram.store import set_cursor, get_cursor
        self.assertIsNone(get_cursor(self.conn, "testchan"))
        set_cursor(self.conn, "testchan", 500)
        self.assertEqual(get_cursor(self.conn, "testchan"), 500)
        set_cursor(self.conn, "testchan", None)
        self.assertIsNone(get_cursor(self.conn, "testchan"))

    def test_coverage_records_gaps_not_silence(self):
        from tools.social.telegram.store import upsert_messages, record_coverage
        # ids 1,2,5 on one day: 3 and 4 are a gap that MUST be recorded
        upsert_messages(self.conn, [make_msg(1), make_msg(2), make_msg(5)])
        record_coverage(self.conn, "testchan")
        row = self.conn.execute(
            "SELECT message_count, min_msg_id, max_msg_id, gap_ids_json "
            "FROM coverage WHERE channel='testchan' AND day='2026-08-01'").fetchone()
        self.assertEqual(row[0], 3)
        self.assertEqual((row[1], row[2]), (1, 5))
        self.assertEqual(json.loads(row[3]), [3, 4])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run, watch fail** — `python3 -m unittest tools.social.telegram.tests.test_store -v` → ImportError.

- [ ] **Step 3: Implement `store.py`**

```python
"""SQLite store for the Telegram collector (schema per design spec §5)."""
import json
import sqlite3

APPROVED = ("seed_approved", "snowball_approved")

_SCHEMA = """
CREATE TABLE IF NOT EXISTS channels(
  username TEXT PRIMARY KEY, title TEXT, source_list TEXT,
  inclusion_criterion TEXT, status TEXT NOT NULL,
  added_at TEXT DEFAULT (datetime('now')), decided_by_user_at TEXT);
CREATE TABLE IF NOT EXISTS messages(
  channel TEXT NOT NULL, msg_id INTEGER NOT NULL, date TEXT, text TEXT,
  views INTEGER, fwd_from_channel TEXT, fwd_from_msg_id INTEGER,
  reply_to_msg_id INTEGER, media_type TEXT, media_ref TEXT,
  source_route TEXT DEFAULT 'web_preview',
  fetched_at TEXT DEFAULT (datetime('now')),
  PRIMARY KEY (channel, msg_id));
CREATE INDEX IF NOT EXISTS idx_messages_fwd ON messages(fwd_from_channel);
CREATE TABLE IF NOT EXISTS candidates(
  username TEXT PRIMARY KEY, forward_evidence_count INTEGER DEFAULT 0,
  distinct_forwarders INTEGER DEFAULT 0,
  first_seen TEXT DEFAULT (datetime('now')),
  status TEXT DEFAULT 'pending', decided_at TEXT);
CREATE TABLE IF NOT EXISTS coverage(
  channel TEXT NOT NULL, day TEXT NOT NULL, message_count INTEGER,
  min_msg_id INTEGER, max_msg_id INTEGER, gap_ids_json TEXT,
  PRIMARY KEY (channel, day));
CREATE TABLE IF NOT EXISTS cursors(
  channel TEXT PRIMARY KEY, before INTEGER);
"""


def open_db(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.executescript(_SCHEMA)
    return conn


def upsert_messages(conn, msgs) -> int:
    inserted = 0
    for m in msgs:
        cur = conn.execute(
            "INSERT OR IGNORE INTO messages(channel, msg_id, date, text, views,"
            " fwd_from_channel, fwd_from_msg_id, reply_to_msg_id, media_type,"
            " media_ref) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (m.channel, m.msg_id, m.date, m.text, m.views, m.fwd_from_channel,
             m.fwd_from_msg_id, m.reply_to_msg_id, m.media_type, m.media_ref))
        inserted += cur.rowcount
    conn.commit()
    return inserted


def set_cursor(conn, channel: str, before) -> None:
    if before is None:
        conn.execute("DELETE FROM cursors WHERE channel=?", (channel,))
    else:
        conn.execute(
            "INSERT INTO cursors(channel, before) VALUES (?,?) "
            "ON CONFLICT(channel) DO UPDATE SET before=excluded.before",
            (channel, before))
    conn.commit()


def get_cursor(conn, channel: str):
    row = conn.execute("SELECT before FROM cursors WHERE channel=?",
                       (channel,)).fetchone()
    return row[0] if row else None


def channel_status(conn, username: str):
    row = conn.execute("SELECT status FROM channels WHERE username=?",
                       (username,)).fetchone()
    return row[0] if row else None


def record_coverage(conn, channel: str) -> None:
    """Recompute per-day coverage. Gaps are ids missing INSIDE a day's range —
    recorded as data (deleted/unavailable), never silently dropped."""
    days = conn.execute(
        "SELECT substr(date,1,10) d, COUNT(*), MIN(msg_id), MAX(msg_id) "
        "FROM messages WHERE channel=? GROUP BY d", (channel,)).fetchall()
    for day, count, lo, hi in days:
        present = {r[0] for r in conn.execute(
            "SELECT msg_id FROM messages WHERE channel=? "
            "AND substr(date,1,10)=?", (channel, day))}
        gaps = [i for i in range(lo, hi + 1) if i not in present]
        conn.execute(
            "INSERT INTO coverage(channel, day, message_count, min_msg_id,"
            " max_msg_id, gap_ids_json) VALUES (?,?,?,?,?,?) "
            "ON CONFLICT(channel, day) DO UPDATE SET message_count=excluded."
            "message_count, min_msg_id=excluded.min_msg_id, max_msg_id=excluded."
            "max_msg_id, gap_ids_json=excluded.gap_ids_json",
            (channel, day, count, lo, hi, json.dumps(gaps)))
    conn.commit()
```

- [ ] **Step 4: Run, watch pass** — `python3 -m unittest tools.social.telegram.tests.test_store -v` → PASS.

- [ ] **Step 5: Commit** — `git add tools/social/telegram && git commit -m "feat(telegram): sqlite store with cursors and gap-honest coverage"`

---

### Task 3: Seed list research + import CLI + approval CLI

**Files:**
- Create: `tools/social/telegram/seed_channels.csv`, `tools/social/telegram/seeds.py`, `tools/social/telegram/channels.py`
- Test: `tools/social/telegram/tests/test_seeds.py`

**Interfaces:**
- Consumes: `open_db`, `channel_status` from `store.py`.
- Produces: `seed_channels.csv` columns exactly `username,title,source_list,inclusion_criterion`; `python3 tools/social/telegram/seeds.py import --db PATH --csv PATH` (inserts rows as `status='seed_pending'`; re-import never overwrites a decided status); `python3 tools/social/telegram/channels.py approve|reject|retire USERNAME --db PATH` and `channels.py list --db PATH [--status S]`; approving a `seed_pending` channel sets `status='seed_approved'` and `decided_by_user_at`.

- [ ] **Step 1: Research the seed list (WebSearch/WebFetch)**

Compile 30–60 public German-language far-right/conspiracy-milieu channels from **published research only**: CeMAS publications (e.g. their Telegram monitoring reports), ISD Germany reports, Amadeu Antonio Stiftung monitoring. For each channel write one CSV row; `source_list` names the exact publication (title + year), `inclusion_criterion` quotes or paraphrases the report's categorisation (e.g. `"CeMAS 2022 'Telegram-Radikalisierung' — Q-adjacent conspiracy channel"`). Do NOT invent channels; if a report names fewer, a shorter list is correct. Verify each username still resolves (`curl -sI https://t.me/s/<username>` → HTTP 200) and note dead ones with `inclusion_criterion` suffix `" (unreachable 2026-08)"` — keep the row; churn is data. All rows enter as `seed_pending`; **the user approves via channels.py — the implementer never approves channels.**

- [ ] **Step 2: Write the failing tests**

`tools/social/telegram/tests/test_seeds.py`:

```python
import csv
import io
import pathlib
import unittest


class TestSeedCsv(unittest.TestCase):
    def test_csv_well_formed_with_provenance(self):
        p = pathlib.Path("tools/social/telegram/seed_channels.csv")
        rows = list(csv.DictReader(p.open(encoding="utf-8")))
        self.assertGreaterEqual(len(rows), 30)
        for r in rows:
            self.assertRegex(r["username"], r"^[A-Za-z0-9_]{4,}$")
            self.assertTrue(r["source_list"].strip())
            self.assertTrue(r["inclusion_criterion"].strip())


class TestImportAndApprove(unittest.TestCase):
    def test_import_pending_then_approve(self):
        from tools.social.telegram.store import open_db
        from tools.social.telegram.seeds import import_csv
        from tools.social.telegram.channels import decide
        conn = open_db(":memory:")
        csv_text = ("username,title,source_list,inclusion_criterion\n"
                    "somechan,Some Chan,Report X 2022,category Y\n")
        n = import_csv(conn, io.StringIO(csv_text))
        self.assertEqual(n, 1)
        row = conn.execute("SELECT status FROM channels WHERE username='somechan'").fetchone()
        self.assertEqual(row[0], "seed_pending")
        decide(conn, "somechan", "approve")
        status, decided = conn.execute(
            "SELECT status, decided_by_user_at FROM channels "
            "WHERE username='somechan'").fetchone()
        self.assertEqual(status, "seed_approved")
        self.assertIsNotNone(decided)
        # re-import must not clobber the decision
        import_csv(conn, io.StringIO(csv_text))
        self.assertEqual(conn.execute(
            "SELECT status FROM channels WHERE username='somechan'"
        ).fetchone()[0], "seed_approved")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 3: Run, watch fail** — `python3 -m unittest tools.social.telegram.tests.test_seeds -v` → ImportError / missing CSV.

- [ ] **Step 4: Implement `seeds.py` and `channels.py`**

`seeds.py`:

```python
"""Import the researched seed list. Rows land as seed_pending — only the user
promotes them (channels.py approve). Re-import never overwrites decisions."""
import argparse
import csv


def import_csv(conn, fp) -> int:
    n = 0
    for r in csv.DictReader(fp):
        cur = conn.execute(
            "INSERT INTO channels(username, title, source_list,"
            " inclusion_criterion, status) VALUES (?,?,?,?,'seed_pending') "
            "ON CONFLICT(username) DO NOTHING",
            (r["username"], r["title"], r["source_list"],
             r["inclusion_criterion"]))
        n += cur.rowcount
    conn.commit()
    return n


if __name__ == "__main__":
    from tools.social.telegram.store import open_db
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    imp = sub.add_parser("import")
    imp.add_argument("--db", required=True)
    imp.add_argument("--csv", required=True)
    args = ap.parse_args()
    with open(args.csv, encoding="utf-8") as fp:
        print(f"imported {import_csv(open_db(args.db), fp)} new channels (seed_pending)")
```

`channels.py`:

```python
"""User decision CLI: approve / reject / retire channels; list by status."""
import argparse

_TRANSITIONS = {
    "approve": {"seed_pending": "seed_approved", "pending": "snowball_approved"},
    "reject": {"seed_pending": "rejected", "pending": "rejected"},
    "retire": {"seed_approved": "retired", "snowball_approved": "retired"},
}


def decide(conn, username: str, action: str) -> str:
    row = conn.execute("SELECT status FROM channels WHERE username=?",
                       (username,)).fetchone()
    if row is None:
        raise SystemExit(f"unknown channel: {username}")
    new = _TRANSITIONS[action].get(row[0])
    if new is None:
        raise SystemExit(f"cannot {action} channel in status {row[0]}")
    conn.execute("UPDATE channels SET status=?, decided_by_user_at="
                 "datetime('now') WHERE username=?", (new, username))
    conn.commit()
    return new


if __name__ == "__main__":
    from tools.social.telegram.store import open_db
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["approve", "reject", "retire", "list"])
    ap.add_argument("username", nargs="?")
    ap.add_argument("--db", required=True)
    ap.add_argument("--status")
    args = ap.parse_args()
    conn = open_db(args.db)
    if args.action == "list":
        q = "SELECT username, status, source_list FROM channels"
        rows = (conn.execute(q + " WHERE status=?", (args.status,))
                if args.status else conn.execute(q)).fetchall()
        for u, s, src in rows:
            print(f"{s:20s} {u:30s} {src}")
    else:
        if not args.username:
            raise SystemExit("username required")
        print(f"{args.username} -> {decide(conn, args.username, args.action)}")
```

Note: `decide()` also handles snowball candidates' channel rows later — Task 5 inserts candidate channels with `status='pending'`.

- [ ] **Step 5: Run, watch pass** — `python3 -m unittest tools.social.telegram.tests.test_seeds -v` → PASS.

- [ ] **Step 6: Commit** — `git add tools/social/telegram && git commit -m "feat(telegram): researched seed list with provenance, import + approval CLIs"`

---

### Task 4: Snowball candidate accumulation + review-queue CLI

**Files:**
- Create: `tools/social/telegram/candidates.py`
- Test: `tools/social/telegram/tests/test_candidates.py`

**Interfaces:**
- Consumes: `store.py` (`open_db`, `APPROVED`), `channels.decide`.
- Produces: `update_candidates(conn) -> None` (recomputes `candidates` from `messages.fwd_from_channel`, excluding usernames already in `channels`); `proposal_ready(conn) -> list[tuple]` (rows meeting the threshold: `distinct_forwarders >= 3 OR forward_evidence_count >= 20`, status `pending`); CLI `python3 tools/social/telegram/candidates.py report --db PATH` and `... approve|reject USERNAME --db PATH` (approve inserts a `channels` row `status='snowball_approved'`, `source_list='snowball'`, `inclusion_criterion='forwarded-from evidence: <counts>'`, and stamps `candidates.decided_at`).

- [ ] **Step 1: Write the failing tests**

`tools/social/telegram/tests/test_candidates.py`:

```python
import unittest

from tools.social.telegram.preview import Message


def fwd_msg(channel, msg_id, fwd):
    return Message(channel=channel, msg_id=msg_id,
                   date="2026-08-01T10:00:00+00:00", text="x", views=None,
                   fwd_from_channel=fwd, fwd_from_msg_id=1,
                   reply_to_msg_id=None, media_type=None, media_ref=None)


class TestSnowball(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db, upsert_messages
        self.conn = open_db(":memory:")
        self.upsert = upsert_messages

    def test_threshold_three_distinct_forwarders(self):
        from tools.social.telegram.candidates import update_candidates, proposal_ready
        self.upsert(self.conn, [fwd_msg("a", 1, "newchan"),
                                fwd_msg("b", 1, "newchan")])
        update_candidates(self.conn)
        self.assertEqual(proposal_ready(self.conn), [])   # 2 distinct: below
        self.upsert(self.conn, [fwd_msg("c", 1, "newchan")])
        update_candidates(self.conn)
        ready = proposal_ready(self.conn)
        self.assertEqual(len(ready), 1)
        self.assertEqual(ready[0][0], "newchan")

    def test_threshold_twenty_total_forwards(self):
        from tools.social.telegram.candidates import update_candidates, proposal_ready
        self.upsert(self.conn, [fwd_msg("a", i, "loudchan") for i in range(1, 21)])
        update_candidates(self.conn)
        self.assertEqual([r[0] for r in proposal_ready(self.conn)], ["loudchan"])

    def test_tracked_channels_never_become_candidates(self):
        from tools.social.telegram.candidates import update_candidates
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('a', 'seed_approved')")
        self.upsert(self.conn, [fwd_msg("b", i, "a") for i in range(1, 30)])
        update_candidates(self.conn)
        n, = self.conn.execute("SELECT COUNT(*) FROM candidates").fetchone()
        self.assertEqual(n, 0)

    def test_approve_creates_snowball_channel(self):
        from tools.social.telegram.candidates import (update_candidates,
                                                      approve_candidate)
        self.upsert(self.conn, [fwd_msg(c, 1, "newchan") for c in "abc"])
        update_candidates(self.conn)
        approve_candidate(self.conn, "newchan")
        status, src = self.conn.execute(
            "SELECT status, source_list FROM channels "
            "WHERE username='newchan'").fetchone()
        self.assertEqual((status, src), ("snowball_approved", "snowball"))
        decided, = self.conn.execute(
            "SELECT decided_at FROM candidates WHERE username='newchan'").fetchone()
        self.assertIsNotNone(decided)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run, watch fail** → ImportError.

- [ ] **Step 3: Implement `candidates.py`**

```python
"""Snowball with human review: forward sources accumulate evidence; nothing is
collected until the user approves (design spec §4). Thresholds: >=3 distinct
forwarders OR >=20 total forwards."""
import argparse


def update_candidates(conn) -> None:
    rows = conn.execute(
        "SELECT fwd_from_channel, COUNT(*), COUNT(DISTINCT channel) "
        "FROM messages WHERE fwd_from_channel IS NOT NULL "
        "AND fwd_from_channel NOT IN (SELECT username FROM channels) "
        "GROUP BY fwd_from_channel").fetchall()
    for username, total, distinct in rows:
        conn.execute(
            "INSERT INTO candidates(username, forward_evidence_count,"
            " distinct_forwarders) VALUES (?,?,?) "
            "ON CONFLICT(username) DO UPDATE SET forward_evidence_count=?,"
            " distinct_forwarders=?",
            (username, total, distinct, total, distinct))
    conn.commit()


def proposal_ready(conn) -> list:
    return conn.execute(
        "SELECT username, forward_evidence_count, distinct_forwarders, first_seen "
        "FROM candidates WHERE status='pending' "
        "AND (distinct_forwarders >= 3 OR forward_evidence_count >= 20) "
        "ORDER BY forward_evidence_count DESC").fetchall()


def approve_candidate(conn, username: str) -> None:
    row = conn.execute("SELECT forward_evidence_count, distinct_forwarders "
                       "FROM candidates WHERE username=?", (username,)).fetchone()
    if row is None:
        raise SystemExit(f"not a candidate: {username}")
    conn.execute(
        "INSERT INTO channels(username, title, source_list, inclusion_criterion,"
        " status, decided_by_user_at) VALUES (?, ?, 'snowball', ?,"
        " 'snowball_approved', datetime('now'))",
        (username, username,
         f"forwarded-from evidence: {row[0]} forwards, {row[1]} distinct forwarders"))
    conn.execute("UPDATE candidates SET status='approved',"
                 " decided_at=datetime('now') WHERE username=?", (username,))
    conn.commit()


def reject_candidate(conn, username: str) -> None:
    conn.execute("UPDATE candidates SET status='rejected',"
                 " decided_at=datetime('now') WHERE username=?", (username,))
    conn.commit()


if __name__ == "__main__":
    from tools.social.telegram.store import open_db
    ap = argparse.ArgumentParser()
    ap.add_argument("action", choices=["report", "approve", "reject"])
    ap.add_argument("username", nargs="?")
    ap.add_argument("--db", required=True)
    args = ap.parse_args()
    conn = open_db(args.db)
    if args.action == "report":
        update_candidates(conn)
        rows = proposal_ready(conn)
        if not rows:
            print("no candidates over threshold")
        for u, total, distinct, seen in rows:
            print(f"{u:30s} {total:5d} forwards  {distinct:3d} forwarders  first seen {seen}")
    elif args.action == "approve":
        approve_candidate(conn, args.username)
        print(f"{args.username} -> snowball_approved")
    else:
        reject_candidate(conn, args.username)
        print(f"{args.username} -> rejected")
```

- [ ] **Step 4: Run, watch pass** — `python3 -m unittest tools.social.telegram.tests.test_candidates -v` → PASS.

- [ ] **Step 5: Commit** — `git add tools/social/telegram && git commit -m "feat(telegram): snowball candidates with review-gated approval"`

---

### Task 5: Collector — backfill/incremental with resume cursors and reconciliation

**Files:**
- Create: `tools/social/telegram/collect.py`
- Test: `tools/social/telegram/tests/test_collect.py`

**Interfaces:**
- Consumes: everything above. HTTP is injected: `collect_channel(conn, username, fetch, mode, max_pages=None) -> dict` takes `fetch(username, before) -> str` so tests pass a fake; production wires `preview.fetch_page` with a shared `requests.Session`.
- Produces: `collect_channel(...) -> {"channel", "status" ("complete"|"failed"), "new_messages", "failure_reason"}`; `run(conn, fetch, mode, max_pages=None) -> dict` over all approved channels — report `{"channels": [...], "ok": bool}` where `ok` is True **only if every approved channel is complete or carries a failure_reason**; CLI `python3 tools/social/telegram/collect.py --db PATH --mode backfill|incremental [--channel U] [--max-pages N]`, exit code 0 iff `ok`.

**Backfill semantics:** start from `get_cursor()` (or newest page if none); after parsing each page, `upsert_messages`, then `set_cursor(channel, oldest_msg_id_seen)`; stop when a page yields no messages or only already-known ids with `min(msg_id) == 1`; on completion `set_cursor(channel, None)` and `record_coverage`. A crash resumes from the cursor. **Incremental semantics:** fetch newest pages (no `before`) until a page contains only already-stored ids; never touches the backfill cursor; runs `update_candidates` and `record_coverage` at the end.

- [ ] **Step 1: Write the failing tests**

`tools/social/telegram/tests/test_collect.py`:

```python
import unittest

from tools.social.telegram.preview import NoPreviewError


def page_html(channel, ids):
    """Minimal t.me/s-shaped HTML the parser accepts."""
    msgs = "".join(
        f'<div class="tgme_widget_message" data-post="{channel}/{i}">'
        f'<div class="tgme_widget_message_text">msg {i}</div>'
        f'<span class="tgme_widget_message_views">5</span>'
        f'<a class="tgme_widget_message_date" href="https://t.me/{channel}/{i}">'
        f'<time datetime="2026-08-01T10:00:{i % 60:02d}+00:00"></time></a></div>'
        for i in ids)
    return f'<html><body class="tgme_widget_message_wrap">{msgs}</body></html>'


def make_fake_fetch(channel, all_ids, calls=None):
    """Serves pages of 5 ids, newest first, honouring ?before like t.me/s."""
    def fetch(username, before):
        if calls is not None:
            calls.append(before)
        older = sorted(i for i in all_ids if before is None or i < before)
        page = older[-5:]
        return page_html(channel, page)
    return fetch


class TestCollect(unittest.TestCase):
    def setUp(self):
        from tools.social.telegram.store import open_db
        self.conn = open_db(":memory:")
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('chan', 'seed_approved')")
        self.conn.commit()

    def test_backfill_walks_to_start_and_clears_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import get_cursor
        fetch = make_fake_fetch("chan", list(range(1, 14)))
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "complete")
        self.assertEqual(r["new_messages"], 13)
        self.assertIsNone(get_cursor(self.conn, "chan"))

    def test_backfill_resumes_from_cursor(self):
        from tools.social.telegram.collect import collect_channel
        from tools.social.telegram.store import set_cursor
        calls = []
        fetch = make_fake_fetch("chan", list(range(1, 14)), calls)
        set_cursor(self.conn, "chan", 6)   # simulate a crash mid-history
        collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(calls[0], 6)      # resumed, not restarted

    def test_no_preview_is_recorded_failure_not_crash(self):
        from tools.social.telegram.collect import collect_channel
        def fetch(username, before):
            raise NoPreviewError("chan: no public web preview")
        r = collect_channel(self.conn, "chan", fetch, mode="backfill")
        self.assertEqual(r["status"], "failed")
        self.assertIn("no public web preview", r["failure_reason"])

    def test_run_ok_requires_every_channel_accounted_for(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('dead', 'seed_approved')")
        good = make_fake_fetch("chan", [1, 2, 3])
        def fetch(username, before):
            if username == "dead":
                raise NoPreviewError("dead: no public web preview")
            return good(username, before)
        report = run(self.conn, fetch, mode="backfill")
        self.assertTrue(report["ok"])      # failed-with-reason counts as accounted
        statuses = {c["channel"]: c["status"] for c in report["channels"]}
        self.assertEqual(statuses, {"chan": "complete", "dead": "failed"})

    def test_unapproved_channels_never_collected(self):
        from tools.social.telegram.collect import run
        self.conn.execute("INSERT INTO channels(username, status) "
                          "VALUES ('pendingchan', 'seed_pending')")
        fetch = make_fake_fetch("chan", [1, 2])
        report = run(self.conn, fetch, mode="backfill")
        self.assertNotIn("pendingchan", [c["channel"] for c in report["channels"]])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run, watch fail** → ImportError.

- [ ] **Step 3: Implement `collect.py`**

```python
"""Backfill / incremental collector over approved channels (spec §5-§6).

Reconciliation rule: run() reports ok=True only when every approved channel
either completed or recorded its failure reason. Silence is the failure mode
being designed out."""
import argparse
import json

import requests

from tools.social.telegram.preview import (NoPreviewError, fetch_page,
                                           parse_preview_html)
from tools.social.telegram.store import (APPROVED, get_cursor, open_db,
                                         record_coverage, set_cursor,
                                         upsert_messages)
from tools.social.telegram.candidates import update_candidates


def collect_channel(conn, username, fetch, mode, max_pages=None):
    new_total, pages = 0, 0
    try:
        before = get_cursor(conn, username) if mode == "backfill" else None
        while True:
            if max_pages is not None and pages >= max_pages:
                return {"channel": username, "status": "failed",
                        "new_messages": new_total,
                        "failure_reason": f"page budget exhausted ({max_pages})"}
            msgs = parse_preview_html(fetch(username, before))
            pages += 1
            if not msgs:
                break
            inserted = upsert_messages(conn, msgs)
            new_total += inserted
            oldest = min(m.msg_id for m in msgs)
            if mode == "backfill":
                set_cursor(conn, username, oldest)
                if oldest <= 1:
                    break
                before = oldest
            else:  # incremental: newest pages until nothing new
                if inserted == 0:
                    break
                before = oldest
        if mode == "backfill":
            set_cursor(conn, username, None)
        record_coverage(conn, username)
        return {"channel": username, "status": "complete",
                "new_messages": new_total, "failure_reason": None}
    except (NoPreviewError, requests.RequestException) as e:
        return {"channel": username, "status": "failed",
                "new_messages": new_total, "failure_reason": str(e)}


def run(conn, fetch, mode, max_pages=None, only_channel=None):
    channels = [r[0] for r in conn.execute(
        "SELECT username FROM channels WHERE status IN (?,?) ORDER BY username",
        APPROVED)]
    if only_channel:
        channels = [c for c in channels if c == only_channel]
    results = [collect_channel(conn, c, fetch, mode, max_pages)
               for c in channels]
    update_candidates(conn)
    ok = all(r["status"] == "complete" or r["failure_reason"] for r in results)
    return {"mode": mode, "channels": results, "ok": ok}


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--mode", choices=["backfill", "incremental"], required=True)
    ap.add_argument("--channel")
    ap.add_argument("--max-pages", type=int)
    args = ap.parse_args()
    conn = open_db(args.db)
    session = requests.Session()
    report = run(conn, lambda u, b: fetch_page(u, b, session), args.mode,
                 max_pages=args.max_pages, only_channel=args.channel)
    print(json.dumps(report, indent=1))
    raise SystemExit(0 if report["ok"] else 1)
```

- [ ] **Step 4: Run, watch pass** — `python3 -m unittest tools.social.telegram.tests.test_collect -v` → PASS. Then run the whole suite: `python3 -m unittest discover -s tools/social/telegram/tests -v` → all PASS.

- [ ] **Step 5: Live smoke test (harmless channel, bounded)**

```bash
mkdir -p /Volumes/Eregion/bluex-data/social
python3 - <<'EOF'
from tools.social.telegram.store import open_db
conn = open_db("/Volumes/Eregion/bluex-data/social/telegram.db")
conn.execute("INSERT OR IGNORE INTO channels(username, title, source_list,"
             " inclusion_criterion, status) VALUES ('telegram', 'Telegram News',"
             " 'smoke test', 'harness validation only', 'seed_approved')")
conn.commit()
EOF
python3 tools/social/telegram/collect.py --db /Volumes/Eregion/bluex-data/social/telegram.db \
  --mode backfill --channel telegram --max-pages 3
sqlite3 "file:/Volumes/Eregion/bluex-data/social/telegram.db?mode=ro" \
  "SELECT COUNT(*), MIN(msg_id), MAX(msg_id) FROM messages WHERE channel='telegram';"
```

Expected: exit 1 with `failure_reason: "page budget exhausted (3)"` (bounded run — correct honesty), and ~40–60 rows in the DB. Then retire the smoke channel: `python3 tools/social/telegram/channels.py retire telegram --db /Volumes/Eregion/bluex-data/social/telegram.db`

- [ ] **Step 6: Commit** — `git add tools/social/telegram && git commit -m "feat(telegram): backfill/incremental collector with resume cursors and reconciliation"`

---

### Task 6: Daily launchd job (script + plist; installation stays manual)

**Files:**
- Create: `tools/jobs/bluex-telegram-daily.sh`, `tools/jobs/net.pulsschlag.bluex.telegram.daily.plist`
- Test: manual dry-run (Step 3) — shell scripts here are validated by running them; mirror `tools/jobs/bluex-continuous.sh` conventions exactly.

**Interfaces:**
- Consumes: `collect.py` CLI (Task 5).
- Produces: heartbeat JSON at `/Volumes/Eregion/bluex-data/social/telegram-heartbeat.json` with keys `ts`, `mode`, `exit`, `ok_channels`, `failed_channels`.

- [ ] **Step 1: Read the existing pattern** — Read `tools/jobs/bluex-continuous.sh` and one existing plist to copy conventions (log dir, EPERM probe, PATH handling).

- [ ] **Step 2: Write `bluex-telegram-daily.sh`**

```bash
#!/bin/zsh
# Daily incremental Telegram collection. One-shot (StartCalendarInterval), not
# KeepAlive: a failed day is retried tomorrow; the heartbeat records the outcome.
set -u
DATA=/Volumes/Eregion/bluex-data/social
LOGDIR=/Volumes/Eregion/bluex-data/logs
REPO=/Volumes/Eregion/projects/bluex-v2
TS=$(date +%Y-%m-%d_%H%M%S)
LOG="$LOGDIR/telegram_${TS}.log"
HEARTBEAT="$DATA/telegram-heartbeat.json"

mkdir -p "$DATA" "$LOGDIR" 2>/dev/null

# Store writability probe (TCC/EPERM = transient, not a crash)
if ! touch "$DATA/.probe" 2>/dev/null; then
  echo "$(date): store not writable (EPERM/TCC?) — skipping run" >> "$HOME/Library/Logs/BlueX/telegram.log"
  exit 0
fi
rm -f "$DATA/.probe"

cd "$REPO" || exit 1
python3 tools/social/telegram/collect.py --db "$DATA/telegram.db" \
  --mode incremental > "$LOG" 2>&1
EXIT=$?

python3 - "$LOG" "$HEARTBEAT" "$EXIT" <<'EOF'
import json, sys, datetime
log, hb, code = sys.argv[1], sys.argv[2], int(sys.argv[3])
ok = failed = 0
try:
    report = json.load(open(log))
    ok = sum(1 for c in report["channels"] if c["status"] == "complete")
    failed = sum(1 for c in report["channels"] if c["status"] == "failed")
except Exception:
    pass
json.dump({"ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
           "mode": "telegram-incremental", "exit": code,
           "ok_channels": ok, "failed_channels": failed}, open(hb, "w"))
EOF

echo "$(date): telegram incremental exit=$EXIT — see $LOG" >> "$HOME/Library/Logs/BlueX/telegram.log"
exit $EXIT
```

- [ ] **Step 3: Write the plist**

`tools/jobs/net.pulsschlag.bluex.telegram.daily.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
 "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>net.pulsschlag.bluex.telegram.daily</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>/Volumes/Eregion/projects/bluex-v2/tools/jobs/bluex-telegram-daily.sh</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>6</integer><key>Minute</key><integer>17</integer></dict>
  <key>StandardOutPath</key><string>/tmp/bluex-telegram-daily.out</string>
  <key>StandardErrorPath</key><string>/tmp/bluex-telegram-daily.err</string>
</dict>
</plist>
```

- [ ] **Step 4: Dry-run the script directly** (no launchd installation):

```bash
chmod +x tools/jobs/bluex-telegram-daily.sh
zsh tools/jobs/bluex-telegram-daily.sh; echo "exit=$?"
cat /Volumes/Eregion/bluex-data/social/telegram-heartbeat.json
```

Expected: exit 0 (no approved channels yet → empty run is `ok`), heartbeat JSON with `"mode": "telegram-incremental"`, `"exit": 0`. **Do NOT run tools/install-jobs.sh or load the plist** — installation is coordinated manually by the session controller.

- [ ] **Step 5: Commit** — `git add tools/jobs && git commit -m "feat(telegram): daily incremental launchd job (installation manual)"`

---

## Self-Review (done at planning time)

- **Spec coverage:** §3 route 1 → Task 1; §4 seed+snowball+review → Tasks 3–4; §5 schema/reconciliation/cursors → Tasks 2, 5; §6 operations/job → Tasks 5–6; §7 ethics → constraints (public-only, no media, UA); §8 testing → golden fixture (T1), gap test (T2), snowball tests (T4), reconciliation tests (T5). §9/§10 need no tasks.
- **Not covered by design (out of scope):** watchdog extension for the telegram heartbeat — deferred deliberately; the daily job is one-shot and its heartbeat is inspectable; wire it into the watchdog when the corpus goes into production use.
- **Type consistency:** `Message` fields match `messages` columns; `APPROVED` statuses match `channels.py` transitions and `candidates.approve_candidate`; `fetch(username, before)` signature identical in tests and production lambda.
- **Placeholders:** none; all code inline.
