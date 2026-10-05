#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"

cd "$REPO"
# Every fixture uses the per-run root; Foundation's temp APIs bypass it on macOS.
python3 - <<'PY'
from pathlib import Path
import re
import sys

direct_temp = re.compile(r'\bNSTemporaryDirectory\s*\(|\.\s*temporaryDirectory\b')
failed = False
for path in Path('PensieveTests').rglob('*.swift'):
    if path == Path('PensieveTests/Fixtures/TestTemporaryDirectory.swift'):
        continue
    source = path.read_text()
    for match in direct_temp.finditer(source):
        line = source.count('\n', 0, match.start()) + 1
        print(f'{path}:{line}: test temp paths must use TestTemporaryDirectory.path or .url', file=sys.stderr)
        failed = True
sys.exit(1 if failed else 0)
PY
xcodegen generate

if command -v swiftlint >/dev/null 2>&1; then
  swiftlint --strict
elif command -v swift-format >/dev/null 2>&1; then
  swift-format lint --recursive Pensieve
else
  echo "lint: no linter installed (see docs/CONVENTIONS.md §10)"
fi
