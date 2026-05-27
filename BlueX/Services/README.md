# BlueX/Services — Domain Services

Business logic layer. Services are pure Swift structs/classes with no SwiftUI dependencies.

## API/

| File | Purpose |
|------|---------|
| `BlueskyAPIClient` | AT Protocol REST client. `createSession`, `getAuthorFeed`, `getPostThread`. Returns `Result<T, BlueskyError>`. |
| `BlueskyError` | Typed error enum: `authFailed`, `rateLimited(retryAfter:)`, `networkError(underlying:)`, `decodingError(underlying:)`, `notFound`. |
| `BlueskyStructs` | Codable response types for the Bluesky API. |
| `KeychainCredentials` | Keychain wrapper for storing/loading handle + app password. Service key: `net.pulsschlag.BlueX`. |

## Scraping/

| File | Purpose |
|------|---------|
| `ScrapeCoordinator` | @Observable state machine. Orchestrates feed → thread → annotation pipeline. Exposes `phase`, `progress`, `lastError`. |
| `FeedScraper` | Paginates `getAuthorFeed`, deduplicates by URI, persists new posts. |
| `ThreadScraper` | Fetches reply threads for root posts with `pending` status. Processes in batches of 20. |
| `RescrapingPolicy` | Decides whether a post's thread needs re-scraping based on age and current status. |

## Annotation/

| File | Purpose |
|------|---------|
| `AnnotationService` | Orchestrates NLTagger and LLM passes. Reads `ModelConfig` from SwiftData for LLM settings. |
| `NLTaggerAnalyser` | Apple NLTagger-based baseline: sentiment score + language detection. Offline. |
| `LocalModelClient` | Protocol for LLM clients: `classify(text:language:) async throws -> LLMAnnotation`. |
| `OllamaClient` | Ollama-compatible client (generates via `/api/generate`). |
| `OpenAICompatibleClient` | OpenAI-compatible endpoint client (for MLX server, LM Studio, etc.). |
| `MLXClient` | MLX Swift local inference client. |
| `LLMResponseParser` | Parses JSON `{ class, severity, confidence, reasoning }` from LLM output. |
