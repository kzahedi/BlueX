"""Generic Hugging Face sequence-classification wrapper.

WHY THIS EXISTS
----------------
One wrapper, model id as a parameter, so adding a candidate model to the
benchmark never means writing a new detector module. `transformers==4.53.1`
and `torch==2.7.1` are installed; MPS is available on this machine and is
preferred over CPU when present.

WHAT THIS IS NOT
-----------------
Not a guarantee any given model id downloads or runs. Model ids are attempted
at call time and failures (missing repo, gated repo, incompatible config,
OOM) are raised as `DetectorLoadError` with the underlying message intact —
a failed download is a legitimate, reportable result for this benchmark, not
something to silently skip or work around.

MULTI-HEAD MODELS
-------------------
`score_heads` returns EVERY output head separately (dict of
{head_name: list[float]}), never averaged or collapsed into one number. A
generic `toxicity` head and a narrower `identity_attack` head can behave very
differently against `hard_negative` (rude-but-not-hateful) text, and
collapsing them would hide exactly the distinction this benchmark exists to
surface. Softmax is used for single-label configs (num single "winning"
class), sigmoid for multi-label configs (`problem_type ==
"multi_label_classification"`, or more than 2 labels with no single-label
problem_type set) — most Detoxify-style checkpoints are multi-label sigmoid
because a post can be simultaneously "insult" and "threat".
"""
import functools

import torch
from transformers import AutoModelForSequenceClassification, AutoTokenizer


class DetectorLoadError(Exception):
    """A model id failed to download, load, or run. Carries the original cause."""


def pick_device(requested=None):
    if requested:
        return requested
    if torch.backends.mps.is_available():
        return "mps"
    return "cpu"


@functools.lru_cache(maxsize=8)
def _load(model_id, device):
    try:
        tokenizer = AutoTokenizer.from_pretrained(model_id)
        model = AutoModelForSequenceClassification.from_pretrained(model_id)
        model.to(device)
        model.eval()
    except Exception as exc:  # noqa: BLE001 - deliberately broad, see module docstring
        raise DetectorLoadError("%s: %s: %s" % (model_id, type(exc).__name__, exc)) from exc
    return tokenizer, model


def _is_multi_label(model):
    cfg = model.config
    if getattr(cfg, "problem_type", None) == "multi_label_classification":
        return True
    # Heuristic fallback for checkpoints that don't set problem_type: more
    # than 2 labels with names suggesting independent attributes (Detoxify
    # lineage) behave as multi-label in practice.
    return False


def score_heads(texts, model_id, batch_size=16, device=None, max_length=256):
    """Return {head_name: list[float]} — one entry per output label, in the
    model's own id2label order. Raises DetectorLoadError on any failure to
    download/load/run the model; the caller decides how to report that.
    """
    device = pick_device(device)
    try:
        tokenizer, model = _load(model_id, device)
    except DetectorLoadError:
        raise

    id2label = model.config.id2label
    n_labels = len(id2label)
    multi_label = _is_multi_label(model) or n_labels > 2

    heads = {id2label[i]: [] for i in range(n_labels)}

    try:
        with torch.no_grad():
            for i in range(0, len(texts), batch_size):
                batch = [t or "" for t in texts[i:i + batch_size]]
                encoded = tokenizer(
                    batch, padding=True, truncation=True,
                    max_length=max_length, return_tensors="pt",
                ).to(device)
                logits = model(**encoded).logits
                if multi_label:
                    probs = torch.sigmoid(logits)
                else:
                    probs = torch.softmax(logits, dim=-1)
                probs = probs.to("cpu").tolist()
                for row in probs:
                    for idx, p in enumerate(row):
                        heads[id2label[idx]].append(float(p))
    except Exception as exc:  # noqa: BLE001 - see module docstring
        raise DetectorLoadError("%s: inference failed: %s: %s" % (model_id, type(exc).__name__, exc)) from exc

    return heads


def score(texts, model_id, head=None, **kwargs):
    """Convenience single-score wrapper: pick one head (default: last label,
    conventionally the "positive"/toxic class for binary checkpoints).
    """
    heads = score_heads(texts, model_id, **kwargs)
    if head is None:
        head = list(heads.keys())[-1]
    return heads[head]
