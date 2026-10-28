# Contributing to Pensieve

Thanks for taking a look. Pensieve is a small project, and for now the way to help is through issues.

## Issues, not pull requests (for now)

Bug reports and ideas are very welcome. [Open an issue](https://github.com/jaredatch/pensieve/issues) for either.

For a bug, these help most:

- your macOS version and Pensieve's version (Pensieve › About Pensieve)
- which agents you deploy to
- what you did, what you expected, and what happened instead

Pull requests aren't accepted yet. Pensieve uses Slipway: an issue assigned to kramer-bot is built and read by agents from different model families and landed by a script after its checks pass. That process isn't set up for outside contributions yet. Until then, an issue describing the fix is the best way to get it made.

## Building and testing

You'll need a Mac with Apple silicon, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for linting, [SwiftLint](https://github.com/realm/SwiftLint).

```sh
script/build_and_run.sh              # generate the project, build, and launch the app
script/build_and_run.sh --headless   # build and smoke-test without opening a window
script/test.sh                       # run the test suite
script/lint.sh                       # SwiftLint in strict mode
```

`script/test.sh --filter PensieveTests/SomeTests` runs one test class. The project file is generated, so change `project.yml` and run `script/generate.sh` rather than editing `Pensieve.xcodeproj`.

## Committing

There are no hooks to install. Run `script/public-hygiene.sh --tree` before committing. The public hygiene guard refuses personal details and references to private records, including home paths, real email addresses, private hostnames, and internal decision numbers. It also checks image locations. Refusals name the rule, file and line. The maintainer keeps an additional private list of personal names and hosts; a clone without that list cannot check those terms.

The reader checks for leaks, and CI scans pushed commits after the push to master. Slipway installs no commit-time project check or pre-push hygiene batch.

If your clone ran the old hook installer, remove its local configuration:

```sh
git config --unset core.hooksPath
git config --remove-section merge.execplan-log
```

Delete the `merge=execplan-log` line from `info/attributes` in the common Git directory (`git rev-parse --git-common-dir`). Apply the same cleanup in any repository the installer wired alongside this one. These commands remove local settings; a setting that is already absent needs no cleanup.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`. Stage files by name rather than with `git add -A`.

## What `PLAN-NN` and `sprint-N` mean

You'll see `PLAN-44` or `sprint-6` in commit messages and code comments. Each names a milestone on this repository's GitHub page, where you can see what that piece of work set out to do and the issues it closed.
