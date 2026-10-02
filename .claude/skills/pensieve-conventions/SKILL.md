---
name: pensieve-conventions
description: Swift and SwiftUI conventions for the Pensieve codebase. Load when writing or modifying Swift code in this project.
---

# Pensieve Code Conventions

## Architecture

- **Three-layer pattern**: Models (SwiftData `@Model`) → Services (protocol-based) → ViewModels (`@Observable`) → Views (SwiftUI)
- **All file I/O goes through `FileService`** — never use `FileManager` directly in services, view models, or views. `FileService` conforms to `FileServiceProtocol` for testability.
- **Services use protocols** for testability: `FileServiceProtocol`, `SkillStoreProtocol`, `LinkServiceProtocol`, etc. Inject protocols, not concrete types.
- **Skill body lives on the filesystem** (`~/.pensieve/skills/{name}/SKILL.md`), metadata lives in SwiftData. Never duplicate the markdown body into the database.

## SwiftUI Patterns

- Use `@Observable` (Observation framework), NOT `ObservableObject` / `@Published`
- Use `@MainActor` on view models and any class that touches UI state
- Navigation: `NavigationSplitView` three-column layout (sidebar, list, detail)
- Prefer SwiftUI-native controls. This is a native macOS app — it should feel like one.

## SwiftData

- `@Model` classes in `Pensieve/Models/`
- Relationships use SwiftData's `@Relationship` macro
- The `modelContainer` is configured in `PensieveApp.swift` and passed through the environment

## Naming & Style

- No force unwrapping (`!`) except in tests
- Prefer `guard let` for early returns over nested `if let`
- Use `async/await` for concurrency, not completion handlers
- File names match the primary type they contain: `SkillStore.swift` contains `SkillStore`
- Test files: `{ServiceName}Tests.swift` in `PensieveTests/ServiceTests/` or `PensieveTests/ParserTests/`

## Testing

- All tests use **temp directories** for filesystem operations, cleaned up in `tearDown`
- Test against protocols, inject mock/stub implementations
- Test file fixtures go in `PensieveTests/Fixtures/`
- Existing test coverage: SkillParser, SkillSerializer, LinkService, CursorCompiler, SkillStore, TokenCounter, ImportScanner

## Project Generation

- **Never modify `.xcodeproj` directly** — edit `project.yml` and run `xcodegen generate`
- When adding new Swift files, add them to the appropriate target in `project.yml` under `sources`
- SPM dependencies are declared in `project.yml` under `packages` and linked in target `dependencies`

## Directory Structure

```
Pensieve/
  Models/          — @Model classes (Skill, Project, DeployRecord, etc.)
  Services/        — Protocol-based services
  ViewModels/      — @Observable view models
  Views/
    MainWindow/    — ContentView, SidebarView, SkillListView, DetailView
    SkillViews/    — Editor, preview, metadata bar, create sheet
    PlatformViews/ — Platform panel, target row
    ImportViews/   — Import wizard, results list
    ProjectViews/  — Project list, add project sheet
    SettingsViews/ — General + platform settings
  Utilities/       — Constants (paths, token budgets)
```

When creating new views, place them in the appropriate subdirectory. When creating new services, create both the protocol and the concrete implementation.
