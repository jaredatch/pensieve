# Test Skip Allowlist

The ratchet permits a new test skip marker only when the disabled test is named here with a reason, a follow-up, and the rationale for approving the skip. This covers `XCTSkip(If|Unless)?`, `.disabled(`, and `@Test(... .disabled` additions **in test files** (paths under a `*Tests/` dir or a `*Tests.swift` file) — app code and docs are not scanned, so the SwiftUI view-disable modifier and prose naming these tokens are free. Per `docs/TESTING.md` §5.

| Test | Reason | Follow-up | Rationale |
|---|---|---|---|
