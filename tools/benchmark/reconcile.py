#!/usr/bin/env python3
"""Parse the Obsidian review doc and merge the user's verdicts/notes/reviewed
state back into benchmark-set.json.

Robustness: blocks are split on lines that are EXACTLY an anchor comment
(`<!-- bm: <uri> -->` as the whole line). An anchor-looking string inside a
blockquote (prefixed with '> ') is not a line-start anchor and is ignored.
"""
import json
import os
import re

SET = os.path.join(os.path.dirname(__file__), "benchmark-set.json")
REVIEW = os.path.expanduser(
    "~/Obsidian/projects/personal/bluex-v2/BlueX Benchmark Review.md"
)

ANCHOR = re.compile(r"^<!-- bm: (\S+) -->\s*$", re.MULTILINE)


def parse_review(text):
    """uri -> {verdict, notes, reviewed} for each anchored block."""
    out = {}
    matches = list(ANCHOR.finditer(text))
    for idx, m in enumerate(matches):
        uri = m.group(1)
        start = m.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        block = text[start:end]
        verdict = ""
        notes = ""
        reviewed = False
        for line in block.splitlines():
            s = line.strip()
            if s.startswith("**Verdict:**"):
                verdict = s[len("**Verdict:**"):].strip()
            elif s.startswith("**Notes:**"):
                notes = s[len("**Notes:**"):].strip()
            elif s.startswith("- [x] reviewed") or s.startswith("- [X] reviewed"):
                reviewed = True
        out[uri] = {"verdict": verdict, "notes": notes, "reviewed": reviewed}
    return out


def apply(entries, parsed):
    """Write user_label/notes/reviewed into entries from parsed review data.
    A user_label is set only when the post is reviewed AND a verdict is present;
    severity is carried from claude_label when the verdict class matches, else None."""
    for e in entries:
        p = parsed.get(e["uri"])
        if not p:
            continue
        e["notes"] = p["notes"]
        e["reviewed"] = p["reviewed"]
        if p["reviewed"] and p["verdict"]:
            cl = e.get("claude_label") or {}
            sev = cl.get("severity") if p["verdict"] == cl.get("class") else None
            e["user_label"] = {"class": p["verdict"], "severity": sev}
    return entries


def main():
    if not os.path.exists(REVIEW):
        raise SystemExit(f"review doc not found: {REVIEW}")
    with open(REVIEW) as fh:
        parsed = parse_review(fh.read())
    with open(SET) as fh:
        entries = json.load(fh)
    apply(entries, parsed)
    with open(SET, "w") as fh:
        json.dump(entries, fh, ensure_ascii=False, indent=2)
    reviewed = sum(1 for e in entries if e.get("reviewed"))
    overrides = sum(1 for e in entries if e.get("user_label"))
    print(f"reconciled {len(parsed)} blocks → {reviewed} reviewed, {overrides} user labels set")


if __name__ == "__main__":
    main()
