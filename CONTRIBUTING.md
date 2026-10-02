# Contributing to Pensieve

Thanks for taking a look. Pensieve is a small project, and for now the way to help is through issues.

## Issues, not pull requests (for now)

Bug reports and ideas are very welcome. [Open an issue](https://github.com/jaredatch/pensieve/issues) for either.

For a bug, these help most:

- your macOS version and Pensieve's version (Pensieve › About Pensieve)
- which agents you deploy to
- what you did, what you expected, and what happened instead

Pull requests aren't accepted yet. Every change to Pensieve goes through a planning and review process that isn't set up for outside contributions. That may change. Until then, an issue describing the fix is the best way to get it made.

## Building and testing

You'll need a Mac with Apple silicon, Xcode 26, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and, for linting, [SwiftLint](https://github.com/realm/SwiftLint).

```sh
script/build_and_run.sh              # generate the project, build, and launch the app
script/build_and_run.sh --headless   # build and smoke-test without opening a window
script/test.sh                       # run the test suite
script/lint.sh                       # SwiftLint in strict mode
```

`script/test.sh --filter PensieveTests/SomeTests` runs one test class. The project file is generated, so change `project.yml` and run `xcodegen generate` rather than editing `Pensieve.xcodeproj`.

## Committing

Run `script/install-hooks.sh` once after cloning. It points git at the hooks in `script/hooks/`, which check every commit before it lands:

- The ratchet (`script/ratchet.sh`) refuses secrets, skipped or disabled tests, and a drop in the test count. The count only goes up.
- The public hygiene guard (`script/public-hygiene.sh`) keeps personal and private details out of the repository. It refuses a line that adds a path in someone's home folder, a real email address, a Tailscale hostname (`*.ts.net`), a cite of one of the project's private records, or an internal decision number. The maintainer also keeps a private list of personal names and hosts that it refuses. Your clone won't have that list, so a passing guard doesn't mean every private name was caught. It also refuses an image added outside the app's asset catalog. The refusal names the rule, the file and the line, and says how to fix it. Run `script/public-hygiene.sh --tree` to check the whole tree.

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/): `feat:`, `fix:`, `docs:`, `test:`, `refactor:`, `chore:`. Stage files by name rather than with `git add -A`.

## What `PLAN-NN` and `sprint-N` mean

You'll see `PLAN-44` or `sprint-6` in commit messages and code comments. Each names a milestone on this repository's GitHub page, where you can see what that piece of work set out to do and the issues it closed.
