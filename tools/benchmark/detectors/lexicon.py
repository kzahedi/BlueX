"""A deliberately trivial keyword-matching baseline.

WHY THIS EXISTS
----------------
Not filler. This is the floor against which every learned model must be
judged: if a 500M-parameter transformer cannot beat a hand-written word list
on this corpus, that is a finding about the corpus or the model, not a bug in
this baseline. It also has none of a neural model's failure modes (no
download, no OOM, no device dependency), so it always runs and always gives
a number to compare against.

WHAT THIS IS NOT
-----------------
Not a serious detector. It has no context sensitivity, no negation handling,
and matches substrings — "class" would match a lexicon entry "ass" if one
existed (it doesn't, deliberately: entries are chosen to be reasonably
specific multi-character tokens/phrases). It is intentionally crude.

The list mixes English and German dehumanising / exterminationist language
and well-known agitation phrases seen in this corpus's domain (replies to
news accounts), not an attempt at a comprehensive hate lexicon.
"""
import re

LEXICON = (
    # dehumanising language
    "untermensch",
    "subhuman",
    "vermin",
    "cockroaches",
    "parasites",
    "invasion",
    "invaders",
    "infestation",
    "ungeziefer",
    # exterminationist / violent
    "gas the",
    "exterminate",
    "genocide",
    "kill all",
    "kill yourself",
    "kill every",
    "should be shot",
    "should be killed",
    "todesstrafe für",
    "erschießen",
    "vergasen",
    "auslöschen",
    # racial/ethnic agitation (non-slur phrases seen in this domain)
    "ausländer raus",
    "zurück in die wüste",
    "geht zurück",
    "rapefugee",
    "rapefugees",
    "go back to your country",
    "not your country",
    # antisemitic dogwhistles seen in this corpus's failure-mode list
    "konzentrationslager",
    "nazi kolonie",
    "antisemiten haben pech",
    # generic identity-attack markers
    "islamisierung",
    "umvolkung",
    "great replacement",
    "white genocide",
    # slur-adjacent generic terms kept intentionally mild/specific
    "braunen horden",
    "die braunen",
)

_PATTERN = re.compile(
    "|".join(re.escape(term) for term in LEXICON),
    re.IGNORECASE,
)

NAME = "lexicon"


def score(texts):
    """Return one float per text: the count of lexicon matches (0 if none)."""
    return [float(len(_PATTERN.findall(text or ""))) for text in texts]
