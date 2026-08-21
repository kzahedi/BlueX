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
    import pathlib
    import sys

    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3]))

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
