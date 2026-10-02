#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$REPO/VERSION"
PROJECT_FILE="$REPO/project.yml"
DIST_DIR="$REPO/build/dist"
DMG_ROOT="$DIST_DIR/dmg-root"
DERIVED_DATA="$REPO/build/package-dd"
APP_NAME="Pensieve.app"
APP_PATH="$DMG_ROOT/$APP_NAME"
SIGN_IDENTITY="-"
MODE="full"

usage() {
  echo "usage: $0 [--app-only|--dmg-only] [--sign IDENTITY]" >&2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app-only)
      [ "$MODE" = "full" ] || { usage; exit 64; }
      MODE="app-only"
      shift
      ;;
    --dmg-only)
      [ "$MODE" = "full" ] || { usage; exit 64; }
      MODE="dmg-only"
      shift
      ;;
    --sign)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      # package.sh signs ad-hoc only. A real identity here would produce an app whose
      # nested Sparkle helpers stay ad-hoc (the inside-out re-sign lives in release.sh),
      # i.e. an inconsistently signed artifact — refuse rather than emit one.
      [ "$2" = "-" ] || { echo "package: --sign accepts only '-' (ad-hoc); real signing is release.sh's job (sign_inside_out + sign_dmg)" >&2; exit 64; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

[ -f "$VERSION_FILE" ] || { echo "package: VERSION file missing" >&2; exit 3; }
version="$(tr -d '[:space:]' < "$VERSION_FILE")"
marketing_versions="$(awk -F: '/^[[:space:]]*MARKETING_VERSION:/ { value = $2; gsub(/[ "]/, "", value); print value }' "$PROJECT_FILE" | sort -u)"

if [ -z "$version" ] || [ -z "$marketing_versions" ]; then
  echo "package: VERSION and MARKETING_VERSION must both be set" >&2
  exit 3
fi

while IFS= read -r marketing_version; do
  if [ "$marketing_version" != "$version" ]; then
    echo "package: VERSION ($version) does not match MARKETING_VERSION ($marketing_version)" >&2
    exit 3
  fi
done <<< "$marketing_versions"

DMG_PATH="$DIST_DIR/Pensieve-$version.dmg"

build_app() {
  cd "$REPO"
  local build_number
  build_number="$("$REPO/script/build-number.sh")"
  xcodegen generate
  # xcodebuild always signs ad-hoc here, even when --sign carries a real identity:
  # a command-line CODE_SIGN_IDENTITY override applies to every target including SPM
  # packages, which have no development team and fail the build with a Developer ID
  # identity. The real identity is applied post-build (assemble_dmg_root below and
  # release.sh sign_inside_out re-sign every component --force before verification).
  xcodebuild build \
    -scheme Pensieve \
    -configuration Release \
    -destination "generic/platform=macOS" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGNING_ALLOWED=YES \
    CODE_SIGNING_REQUIRED=YES \
    -derivedDataPath "$DERIVED_DATA"
}

assemble_dmg_root() {
  local built_app="$DERIVED_DATA/Build/Products/Release/$APP_NAME"

  test -d "$built_app"
  rm -rf "$DMG_ROOT"
  mkdir -p "$DMG_ROOT"
  ditto "$built_app" "$APP_PATH"
  ln -s /Applications "$DMG_ROOT/Applications"
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH/Contents/MacOS/pensieve-daemon"
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$APP_PATH"
}

create_dmg() {
  test -d "$APP_PATH"
  app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
  if [ "$app_version" != "$version" ]; then
    echo "package: dmg-root app version ($app_version) does not match VERSION ($version) — stale dmg-root?" >&2
    exit 3
  fi
  mkdir -p "$DIST_DIR"
  hdiutil create \
    -volname "Pensieve" \
    -srcfolder "$DMG_ROOT" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
}

case "$MODE" in
  full)
    build_app
    assemble_dmg_root
    create_dmg
    ;;
  app-only)
    build_app
    assemble_dmg_root
    ;;
  dmg-only)
    create_dmg
    ;;
esac
