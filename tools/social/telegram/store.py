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
