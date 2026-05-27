# BlueX/Views — SwiftUI Views

All views are SwiftUI structs targeting macOS 14+. They observe `@Observable` ViewModels and query SwiftData via `@Query`.

## Structure

```
Views/
├── RootView.swift          NavigationSplitView root + SidebarItem enum
├── BlueXColors.swift       Dark-mode color palette (Color extensions)
├── Sidebar/
│   └── SidebarView.swift   Left column: groups, accounts, queue, settings links
├── Account/
│   ├── AccountContentView.swift  Centre column: filtered post list
│   └── AccountChartsView.swift   Right column: stacked area + hate ratio charts
├── Group/
│   ├── GroupContentView.swift    Centre column: account list with stats
│   └── GroupChartsView.swift     Right column: overlaid multi-series + small multiples
├── Thread/
│   ├── ThreadView.swift          Right column: depth-ordered reply tree
│   ├── PostRowView.swift         Single post row with left border + badge
│   └── AnnotationBadge.swift     Colored pill showing speechClass + severity
├── Queue/
│   └── QueueView.swift           Right column: LLM annotation queue + controls
└── Settings/
    ├── SettingsView.swift         3-tab settings scaffold
    ├── CredentialsSettingsView.swift  Keychain credential management
    ├── ModelSettingsView.swift    LLM endpoint + prompt template editor
    └── ScrapingSettingsView.swift Batch size, depth, rate limit controls
```

## Navigation

`SidebarItem` (enum in `RootView.swift`) drives the `NavigationSplitView`:
- Sidebar selection → `content` column (list/overview)
- Sidebar selection → `detail` column (charts/thread/queue/settings)

## Color System

Use `Color.speechClassBorder(_:)`, `.speechClassBackground(_:)`, `.speechClassBadgeText(_:)` for annotation-class-aware styling. Never hard-code RGB values in views — always use the named constants from `BlueXColors.swift`.

## Charts

`AccountChartsView` and `GroupChartsView` use Swift Charts (`import Charts`). Data is pre-aggregated by `ChartsViewModel.computeBuckets(from:)` into `[WeekBucket]` before being passed to chart marks.
