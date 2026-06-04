#!/usr/bin/env python3
"""Generate the Obsidian review doc from benchmark-set.json.

Each post is one anchored block. The Verdict line is pre-filled with the
user's label if set, else Claude's, so the default action is "accept". The
reviewed checkbox tracks progress and is resumable.
"""
import json
import os

SET = os.path.join(os.path.dirname(__file__), "benchmark-set.json")
OUT = os.path.expanduser(
    "~/Obsidian/projects/personal/bluex-v2/BlueX Benchmark Review.md"
)


def _verdict(entry):
    label = entry.get("user_label") or entry.get("claude_label") or {}
    return label.get("class", "")


def render(entries):
    # Hard cases first (highest value), then core; stable order within each.
    ordered = sorted(enumerate(entries), key=lambda iz: (iz[1]["tag"] != "hard", iz[0]))
    lines = [
        "# BlueX Benchmark Review",
        "",
        "Edit **Verdict:** only when you disagree with Claude's proposal; add **Notes:** freely.",
        "Check `reviewed` once you've eyeballed a post. Unreviewed posts fall back to Claude's label.",
        "",
    ]
    for n, (_, e) in enumerate(ordered, start=1):
        cl = e.get("claude_label") or {}
        sev = cl.get("severity")
        sev_str = f" ({sev})" if sev else ""
        checkbox = "- [x] reviewed" if e.get("reviewed") else "- [ ] reviewed"
        notes = e.get("notes", "") or ""
        quoted = "\n".join("> " + ln for ln in ((e["text"] or "").splitlines() or [""]))
        lines += [
            f"<!-- bm: {e['uri']} -->",
            f"### [{n}] · {e['tag']}",
            quoted,
            "",
            f"**Claude:** {cl.get('class','?')}{sev_str} — {cl.get('rationale','')}",
            f"**Verdict:** {_verdict(e)}",
            f"**Notes:** {notes}",
            checkbox,
            "",
            "---",
            "",
        ]
    return "\n".join(lines)


def main():
    with open(SET) as fh:
        entries = json.load(fh)
    md = render(entries)
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as fh:
        fh.write(md)
    print(f"wrote review doc with {len(entries)} posts to {OUT}")


if __name__ == "__main__":
    main()
