# BlueX/Data — SwiftData Models

All persistence models. Each is annotated with `@Model` and lives in the shared `ModelContainer` configured in `BlueXApp.swift`.

## Models

| Model | Purpose |
|-------|---------|
| `TrackedAccount` | A Bluesky account being monitored. Has many `Post`s and `AccountSnapshot`s. |
| `AccountGroup` | Named collection of `TrackedAccount`s (e.g. "German Media"). M:N relationship. |
| `Post` | A single Bluesky post. Has many `Annotation`s. Tracks reply tree scrape status. |
| `Annotation` | One classification result for a `Post`. Carries `speechClass`, `severity`, `confidence`, and full `rawResponse`. |
| `AccountSnapshot` | Point-in-time follower/post count for charting growth. |
| `ScrapeLog` | Audit log of each scrape run — type, status, post count, cursor for resume. |
| `ModelConfig` | LLM endpoint configuration (name, endpoint URL, model ID, prompt template). |
| `CoordinatorState` | Persisted scrape state for crash recovery. Single-row table. |

## Annotation schema

`Annotation.stage` distinguishes pipeline stages:
- `"nltagger"` — Apple NLTagger baseline (sentiment + language)
- `"llm"` — LLM classification (hate / counter / neutral + severity)

The UI always reads the latest `"llm"` annotation for display. NLTagger annotations are kept for research comparison.

## Relationships

```
AccountGroup ←→ TrackedAccount  (M:N, .nullify both ways)
TrackedAccount → Post           (1:N, .cascade on delete)
TrackedAccount → AccountSnapshot (1:N, .cascade on delete)
Post → Annotation               (1:N, .cascade on delete)
```

## Seeding

`AccountSeeder.seed(into:)` populates 20 German and US media accounts on first launch. Called from `RootView.task`.
