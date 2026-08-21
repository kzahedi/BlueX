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
