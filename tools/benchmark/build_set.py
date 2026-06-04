#!/usr/bin/env python3
"""Build or refresh tools/benchmark/benchmark-set.json.

core: posts annotated by ALL of phi4:14b, qwen2.5:7b, gpt-oss-120b (the
      comparable set already classified by the three reference models).
hard: posts whose text matches a curated list of known failure-mode substrings.

Merge-preserving: re-running keeps any existing user_label / notes / reviewed /
claude_label, refreshing only text and tag from the store.
"""
import json
import os
import sqlite3
import sys

STORE = os.path.expanduser("~/Library/Application Support/BlueX/default.store")
OUT = os.path.join(os.path.dirname(__file__), "benchmark-set.json")

REFERENCE_MODELS = ("phi4:14b", "qwen2.5:7b", "gpt-oss-120b")

# Known failure modes surfaced during development. Substrings are matched against
# post text; first matching post per substring is added as a hard case.
HARD_SUBSTRINGS = [
    '"China" ihr Kackhaufen',
    "Neonazi mit Pimmel",
    "die Braunen",
    "braunen Horden",
    "Antisemiten haben Pech",
    "Konzentrationslager",
    "Haha lol vergewaltigung",
    "Man kann den Israelis nur empfehlen",
    "Nazi Kolonie",
    "dringend Krieg",
]


def select_core(conn):
    rows = conn.execute(
        """
        WITH m AS (
          SELECT a.ZPOST AS pk, a.ZMODELNAME AS model
          FROM ZANNOTATION a
          WHERE a.ZSTAGE='llm' AND a.ZCONFIDENCE > 0 AND a.ZMODELNAME IN (?,?,?)
          GROUP BY a.ZPOST, a.ZMODELNAME
        ),
        inter AS (
          SELECT pk FROM m GROUP BY pk HAVING COUNT(DISTINCT model)=3
        )
        SELECT p.ZURI, p.ZTEXT FROM ZPOST p
        JOIN inter ON inter.pk = p.Z_PK
        ORDER BY p.ZURI
        """,
        REFERENCE_MODELS,
    ).fetchall()
    return [{"uri": u, "text": t or "", "tag": "core"} for (u, t) in rows]


def select_hard(conn, substrings=HARD_SUBSTRINGS):
    seen = set()
    out = []
    for sub in substrings:
        row = conn.execute(
            "SELECT ZURI, ZTEXT FROM ZPOST WHERE ZTEXT LIKE ? LIMIT 1",
            ("%" + sub + "%",),
        ).fetchone()
        if row and row[0] not in seen:
            seen.add(row[0])
            out.append({"uri": row[0], "text": row[1] or "", "tag": "hard"})
    return out


def merge(existing, fresh):
    """Return fresh entries, carrying over user_label/notes/reviewed/claude_label
    from existing entries with the same uri. text and tag come from fresh."""
    prior = {e["uri"]: e for e in existing}
    out = []
    for f in fresh:
        p = prior.get(f["uri"], {})
        out.append({
            "uri": f["uri"],
            "text": f["text"],
            "tag": f["tag"],
            "claude_label": p.get("claude_label"),
            "user_label": p.get("user_label"),
            "notes": p.get("notes", ""),
            "reviewed": p.get("reviewed", False),
        })
    return out


def main():
    if not os.path.exists(STORE):
        sys.exit(f"store not found: {STORE}")
    conn = sqlite3.connect(f"file:{STORE}?mode=ro", uri=True)
    fresh = select_core(conn) + select_hard(conn)
    # Dedup by uri (a hard case might also be in core); prefer the 'hard' tag.
    by_uri = {}
    for e in fresh:
        if e["uri"] in by_uri and e["tag"] == "core":
            continue
        by_uri[e["uri"]] = e
    fresh = list(by_uri.values())

    existing = []
    if os.path.exists(OUT):
        with open(OUT) as fh:
            existing = json.load(fh)
    merged = merge(existing, fresh)
    with open(OUT, "w") as fh:
        json.dump(merged, fh, ensure_ascii=False, indent=2)
    core = sum(1 for e in merged if e["tag"] == "core")
    hard = sum(1 for e in merged if e["tag"] == "hard")
    print(f"wrote {len(merged)} entries to {OUT} ({core} core, {hard} hard)")


if __name__ == "__main__":
    main()
