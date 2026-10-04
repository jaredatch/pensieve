# Security

## Reporting a vulnerability

Please report it privately through [GitHub's vulnerability reporting](https://github.com/jaredatch/pensieve/security/advisories/new) rather than in a public issue. Say what you found, how to reproduce it, and which version of Pensieve you ran (Pensieve › About Pensieve).

Pensieve is maintained by one person, so a reply can take a few days. Fixes ship in a new release through the usual update channel, and only the latest release gets them.

## What Pensieve writes, and where

Pensieve isn't sandboxed. Its whole job is writing into other apps' folders, which the App Store sandbox doesn't allow. Here's where it writes:

- **Your library** in `~/.pensieve/`, with one folder per skill under `~/.pensieve/skills/`. With sync on, it's a git repository.
- **Agent folders.** A deployed skill becomes a symlink into your library in `~/.claude/skills/`, `~/.codex/skills/`, `~/.grok/skills/`, `~/.openclaw/skills/` or `~/.hermes/skills/pensieve/`. Cursor gets a generated `.mdc` file in `~/.cursor/rules/` instead.
- **Project folders,** when you deploy to one project. Claude Code and Grok get a symlink in the project's `.claude/skills/` or `.grok/skills/`. Codex gets a symlinked `agents/<name>.md` file, and Cursor a generated `.cursor/rules/<name>.mdc`. OpenClaw and Hermes deploy for the whole Mac only.
- **A project marker,** `.pensieve-project`, holding a random ID. It's written into a project Pensieve can't identify by its git remote: one with no `origin`, or a git worktree or submodule.
- **App data** in `~/Library/Application Support/Pensieve/`: a sync log, lock files, deploy state, a machine ID, and scratch folders for installs and update checks.
- **Its own preferences and database,** in the usual macOS locations for an app.

A symlink deploy never replaces a real file or folder. If something other than a link is already there, Pensieve refuses. A new skill's folder name is reduced to lowercase letters, digits and hyphens. A name Pensieve finds on disk or in a sync must be a single folder name, not `.` or `..`, and its folder must resolve inside the library without a symlink. A name written into the sync manifest also can't start with a dot or hold control characters. Either way, a name can't climb out of the folder it belongs in. File access goes through one layer. Reading a skill refuses a symlinked skill folder or anything that isn't a regular file, and writes are atomic.

There's no background launch agent. Sync runs while the app is open, and the app only starts at login if you turn that on.

## Untrusted skills

A skill installed from GitHub is text someone else wrote. Pensieve treats it that way:

- **It never runs a skill.** Skills are instructions for your agents, and what an agent does with them is up to the agent. Read a skill before you deploy it, as you would a script.
- **YAML frontmatter** is checked before it's parsed, with limits on nesting, aliases and merges. A hostile file can't blow up memory ("billion laughs").
- **The editor** is a web view locked down by a strict content security policy. It loads only Pensieve's bundled code, makes no network connections, and opens clicked links in your browser.
- **The preview** renders markdown natively and makes no network requests. It shows embedded images and images inside the skill's folder. Remote or unavailable images show a placeholder with their alt text. Local reads refuse symlinks and special files and stop at 4 MiB.
- **Installs** refuse symlinks and special files inside the downloaded skill.

## Git remotes and credentials

Pensieve accepts only `https://`, `ssh://` and `user@host:path` remotes. It refuses git's `ext::` and other helper transports, `file://`, plain `http://`, and anything that could be read as a command-line option. It checks the remote when you connect and again before every sync. Git runs with a cleaned environment, so variables like `GIT_SSH_COMMAND` from your shell can't redirect it.

A personal access token is stored in your macOS Keychain. It reaches git only through a small helper that reads it from the environment of that one git process. It never lands in a URL, a command line, `.git/config` or a log.

## Releases and updates

Every release is signed with a Developer ID, built with the hardened runtime, and notarized and stapled by Apple. Updates come through [Sparkle](https://sparkle-project.org) over HTTPS. Sparkle checks each update's EdDSA signature against the public key built into the installed app. So the signing key can be rotated, it also accepts an update signed with a new EdDSA key when the update carries that key and its Apple code signature matches the installed app's. An update that passes neither check isn't installed.

## What leaves your Mac

Pensieve sends no analytics or telemetry. It talks to the network for:

- the update check (Sparkle's appcast on GitHub)
- your own sync remote, where each Mac also records its name, the agents it found and the projects you registered
- GitHub, when you install a skill, read its upstream History, or check installed skills for updates (weekly by default, or on request)

Previewing a skill never loads remote images.
