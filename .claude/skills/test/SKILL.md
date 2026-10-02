---
name: test
description: Run the Pensieve test suite
---

Run the Pensieve test suite through the repo's wrapper, which runs `xcodegen generate` then `xcodebuild test` with repo-local DerivedData and module caches, and prints `PENSIEVE_TEST_COUNT=<n>` at the end. Run it from the repo root (paths are repo-relative; never hardcode a checkout path):

```bash
script/test.sh 2>&1 | tail -40
```

To run one test class or method, pass `--filter` (a bare identifier is prefixed with `PensieveTests/`):

```bash
script/test.sh --filter SkillParserTests 2>&1 | tail -40
```

If tests fail, read the output to identify which tests failed and why. Fix the failing tests before proceeding. All tests use temp directories for filesystem operations — never modify real user directories in tests.
