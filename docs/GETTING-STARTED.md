# Getting Started with Pensieve

Pensieve is in public beta. If something feels broken or confusing, [open an issue](https://github.com/jaredatch/pensieve/issues) so we can improve it.

## What is Pensieve

Pensieve is a native macOS app that manages your AI skills (the `SKILL.md` instruction files that Claude Code, Grok, Codex, Cursor, and friends read) in one place. You keep a single library, deploy any skill to every agent on your machine with a click, and sync the whole library across your machines through a private git repo you own.

The problem it solves: every agent reads skills from its own directory (`~/.claude/skills/`, `~/.grok/skills/`, `~/.codex/skills/`, `~/.cursor/rules/`, ...). Install a skill once and it lands in exactly one of them. Run two agents and you install it twice; add a second machine and twice again. The pain scales with agents times machines. Pensieve collapses that to one library.

## How it works

One mental model covers everything:

**There is a single canonical store at `~/.pensieve/skills/`.** Each skill is a plain `SKILL.md` file (standard Agent Skills format: YAML `name` + `description` frontmatter, then markdown) in its own folder, plus a small manifest of bookkeeping (tags, categories, project identities) under `~/.pensieve/manifest/`. The store is fully portable and self-describing: point any tool at it and the files make sense on their own.

Everything else derives from that store:

- **Agents get symlinks.** Deploying a skill to Claude Code, Grok, Codex, OpenClaw, or Hermes creates a symlink from that agent's directory into the canonical store. Edit the skill once and every agent sees the change instantly, because they're all reading the same file. Cursor is the one exception: it gets a compiled `.mdc` file, since that's the format it wants.
- **Machines sync the store, not the agent directories.** Cross-machine sync pushes `~/.pensieve/` through a private git repo you supply. Each machine pulls the store and re-fans-out to its own local agents. N agents times M machines becomes just M.

Your files stay plain markdown on your disk the entire time. There's no proprietary database holding your content (the app keeps a metadata index, but it's rebuilt from the files, never the other way around). Delete Pensieve tomorrow and every skill is still sitting in `~/.pensieve/skills/` as readable markdown.

## Install

The easy way, with Homebrew:

```sh
brew install --cask jaredatch/tap/pensieve
```

Or grab the DMG from [Releases](https://github.com/jaredatch/pensieve/releases): download, open, drag to Applications. Every build is Developer ID signed and notarized, and updates arrive automatically through Sparkle once you're running.

If you'd rather build from source (an Apple silicon Mac with Xcode 26):

```sh
brew install xcodegen
git clone https://github.com/jaredatch/pensieve.git && cd pensieve
xcodegen generate
open Pensieve.xcodeproj   # then press Run in Xcode
```

Or skip Xcode's UI entirely:

```sh
./script/build_and_run.sh
```

One heads-up: Pensieve is unsandboxed on purpose. It needs to write symlinks into `~/.claude`, `~/.codex`, and the rest, which the App Store sandbox doesn't allow.

## First 10 minutes

1. **Launch it.** On first run with an empty library, Pensieve opens an import wizard that scans for skills you already have: `~/.claude/skills/`, `~/.codex/skills/`, `~/.grok/skills/`, and `~/.cursor/rules/`. Results are grouped by source, near-duplicates get flagged, everything is selected by default. Import what you want; each skill's whole `SKILL.md`, frontmatter and all, is copied into the canonical store. Anything already symlinked into `~/.pensieve` is skipped as already managed. You can rerun the scan anytime from the + menu's Find Skills on This Mac…, and Import from Folder… (`Cmd+Shift+I`) imports a folder of your choosing instead. One exception: if Pensieve can't read the library (say, a newer version wrote it), it says so in the window and holds off on adding anything until you update.

2. **Browse the library.** Three panels: a sidebar of sections (Skills, Projects, Categories, Scenarios, Tags — plus Machines once sync is in the picture), the middle column listing whatever section you picked, and detail. Search sits at the right end of the toolbar and filters the list you're in. The detail starts on **Overview**; the **Content** tab shows the rendered file, and its source toggle turns it into an editor (syntax highlighting, line numbers; `Cmd+S` or the Save button saves, Revert drops the edit — nothing reaches your agents until you save).

3. **Deploy a skill.** Select a skill and open its **Deployments** tab. Pensieve detects which agents you actually have installed and only shows those. Deploy to Claude Code, then verify it yourself:

   ```sh
   ls -la ~/.claude/skills/
   ```

   You'll see a symlink pointing into `~/.pensieve/skills/`. That's the whole trick. Remove the deploy in the app and the symlink goes away; the skill stays in your library.

4. **Register a project.** Open the Projects section and add a project directory with the toolbar's + button, or use Add Project at the bottom of a skill's Deployments tab. This is what enables project-scoped deploys (a skill that's active only inside that repo, via `{project}/.claude/skills/` and friends).

5. **Make a category.** Open the Categories section, create something like "Swift", and add a couple of registered projects to it. Now assigning a skill to that category deploys it to every project in the category, and keeps doing so as the category changes. More below.

## Feature tour

### The library and editor

By default, every skill row shows its name, its recorded deployment summary on this Mac (or "Deploy state unavailable"), and its description. The View menu can hide the deployment or description line.

A skill's detail is a header (name, where it came from, description, tags) over four tabs:

- **Overview:** what the skill costs to load, what its folder holds, and where it's deployed on this Mac.
- **Deployments:** a switch per agent, for this Mac, each registered project, and (once sync is set up) your other Macs.
- **Content:** the rendered file. Switch to source to edit it in a real code editor. Nothing is saved until you press Save or `Cmd+S`, and leaving with unsaved changes asks first.
- **History:** the versions saved in your sync repo, newest first. View Diff shows what changed since a version, and Restore This Version… puts it back.

Edit a skill's tags right in the header, with suggestions from tags you already use. Pensieve keeps them in its own metadata and leaves `SKILL.md` alone. File › Export SKILL.md… saves a copy anywhere you like.

If you edit a `SKILL.md` outside the app (terminal, vim, whatever), Pensieve's filesystem watcher notices and refreshes, with a small notice that the file changed outside the app. If you had unsaved edits, it asks before replacing them. Useful shortcuts: `Cmd+N` new skill, `Cmd+S` save, `Cmd+Delete` delete.

### Deploy targets and install detection

Six agents ship today:

| Agent | Mechanism | User-wide location |
|---|---|---|
| Claude Code | symlink | `~/.claude/skills/{name}/` |
| Grok | symlink | `~/.grok/skills/{name}/` |
| Codex | symlink | `~/.codex/skills/{name}` |
| OpenClaw | symlink | `~/.openclaw/skills/` |
| Hermes | symlink | `~/.hermes/skills/{category}/` |
| Cursor | compiled `.mdc` | `~/.cursor/rules/{name}.mdc` |

Pensieve only offers agents it detects on your machine (config dir, app bundle, or CLI on `PATH`). Skills can be user-wide (active everywhere) or project-scoped; Claude Code, Grok, Codex, and Cursor support project-scoped deploys, while OpenClaw and Hermes are user-wide only. Cursor skills carry a bit of per-skill config (description, globs, alwaysApply) that Pensieve compiles into the `.mdc` frontmatter.

### Projects and categories

A registered project gets a stable identity: its git remote, or a small committed `.pensieve-project` marker if it has no remote. That identity, not the path, is how the same project is recognized on your other machines.

A category is a standing rule. Assign a skill to a category and it deploys to every project in that category, across your installed project-capable agents, and stays correct as things change: add a project to the category and the skills fan out to it; un-assign a skill and its category-managed deploys are cleaned back off. This is the management move a stateless CLI can't do.

### Bulk operations

Multi-select skills and deploy, remove, or recompile in one pass. One failing item doesn't abort the rest; you get a summary of what succeeded and what didn't.

### Token counts

Every skill shows an estimated token count (a chars/4 heuristic) against a per-agent budget: 2,500 for Claude Code and Grok, 5,000 for Cursor, unlimited for Codex, all configurable in Settings › Platforms. It's advisory only. Nothing is ever blocked, you just get a yellow or red indicator when a skill is getting heavy. Handy once your library grows past what you can eyeball.

### Installing from GitHub

Choose Add Skill from GitHub… from the + menu and paste a repository, a skill folder, or a direct `SKILL.md` link. Pensieve finds the skills inside and remembers where each one came from. Private repos work once you've saved a personal access token in Settings › GitHub.

When the original changes, Pensieve tells you with a notice above the Skills list, and you read the diff before anything updates. It checks on its own, or you can ask with File › Check All Skills for Updates. An installed skill's History also shows commits from its original repository and marks the version you installed.

### Scenarios

A scenario is a named, user-wide group of skills you switch on as a unit: "iOS work" loads your Swift and review skills, "writing" loads your prose ones. Activating a scenario deploys its members to the agents it names; switching to another removes the old scenario's deploys and adds the new one's. Skills you deployed manually are left alone; scenarios only manage their own.

Scenario *definitions* sync across machines. Which scenario is *active* is per-machine, so your laptop and your desk machine can be in different modes.

### Sync setup

Sync runs through a git remote you own. Setup:

1. For your first Mac, create an **empty, private** repo on GitHub (or any git host). Private matters: your skills may encode how you work. Import or create your local skills, then connect the repo.
2. On each fresh additional Mac, dismiss the import wizard and connect that same repo before adding local skills. Pensieve creates a small empty scaffold on launch; Connect recognizes it, adopts it in place, and brings down your existing library on the first try. You do not need to delete `~/.pensieve` first.
3. HTTPS remotes authenticate with a personal access token, which Pensieve stores in the macOS Keychain and never writes to disk or `.git/config`. SSH remotes go through your existing `ssh-agent`, so if `git push` works in your terminal, it works here.
4. Sync. `~/.pensieve` becomes a git working tree; Pensieve commits, pulls, and pushes it for you.

To stop syncing, use Disconnect… in Settings › Sync. It removes the link to the repo and the token saved for it, and leaves your skills and their history alone.

Concurrent edits from two machines usually merge automatically (membership lists like category assignments union-merge). When both machines edit the same skill body, you get a conflict sheet: a diff of the two versions, and you pick a side. You will never be dropped into raw `<<<<<<<` markers. And since git is quietly keeping every revision, each skill's History tab lets you look back and restore.

### Background sync

Sync runs inside the app itself. Pensieve can launch at login and stays in the menu bar after you close its last window, so it's always around to sync: at launch, every 15 minutes, after your Mac wakes, and after synced changes land. Each cycle pulls, pushes, and self-heals your deployed files; when a cycle brings in new changes, it also reapplies your category, scenario, and machine deploy rules (symlinked agents see new content immediately anyway; stale Cursor `.mdc` files get recompiled). Pensieve compares the parsed fields it knows about and republishes a machine's readable snapshot only when its content actually changes. If the snapshot is missing or corrupt, Pensieve tries to repair it. That keeps idle Macs from stamping timestamp-only commits into the sync repo's history.

Since always-on machines are often driven over SSH, a small companion CLI ships in the app bundle for checking on things from a terminal:

```sh
pensieve-daemon status     # sync health at a glance
pensieve-daemon log        # recent daemon activity
pensieve-daemon run        # trigger a pull right now
pensieve-daemon deployed   # what this machine has deployed where
```

The binary lives inside the app bundle at `Pensieve.app/Contents/MacOS/pensieve-daemon`.

## Multi-machine notes

- Point every machine at the **same** private remote. Each machine pulls the shared store and fans out to its own local agents.
- Absolute paths never sync, on purpose. Projects are matched by their stable identity (git remote or marker), so `~/code/foo` on the laptop and `~/dev/foo` on the desktop resolve to the same project. A synced project you haven't registered locally simply doesn't fan out on that machine.
- Which scenario is active stays local to each machine. Everything else worth seeing (app version, detected agents, registered projects, what's actually deployed) shows up read-only in the MACHINES section, so you can check on any Mac from any other.
- You can deploy to your other Macs from this one. A skill's Deployments tab lists each of them with its projects, and the bulk deploy sheet can target machines too. Each Mac picks up the change on its own next sync, for the agents it actually has installed.
- **One real caveat, worth reading twice:** update Pensieve on *every* syncing Mac together. Some releases move the library to a newer format, and older versions refuse to read it rather than risk damaging it. A Mac left behind stops syncing and says why until you update it.

## FAQ

**Is my data locked in?**
No. Skills are plain `SKILL.md` markdown files in `~/.pensieve/skills/`, in the standard Agent Skills format. The manifest is a handful of small YAML files. `cat` them, grep them, commit them, walk away with them.

**What does Pensieve write outside `~/.pensieve`?**
Only what you deploy: symlinks (or the compiled `.mdc` for Cursor) into the agent directories you chose, plus a small `.pensieve-project` marker if you register a project that has no git remote. App-internal state lives in `~/Library/Application Support/Pensieve`. It never touches anything else.

**Does it phone home?**
No. No telemetry, no analytics, no Pensieve server. The only network traffic is git talking to the remote *you* configured, and if you never set up sync there's no network traffic at all.

**What if I edit a `SKILL.md` in a terminal or another editor?**
Totally supported. The filesystem watcher picks up the change and refreshes the app, with an indicator that the file was modified externally. Since deployed symlinks point at the same file, every agent sees your edit immediately too.

**What happens if two machines edit the same skill?**
The next sync detects the conflict and shows a diff-and-pick sheet: both versions side by side, you choose. Nothing is silently overwritten, and version history has your back if you pick wrong.

**Can I use it with an agent you don't support?**
Not yet. Any agent that reads standard `SKILL.md` from a known directory is a natural fit, and letting you register a custom agent by name and path is on the backlog. For now it's the six above.

**Why isn't it in the App Store?**
The sandbox. Pensieve writes symlinks into directories like `~/.claude` and `~/.cursor`, which the App Store sandbox doesn't allow. Builds are Developer ID signed and notarized instead, and ship through Releases and Homebrew.

**Do I need to know git to use sync?**
You need to be able to create a private repo and (for HTTPS) mint a token. That's it. Pensieve drives git itself and is specifically designed so you never see a raw merge conflict. It does use the git on your Mac, so if that's broken (the Xcode license hasn't been accepted, or the Command Line Tools are missing), Settings › Sync says so and gives you the Terminal command that fixes it.

**How do I uninstall or bail out?**
Delete `Pensieve.app`. Your skills remain in `~/.pensieve/skills/` as plain files, and any deployed symlinks keep working since their target still exists. If you want the agent directories cleaned too, remove the deploys in the app first, or delete the symlinks by hand. Nothing about your setup is held hostage.

**What macOS version do I need?**
macOS 14 or later.

**Where do I report bugs?**
[Open an issue](https://github.com/jaredatch/pensieve/issues) on the public repo. Notes on what confused you are as valuable as crashes.

## What's coming (not here yet)

- **Item taxonomy:** skills, agents, and rules as distinct types with their own deploy behavior.
- **Drift indicators:** surfacing when a project's copy of a skill diverges from the canonical one, with clear resolve actions.

Everything else you may have heard mentioned (marketplace aggregation, team libraries, an MCP server) is further out. What's in this build is what's described above.

Happy dogfooding. Break it and say how.
