"""Canonical channel identity.

Telegram usernames are case-insensitive, but SQLite string comparisons are
case-sensitive. `t.me/s/<name>` returns each channel's own canonical casing
in its `data-post` attribute, which often differs from the casing a human
approved or typed -- e.g. approved `FrankKraemer` vs. the site returning
`frankkraemer`. Left unreconciled, `messages.channel` and `channels.username`
silently stop matching and every incremental/coverage/candidate lookup keyed
on the channel name breaks quietly.

`canonical_channel()` is the single normalisation applied at every boundary
where a channel name enters the system (parsing, seed import, human decision
CLIs, the collector's channel iteration, reachability checks). Display names
(`channels.title`) are untouched -- only the identity is canonicalised.

Deliberately its own module (no dependency on preview/store/collect/
candidates/seeds/channels) so every one of those modules can import it
without risking a circular import.
"""


def canonical_channel(name: str) -> str:
    """Lowercase, strip a leading '@', and strip surrounding whitespace.

    Idempotent: canonical_channel(canonical_channel(x)) == canonical_channel(x).
    """
    s = name.strip()
    if s.startswith("@"):
        s = s[1:].strip()
    return s.lower()
