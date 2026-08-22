# doc2vec on the full reply corpus: probe evidence

**Date:** 2026-08-22
**Model:** `/Volumes/Eregion/bluex-data/embeddings/doc2vec-final.model`
**Training:** 2,192,980 replies, 10 epochs, PV-DM, vector_size 200, min_count 5,
seed 42, workers 8, gensim 4.4.0. Wall time **801s (13.4 min)**, vocabulary
**104,839** tokens. Unsupervised: no label, prediction or annotation table was
read (recorded in the model's metadata).

## Why this model exists

Every supervised model measured on this corpus was trained on
hate-versus-`rude` and has therefore never seen the majority class. Performance
collapses accordingly: 0.959 cross-validated on hate-vs-rude, 0.61–0.68 against
random corpus text. A representation learned from the deployment distribution
itself is the designed remedy (proposal §Stage 1), and it costs CPU-minutes.

## Probe results (no labels involved)

### Nearest neighbours

| Probe | Neighbours (cosine) |
|---|---|
| `migrants` | immigrants 0.84, refugees 0.70, foreigners 0.68, **illegals 0.64**, migrant 0.60 |
| `idiot` | moron 0.81, imbecile 0.79, asshole 0.74, buffoon 0.67, fool 0.66 |
| `flüchtlinge` | **fachkräfte 0.81**, geflüchtete 0.78, asylbewerber 0.76, einwanderer 0.76, arbeitskräfte 0.75 |
| `lügenpresse` | hetze 0.51, steigbügelhalter 0.48, spinner 0.48, extremisten 0.47, hass 0.46 |

Two of these are worth more than a sanity check.

**`migrants` → `illegals` at 0.64.** The pejorative sits inside the neutral
cluster. That adjacency is precisely the structure a hate detector needs to
exploit, and it is present without any supervision.

**`flüchtlinge` → `fachkräfte` at 0.81.** "Skilled workers" is the *nearest*
neighbour of "refugees" — the two competing framings of the German migration
debate argued in the same breath. No English-trained or general-purpose model
encodes this; it is a property of this corpus's own discourse, which is exactly
the argument for training on it (proposal: "it also learns the corpus's own
bilingual vocabulary, which off-the-shelf models lack").

### Document-level separation (paraphrase vs unrelated)

| Pair | Cosine |
|---|---|
| EN paraphrase ("this is completely unacceptable behaviour from a government" / reordered) | **0.921** |
| EN unrelated (same vs "the weather in spring is lovely for hiking") | 0.192 |
| DE paraphrase ("Das ist eine Schande für unser Land" / reordered) | **0.887** |
| DE unrelated (same vs "Der Kuchen im Café war sehr lecker") | 0.232 |

The classifier consumes *document* vectors, so this is the load-bearing check:
clean separation in both languages, ~0.9 vs ~0.2.

## What this does and does not license

- It licenses using these vectors as an ensemble member's input features, and as
  the basis for unsupervised work (clustering, near-duplicate detection, topic
  structure).
- It does **not** say anything about hate detection performance. That requires
  the base rate and held-out human labels (Stage 0, starting 2026-08-24).
- Reproducibility caveat recorded in the model metadata: gensim is bit-for-bit
  reproducible only with `workers=1`; this run used 8, so it is
  seed-reproducible-in-expectation, not bit-identical.

## Process note

A duplicate training run was accidentally started twice today (an empty output
directory read as a dead process; then a lock "verification" run against a
trainer that predated the lock). Neither damaged the final model, but both are
the same error: **a protection added while a job is running does not protect
that job**, and `pgrep -f` matches the watcher's own command line. Locks are now
shared via `tools/common/single_instance.py` and must be verified with a
deliberately-held lock in a temp directory, never against live work.
