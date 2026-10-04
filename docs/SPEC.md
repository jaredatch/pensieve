# Pensieve Product Specification

## Product Definition

Pensieve is a native macOS app that manages AI skills (markdown instruction files) and keeps them in sync across multiple AI coding agents and across multiple machines. It provides a single canonical store for skills, deploys to each agent in its native format, and keeps every agent and machine consistent.

> This spec documents the implemented product mechanics: the canonical store, per-agent deploy, cross-machine sync, and GitHub install/update flows.

### What "skill" means

A **skill** is a markdown file containing instructions for an AI coding tool — coding conventions, review checklists, framework-specific guidance, workflow rules. Each platform has its own format and file location. Pensieve stores one canonical copy and deploys it everywhere.

### Target user

Developers who use multiple AI coding tools (Claude Code, Grok, Codex, Cursor, OpenClaw, Hermes, and more), often more than one at once and increasingly across more than one machine, and want consistent skills everywhere without manually managing files in different formats and locations.

---

## Storage Model

### Canonical Store

All skills live as self-describing `SKILL.md` files in `~/.pensieve/skills/`:

```
~/.pensieve/skills/
├── typescript-best-practices/
│   └── SKILL.md                 ← YAML name+description frontmatter + body (self-describing)
├── code-review-guidelines/
│   └── SKILL.md
└── react-patterns/
    └── SKILL.md
```

**Skill body is on disk only.** SwiftData stores metadata (name, description, tags, scope, Cursor config); the markdown content is never duplicated into the database. The on-disk `SKILL.md` is **self-describing** (YAML `name`+`description` frontmatter + body), and the durable bookkeeping SwiftData holds is also mirrored to a portable **manifest overlay** under `~/.pensieve/manifest/` (schema v5) so a fresh machine can rebuild its index from disk alone (see `docs/ARCHITECTURE.md` §2). Per-entry machine deploy intent lives under `manifest/deploys/` and can target the whole Mac or a project identity key. Each machine also publishes a read-only snapshot under `~/.pensieve/machines/`; its canonical UUID appears in that synced filename and payload and in deploy-intent paths. The local `machine-id` seed file, local paths, secrets, and SwiftData remain outside the synced facts. There is no `version` field; git is the version truth.

### Metadata (SwiftData)

| Field | Type | Description |
|-------|------|-------------|
| `id` | UUID | Unique identifier |
| `name` | String | Display name |
| `skillDescription` | String | Short description |
| `tags` | [String] | Categorization tags |
| `scope` | SkillScope | `.user` (everywhere) or `.project` (specific project) |
| `directoryName` | String | Slug used for filesystem directory name |
| `cursorConfigData` | Data? | JSON-encoded Cursor adapter config |
| `createdAt` | Date | Creation timestamp |
| `updatedAt` | Date | Last modification timestamp |
| `importedFrom` | String? | Source platform if imported |
| `installedOriginData` | Data? | Codable cache of the manifest's schema-v3 `InstalledOrigin` fact |
| update-check fields | mixed | Per-machine `lastCheckedAt`/head, available commit/tree/date, error, and `updateAvailable`; never synced |

---

## Canonical Skill Format (self-describing)

The canonical `SKILL.md` that Pensieve creates is a genuine, spec-valid **Agent-Skills** file: standard **YAML frontmatter** carrying exactly `name` + `description` (the two fields the ecosystem requires; there is no `version` field because git is the version truth), followed by the markdown body. It is the same file every agent's deploy symlink points at, so a deployed skill is portable and discoverable everywhere. Pensieve parses frontmatter with **Yams** and composes new files with a hand-rolled canonical writer. There is no Pensieve-specific field in the file; the earlier TOML `format_version` format is superseded.

When Pensieve saves a body edit to an existing skill, it replaces only the body. Every other byte stays as written, including frontmatter keys Pensieve does not own, comments and formatting, and the file's trailing-newline state. A store migration may normalize `name` and `description`; it preserves every other frontmatter entry verbatim and leaves the file unchanged with a warning when it cannot split those entries safely.

```yaml
---
name: TypeScript Best Practices
description: Enforce TypeScript conventions and patterns
---

# TypeScript Best Practices

Always use strict mode. Prefer `const` over `let`.
```

**Required frontmatter:** `name`, `description` — both non-empty. `ParsedSkill.hasRequiredFrontmatter` gates import preservation, migration, and rebuild admission; a body-only file *parses* (as all-body) but is **not** an admissible skill.

**GitHub-installed third-party skills are vendored byte-pristine.** Pensieve copies the complete selected directory, including scripts, references, assets, and owner-executable mode; symlinks and special files are refused. If you later edit the skill's body, Pensieve preserves the frontmatter and every other byte it does not own. New Pensieve-authored skills and Cursor rules start in canonical form. A skill imported from a local folder keeps its whole `SKILL.md`, with only `name` and `description` set. Adopting an existing skill records provenance and local drift without rewriting or merging its bytes.

**Everything else Pensieve tracks** about a skill — scope, tags, Cursor adapter config, provenance/`origin`, durable `created_at`, and the deploy-target `agents` allowlist — lives in the **per-entity YAML manifest overlay** under `~/.pensieve/manifest/` (categories and one `skills/<slug>.yaml` per skill), outside any skill file. Manifest schema v5 retains schema v3's installed-origin data and schema v4's machine-scoped deploy-intent files at `manifest/deploys/<machine-id>/<slug>.yaml`. A file's `platforms` list targets the whole Mac; its optional `projects` entries pair a project identity key with a platform list. Presence is intent; deleting the last scope retracts the file. Local update-check flags and realized assignment ledgers never enter the manifest.

**On disk at `~/.pensieve/skills/`:** the self-describing `SKILL.md` (YAML `name`+`description` frontmatter + body) — readable, symlinkable, and a valid skill in every agent that reads it.

---

## Platform Adapters

Claude Code, Grok, Cursor, Codex, OpenClaw, and Hermes ship today. Grok (`~/.grok/skills/{name}/`, project-level `{project}/.grok/skills/{name}/`), OpenClaw (`~/.openclaw/skills/{name}/`, user-wide only), and Hermes (`~/.hermes/skills/pensieve/{name}/`, user-wide only, nested under the default category) are whole-directory symlinks exactly like Claude Code's. A generic custom-agent adapter for any other tool that reads the standard `SKILL.md` directory format is deferred.

### Claude Code

| Property | Value |
|----------|-------|
| Deploy mechanism | **Symlink** (directory) |
| User-wide path | `~/.claude/skills/{name}/` → symlink → `~/.pensieve/skills/{name}/` |
| Project-level path | `{project}/.claude/skills/{name}/` → symlink → `~/.pensieve/skills/{name}/` |
| Format | Standard markdown (SKILL.md inside directory) |
| Token budget | Advisory, default 2,500 tokens |

Edits to the canonical SKILL.md are visible instantly — the symlink points to the same file.

### Cursor

| Property | Value |
|----------|-------|
| Deploy mechanism | **Compiled** (.mdc file) |
| User-wide path | `~/.cursor/rules/{name}.mdc` |
| Project-level path | `{project}/.cursor/rules/{name}.mdc` |
| Format | `.mdc` with YAML-like frontmatter |
| Token budget | Advisory, default 5,000 tokens |

Generated `.mdc` format:
```
---
description: TypeScript conventions
globs: **/*.ts, **/*.tsx
alwaysApply: false
---

# Skill content here
```

Cursor-specific config (description, globs, alwaysApply) is stored as JSON on the Skill model. Only Cursor needs per-platform adapter config; every other shipped agent gets a symlink.

Freshness is checked by comparing the full generated output against the existing file. If the skill body or Cursor config changes, the `.mdc` needs recompilation.

### Codex

| Property | Value |
|----------|-------|
| Deploy mechanism | **Symlink** (directory user-wide, file project-level) |
| User-wide path | `~/.codex/skills/{name}` → symlink → `~/.pensieve/skills/{name}` (whole directory) |
| Project-level path | `{project}/agents/{name}.md` → symlink → `~/.pensieve/skills/{name}/SKILL.md` |
| Format | Standard markdown |
| Token budget | Unlimited |

Codex deploys both user-wide and project-level. User-wide deploy is a whole-directory symlink at `~/.codex/skills/{name}` pointing at the canonical skill directory; project-level deploy writes a `{project}/agents/{name}.md` file symlink to the canonical `SKILL.md` when the user registers a project in Pensieve. The symlink target is scope-aware (directory vs. file).

---

## Import

### First-Run Scanner

On first launch (when no skills exist in SwiftData and the store's manifest is readable — an unreadable store fences every add instead), Pensieve opens an import wizard that scans for existing skills:

| Platform | Scan paths |
|----------|-----------|
| Claude Code | `~/.claude/skills/*/SKILL.md` |
| Grok | `~/.grok/skills/*/SKILL.md` |
| Cursor | `~/.cursor/rules/*.mdc` |
| Codex | `~/.codex/skills/*/SKILL.md` |

Anything whose path lands in or passes through `~/.pensieve/` — a deploy symlink, a `SKILL.md` that is itself a link, a link along the way — is excluded (already managed by Pensieve; the check is by the file system's identity, so a differently cased spelling is the same directory).
When a skills directory's children are enumerated (Claude Code, Grok, Codex, and a chosen folder of
skills), dot-entries are skipped — Codex keeps `.system` beside its skills; a folder you choose
explicitly may itself be a dot-folder, and Cursor's `.mdc` scan filters by extension only. Import from
Folder… (⌘⇧I, in the + menu) scans one chosen folder: either the folder is a skill, or its immediate
children are. It never scans deeper and refuses Pensieve's own library.

### Import Flow

1. Scanner discovers skill files across platforms
2. Results shown grouped by source platform
3. Duplicate detection: skills with >80% word-level similarity (Jaccard) are flagged
4. User selects which skills to import (all selected by default)
5. Each imported skill's whole `SKILL.md` is written to `~/.pensieve/skills/{slug}/SKILL.md` with only `name` and `description` set, and its metadata goes into SwiftData. When its frontmatter can't be kept safely, a fresh `name`/`description` header goes on top and the whole source follows as the body, and the done step names that skill. A `SKILL.md` that's a symlink or a special file isn't offered (PLAN-42). Neither is a scanned `SKILL.md` or `.mdc` that's a link, a special file or over 4 MiB, and the results and done steps say how many entries were skipped and why (PLAN-48)
6. Cursor `.mdc` imports extract frontmatter (description, globs, alwaysApply) and store as Cursor adapter config

### Slug Generation

Skill names are slugified for directory names: lowercased, non-alphanumeric stripped, spaces → hyphens. Collisions get a `-2`, `-3` suffix.

```
"TypeScript Best Practices" → typescript-best-practices
"TypeScript Best Practices" → typescript-best-practices-2 (if collision)
```

## Install from GitHub

Pensieve accepts three GitHub HTTPS forms: a repository URL, a `/tree/<ref>/<path>` skill-directory URL, or a `/blob/<ref>/<path>/SKILL.md` URL. Direct tree/blob links do not support refs containing `/`; paste the repository URL to discover skills from its default branch instead. Other hosts, schemes, embedded credentials, ports, traversal components, and commit-permalink refs are rejected before git runs.

### Install Flow

1. Choose **Add Skill from GitHub…** and paste a supported URL.
2. Pensieve reconstructs the repository remote, shallow-clones it, and discovers skills only at the repository root, `skills/<name>`, `skills/<category>/<name>`, and `.claude/skills/<name>`. A direct tree/blob link targets one directory.
3. The picker shows every candidate. Missing/invalid required frontmatter and symlink-bearing candidates remain visible but cannot be selected.
4. Select skills and install. Pensieve vendors each complete skill directory byte-pristine into the canonical store and records schema-v3 `InstalledOrigin` coordinates.
5. A slug collision can be skipped, renamed, or adopted. Adopt links the existing skill to the named repository and flags local drift; it never merges or overwrites the existing files.

The network path is git-only (`ls-remote` and shallow `clone` through `GitService`); there is no GitHub API client. Public repositories need no credential. Private repositories use only the fine-grained PAT stored in the separate `github.com#install` Keychain slot, never the sync credential.

Installing does not deploy automatically. The vendored bytes enter the canonical store and therefore ride ordinary cross-machine sync; each machine's existing deploy state determines where they appear.

## Skill Updates

Update checks are manual or run when the foreground schedule is due. Pensieve batches linked skills by repository/ref, resolves each remote head once, shallow-clones only moved heads, and compares the git tree for each installed skill directory. Check results and pinned upstream coordinates are per-machine SwiftData state; the synced manifest is unchanged. A failure that belongs to this Mac (git unusable, no network) leaves each affected skill's check result as it was and reports one error for the run. A run that hit such a failure with no source answering doesn't count as the scheduled run, so the next launch tries again.

### Update Flow

1. Run **Check for Updates** for one skill, or let the Off/Daily/Weekly foreground schedule check when due.
2. A quiet notice appears when checked, non-error skills have updates. Open it to see the update list and select rows. Each row shows the source repository (`owner/name`, from the validated parse — or a "Source unavailable" indicator when the stored origin no longer parses) and the in-repo path, so a repointed origin is visible before applying.
3. **View Changes** verifies the row's pinned commit and tree, then shows a read-only `SKILL.md` diff. A GitHub compare link covers the complete upstream change.
4. **Update Selected** re-fetches and verifies the same pinned commit before using any bytes. If the branch moved, Pensieve refuses the apply and asks for a re-check.
5. If the canonical copy has local edits, that row requires explicit overwrite confirmation. A confirmed update atomically replaces the complete vendored directory, refreshes `InstalledOrigin`, and clears its local update flags. One failed row does not abort the rest.

Pensieve never auto-installs skill updates. Scheduled work detects and reports them; applying third-party content is always a user action.

---

## Token Budget Validation

Token counting uses **char/4 heuristic** (1 token ≈ 4 characters). Advisory, not enforced.

| Status | Condition | UI |
|--------|-----------|-----|
| OK | < 80% of budget | No indicator |
| Warning | 80-100% of budget | Yellow |
| Exceeded | > 100% of budget | Red |

Default budgets: Claude Code 2,500, Grok 2,500, Cursor 5,000, Codex unlimited. User-configurable in Settings.

Settings stores the budgets, but nothing reads them yet. `TokenCounter.budgetStatus` has no caller, so no skill shows the Warning or Exceeded state (#52).

---

## Skill Scopes

| Scope | Deployed to | Active in |
|-------|------------|-----------|
| **User** (`scope = "user"`) | User-level paths (`~/.claude/skills/`, `~/.cursor/rules/`) | Every project |
| **Project** (`scope = "project"`) | Project-level paths (`{project}/.claude/skills/`, etc.) | That project only |

Project assignment is app state (SwiftData), not file state. The canonical SKILL.md doesn't know which projects it's assigned to. This is intentional — project paths differ across machines.

**Project targeting.** A user registers project directories from the Projects list in the middle column; the Deployments tab has a section per scope — This Mac, then each registered project — and the bulk sheet a target picker: This Mac or any registered project. **Claude Code, Grok, Codex, and Cursor support project-scoped deploy** (they have a project-level skill path); OpenClaw and Hermes are user-wide-only and are filtered out of the agent list while a project is the target. Each registered project also gets a stable cross-machine identity, either a normalized git remote or a committed `.pensieve-project` UUID marker when there is no remote, so the same project is recognized across machines even though its absolute path differs. Selecting a project in the Projects list opens its detail in the third column: path, identity status, category membership, and a snapshot of the skills that reach it — both deployed and assigned-but-not-yet-deployed.

**Machine targeting.** With This Mac as the target, the bulk deploy sheet adds a machine picker. It lists This Mac, machines with published state, and intent-only machines marked `unseen`. Selecting This Mac records synced intent and applies it locally for locally installed agents (intent for an agent this Mac lacks is recorded but not realized); selecting only remote machines records intent without creating a local artifact. Remove retracts intent for the selected machines and only removes locally when This Mac is selected. Project mode hides the machine picker, writes project-scoped intent addressed to This Mac, and immediately reconciles it into every registered checkout with that project identity. The manifest and local intent rows carry the direct project×machine intent, so another Mac can apply it when that project is registered there.

---

## Categories

Categories let a user group registered projects and deploy a skill to a whole class of projects with one **standing rule**, kept in sync as the class changes — the management move no CLI does.

- **A category** (the Categories section's list → `CategoryDetailView` in the detail column) owns **member projects** and **assigned skills**, managed as toggles in one surface. A skill **assigned to a category** is *bound* to it: it deploys to **every** member project, and stays correct as the category changes.
- **Standing-rule semantics.** Add a project to the category → the category's assigned skills auto-deploy into it. Un-assign a skill (or delete the category, or remove a project from it) → those category-managed deploys are reconciled **off** the member projects' directories — rules govern files (a deliberate contrast with the non-destructive project-*unregister*, which leaves files in place). Install a new project-capable agent → the next reconcile fans the category's skills out to it.
- **Where it deploys.** A category assignment fans out to **all project-capable installed agents** — Claude Code, Grok, Cursor, and Codex ∩ installed; per-category agent selection is a future, additive refinement. The surface derives this list from `PlatformTarget.allCases`.
- **Keyed by stable identity.** A category stores membership by `Project.identityKey` and assignment by `Skill.directoryName` (the cross-machine **stable identities**), never local UUIDs — so a synced category resolves correctly on another machine (cross-machine sync of rules is itself a BETTER milestone). A project whose identity is still pending (no `identityKey`) is shown non-addable with a hint.
- **Resilient + idempotent.** Each change reconciles desired-vs-current at `(skill, project, agent)` granularity and surfaces a quiet result summary (failures called out the `BulkDeploySheet` way); one failing project/agent never aborts the rest, and a failed write retries on the next reconcile.

---

## Resident Background Sync and Machines

Pensieve owns background sync in the main app. Launch at Login is optional. Closing the last window leaves the process running in the menu bar; Open Pensieve restores the main window and Quit ends the process.

Pensieve creates an empty manifest scaffold at launch, before sync is configured. The first Mac with local skills initializes an empty remote and pushes its store. A fresh additional Mac should connect before importing or creating skills: Connect adopts the launch-created store in place — fetching the existing remote, materializing the tree, and rebuilding the local index — when the store is provably safe to adopt. Safe means no local branch, every synced model family empty, and a disk shape that is either the virgin scaffold (stray `.DS_Store` entries and a `.git` left by an interrupted attempt are tolerated) or a partial tree fetched by Pensieve's own interrupted adoption, recognized by the matching origin plus the remote-tracking ref that fetch created — never local-only content of the user's. A branch-less repository that fits neither shape gets an explicit error with nothing on disk or in the index mutated. Everything else keeps its ordinary connect path: stores with a local branch re-point their remote, first Macs with local skills initialize and push, and a plain target with no repository and no skills still clones.

The scheduler requests sync at process launch, every 15 minutes, after wake, and 30 seconds after a synced-state change. It waits until both coordinator bootstrap and launch ingestion are ready, allows one cycle at a time, and folds overlapping triggers into one follow-up. Scheduled work is skipped when background sync is off, no remote is configured, git is known to be unusable on this Mac, or a conflict needs attention. Sync Now remains available as a manual request, except while a conflict waits: then it's refused from every entry point until the conflict is resolved.

Each cycle pulls and pushes from a fresh SwiftData context off the main actor. Before snapshotting, the engine-owned lock runs an ingest preflight so a CLI fast-forward cannot be overwritten by stale app state. The same hook publishes this machine's state. Successful cycles self-heal deploy artifacts; cycles that ingest a new HEAD also re-run category and machine-intent reconciliation locally.

Each installation has a canonical UUID in app support. Its single-writer `machines/<id>.yaml` snapshot reports the machine name, app version, snapshot update time, detected agents, stable project identities, and realized user/project deploys. The snapshot is republished only when its content changes, with content compared across parsed known fields while ignoring the timestamp. An absent or unreadable snapshot takes the rewrite arm for self-heal; if publication fails, sync continues and reports a warning. Pull and push still run on every sync cycle; only the commit is content-gated, so an idle sync cycle creates no commit. The read-only Machines section appears in the sidebar when sync is configured or machine files exist; its machines are listed in the middle column. Selecting a machine shows when its known state was last updated, app version, agents, local-project overlap, remote-only projects, and realized deploys. Remote project state never registers a project locally.

---

## UI Model

### Three-Panel Layout (NavigationSplitView)

```
┌──────────┬────────────────────────────────┬───────────────────────────────────┐
│ Sidebar  │ Skills                 [≡] [⋯] │ [+ ▾]                [⋯] [Search] │
│          │ 4 skills                       │                                   │
│ Skills   │ basecamp              ⓖ 9/5/26 │ basecamp                          │
│ Projects │ Claude Code, Codex · This Mac  │ ⑂ 37signals/basecamp · main       │
│ Categori…│ Interact with Basecamp via the…│ Interact with Basecamp via the…   │
│ Tags     │ skill-b                        │ typescript  code-quality          │
│ Machines │                                │ Overview Deployments Content Hi…  │
│          │                                │ ───────────────────────────────── │
│          │                                │ [Context cost] [Bundle] [Deployed]│
│          │                                │ Source                            │
│          │                                │   Repository   37signals/basecamp │
│          │                                │   Local path   ~/.pensieve/skills…│
│          │                                │ Contents                          │
│          │                                │   SKILL.md      ▇▇▇▇▇▇▇▇  412 tok │
└──────────┴────────────────────────────────┴───────────────────────────────────┘
```

**Sidebar:** An AppKit source list (`NSOutlineView`, `.sourceList` style, hosted in SwiftUI), so selection, row height, icon size, and text size are the system's and follow System Settings › Appearance › Sidebar icon size; the trailing count badge is the one custom element. Five section rows — Skills, Projects, Categories, Tags, and Machines (the Machines row appears only when sync is configured or a machine has reported). Selecting a section fills the middle column with that section's entries; selecting an entry fills the detail column. Search sits at the toolbar's trailing edge, over the detail column, and filters the middle column's list by name (the Skills list also matches description and tags). A tag is an entity: its detail view lists the skills carrying it, and clicking one reveals it in Skills; the Skills Filter menu can also narrow the list to skills carrying chosen tags. The middle column's toolbar holds Filter (Skills) and View options; adding lives in the detail toolbar's leading + control, which serves Skills, Projects and Categories and is absent for Tags and Machines; rename and remove stay in row context menus. Removing a project deletes only the registration record, never the directory.

**Skill List:** Each row follows Mail's anatomy: a bold name; at the trailing edge, the conflict triangle, the update-available glyph, or the GitHub mark in that order of precedence, then the date; Pensieve's recorded deploy summary on this Mac; and the description. The two-line title reads "No skills", "4 skills", or "2 of 4 skills" when narrowed. The Filter menu groups Deployed on This Mac, Source, Tags, and Categories; choices within Tags and Categories match any selected value, while groups combine with AND. The deploy summary and Deployed group read Pensieve's recorded deploy state for this Mac. The Deployments tab reads the filesystem and stays the truth where they disagree: a deploy to a project without an identity is not recorded (Pensieve assigns a project's identity only when it is registered and does not retry), and launch backfill rediscovers user-wide symlinks by scanning but everything else only from persisted deployment history. An unreadable ledger disables the Deployed group and shows "Deploy state unavailable" in place of the summary. Changes made by the `pensieve-daemon` CLI appear after the next in-app deploy or remove, launch, or successful sync; a cycle that ends conflicted, locked, remote-less, or failed refreshes nothing. The filter is per window and is not remembered. The View menu controls each section's optional lines and adds Sort By for Skills, which defaults to Name A to Z. Projects, Categories, Tags, and Machines share the same row anatomy with section-specific facts.

**Tags:** Tags are edited as tokens in the skill detail's metadata area through an
`NSTokenField`-backed field, with completion suggestions from tags already in use. Pensieve
stores them in the manifest overlay as its own metadata and never changes `SKILL.md` to save them.
Folder and machine imports seed tags from source `SKILL.md` frontmatter.

**Detail:** One header — the skill's name, where it came from (repository and tracked ref for a GitHub skill), its description with a `more` link past two lines, its tags, and any status — over four tabs: Overview, Deployments, Content, and History. Overview shows what the skill costs to load, what its folder holds, and how many installed agents have it on this Mac, then its source (repository, tracked ref, local path, and dates) and its files with a token bar each. Deployments is laid out like System Settings: This Mac lists the installed agents with a switch each; each other Mac with published state gets its own section and agent switches; and Projects combines registered projects with those the other Macs publish, each opening to the project-capable agents. A whole-Mac deploy reads on and disabled under that Mac's projects with the reason. A published deploy with no standing intent reads on and disabled with `Turned on from <Mac>`. Remote switches write intent for that Mac and take effect when it next syncs; Add Project sits at the bottom. Content shows the rendered file or its source, with a pulldown over the bundle's text files; SKILL.md's source is the editor, and Revert and Save appear in the file row while something is unsaved (File › Save, `Cmd+S`, saves too). Leaving an unsaved edit by any route — another tab, another file, the rendered view, another skill or section, the window closed, quit, Skill Updates, or the file changing on disk — asks first with the standard Save / Don't Save / Cancel sheet, which names the skill; Delete asks its own confirmation and names an unsaved edit. History lists the versions saved in the sync repo, newest first, with View Diff and Restore This Version…, which confirms before writing. For a skill installed from GitHub, History shows the origin repository's commits to that skill instead — hash, date, author, subject, files and lines changed, newest first — marks the installed version and any newer one as available, shows unsaved local edits as a row with per-file counts, and offers View Diff, View Edits, and Update to This (which opens Skill Updates). The read runs on demand over git through the install path's remote and credential and keeps no clone. After the first successful read, Pensieve keeps the parsed rows on disk and shows them right away on later visits and launches. It checks the upstream head once per skill per launch and refreshes only when that head moved or the user asks. Existing rows stay visible with a small status while a refresh or wider read runs; if a refresh fails, they remain with Try Again. With no kept rows, the tab shows the original loading or failure row. The detail toolbar reads +, More (Reveal in Finder, View on GitHub, Copy Local Path, Check for Updates, Deploy…, Delete Skill), then Search; an unlinked skill's More menu offers Connect to Repository… for adoption.

### Keyboard Shortcuts

App-wide shortcuts live in the menu bar's command groups, never only on a toolbar item.

| Shortcut | Action |
|----------|--------|
| Cmd+N | New skill (File menu; replaces the standard New group, so there is no New Window — Pensieve is a single-window app) |
| Cmd+Shift+I | Import from Folder… (File menu). Opens a directory chooser; a skill folder or a folder of skills; also in the + menu |
| Cmd+S | Save (File menu). Writes the edited skill; enabled only while something is unsaved |
| Cmd+Delete | Delete Skill (File menu). Asks first; also in the More menu and the list's context menu |
| Cmd+, | Settings |

Add Skill from GitHub…, Check All Skills for Updates, and Check for Updates… are menu items without shortcuts. Sheets use Return/Escape as their default and cancel actions.

### Settings

**General tab:**
- Skills directory path (default `~/.pensieve/skills/`)
- Machine display name
- Launch at login, background sync, and beta-update toggles
- **Skill Updates:** Off, Daily, or Weekly (default Weekly) schedules detection on launch/foreground. Check Now runs against every installed skill immediately, even when the schedule is Off; File › Check All Skills for Updates does the same. Detection never applies an update.

**Platforms tab:**
- Token budgets per platform (Claude Code, Grok, Cursor, Codex)
- Platform path display for Claude Code, Grok, and Cursor (read-only)

**GitHub tab:**
- Fine-grained personal access token for private skill repositories
- The token needs Contents read-only access to each repository it installs from
- Save/Remove controls report presence without reading the secret back into the UI
- Stored in the `github.com#install` Keychain namespace, separate from the sync credential

---

## Deploy Records

Each deploy/remove action is tracked in SwiftData:

| Field | Description |
|-------|-------------|
| `skillID` | Which skill was deployed |
| `platform` | Target platform |
| `targetPath` | Where the symlink/file was created |
| `deployedAt` | Timestamp |
| `contentHash` | Hash of skill body at deploy time |
| `projectID` | Which project the deploy targeted, if project-scoped (optional) |

Used for freshness checking and deployment history. `DeployRecord` is **append-only/historical**: removing a deploy does not delete its record — live connected-state is read from the filesystem (symlink presence), not derived from record counts.

---

## Error Handling

| Case | Behavior |
|----------|----------|
| Symlink target doesn't exist | Create parent directories first |
| Symlink already exists (stale) | Remove old, create new |
| Permission denied | Show error with full path |
| Cursor write fails | Show error with full path |
| `~/.claude/` doesn't exist | Skip gracefully during import |
| YAML frontmatter absent (it must open on the file's first line and close at a column-0 `---`), unparseable, or refused by the checked loader (a non-scalar key, an alias bomb) | Treat body as all-content; not admitted unless `name`+`description` are present |
| Skill name collision | Append `-2`, `-3` suffix |
| Deploy to Cursor via symlink | Reject with error — Cursor uses compiled output |
