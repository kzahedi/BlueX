"""Python wrapper around the compiled nl_score Swift binary.

Compiles support/nl_score.swift on first use (or when the source is newer
than the cached binary) and shells out to it in batches. This is the single
chokepoint both build_eval_set.py (language tagging) and
detectors/nltagger.py (sentiment scoring) go through, so both are provably
using the exact same NLTagger/NLLanguageRecognizer configuration as the app.
"""
import json
import os
import subprocess

SUPPORT_DIR = os.path.dirname(os.path.abspath(__file__))
SWIFT_SRC = os.path.join(SUPPORT_DIR, "nl_score.swift")
BINARY = os.path.join(SUPPORT_DIR, "nl_score")

DEFAULT_BATCH_SIZE = 2000


def ensure_binary(src=SWIFT_SRC, binary=BINARY):
    """Compile the swift scorer if missing or stale. Returns the binary path."""
    needs_build = (
        not os.path.exists(binary)
        or os.path.getmtime(binary) < os.path.getmtime(src)
    )
    if needs_build:
        subprocess.run(
            ["swiftc", "-O", src, "-o", binary],
            check=True,
        )
    return binary


def score_texts(texts, binary=None, batch_size=DEFAULT_BATCH_SIZE):
    """Run nl_score over `texts`, return list of {"sentiment", "language"} dicts.

    Batches to keep the JSON payload and argv reasonable for very large
    corpora; batching does not change results, each text is scored
    independently.
    """
    binary = binary or ensure_binary()
    results = []
    for i in range(0, len(texts), batch_size):
        batch = texts[i:i + batch_size]
        payload = json.dumps(batch).encode("utf-8")
        proc = subprocess.run(
            [binary], input=payload, capture_output=True, check=True,
        )
        results.extend(json.loads(proc.stdout))
    return results
