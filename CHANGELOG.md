# Changelog

All notable changes to Pensieve are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Pensieve is open source. The code lives at [github.com/jaredatch/pensieve](https://github.com/jaredatch/pensieve), and that's the place to report a bug or ask for something.

- Pensieve has its own glyph in the menu bar, in place of the stock brain symbol.

- A skill that's close to or over a platform's token budget now says so on its Overview tab.

### Removed

- Scenarios are gone. Skills they deployed stay in place, and existing scenario files stay in your synced store for older builds.

### Changed

- The skill preview stays offline. An image a skill links from the web shows its alt text instead of loading, so opening a skill never pings someone else's server. Images in the skill's own folder, and images embedded in the file, still show.
- Import from Folder skips linked files, pipes and anything over 4 MiB, and tells you how many it skipped and why. The "kept as text" notice now lists each skill on its own line.
- Frontmatter has to start on a skill's first line, the way your agents read it. If there are blank lines above the opening `---`, Pensieve reads the whole file as text. Skills already in your library stay put either way.

### Fixed

- History's line counts for your local edits now match what `git diff` reports.
- Pensieve could freeze while running git on Macs with only a few cores. Several git commands at once could wait on each other forever. They don't anymore.
- A crafted `SKILL.md` could trick Pensieve into rewriting the wrong line of its frontmatter on import or upgrade. Pensieve now only rewrites a key when it and the YAML parser agree on exactly where that key starts, and it double-checks the result. If anything looks off, the file stays as it was.
- Saving a skill with Windows line endings no longer shows up as a change made outside the app.

## [0.14.0] - 2026-09-30

This one's big. Five weeks of work went into it, and most of it is about the skill itself: it gets a real page with tabs, a History you can restore from, saving that waits for you, tags, and deployments that follow you to your other Macs.

**Heads up if you sync more than one Mac:** update all of them to 0.14.0 before you sync. This version moves your synced library to schema 5 so it can remember where each skill is deployed, and older versions refuse to open it.

### Added

- A skill now opens as one page: its name, where it came from, its description and tags up top, then four tabs. Overview shows what the skill costs to load, what's in its folder and where it's deployed. Content shows the file, rendered or as source.
- Deployments is laid out like System Settings. This Mac lists your agents with a switch each. Projects lists your registered projects with their own switches. Your other Macs show up too: flip a switch there and that Mac picks it up on its next sync.
- Where a skill is deployed is now remembered and synced. Rebuild a Mac and its deployments come back.
- History is a tab: every version saved in your sync repo, newest first. View Diff shows what changed, and Restore This Version… puts one back. For a skill you installed from GitHub, it also shows the original repository's commits, marks the one you have and flags anything newer. After the first visit it opens instantly, even after a relaunch.
- Tags. Add them right in a skill's header, with suggestions from tags you already use. They live in Pensieve's own records, so your `SKILL.md` stays untouched. Imported skills keep the tags in their frontmatter, and the Tags section has its own list and detail.
- Import from Folder… (`Cmd+Shift+I`, or the + menu). Pick one skill folder, or a folder full of them.
- File › Export SKILL.md… saves a copy anywhere you like. It's in the right-click menu too.
- Check Now (Settings › General) and File › Check All Skills for Updates check every installed skill in one go.
- Settings › Sync has a Disconnect… button. It unlinks your sync repository and forgets its token. Your skills, their history and your GitHub token stay put.
- The first-launch scan now finds skills in Codex's `~/.codex/skills` too.

### Changed

- Editing no longer saves as you type. Change something and Revert and Save show up above the editor, and `Cmd+S` works. Nothing reaches your agents until you save.
- Leave a skill with unsaved edits (switch skills, close the window, quit, delete it) and you get the familiar Save / Don't Save / Cancel sheet. If the file changes on disk while you're editing, say from a sync pull, Pensieve asks the same question instead of swapping your text out.
- The editor got a makeover in the spirit of MarkEdit: SF Mono with roomier lines, a highlight on the current line, headings that grow with their level, code on a soft gray pill, and long lines that wrap.
- Everything you can do to a skill lives in one More menu: Reveal in Finder, View on GitHub, Copy Local Path, Check for Updates, Deploy… and Delete Skill. Delete is in the File menu too (`Cmd+Delete`) and asks once.
- Importing keeps the whole `SKILL.md`, so `license:`, `allowed-tools:`, `metadata:` and your comments come along. If Pensieve can't safely read a skill's frontmatter, it adds a fresh name and description on top, keeps the rest below, and tells you which skill it was.
- The sidebar works like Finder's now and has six sections: Skills, Projects, Categories, Scenarios, Tags and Machines. It follows your Sidebar icon size setting, and sync status is one quiet line. Point at it and click to sync.
- The middle column borrows from Mail: tidy two- and three-line rows, a Filter menu, Sort By and View options.
- The + button is one menu: New Skill, Import from Folder…, Find Skills on This Mac… and Add Skill from GitHub…. `Cmd+N` still makes a skill right away, and you land on it.
- When updates are available, the notice sits above the Skills list and stays put while you scroll.
- Sync gets set up in Settings › Sync, which also holds the Background sync switch.
- Settings › GitHub shows a green check when your token is saved, with Replace… for a new one. Settings fills in your Mac's name, and Platforms shows Grok's budget and folder.
- Check for Updates shows that it's working. When GitHub can't be reached, it says so in plain words instead of printing git's error.
- Pensieve keeps to one main window. New windows open at 1280 × 850.

### Fixed

- No more "Apple could not verify Pensieve is free of malware" on a fresh install. The notarization ticket now travels inside the app, so Gatekeeper can check it offline. This only hit Homebrew installs or drags from the .dmg on a Mac that couldn't reach Apple at that moment. If 0.13.0 is stuck for you, run `xattr -dr com.apple.quarantine /Applications/Pensieve.app` once, or use Open Anyway in System Settings › Privacy & Security.
- A YAML file with a list or map as a key, like `? [x]`, no longer crashes Pensieve, and one built to blow up through aliases no longer hangs it. Either could arrive through sync or a GitHub install. A bad manifest now stops the sync before anything changes.
- When git itself is broken (the Xcode license isn't accepted, or the Command Line Tools are missing), Pensieve says so and gives you the Terminal command that fixes it. Sync stops before touching your library, and your skills don't all get marked with errors. Once git works again, the message clears on its own. You don't need to relaunch.
- Editing a skill installed from GitHub no longer drops the rest of its frontmatter.
- Sync no longer makes a project-only change every cycle when your Macs register different projects. Every Mac needs 0.14.0 for this one.
- Delete Skill actually deletes now, and it cleans up the links Pensieve made for your agents.
- If a newer version of Pensieve wrote your library, this one says so instead of greeting you with the welcome sheet.
- Undo can't roll a freshly opened skill back to blank anymore.
- Sync Now in the menu bar waits while a sync conflict needs your answer.
- GitHub installs accept `github.com/...` without the `https://`.
- Sheets fit the smallest window, and a few bits of wording are fixed ("Just now" instead of "in 0s", "Install 1 Skill").

### Removed

- The old background-sync launchd job. 0.12.0 and 0.13.0 only kept it around to switch it off.
- The toolbar's Link Claude Code button and `Cmd+L`. Deploy from the Deployments tab.

## [0.13.0] - 2026-08-26

### Fixed

- Sync no longer creates timestamp-only machine-state commits every cycle. The Machines view line now reads "Last updated": it tells you when Pensieve's known state for that machine last changed, not whether the Mac is online. Macs on older versions that publish machine state (that's 0.12.0) keep republishing every cycle until they update.

## [0.12.0] - 2026-08-20

### Added

- Pensieve now lives in your menu bar. It can launch at login and keeps running after you close the last window, so sync keeps working without you thinking about it.
- Background sync moved into the app: it syncs at launch, every 15 minutes, after your Mac wakes, and after synced changes land. Each cycle pulls, pushes, and reapplies your category, scenario, and machine deploy rules.
- A new MACHINES section shows every synced Mac: app version, detected agents, registered projects, and what's deployed there.
- Deploys can target machines. Pick one or more Macs for a user-wide deploy and each one applies it on its own next sync, for the agents it actually has installed.

### Changed

- The launchd sync job is retired; the app handles sync now. The bundled `pensieve-daemon` sticks around for SSH use: status, logs, deployed-state inspection, and an on-demand run.
- The synced manifest moves to schema 4 to carry machine deploy intent. Update every syncing Mac to 0.12.0 before creating your first machine-targeted deploy.

### Fixed

- Connecting a fresh Mac to your sync repo now works on the first try. (It used to trip over its own launch scaffold. It doesn't anymore.)

## [0.11.0] - 2026-08-14

### Added

- Grok is now a first-class agent. Pensieve spots it on your machine (config directory or CLI on PATH), deploys skills to it user-wide or per-project, and the import wizard picks up anything already living in `~/.grok/skills`. Same one-click flow as every other agent.

### Changed

- Deploy got more careful: if a real file or directory is already sitting at a deploy path, Pensieve now refuses and says so instead of overwriting it. Symlinks still get replaced or repaired like always.
- Scenarios are kinder to your other machines. If a synced scenario mentions an agent this build doesn't recognize, editing the scenario keeps that value instead of quietly deleting it.
- Multi-machine users: update every machine to 0.11.0 before assigning Grok to a scenario — older versions silently drop it on any scenario edit

## [0.10.0] - 2026-08-12

### Added

- Install skills from a GitHub repository URL, a skill directory, or a direct `SKILL.md` link. Pensieve finds skills in the usual repository layouts and copies the selected files byte for byte.
- Private GitHub repositories work with a fine-grained personal access token stored in Keychain and sent only to github.com.
- Tracked skills show their repository, branch, commit, and install date. Locally created skills can connect to a repository later.
- Pensieve checks tracked skills for upstream commits on a configurable schedule, shows diffs before updating, and supports individual or batch updates.
- Name collisions can be resolved by renaming the incoming skill or adopting the existing local skill.

### Changed

- Locally edited skills require explicit confirmation before an update can overwrite them. Batch updates skip those edits instead of clobbering them.
- The skill store upgrades to schema 3 on first launch. Older Pensieve versions refuse the upgraded store, so synced machines must be updated together.

## [0.9.1] - 2026-07-27

- Maintenance release for the initial signed and notarized distribution pipeline.

## [0.9.1-beta.1] - 2026-07-24

- Prerelease that verified Sparkle's beta channel without changing the stable Homebrew cask.

## [0.9.0] - 2026-07-24

- First signed, notarized, and publicly distributed Pensieve release.
