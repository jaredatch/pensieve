# Pensieve

Pensieve is a native Mac app for managing AI skills: the `SKILL.md` files that teach coding agents like Claude Code, Codex, and Cursor how you work.

If you run more than one agent, you know the problem. Each one reads skills from its own directory (`~/.claude/skills/`, `~/.codex/`, `~/.cursor/rules/`, and so on), so every skill you install lands in exactly one of them. Two agents means installing everything twice. A second Mac doubles it again. Pensieve keeps one canonical library and handles the rest: it deploys each skill to every agent in the form that agent expects, and syncs the library across your machines so an edit on one Mac shows up on all of them.

The app's source is private for now. This repo is the public home for releases: the DMGs, the Sparkle update feed, and release notes all live here.

## What you get

- A real library view of every skill (name, description, tags, token cost, where it's deployed) with a markdown editor and live preview. Much nicer than squinting at `/skills` output in a terminal.
- One-click deploy to Claude Code, Codex, Cursor, OpenClaw, Hermes, or anything that reads standard `SKILL.md`. Agents that read standard markdown get a symlink, so there is no copy to go stale; agents with their own format get a compiled file.
- Cross-machine sync through a git remote you control. A background daemon keeps every Mac current, and when two machines edit the same skill you get a side-by-side view to pick from, not `<<<<<<<` markers.
- Scenarios: named groups of skills you can switch on and off as a unit. Think "client work", "writing", or "everything off".
- Updates arrive automatically through Sparkle, and every build is signed and notarized.

## Install

With Homebrew:

```sh
brew install --cask jaredatch/tap/pensieve
```

The first install may ask you to confirm that you trust the `jaredatch/homebrew-tap` tap. That's normal for third-party taps.

Or grab the DMG straight from [Releases](https://github.com/jaredatch/pensieve/releases): download, open, drag to Applications.

## Requirements

- macOS 14 or later
- Apple silicon or Intel

## It's a beta

Pensieve 0.9.0 is a public beta. Every build here is Developer ID signed and notarized by Apple. Still, this is early software that writes to real agent directories on your machine. If your skill library matters to you (it should, that's the point), keep a backup until you trust it.

Pensieve is also not sandboxed, on purpose. It creates symlinks and compiled files under directories like `~/.claude` and `~/.cursor`, which the Mac App Store sandbox doesn't allow. That's why it ships here instead of the App Store.

## Feedback

Found a bug or have an idea? [Open an issue](https://github.com/jaredatch/pensieve/issues). This is the stage where feedback actually changes what gets built, so don't be shy.
