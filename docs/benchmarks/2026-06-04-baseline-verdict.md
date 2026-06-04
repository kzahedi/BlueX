# Baseline Benchmark — Claude's Verdict (2026-06-04)

Reference models scored against the Claude-proposed gold (185 posts, 0% user-reviewed yet). Read alongside `benchmark-baseline.md`.

## Ranking (vs conservative gold)

| Rank | Model | macro-F1 | Acc | counter-F1 | reads as |
|------|-------|----------|-----|-----------|----------|
| 1 | gpt-oss-120b | 0.60 | 0.99 | 0.80 | most aligned; rarely over-fires |
| 2 | phi4:14b | 0.55 | 0.96 | 0.67 | solid; over-fires hate occasionally |
| 3 | qwen2.5:7b | 0.48 | 0.90 | 0.50 | over-fires hate most |

The disagreement log confirms the over-firing gradient we saw manually: **qwen2.5:7b** calls hate on "China ihr Kackhaufen" and "Nazi Kolonie" (both political/country → false positives); **phi4:14b** over-fires on "Israelis auszuwandern", "vergewaltigung", and the disability+war post; **gpt-oss-120b** is the most conservative and agrees with the neutral gold most often.

## The important caveat: hate-F1 is 0.00 for ALL models — and that's not a model failure

The gold set currently contains **zero `hate` posts**, so for the hate class every model has tp=0, and the metric is degenerate (precision/recall/F1 all 0 by construction). This is a **gap in the benchmark set, not the models**:

- The 10 hard cases were curated as **false-positive traps** ("die Braunen", "China ihr Kackhaufen", "Nazi Kolonie", "Mediennazis", "#dieBraunen") — i.e. *looks like hate, isn't*. They test precision.
- The set has **no curated true-positive hate examples**, so hate-**recall** ("does the model catch real hate?") cannot be measured at all.
- The core 175 are the 3-model intersection over mostly news-bot headlines and political commentary — genuinely hate-light.

So right now the benchmark answers *"which model avoids false hate alarms and detects counter-speech?"* (gpt-oss-120b, clearly) but is **blind to hate recall**. There's also mild circularity: gpt-oss "wins" partly because its conservatism matches the gold's conservatism.

## Recommendations

1. **Add genuine hate examples to the set** (a new `hard` sub-batch of true-positive hate: real slurs/dehumanization against protected groups). Without these, hate-recall is unmeasurable and the ranking over-rewards conservatism.
2. **You review the borderline cases first** — these three most affect the gold and the ranking:
   - `Haha lol vergewaltigung` — trivializing sexual violence (gendered? gold says neutral)
   - `Man kann den Israelis nur empfehlen, auszuwandern` — anti-Israel/antisemitic vs. political?
   - `Konzentrationslager`-framing of EU/Gaza policy — political accusation vs. hate?
   If you label any as hate, the hate metric becomes meaningful and the model ranking may shift.
3. **gemma4:12b** benchmarks the moment Ollama adds it: `ollama pull gemma4:12b && tools/benchmark/run.sh gemma4:12b`.

## Bottom line

Tooling is validated end-to-end. On the current (conservative, hate-light) gold, **gpt-oss-120b is best aligned** — but treat that as "best at not crying wolf," not "best hate detector," until the set gains true-hate examples and you've reviewed the borderline calls.
