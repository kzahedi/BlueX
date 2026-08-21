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
