"""SQLite store for the Telegram collector (schema per design spec §5)."""
import json
import sqlite3
from collections import defaultdict

from tools.social.telegram.identity import canonical_channel

APPROVED = ("seed_approved", "snowball_approved")

# Wait rather than failing when another writer holds the lock.
BUSY_TIMEOUT_SECONDS = 30.0

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
    conn = sqlite3.connect(path, timeout=BUSY_TIMEOUT_SECONDS)
    conn.execute("PRAGMA journal_mode=WAL")
    # Without this, a concurrent writer (daily job overlapping a manual run)
    # turns momentary contention into an immediate "database is locked" abort
    # mid-collection instead of a short wait.
    conn.execute(f"PRAGMA busy_timeout={int(BUSY_TIMEOUT_SECONDS * 1000)}")
    conn.executescript(_SCHEMA)
    _migrate_channels_add_backfill_complete_at(conn)
    return conn


def _migrate_channels_add_backfill_complete_at(conn) -> None:
    """CREATE TABLE IF NOT EXISTS never adds a column to a channels table
    that already exists from before this column was introduced -- this
    runs on every open() and is a no-op once the column is present."""
    cols = {row[1] for row in conn.execute("PRAGMA table_info(channels)")}
    if "backfill_complete_at" not in cols:
        conn.execute("ALTER TABLE channels ADD COLUMN backfill_complete_at TEXT")
        conn.commit()


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


def mark_backfill_complete(conn, channel: str) -> None:
    """Record that a backfill walk reached msg_id 1 for `channel`. This is
    the completion marker a later backfill run checks so it doesn't re-walk
    a channel's entire history for zero new rows."""
    conn.execute(
        "UPDATE channels SET backfill_complete_at=datetime('now') "
        "WHERE username=?", (channel,))
    conn.commit()


def backfill_completed_at(conn, channel: str):
    row = conn.execute(
        "SELECT backfill_complete_at FROM channels WHERE username=?",
        (channel,)).fetchone()
    return row[0] if row else None


def max_msg_id(conn, channel: str):
    """Highest msg_id in the CONTIGUOUS block starting at the channel's
    oldest stored message -- NOT simply the table's raw MAX(msg_id).

    Use this ONLY for a deliberate gap-REPAIR walk (`--mode repair`). An
    interrupted incremental run can leave a disjoint island of newer ids
    above a real gap (e.g. it saved the newest page, then died, before
    walking back far enough to fill in beneath it). Reporting the raw max
    there would make a later overlap-walk stop the instant it
    re-encounters that island, never reaching the actual gap below it.
    Reporting the top of the genuinely gapless prefix instead means the
    walk keeps going until it reconnects with real history -- at the cost
    of being expensive: for a large channel this is a full walk from the
    top down to wherever the earliest gap sits, however deep that is.

    Do NOT use this as the daily incremental job's stop condition -- that
    was the bug (measured 2026-08-22, EvaHermanOffiziell: an old gap deep
    in an 87k-message history made the contiguous prefix top land far
    below the newest stored id, so the scheduled "incremental" run walked
    the entire channel, ~4,400 fetches, zero inserts, four hours, and
    would repeat every day). Use `newest_msg_id()` for that.

    Returns None if the channel has no stored messages at all.
    """
    rows = conn.execute(
        "SELECT msg_id FROM messages WHERE channel=? ORDER BY msg_id",
        (channel,)).fetchall()
    if not rows:
        return None
    top = prev = rows[0][0]
    for (mid,) in rows[1:]:
        if mid != prev + 1:
            break
        top = mid
        prev = mid
    return top


def newest_msg_id(conn, channel: str):
    """Raw MAX(msg_id) across ALL stored messages for `channel`, island or
    no island -- NOT the contiguous-prefix top that `max_msg_id()` reports.

    Use this as the daily incremental job's ("top-up only") stop
    condition: walk back from the newest page until a page's own minimum
    msg_id is <= this value, or the page is empty. That is cheap and
    bounded -- one or two pages for a channel that is already up to date
    -- because it only cares "have we reached ids we already hold", not
    "have we reached a genuinely gapless run of history". It will walk
    past (and re-fetch) an island of already-stored newer ids without
    noticing it as a stopping point, which is fine for top-up: an island
    means those ids are already in the store, so re-fetching them just
    re-upserts rows that are already there (zero new inserts, no harm) on
    the way down to the raw max.

    Do NOT use this to repair a hole left by a crashed run -- it will
    stop at the top of an island above the hole and never reach it. Use
    `max_msg_id()` (via `--mode repair`) for that.

    Returns None if the channel has no stored messages at all.
    """
    row = conn.execute(
        "SELECT MAX(msg_id) FROM messages WHERE channel=?",
        (channel,)).fetchone()
    return row[0] if row and row[0] is not None else None


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


def migrate_canonical_names(conn) -> dict:
    """One-shot, idempotent migration to canonical (lowercase) channel
    identity across every table keyed on a channel name: messages,
    channels, candidates, cursors, coverage.

    The production bug this fixes: t.me/s/<name> returns each channel's own
    canonical casing in data-post, which can differ from the casing that
    was requested/approved (e.g. approved `FrankKraemer`, messages stored
    under `frankkraemer`). SQLite compares case-sensitively, so the two
    silently stop matching. This lowercases the identity column everywhere
    it appears.

    A lowercase pass can make two previously-distinct rows collide (e.g.
    `Foo` and `foo` both existed). Never silently drops one -- every merge
    is recorded as a human-readable line in report['merge_lines'] and
    tallied in report['merges']; every rename is recorded in
    report['renames']. Runs as a single transaction: on any error nothing
    is changed. Running it twice is a no-op the second time.
    """
    tables = ["messages", "channels", "candidates", "cursors", "coverage"]
    report = {"renames": [], "merges": [], "merge_lines": [],
              "before_counts": {}, "after_counts": {}}
    for t in tables:
        report["before_counts"][t] = conn.execute(
            f"SELECT COUNT(*) FROM {t}").fetchone()[0]

    # Snapshot message counts per RAW (pre-migration) channel casing, used
    # only to break ties when two `channels` rows collapse onto the same
    # canonical identity ("keep the row with data (most messages)").
    raw_msg_counts = defaultdict(int)
    for channel, cnt in conn.execute(
            "SELECT channel, COUNT(*) FROM messages GROUP BY channel"):
        raw_msg_counts[channel] = cnt

    try:
        _migrate_messages_canonical(conn, report)
        _migrate_channels_canonical(conn, report, raw_msg_counts)
        _migrate_candidates_canonical(conn, report)
        _migrate_cursors_canonical(conn, report)
        _migrate_coverage_canonical(conn, report)
        conn.commit()
    except Exception:
        conn.rollback()
        raise

    for t in tables:
        report["after_counts"][t] = conn.execute(
            f"SELECT COUNT(*) FROM {t}").fetchone()[0]
    return report


def _migrate_messages_canonical(conn, report) -> None:
    rows = conn.execute("SELECT rowid, channel, msg_id FROM messages").fetchall()
    groups = defaultdict(list)
    for rowid, channel, msg_id in rows:
        groups[(canonical_channel(channel), msg_id)].append((rowid, channel))
    merge_count = 0
    for (canon, msg_id), items in groups.items():
        keep_rowid, keep_channel = items[0]
        for rowid, channel in items[1:]:
            conn.execute("DELETE FROM messages WHERE rowid=?", (rowid,))
            merge_count += 1
            report["merge_lines"].append(
                f"messages: merged duplicate {channel}/{msg_id} into "
                f"{canon}/{msg_id} (kept the row originally stored as "
                f"{keep_channel}/{msg_id})")
        if keep_channel != canon:
            conn.execute("UPDATE messages SET channel=? WHERE rowid=?",
                        (canon, keep_rowid))
            report["renames"].append({"table": "messages",
                                      "from": keep_channel, "to": canon})
    if merge_count:
        report["merges"].append({"table": "messages", "count": merge_count})


def _migrate_channels_canonical(conn, report, raw_msg_counts) -> None:
    rows = conn.execute("SELECT rowid, username FROM channels").fetchall()
    groups = defaultdict(list)
    for rowid, username in rows:
        groups[canonical_channel(username)].append((rowid, username))
    merge_count = 0
    for canon, items in groups.items():
        items.sort(key=lambda ru: raw_msg_counts.get(ru[1], 0), reverse=True)
        keep_rowid, keep_username = items[0]
        for rowid, username in items[1:]:
            conn.execute("DELETE FROM channels WHERE rowid=?", (rowid,))
            merge_count += 1
            report["merge_lines"].append(
                f"channels: merged duplicate {username} into {canon} (kept "
                f"the row originally stored as {keep_username} -- "
                f"{raw_msg_counts.get(keep_username, 0)} messages vs "
                f"{raw_msg_counts.get(username, 0)})")
        if keep_username != canon:
            conn.execute("UPDATE channels SET username=? WHERE rowid=?",
                        (canon, keep_rowid))
            report["renames"].append({"table": "channels",
                                      "from": keep_username, "to": canon})
    if merge_count:
        report["merges"].append({"table": "channels", "count": merge_count})


def _migrate_candidates_canonical(conn, report) -> None:
    rows = conn.execute(
        "SELECT rowid, username, forward_evidence_count, distinct_forwarders "
        "FROM candidates").fetchall()
    groups = defaultdict(list)
    for rowid, username, evid, dist in rows:
        groups[canonical_channel(username)].append(
            (rowid, username, evid, dist))
    merge_count = 0
    for canon, items in groups.items():
        items.sort(key=lambda r: (r[2] or 0, r[3] or 0), reverse=True)
        keep_rowid, keep_username, keep_evid, keep_dist = items[0]
        for rowid, username, evid, dist in items[1:]:
            conn.execute("DELETE FROM candidates WHERE rowid=?", (rowid,))
            merge_count += 1
            report["merge_lines"].append(
                f"candidates: merged duplicate {username} into {canon} "
                f"(kept the row with most evidence: {keep_evid} forwards, "
                f"{keep_dist} forwarders vs {evid} forwards, {dist} "
                f"forwarders)")
        if keep_username != canon:
            conn.execute("UPDATE candidates SET username=? WHERE rowid=?",
                        (canon, keep_rowid))
            report["renames"].append({"table": "candidates",
                                      "from": keep_username, "to": canon})
    if merge_count:
        report["merges"].append({"table": "candidates", "count": merge_count})


def _migrate_cursors_canonical(conn, report) -> None:
    rows = conn.execute("SELECT rowid, channel, before FROM cursors").fetchall()
    groups = defaultdict(list)
    for rowid, channel, before in rows:
        groups[canonical_channel(channel)].append((rowid, channel, before))
    merge_count = 0
    for canon, items in groups.items():
        # "Furthest back" = smallest non-null `before` (deepest into
        # history walked so far). A NULL cursor carries no evidence of
        # having walked anywhere, so it loses a tie-break against any
        # concrete in-progress cursor.
        items.sort(key=lambda item: (item[2] is None,
                                     item[2] if item[2] is not None else 0))
        keep_rowid, keep_channel, keep_before = items[0]
        for rowid, channel, before in items[1:]:
            conn.execute("DELETE FROM cursors WHERE rowid=?", (rowid,))
            merge_count += 1
            report["merge_lines"].append(
                f"cursors: merged duplicate {channel} (before={before}) "
                f"into {canon} (kept the furthest-back cursor: before="
                f"{keep_before}, originally stored as {keep_channel})")
        if keep_channel != canon:
            conn.execute("UPDATE cursors SET channel=? WHERE rowid=?",
                        (canon, keep_rowid))
            report["renames"].append({"table": "cursors",
                                      "from": keep_channel, "to": canon})
    if merge_count:
        report["merges"].append({"table": "cursors", "count": merge_count})


def _migrate_coverage_canonical(conn, report) -> None:
    rows = conn.execute(
        "SELECT rowid, channel, day, message_count FROM coverage").fetchall()
    groups = defaultdict(list)
    for rowid, channel, day, count in rows:
        groups[(canonical_channel(channel), day)].append(
            (rowid, channel, count))
    merge_count = 0
    for (canon, day), items in groups.items():
        items.sort(key=lambda r: (r[2] or 0), reverse=True)
        keep_rowid, keep_channel, keep_count = items[0]
        for rowid, channel, count in items[1:]:
            conn.execute("DELETE FROM coverage WHERE rowid=?", (rowid,))
            merge_count += 1
            report["merge_lines"].append(
                f"coverage: merged duplicate {channel}/{day} into "
                f"{canon}/{day} (kept the row with more data: "
                f"{keep_count} messages vs {count})")
        if keep_channel != canon:
            conn.execute("UPDATE coverage SET channel=? WHERE rowid=?",
                        (canon, keep_rowid))
            report["renames"].append({"table": "coverage",
                                      "from": keep_channel, "to": canon})
    if merge_count:
        report["merges"].append({"table": "coverage", "count": merge_count})
