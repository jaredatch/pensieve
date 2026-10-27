#!/usr/bin/env bash
# Makes Pensieve.xcodeproj from project.yml. Swift seeds its hashing per process, so plain `xcodegen generate` can put
# the app's two "Embed Dependencies" copy phases in either order from one run to the next; with the seed fixed the
# project comes out the same every time, so regenerating it never shows up as a change to the tracked file.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
SWIFT_DETERMINISTIC_HASHING=1 exec xcodegen generate "$@"
