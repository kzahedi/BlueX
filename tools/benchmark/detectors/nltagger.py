"""Apple NLTagger sentiment as a hate-detection "detector" — the calibration floor.

WHY THIS EXISTS
----------------
`docs/superpowers/notes/2026-08-11-nltagger-sentiment-does-not-detect-hate.md`
measured this at AUC 0.508 (chance) against 235 moderator-labelled hate posts.
It is wired into this harness anyway, deliberately, as a calibration floor: if
a bug in build_eval_set.py or evaluate.py ever made NLTagger score anywhere
near 0.9, the bug is in the harness, not a sudden improvement in Apple's
on-device sentiment model. Every harness run should reproduce ≈0.508 on
positive-vs-easy_negative before any other detector's number is trusted.

WHAT THIS IS NOT
-----------------
Not a hate classifier. It is a sentiment score, negated, so "more negative
sentiment" maps to "higher score" (the direction the note used). Negativity
is the near-universal baseline of replies to news accounts in this corpus, so
this signal is expected to carry almost no information distinguishing hate
from ordinary negativity — that is the finding being reproduced here, not a
defect.

Shells out to a Swift binary compiled from
tools/benchmark/support/nl_score.swift, which mirrors
BlueX/Services/Annotation/NLTaggerAnalyser.swift exactly
(NLTagger(tagSchemes: [.sentimentScore]), unit: .paragraph). This is
deliberate: a Python reimplementation of sentiment scoring could drift from
the app's actual behaviour without anyone noticing.
"""
import os
import sys

SUPPORT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "support")
sys.path.insert(0, SUPPORT_DIR)
import nl_score  # noqa: E402

NAME = "nltagger"


def score(texts):
    """Negated NLTagger sentiment: higher score = more negative = more hate-like.

    An empty text list is valid input and returns an empty list.
    """
    if not texts:
        return []
    results = nl_score.score_texts(list(texts))
    return [-r["sentiment"] for r in results]
