# Consensus committee -- pairwise disagreement report

## Honest header

- `incivility_toxicity` measures INCIVILITY, not hate: hate-vs-rude AUC
  0.198 (worse than chance, wrong direction), rude-vs-random AUC 0.946.
- `tfidf_lr` and `doc2vec_lr` both answer "given hate or rude, which?" --
  they are known weak on random (not curated) text, AUC 0.61-0.68 in prior
  diagnostics.
- All three members were trained on Bluesky-moderator-reported labels,
  which record what was reported and actioned, not ground truth.
- This committee is not a hate detector. It exists to produce decorrelated
  per-post signals whose disagreement is informative, and to define strata
  for future weighted-sampling labelling.


## Pairwise Spearman correlations (posts all relevant members scored)

- incivility_toxicity vs tfidf_lr: rho=0.0309 (n=2018665)
- incivility_toxicity vs doc2vec_lr: rho=0.0213 (n=2085088)
- tfidf_lr vs doc2vec_lr: rho=0.2100 (n=2124575)

## spread_pct distribution (deciles)

0.00, 6.10, 9.90, 13.12, 16.09, 19.07, 22.11, 25.39, 29.24, 34.24, 49.71

## Top mean_pct bands

- top 1 pct (2197431 posts): 21974 posts
- top 0.1 pct: 2197 posts

## Top-1% overlap (Jaccard) between members' own top-1% sets

- incivility_toxicity_vs_tfidf_lr: 0.0001
- incivility_toxicity_vs_doc2vec_lr: 0.0020
- tfidf_lr_vs_doc2vec_lr: 0.0296
