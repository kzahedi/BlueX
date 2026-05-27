# BlueX v2 — Architecture

BlueX is a macOS research instrument for studying hate and counter speech on Bluesky. It follows a layered architecture with strict separation of concerns.

## Layer Overview

```
┌──────────────────────────────────────────────────────────┐
│  BlueX/Views/          UI layer (SwiftUI)                │
│  BlueX/ViewModels/     UI logic (@Observable)            │
├──────────────────────────────────────────────────────────┤
│  BlueX/Services/       Domain services                   │
│  ├── API/              Bluesky AT Protocol client        │
│  ├── Scraping/         Feed + thread scrapers            │
│  └── Annotation/       NLTagger + LLM annotation         │
├──────────────────────────────────────────────────────────┤
│  BlueX/Data/           SwiftData models                  │
└──────────────────────────────────────────────────────────┘
```

## Key Design Decisions

### SwiftData (not CoreData)
All persistence uses SwiftData `@Model` classes. `@Query` in SwiftUI views provides reactive data binding with zero boilerplate.

### @Observable (not ObservableObject)
ViewModels use the `@Observable` macro (macOS 14+). This tracks exactly which properties each view reads and only re-renders those views — no `@Published` needed, no spurious re-renders.

### ScrapeCoordinator
Central state machine for the scraping pipeline. Manages feed scraping → thread scraping → NLTagger annotation in sequence. Exposes `phase`, `progress`, and `lastError` for UI binding.

### Three-class annotation schema
Posts are classified as `hate | counter | neutral` per the founding paper's schema. Hate posts additionally carry a `severity: mild | moderate | severe` field.

### Two-stage annotation
1. **NLTagger baseline** (offline, instant): sentiment score + language detection
2. **LLM pass** (on-demand via QueueView): full classification using Ollama or compatible endpoint

## Navigation Model

`SidebarItem` (defined in `RootView.swift`) drives the three-column `NavigationSplitView`:

| SidebarItem | Content column | Detail column |
|-------------|---------------|---------------|
| `.group(g)` | `GroupContentView` | `GroupChartsView` |
| `.account(a)` | `AccountContentView` | `AccountChartsView` |
| `.post(p)` | — | `ThreadView` |
| `.queue` | — | `QueueView` |
| `.settings` | — | `SettingsView` |

## Color System

`BlueXColors.swift` defines a dark-mode-only palette. Use `Color.speechClassBorder(_:)`, `Color.speechClassBackground(_:)`, and `Color.speechClassBadgeText(_:)` for annotation-class-aware coloring throughout the UI.

## Credentials

Bluesky credentials are stored in macOS Keychain via `KeychainCredentials`. Never in UserDefaults or files. App passwords (not account passwords) are used.
