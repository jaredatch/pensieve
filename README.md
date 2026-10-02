# Pensieve

Pensieve is a native Mac app for managing AI skills: the `SKILL.md` files that teach coding agents like Claude Code, Codex, Cursor and Grok how you work.

Every agent reads skills from its own folder (`~/.claude/skills/`, `~/.codex/skills/`, `~/.cursor/rules/`, and so on). Install a skill and it lands in one of them. Run two agents and you install it twice. Add a second Mac and you do it all again. Pensieve keeps one library of skills and deploys each one to every agent, in the form that agent expects. It also syncs the library across your Macs through a git repository you own.

## What it does

- Shows every skill in one library, with its description, tags, token cost and where it's deployed. Edit it in a markdown editor, save when you're ready, and roll back to any saved version from its History.
- Deploys a skill to Claude Code, Codex, Cursor, Grok, OpenClaw or Hermes with a switch in its Deployments tab, for the whole Mac or for one project. OpenClaw and Hermes deploy for the whole Mac only. Agents that read standard markdown get a symlink, so there's no copy to go stale. Cursor gets a compiled `.mdc` file.
- Installs skills from GitHub. Paste a repository, a folder or a `SKILL.md` link, and Pensieve remembers where each skill came from. When the original changes, Pensieve can tell you, and you can read the diff before you update.
- Syncs your library across Macs through a private git remote. It runs from the menu bar, you can turn a skill on for another Mac from this one, and when two Macs edit the same skill you pick between the versions side by side.
- Keeps your skills as plain files in `~/.pensieve/skills/`. Delete the app and they're still there, readable as markdown.

## Install

With Homebrew:

```sh
brew install --cask jaredatch/tap/pensieve
```

Homebrew may ask you to trust the `jaredatch/homebrew-tap` tap the first time. That's normal for a third-party tap.

Or download the dmg from [Releases](https://github.com/jaredatch/pensieve/releases), open it and drag Pensieve to Applications.

Pensieve needs macOS 14 or later and runs on Apple silicon and Intel. Every release is signed with a Developer ID and notarized by Apple, and updates arrive through Sparkle.

Pensieve isn't sandboxed, and that's on purpose. It writes symlinks and files into folders like `~/.claude` and `~/.cursor`, which the App Store sandbox doesn't allow. It's also beta software that writes to real agent folders, so keep a backup of any skills you care about. If you sync more than one Mac, update them all together: a new version can move the library to a format older versions won't open.

## Build from source

You'll need a Mac with Apple silicon, Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is generated from `project.yml`, so edit that file, not the project.

```sh
brew install xcodegen
git clone https://github.com/jaredatch/pensieve.git
cd pensieve
script/build_and_run.sh
```

That generates the project, builds the app and opens it. `script/test.sh` runs the test suite. If you'd rather work in Xcode, run `xcodegen generate` and open `Pensieve.xcodeproj`.

The scripts build for Apple silicon only. Release builds are universal.

## Docs

- [Getting started](docs/GETTING-STARTED.md): a tour of the app.
- [Architecture](docs/ARCHITECTURE.md): how the pieces fit together.
- [Specification](docs/SPEC.md): what the app is meant to do.
- [Changelog](CHANGELOG.md): what changed in each release.
- [Contributing](CONTRIBUTING.md): building, testing and reporting issues.
- [Security](SECURITY.md): what Pensieve touches on your Mac, and how to report a vulnerability.
- [How Pensieve is built](docs/HOW-PENSIEVE-IS-BUILT.md): frozen criteria, checks proven both ways, and review by a second AI model.

## License

Pensieve is released under the [MIT License](LICENSE). The open-source packages it uses are listed with their licenses in [third-party notices](THIRD-PARTY-NOTICES.md).
