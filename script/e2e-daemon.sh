#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="platform=macOS,arch=arm64"
DERIVED_DATA="$REPO/DerivedData"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-e2e-daemon.XXXXXX")"

cleanup() {
  rm -rf "$TMPROOT"
}
trap cleanup EXIT

export HOME="$TMPROOT/home"
export XDG_CACHE_HOME="$TMPROOT/xdg-cache"
export CLANG_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFT_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFTPM_MODULECACHE_OVERRIDE="$DERIVED_DATA/ModuleCache.noindex"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$CLANG_MODULE_CACHE_PATH"

cd "$REPO"
xcodegen generate

xcodebuild build \
  -scheme PensieveDaemon \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_PATH"

DAEMON_PRODUCT="$DERIVED_DATA/Build/Products/Debug/pensieve-daemon"
test -x "$DAEMON_PRODUCT"
otool -L "$DAEMON_PRODUCT" > "$TMPROOT/otool.txt"
if grep -q SwiftData "$TMPROOT/otool.txt"; then
  echo "e2e-daemon: pensieve-daemon links SwiftData" >&2
  exit 1
fi

xcodebuild test \
  -scheme Pensieve \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_PATH" \
  -only-testing PensieveTests/DaemonEndToEndTests/testRecordGatedCursorReconcileEndToEnd

echo "E2E DAEMON OK"
