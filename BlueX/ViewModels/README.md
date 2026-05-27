# BlueX/ViewModels — UI Logic

All ViewModels use `@Observable` (macOS 14+). They contain UI logic and derived state, keeping Views declarative.

## ViewModels

| ViewModel | Used by | Responsibility |
|-----------|---------|----------------|
| `SidebarViewModel` | `SidebarView`, `RootView` | Scrape phase, progress, active account handle, error state. Forwarded from `ScrapeCoordinator` by `RootView`. |
| `AccountViewModel` | `AccountContentView` | Post filtering (text search, class filter), sort order, count aggregation. |
| `GroupViewModel` | `GroupContentView` | Per-account stats (hate/counter/neutral/pending counts and ratios) for a group. |
| `ThreadViewModel` | `ThreadView` | DFS traversal for flat ordered post list, filter by class. |
| `ChartsViewModel` | `AccountChartsView`, `GroupChartsView` | ISO-week bucket aggregation, visible window slice, trend calculation. |
| `QueueViewModel` | `QueueView` | LLM annotation queue state: pending posts, progress, batch size. |

## Conventions

- ViewModels are `@Observable final class` — never struct.
- ViewModels do NOT import SwiftUI.
- Business logic (API calls, persistence) stays in Services. ViewModels only process data for display.
- `ChartsViewModel.computeBuckets(from:)` accepts `[Post]` from a `@Query` in the View and does all aggregation.
