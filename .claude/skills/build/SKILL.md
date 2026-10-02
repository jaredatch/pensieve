---
name: build
description: Build the Pensieve macOS application
---

Build the Pensieve app through the repo's wrapper, which runs `xcodegen generate` then `xcodebuild build` with repo-local DerivedData and module caches. Run it from the repo root (paths are repo-relative; never hardcode a checkout path):

```bash
script/build_and_run.sh --headless 2>&1 | tail -20
```

`--headless` builds and prints `SMOKE OK` without launching the app. Omit it to build and then `open` the built `Pensieve.app`.

If the build fails, read the error output and diagnose the issue. Common causes:
- Missing file not added to `project.yml` — add it to the appropriate target's sources
- Import errors — check SPM dependencies in `project.yml`
- SwiftUI preview issues — these don't affect the build, ignore them
