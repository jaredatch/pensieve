# Pensieve

If present, read `private/AGENTS.md` before working in this checkout.

Pensieve is a native macOS app that manages AI skills. Read
`docs/ARCHITECTURE.md`, `docs/CONVENTIONS.md` and `docs/TESTING.md` for the code boundaries.

- All app file I/O goes through FileService. Leaf services are synchronous and throwing.
- Use Swift 5.10 and the existing SwiftUI and AppKit patterns.
- Run `./script/lint.sh`, `./script/test.sh` and `./script/build_and_run.sh --headless`.
- Edit `project.yml` instead of the generated Xcode project, then run `xcodegen generate`.
- Never weaken a test, skip hooks, commit secrets, or push without the maintainer's instruction.
- Never sign, notarize or publish a release without the maintainer's approval.
- Public commit messages must not contain `[skip ci]`, `[ci skip]`, `[no ci]`, `[skip actions]` or `skip-checks: true`; those markers tell GitHub to skip the push's hygiene check.
