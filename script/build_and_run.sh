#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="platform=macOS,arch=arm64"
DERIVED_DATA="$REPO/DerivedData"
export HOME="$DERIVED_DATA/Home"
export CLANG_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFT_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFTPM_MODULECACHE_OVERRIDE="$DERIVED_DATA/ModuleCache.noindex"
export XDG_CACHE_HOME="$DERIVED_DATA/XDGCache"
SCHEME="Pensieve"

usage() {
  echo "usage: $0 [--headless]" >&2
}

HEADLESS=0
case "${1:-}" in
  "")
    ;;
  "--headless")
    HEADLESS=1
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [ "$#" -gt 1 ]; then
  usage
  exit 64
fi

cd "$REPO"
xcodegen generate
mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"
xcodebuild build \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_PATH"

if [ "$HEADLESS" -eq 1 ]; then
  echo "SMOKE OK"
  exit 0
fi

settings="$(xcodebuild \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -showBuildSettings)"
target_build_dir="$(printf '%s\n' "$settings" | awk -F' = ' '/^[[:space:]]*TARGET_BUILD_DIR = / { print $2; exit }')"
full_product_name="$(printf '%s\n' "$settings" | awk -F' = ' '/^[[:space:]]*FULL_PRODUCT_NAME = / { print $2; exit }')"

if [ -z "$target_build_dir" ] || [ -z "$full_product_name" ]; then
  echo "build_and_run: could not resolve built app path" >&2
  exit 1
fi

open "$target_build_dir/$full_product_name"
