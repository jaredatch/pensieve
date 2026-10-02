#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO"
xcodegen generate

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint --strict
elif command -v swift-format >/dev/null 2>&1; then
  swift-format lint --recursive Pensieve
else
  echo "lint: no linter installed (see docs/CONVENTIONS.md §10)"
fi
