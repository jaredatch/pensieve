---
name: pensieve
description: Use Pensieve when deploying, installing, updating or removing skills for Claude Code, Grok, Cursor, Codex, OpenClaw or Hermes, in projects or on another Mac.
---

# Pensieve

Use the `pensieve` CLI to manage skills through the app. For a known command, read `pensieve <command> --help --json` for its current arguments and flags. Use `pensieve commands --json` only to find an unfamiliar command.

If `pensieve` isn't on the PATH, use the absolute path inside the intended app: `/Applications/Pensieve.app/Contents/Helpers/pensieve`. Substitute the actual app location if it lives elsewhere. Agents started from GUI apps may have a different PATH from the shell.

## Read before changing

Always pass `--json`. Inspect `ok`, `changed`, `error.code` and the exit code. A successful command may report `changed: false`. A `partial` result needs a report of what applied and what remains.

Look names up before using them with `skill list`, `agent list`, `machine list` and `project list`, each with `--json`. Use the returned skill slugs, agent IDs, project paths and machine IDs. "Claude Code" maps to `claude`; resolve "the mini" from `machine list`. Never guess a name or choose between ambiguous matches.

Never write into `~/.claude/skills` or any other agent's folder directly. Pensieve owns deployed files and can overwrite hand edits. Change deployments through the CLI. Use `undeploy` to remove a deployment; `skill delete` removes the skill from the library and its deployments.

## Preview and confirm

Run `--dry-run` before a broad change. Use `-a '*'` only when the person says "all". Quote the wildcard so the shell leaves it intact. Choose the requested scope explicitly: `-g` for user-wide, or `-p` for a registered project. If scope is unclear, ask. A machine target (`-m`) requires `-g`; remote project deployment isn't supported.

Before `install`, `skill update`, `skill delete` or `project remove`, show the person the dry run and ask for approval. Pass `--yes` only after they agree. Keep that preview's `confirmationToken` in `--confirm-plan` when applying it. If the plan changes, show the new preview and ask again. Overwriting local changes needs explicit approval too. An unsaved draft must be saved or discarded by the person in the app.

## Handle the result

Retry only when `error.retryable` is true. For other failures, report the code and hint and stop. A timeout or interruption can leave accepted work running in Pensieve; inspect its state before proposing another write.

Report what changed. A remote `-m` deploy records intent; it lands on that Mac's next sync after this Mac pushes. Don't claim the other Mac has applied it without evidence from that Mac. Use the returned `next` suggestions to explain any follow-up, such as sync.
