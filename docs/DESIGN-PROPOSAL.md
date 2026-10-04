# Pensieve Design System Proposal

*A design system whose primary reference is Apple's own macOS apps — Finder, Mail, Notes, Photos — read alongside Apple's Human Interface Guidelines, with Mimestream and Chops as secondary references, the other acclaimed third-party native apps cited throughout as background craft citations, and a visual audit of Pensieve's current state.*

---

## Design Philosophy

### The North Star

Pensieve should feel like **an Apple app the user already knows how to use**. Finder, Mail, Notes, and Photos are the reference: existing Mac habits should transfer with no learning curve, and Pensieve should read as an extension of the Finder they already live in rather than a new thing to learn. (This supersedes the earlier "Bear meets 1Password" framing.)

Four principles, in priority order:

1. **Apple's conventions first.** Before designing a surface, find the stock app that already solves it, and adopt its pattern as it ships rather than improving on it.

   **Tier 1 — conventions, binding.** Apple's own apps: **Finder** (browsing, selection, ordering, file operations, sidebar sections), **Mail** (three-pane list/detail rhythm, toolbars, search), **Notes** (editing text inside a list-driven library), **Photos** (collection browsing, library sidebar, the info/inspector pane).

   **Tier 2 — secondary, non-binding.** **Mimestream** (a third-party app built deliberately on Apple's conventions — the proof that a non-Apple app can feel stock) and **Chops** (the closest domain analog: same stack, same three-pane shape, same audience — consulted for *what a skills app has to show*, not for how a Mac app should behave).

   **Background craft citations.** The other apps cited throughout this document (Things 3, Bear, iA Writer, Nova, Craft, 1Password, Raycast) remain useful for spacing, restraint, and polish, but they carry no authority over a pattern. Where any tier-2 or background reference disagrees with a tier-1 app, the tier-1 app wins.

2. **Content over chrome.** The skill body should dominate. UI surfaces (sidebar, toolbar, metadata) should recede. Study how Nova makes its chrome translucent and quiet while the editor area is vibrant. Study how iA Writer removes everything that isn't text.

3. **Native to the bone.** Use system fonts, system colors, system materials. If macOS already provides a pattern (sidebar vibrancy, selection highlighting, accent colors), use it — don't recreate it. Mimestream's entire color system is Apple's semantic colors with zero custom hex values in the chrome. That's why it feels native.

4. **Calm density.** Pensieve manages a library of text files — it should feel like a well-organized bookshelf, not a dashboard. Whitespace is structural, not decorative. Things 3 and Bear prove that generous spacing creates hierarchy without borders or boxes.

**Where there is no Apple analog, we own the opinion.** Deploy targeting, sync and conflict resolution, and skill provenance/versioning have no stock-app equivalent to copy. Those surfaces get a deliberate Pensieve-original pattern — assembled from native components and system behavior, but the arrangement is ours. Name it as ours and explain why it fits rather than inventing a convention and implying macOS already worked that way.

### Aesthetic Direction: The Well-Organized Workshop

Pensieve should feel like **a well-organized workshop** — orderly, capable, ready to use. Not playful (Bear's cozy den) and not clinical (1Password's vault). Somewhere between.

**First 3 seconds:** The user sees a clean, organized space. Skills are visible with enough context to scan quickly. Nothing demands attention. The app feels like it was already set up for them. The reaction is "oh, this is tidy" — not "wow, pretty" and not "where do I start."

**Emotional register:**
- Calm, not exciting
- Capable, not minimal (you can see the app does things, it's not hiding its power)
- Professional, not corporate (built by a developer for developers, not by a design agency)
- Warm neutral, not cold (system materials and semantic colors, but with enough spatial generosity that it doesn't feel sterile)

**What this means in practice:** When making taste calls the mechanics can't decide (should this be a badge or plain text? should this section have a background or not?), ask: "Does this make the workshop feel more organized, or more cluttered?" If more cluttered, cut it.

### What "Good" Looks Like

A developer opens Pensieve for the first time. They see a clean sidebar with their skill categories, a list of skills with enough context to identify each one, and a detail area that makes reading and editing markdown comfortable. They think: "This feels like a real Mac app." They don't think about the UI at all — they think about their skills.

---

## Visual Audit: Current State

> **Staleness note (2026-07-27):** the audit below dates from the pre-PLAN-02 era and was largely addressed by PLAN-02's polish pass (June 2026). It is retained as design rationale, but it no longer describes the live app — and the ~16 backend-dominant plans since PLAN-02 accreted **unaudited surfaces** this document never covered: the Projects / Categories sidebar sections (then stacked "Add X…" placeholder buttons when empty), sync affordances (bottom-corner "Set up sync" CTA), the Platforms collapsed panel, and toolbar growth. A 2026-07-27 side-by-side against Chops identified four gap themes for the pre-1.0 design pass: **list density & row design** (our heavy solid-fill card + "0 tags" noise vs compact rows with per-tool glyphs at 200+-skill scale), **empty states** (admin buttons standing where content should be), **detail-header hierarchy** (flat header, dead left gutter, cramped meta; Chops's frontmatter-as-code-block + bottom status bar are patterns worth stealing), and **chrome craft** (scattered toolbar icons, buried search). The design *system* in this file (colors/type/spacing/components) remains binding; the pass is about applying it to the new surfaces and re-judging density with a populated library. The approach is settled: design work runs as small changes against Apple's stock apps as the north star.

### Problems

| Issue | Current | Target | Reference App |
|-------|---------|--------|---------------|
| **No visual hierarchy** | Everything is the same gray/white weight | Clear primary/secondary/tertiary text layers | Mimestream: 85%/50%/25% opacity layers |
| **Sidebar is barren** | One "Library" section with "All Skills" | Meaningful navigation: categories, tags, projects with counts | Bear: tag hierarchy with counts |
| **Raw TOML in editor** | Users edit `format_version = 1` by hand | Structured metadata fields above a clean editor | iA Writer: editor is pure content |
| **Typography: all defaults** | System defaults with no hierarchy | Intentional scale with weight differentiation | Things 3: weight + size = hierarchy |
| **Monochrome palette** | Only color is blue badge + red unsaved text | One accent color used intentionally, semantic states | Craft: colorful but native |
| **Generic empty state** | "No Skill Selected" with stock icon | Purposeful empty state that guides action | Things 3: empty states inspire |
| **Skill row lacks context** | Name + scope badge + version (no description) | Name + description snippet + metadata | Mimestream: sender + subject + preview |
| **Flat detail header** | Name, badge, version, tokens in one row | Clear title prominence with subordinate metadata | Bear: note title dominates |
| **No spacing system** | Ad-hoc padding values (2, 3, 4, 6, 8, 10, 12, 16, 24) | Consistent 4pt/8pt grid | Raycast: 4/8/12/16/20/24/32 scale |
| **Platform panel** | Functional but visually crude | Polished section with clear deploy states | 1Password: complex data displayed simply |

### What's Working

- Three-panel NavigationSplitView layout is correct
- Platform panel concept (deploy/remove per platform) is good
- Token count indicator is useful
- Keyboard shortcuts are good (Cmd+N, Cmd+S)
- ContentUnavailableView for empty states is the right pattern

---

## Color System

### Principle: Semantic Colors Only

Follow Mimestream's approach: **zero custom hex values in UI chrome.** Use Apple's semantic colors for text (the frames' 85/50/25 % are exactly `.primary/.secondary/.tertiary`); the frames' fills (3 % and 6 % black) and text tints (60 %, 35 %) are named tokens in `DesignTokens.swift`, never a hex in a view. They automatically adapt to light/dark mode, accent color preferences, vibrancy, and accessibility settings.

One exception: the brand tiles on the Deployments tab (`PlatformMarkTile`) carry the brands' own colors — Claude Code's terracotta, OpenClaw's red, black and white for Codex, Cursor, and Grok — with a black or white ink, an 8 % black hairline, and a 5 pt radius, because a brand mark reads wrong in any other color; every other color in chrome stays semantic.

### Text Hierarchy

| Level | SwiftUI | Light Mode | Dark Mode | Usage |
|-------|---------|------------|-----------|-------|
| Primary | `.primary` | Black 85% | White 85% | Skill names, headings, body text |
| Secondary | `.secondary` | Black 50% | White 55% | Descriptions, subtitles, metadata labels |
| Tertiary | `.tertiary` | Black 26% | White 25% | Timestamps, version numbers, path text |
| Quaternary | `.quaternary` | Black 10% | White 10% | Watermarks, disabled text, empty state hints |

**Rule:** Never hardcode text colors. `.primary`, `.secondary`, `.tertiary` handle everything.

### Backgrounds

| Surface | SwiftUI | Usage |
|---------|---------|-------|
| Sidebar | System-managed | NavigationSplitView handles automatically — do not override |
| List background | `.background` | Middle column content area |
| Detail background | `.background` | Detail content area |
| Elevated surface | `Color(.controlBackgroundColor)` | Cards, panels |
| Secondary surface | `Color(.windowBackgroundColor)` | Window fill behind content |

**Rule:** Let NavigationSplitView manage sidebar material/vibrancy. Do not apply custom backgrounds to the sidebar.

### Accent Color

Use the **system accent color** (`Color.accentColor`) for all interactive elements. This respects the user's System Settings choice (blue by default, but some users set it to purple, pink, etc.).

| Element | Color |
|---------|-------|
| Selected sidebar item | System accent (automatic) |
| Selected list row | System accent (automatic) |
| Deploy/action buttons | `.accentColor` via `.buttonStyle(.borderedProminent)` |
| Links and interactive text | `.accentColor` |
| Toggle/switch states | System accent (automatic) |

### Status Colors

Use system semantic colors for status indicators:

| Status | Color | Usage |
|--------|-------|-------|
| Deployed/Linked | `Color.green` | Deploy status dot, "Linked" text |
| Warning | `Color.orange` | Unsaved changes, externally modified |
| Error | `Color.red` | Failed deploy, errors |
| Info | `Color.blue` | Informational badges |

### Badge/Tag Colors

For scope badges and tags, use tinted backgrounds with low opacity:

```swift
// Scope badges
Text("user")
     .font(.caption2)
     .foregroundStyle(.secondary)
       .padding(.horizontal, 6)
       .padding(.vertical, 2)
     .background(.fill.tertiary, in: Capsule())

// Tags
Text("swift")
     .font(.caption)
     .foregroundStyle(.secondary)
       .padding(.horizontal, 8)
       .padding(.vertical, 3)
     .background(.fill.quaternary, in: Capsule())
```

**Key change:** Replace `Color.blue.opacity(0.12)` and `Color.green.opacity(0.12)` with `.fill.tertiary` or `.fill.quaternary`. These are semantic fills that adapt to light/dark mode properly. The current hardcoded blue/green backgrounds for scope badges look non-native.

---

## Typography

> **Superseded for values, 2026-09-22.** The Sketch frames govern every size, weight, fill, and spacing; the measured values are in `Pensieve/Utilities/DesignTokens.swift`. The type scale and quick reference below are the principles' illustration, not values to build from: they named SwiftUI's fixed macOS styles (`.title2` = 17, `.headline` = 13 bold, `.caption` = 10) where the frames ink 22 bold, 16 semibold, and 12.

### Principle: SF Pro for Chrome, Monospace for Code

Use the system font (SF Pro) for all UI elements. Use `.monospaced()` or SF Mono for the editor and code display. No custom fonts needed — SF Pro at the right sizes and weights creates all the hierarchy Pensieve needs.

### Type Scale

Based on macOS actual point sizes:

| Style | Size | Weight | Usage in Pensieve |
|-------|------|--------|-------------------|
| `.title2` | 17pt | Regular | Skill name in detail header |
| `.title2` | 17pt | **Bold** | Sheet title; the one bold in that sheet |
| `.title3` | 15pt | Regular | Section headers ("Platforms", "Editor") |
| `.headline` | 13pt | **Bold** | Skill name in list row, primary emphasis |
| `.body` | 13pt | Regular | Body text, descriptions, metadata values |
| `.callout` | 12pt | Regular | Secondary descriptions, platform names |
| `.subheadline` | 11pt | Regular | Skill description in list row |
| `.footnote` | 10pt | Regular | Timestamps, file paths |
| `.caption` | 10pt | Regular | Badges, version numbers, token counts |

### Hierarchy Rules

1. **One bold per context.** In a list row, only the row's title is `.headline` (bold). Everything else is regular weight. In the detail header, only the skill name is `.title2`. This is how Things 3 creates hierarchy — weight, not decoration.

2. **Size creates sections, weight creates emphasis.** The detail header uses `.title2` (17pt) for the skill name. The section label "Platforms" uses `.title3` (15pt). Body content uses `.body` (13pt). Three sizes, clear hierarchy.

3. **Monospace is for content only.** The editor uses `.body.monospaced()` for editing SKILL.md files. The preview uses proportional rendering via MarkdownUI. Monospace never appears in chrome (no monospace version numbers, no monospace badges).

### Editor Typography

The editor is where users spend the most time. Its values are MarkEdit's, measured on 2026-09-16 and set in the CodeMirror theme (`webeditor/src/editor.mjs`, the WebKit bridge — never `TextEditor`): 12 px monospace on an 18 px line (1.5×), a 28 px gutter of right-aligned numbers with the content at 40, 12 px of padding above and below the text, a full-width caret-line band the appearance colors, and hanging indents so a wrapped list item continues under its text. Headings step up — 17, 15, and 13 px on 24, 22, and 20 px lines — in the heading blue; the rest of the palette is the masters'.

**File-row-blends-with-content pattern (iA Writer):** The Content tab's file row and editor share the detail background, with one separator between them. The controls read as part of the content rather than a second toolbar.

---

## Spacing System

### Principle: 4pt Base Grid

Every spacing value should be a multiple of 4. The one exception is the middle column's list row (§2), which takes Mail's measured 3pt line gap and 5pt padding.

### Scale

| Token | Value | Usage |
|-------|-------|-------|
| `xxs` | 2pt | Icon-to-text inline gap (rare) |
| `xs` | 4pt | Tight internal padding, between related text lines |
| `sm` | 8pt | Standard gap between list items, internal component padding |
| `md` | 12pt | Section padding within a view, label-to-content gap |
| `lg` | 16pt | Content area margins, group spacing, default `.padding()` |
| `xl` | 20pt | Major section spacing, scroll view edge insets |
| `xxl` | 24pt | Window-level margins, hero spacing |
| `xxxl` | 32pt | Maximum breathing room between major sections |

### Application

```swift
// List row (every section; ListRowView, §2) — lines 2 and 3 are optional per section
VStack(alignment: .leading, spacing: 3) {   // Mail's measured line gap (custom layout)
    Text(model.title).font(.headline)
    if let line2 = model.line2 { Text(line2).font(.subheadline) }
    if let line3 = model.line3 { Text(line3).font(.subheadline).foregroundStyle(.secondary) }
}
.padding(.vertical, 5)                       // Mail's measured row padding

// Detail view content: the header, the tab strip, then the tab's own scroll
VStack(spacing: 0) {
    SkillDetailHeader(...)                     // lg margins, md below
    DetailTabBar(...)                          // 31 pt, a hairline along its bottom
    // Overview: a ScrollView with lg margins and xxl between its groups; Deployments: the grouped Form's own spacing
}
```

### What to Fix

Current code uses ad-hoc spacing: `0, 4, 6, 8, 10, 12, 16, 24`. The values `6` and `10` are off-grid. Replace:
- `spacing: 6` → `spacing: 8` (sm)
- `spacing: 10` → `spacing: 12` (md)

### Border Radius Tokens

Raycast defines a full border-radius system. `CornerRadius` lives in `Constants.swift` and defines three levels:

| Token | Value | Usage |
|-------|-------|-------|
| `sm` | 4pt | Small badges, inline pills, tag capsules |
| `md` | 8pt | Cards, panels |
| `lg` | 12pt | Modal sheets, popovers, large containers |

```swift
enum CornerRadius {
    static let sm: CGFloat = 4
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
}
```

Note: `Capsule()` is still used for pill-shaped badges — these tokens are for `RoundedRectangle` contexts.

---

## Component Designs

### 1. Sidebar

**Reference apps:** Photos' People and Places, and Music's Artists and Genres. These tier-1 precedents put entity types in the sidebar and the entities themselves in the content area.

**Design:** The sidebar uses five section rows: Skills, Projects, Categories, Tags, and Machines. Machines appears only when sync is configured or a machine state exists, so an unconfigured app shows four rows. Selecting a row opens that section's searchable list in the middle column; selecting an entity opens its detail. The sidebar never grows one row per project, category, tag, or machine.

**Implementation notes:**
- Use one title-case row per `SidebarSection`, with no extra section headers.
- Use the SF Symbols: `tray`, `folder`, `square.stack`, `square.grid.2x2`, `tag`, and `display`. Every one is an outline glyph of uniform stroke weight, which is the Finder convention: the icon and its label dim together in an inactive window. Filled variants (`tray.full`, `desktopcomputer`, `rectangle.3.group`) stay darker than the text next to them when the window loses focus and read as a second, heavier tone; don't use them. The content column's rows carry no icon (§2, Mail's anatomy); the same symbols name each entity only in the lists' empty states, and Skills' empty states use `doc.text` and `sparkles`.
- **The sidebar is an AppKit source list.** It uses `NSOutlineView` with `style = .sourceList` and `rowSizeStyle = .default`. AppKit owns the emphasized selection, which appears only while the outline is the focused view of the key window; the unemphasized pill with an accent-tinted icon and title, including in inactive windows; and the row height, icon size, and text size, which follow the Sidebar icon size setting. The count badge is the one custom element: trailing, secondary, hidden at zero, white while emphasized, and never receives the unemphasized accent tint. This is OS-provided source-list behavior verified on macOS 26; the deployment target is macOS 14, where the installed OS supplies its own source-list look. Where a SwiftUI wrapper visibly diverges from the tier-1 pattern, use the AppKit control the pattern is made of.
- **Monochrome SF Symbols only** (Nova pattern) — no colored icons in the sidebar. Color is reserved for content.
- Let the system handle sidebar vibrancy — use only semantic colors. Never hardcode colors in the sidebar or vibrancy breaks.
- Keep the system row height and spacing.
- **Column width:** `.navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)`

### 2. List Row (Mail's anatomy)

**Reference:** Mail's message list, measured on 2026-09-07.

Every middle-column list uses the same `ListRowView`, fed by its section's pure `ListRows` builder. The row follows Mail's three-line anatomy: line 1: the title in `.headline`, with optional trailing state and date or count; line 2: the section's primary fact in `.subheadline`; line 3: the section's secondary fact in `.subheadline` and `.secondary`. The View menu can hide the second and third lines for each section; Tags has no third line, so its menu offers only the second.

Mail's measured metrics take precedence over the 4pt grid for this control. The row uses a 3pt line gap and 5pt vertical padding. It has no leading icon and no status dot. The glyph slot shows, in order of precedence, the orange conflict triangle, the accent update-available glyph, or the label-color GitHub mark.

```
Section     Line 1 (bold)          Trailing                    Line 2 (primary)                 Line 3 (secondary)
Skills      name                   [conflict|update|mark] date  deploy summary on this Mac     description
Projects    name                   "N skills" / unavailable    path, tilde-abbreviated, middle  git remote / marker / pending
Categories  name                   "N projects · M skills"     member project names             assigned skill names
Tags        tag                    "N skills"                  carrying skill names             —
Machines    name [+ " (This Mac)"] last published              detected agents                  "N user-wide skills · M project deploys"
```

The middle column stays at `.navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)`. Paths truncate in the middle; other lines truncate at the tail.

### 3. Detail View — Header

**Reference apps:** Bear (note title dominates), the App Store (descriptions that expand with `more`), 1Password (quiet provenance and fields)

**Design:** One header stays above every tab. It holds the skill name, a linked skill's repository and tracked ref, the description, tags, and status messages. The description is two lines until `more` expands it in place. The four text tabs are custom: macOS has no stock control for sections inside one detail pane.

```
┌─────────────────────────────────────────────────────┐
│  [+ ▾]                         [⋯]      [Search]   │
├─────────────────────────────────────────────────────┤
│                                                     │
│  stop-slop                                          │  ← .title2, bold
│  ⑂ owner/repo · main                                │  ← provenance
│  Remove predictable patterns from AI-written prose… │  ← two lines + more
│  swift  writing                                     │  ← tags
│                                                     │
│  Overview  Deployments  Content  History            │  ← text tabs
│  ─────────────────────────────────────────────────  │
│                                                     │
│  The selected tab's content                         │
│                                                     │
└─────────────────────────────────────────────────────┘
```

**Key changes:**
1. **Title prominence.** The skill name uses `.title2` at bold weight, the largest text in the detail.

2. **Provenance stays quiet.** A linked skill shows the git-branch mark, `owner/repo`, and its tracked ref on one line. An authored skill has no provenance line.

3. **The description expands in place.** It shows two lines with a fade and `more` when needed. Selecting another skill starts that skill collapsed.

4. **Tags and status stay in the header.** Tags sit under the description. Errors, external-change notices, local-edit notes, and conflicts sit below the tags, so they remain visible on every tab.

5. **Tabs own the detail's sections.** Overview, Deployments, Content, and History sit directly below the header. The selected tab is boxed on three sides over the strip's bottom hairline.

6. **The toolbar stays quiet.** Its detail controls are `+`, More, and Search. More holds the actions for the selected skill.

### 4. Editor Area

**Reference apps:** MarkEdit (every value), iA Writer (focus, muted chrome)

**Target properties** (set in `webeditor/src/editor.mjs`; the bridge's `MarkdownEditorWebView` hosts it):

- **12 px monospace on an 18 px line.** MarkEdit's defaults; the 1.5× ratio reads as prose without oversizing the column.
- **A 28 px gutter** of right-aligned line numbers; the active line's number and its band highlighted together.
- **Hanging indents.** A wrapped list item continues under its text, not under its marker.
- **Headings in the heading blue** (`#0f5db5` in light, `#6fb3ff` in dark), stepping 17/15/13 px.
- **Read-only for the bundle's other files.** The same editor with `setReadOnly(true)`: no caret, no edits, the pulldown chooses the file.
- **Explicit save:** Revert and Save appear in the file row while the text differs from the file; `Cmd+S` lives in the File menu; the standard unsaved-changes sheet guards every way out. Autosave was retired because every symlinked agent reads the canonical file, so a half-typed edit was live the moment it saved.

### 5. Deployments Tab

**Reference app:** System Settings (grouped form, compact switch rows)

Deployments uses a grouped `Form` with two sections:

- **This Mac** lists each installed agent with its 20 pt brand tile, name, and mini switch. A switch deploys the skill to every project on this Mac through that agent's machine-level location.
- **Projects** lists every registered project as a disclosure row. Opening one shows only the agents that support project deploys, with a switch for each. The footer opens Add Project.

If an agent is on for This Mac, its switch under every project is on and disabled with `On for every project on this Mac`. Turning off the This Mac switch reveals each project's own state again. A collapsed project row shows the marks for its active agents, or `Not deployed` when none are active.

Brand tiles are 20 × 20 pt with a 5 pt radius, the mark at 12 pt, and an 8 % inside hairline. Brand-tile colors are the single exception to semantic-only chrome. They identify the agents: Claude Code terracotta, OpenClaw red, Codex white, Cursor and Grok black, and Hermes on system gray.

### 6. Empty States

**Reference apps:** Things 3 (empty states inspire action), Craft (welcoming onboarding moments)

**Current state:** Generic `ContentUnavailableView` with "No Skill Selected."

**Target design:**

```swift
// No skill selected
ContentUnavailableView {
    Label("Select a Skill", systemImage: "doc.text")
} description: {
    Text("Choose a skill from the list, or press ⌘N to create one.")
}

// No skills exist
ContentUnavailableView {
    Label("No Skills Yet", systemImage: "sparkles")
} description: {
    Text("Import existing skills or create your first one.")
} actions: {
    Button("Import Skills") { showImportWizard = true }
         .buttonStyle(.borderedProminent)
    Button("Create Skill") { showCreateSheet = true }
         .buttonStyle(.bordered)
}

// No search results
ContentUnavailableView.search(text: searchText)
```

**Key changes:**
- Add actionable description text with keyboard shortcut hints
- Add action buttons in the "no skills" empty state
- Use `.search` variant for empty search results (system-provided)
- Choose SF Symbols that communicate purpose, not decoration

---

## Dark Mode

### Principle: Design for Dark Mode First, Verify in Light

Following Mimestream's approach (praised as "the most beautiful dark mode"):

1. **Base is warm charcoal, not pure black.** macOS dark mode uses `rgb(30, 30, 30)` — not `#000000`. This happens automatically when using semantic colors. Never hardcode `Color.black` or `Color.white`.

2. **Elevation through background shift.** Layers of depth are created by subtle background changes, not shadows. The sidebar is one shade, the list another, the detail another. NavigationSplitView handles this automatically.

3. **Opacity-based text hierarchy.** `.primary` at 85% white, `.secondary` at 55%, `.tertiary` at 25%. These create the same hierarchy as in light mode. Never use specific gray values (`Color.gray`) — they don't adapt.

4. **Status colors brighten in dark mode.** System green, blue, orange, and red all shift slightly to remain visible on dark backgrounds. This happens automatically with system colors.

5. **Borders and separators are subtle.** Use `Divider()` (system-managed, ~10% opacity) rather than custom borders. If a custom border is needed, use `.separator` color.

### What to Audit

Every hardcoded color in the current implementation needs to be checked:
- `Color.blue.opacity(0.12)` → `.fill.tertiary` or `.fill.quaternary`
- `Color.green.opacity(0.12)` → `.fill.tertiary`
- `Color.blue.opacity(0.1)` → `.fill.quaternary`
- `Color.green.opacity(0.1)` → `.fill.quaternary`
- `.background.secondary` → Verify this is `Color(.controlBackgroundColor)` equivalent

---

## Motion

### Principle: Minimal-Functional

Motion should aid comprehension, not decorate. Every animation answers "where did that come from?" or "what just happened?" — never "look how smooth this is."

### Transitions

| Action | Animation | Duration | Easing |
|--------|-----------|----------|--------|
| Disclosure group expand/collapse | Height + opacity | 200ms | `.easeInOut` |
| Tab switch (Overview / Deployments / Content / History) | None (instant) | — | — |
| Skill selection change | None (instant) | — | — |
| Sheet presentation | System default | System | System |

**Rule:** Never animate skill list selection changes. Instant response feels faster and more native. Sheets, popovers, and alerts should use system defaults — don't customize their presentation.

### Deploy Feedback

When a user clicks Deploy, the action should feel *real*. A silent status change is unsatisfying. Add a brief confirmation animation:

```swift
// Deploy success feedback
withAnimation(.easeOut(duration: 0.3)) {
    deployState = .deployed
}

// The status dot scales up briefly, then settles
Circle()
    .fill(Color.green)
    .frame(width: 8, height: 8)
    .scaleEffect(justDeployed ? 1.5 : 1.0)
    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: justDeployed)
```

After deploy completes:
1. Status dot pulses from 1.0 → 1.5 → 1.0 scale (spring, ~300ms)
2. Status text changes from "Not connected" → "Linked" / "Compiled"
3. Button changes from "Deploy" → "Remove"
4. `justDeployed` resets to `false` after 600ms via `DispatchQueue.main.asyncAfter`

This is the Things 3 principle: small, satisfying confirmation that the action worked. Not flashy. Just real.

### What NOT to Animate

- Text content changes (skill name, description, body)
- Search filtering results
- Sidebar navigation
- Window resizing
- Scroll position changes

These should be instant. Animation on content changes feels laggy, not smooth.

---

## Default view

### Overview first, then where you left off

The detail starts on Overview, where the summary, source, and bundle contents are easiest to scan, and Content starts in its rendered form. Moving between skills keeps the tab, the file, and the rendered or source view you last chose; a skill with an unsaved draft opens on its source. The source control reveals the editor for `SKILL.md` or a read-only view for another bundle file.

---

## Window Configuration

### Minimum Size

Current: `minWidth: 900, minHeight: 600` — this is good.

Default window size: 1280 × 850.

### Column Proportions

```swift
NavigationSplitView(columnVisibility: $columnVisibility) {
    SidebarView()
          .navigationSplitViewColumnWidth(min: 160, ideal: 200, max: 260)
} content: {
    SkillListView()   // and every other section's list
          .navigationSplitViewColumnWidth(min: 220, ideal: 280, max: 360)
} detail: {
    DetailView()
          .navigationSplitViewColumnWidth(min: 400, ideal: 500)
}
```

The sidebar and content columns carry these widths (`ContentView`, `ContentColumnView`, and each section's list view). The detail column has no width modifier yet and takes SwiftUI's default.

### Toolbar Configuration

The toolbar has three regions. The sidebar toggle comes first. The content column holds the title and subtitle, then Filter on Skills and View on every section. The detail region starts with +, followed by a flexible space, More, and Search.

The + adds what the current sidebar section holds: a skill, project, or category. It is absent for Tags and Machines.

---

## Design Tokens Reference

For implementation, these are the concrete values to use:

### Typography Quick Reference

```swift
// Detail header
Text(skill.name).font(.title2.weight(.bold))
Text(skill.skillDescription).font(.body)

// List row (ListRowView) — trailing text and lines 2 and 3 are optional per section
Text(model.title).font(.headline)                                                        // 13pt bold
if let trailing = model.trailingText { Text(trailing).font(.subheadline).foregroundStyle(.secondary) } // 11pt, Mail's date column
if let line2 = model.line2 { Text(line2).font(.subheadline) }                            // 11pt
if let line3 = model.line3 { Text(line3).font(.subheadline).foregroundStyle(.secondary) } // 11pt

// Section headers
Text("Source").font(.headline)
Text("LIBRARY").font(.subheadline).foregroundStyle(.secondary)   // 11pt (sidebar)
```

The editor's type is set in `webeditor/src/editor.mjs`: 12 px monospace on an 18 px line, with a 28 px gutter.

### Spacing Quick Reference

```swift
// Spacing constants (define in a central location)
enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}
```

### Color Quick Reference

```swift
// Use semantic colors in chrome; brand-tile colors are the single exception.
.foregroundStyle(.primary)           // Main text
.foregroundStyle(.secondary)         // Descriptions
.foregroundStyle(.tertiary)          // Metadata, timestamps
.foregroundStyle(.quaternary)        // Watermarks

.background(.fill.tertiary)         // Subtle badge backgrounds
.background(.fill.quaternary)       // Very subtle tag backgrounds

Color(.controlBackgroundColor)       // Elevated cards/panels
Color(.textBackgroundColor)          // Editor background
Color(.separatorColor)               // Custom separators (prefer Divider())

Color.accentColor                    // Interactive elements (system accent)
Color.green                          // Deployed status
Color.orange                         // Warning state
Color.red                            // Error/destructive state
```

---

## Appendix: App-by-App Lessons Applied

| Lesson | Source App | How It Applies to Pensieve |
|--------|-----------|---------------------------|
| Chrome quietness — mute everything that isn't content | Nova | Sidebar and toolbar use system materials, recede visually |
| Typography IS the design | iA Writer | Font size + weight creates all hierarchy, no decorative boxes |
| Warm dark mode (~rgb(30,30,30)) | Mimestream | Never use pure black; semantic colors handle this |
| Opacity-based text layers (85/50/25/10%) | Mimestream | Use `.primary/.secondary/.tertiary/.quaternary` |
| One bold per context | Things 3 | Only the row's title is bold in a list row, only the name in the detail header |
| Tag hierarchy with counts in sidebar | Bear | Tags section shows tag + badge count |
| Content-forward detail view | 1Password | Title dominates, metadata subordinate, actions accessible |
| 4/8pt spacing grid | Raycast | Every spacing value is a multiple of 4, except the Mail-measured list row (§2) |
| Sections inside one pane as text tabs | — (no stock control) | Overview / Deployments / Content / History under one header; Overview default |
| Editor metrics from a shipping Mac editor | MarkEdit | 12 px on 18 px lines, a 28 px gutter, the caret band (§4) |
| Status dots for deploy state | Mimestream | Small colored dots instead of text-only status |
| Empty states guide action | Things 3, Craft | Action buttons + keyboard shortcut hints in empty states |
| System accent color everywhere | All of them | Never hardcode blue — use `Color.accentColor` |
| Satisfying micro-interactions on actions | Things 3 | Deploy gets a spring-scale pulse on the status dot |
| Overview first, rendered content second | Bear, Craft | Start on the summary and render Content until source is requested; keep the reader's place across skills |
| Trailing glyphs carry state, not leading icons | Mail | Rows have no leading icon; Skills reserve one trailing slot for conflict, update, or the GitHub mark |
| "Well-organized workshop" aesthetic | Original (Pensieve-specific) | Orderly, capable, ready. Not playful, not clinical. |

---

*This proposal is a living document. Update it as design decisions are made and patterns are validated in implementation.*
