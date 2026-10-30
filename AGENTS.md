# Pensieve

If present, read `private/AGENTS.md` before working in this checkout.

Pensieve is a native macOS app that manages AI skills. Read
`docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md` and `docs/TESTING.md` for the code boundaries.

- All app file I/O goes through FileService. Leaf services are synchronous and throwing.
- Use Swift 5.10 and the existing SwiftUI and AppKit patterns.
- Run `./script/lint.sh` and the tests your change touches (`./script/test.sh --filter <TestClass>`). The full suite runs nightly, so don't run it for every change.
- Edit `project.yml` instead of the generated Xcode project, then run `script/generate.sh`.
- Never weaken a test, skip hooks, commit secrets, or push without the maintainer's instruction.
- Never sign, notarize or publish a release without the maintainer's approval.
- Public commit messages must not contain `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `skip-checks: true`; those markers tell GitHub to skip the push's hygiene check.
