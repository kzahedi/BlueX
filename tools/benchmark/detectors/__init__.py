"""Detector plugins for the BlueX hate-detector benchmark.

Uniform interface: every module exposes

    def score(texts: list[str]) -> list[float]

returning one float per input text, higher = more likely hate. Multi-head
models (detectors/hf_encoder.py) additionally expose `score_heads`, which
returns a dict of {head_name: list[float]} so each head can be evaluated
separately rather than collapsed into one number — an identity_attack head
may separate `positive` from `hard_negative` far better than a generic
`toxicity` head, and averaging them together would hide that.

Adding a detector means adding a module here; nothing else in the harness
needs to change (tools/benchmark/evaluate.py drives detectors by name).
"""
