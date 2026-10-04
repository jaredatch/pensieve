#!/usr/bin/env bash
set -euo pipefail

# Keep the tap-write credential in shell memory only. Clear any inherited
# export attribute before the first child, including checkout-path resolution.
CASK_TAP_TOKEN="${TAP_GH_TOKEN:-}"
export -n CASK_TAP_TOKEN
unset TAP_GH_TOKEN

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$REPO/VERSION"
DIST_DIR="$REPO/build/dist"
APPCAST_INPUT_DIR="$DIST_DIR/appcast-input"
DMG_ROOT="$DIST_DIR/dmg-root"
APP_PATH="$DMG_ROOT/Pensieve.app"
DMG_PATH=""
DMG_MINIMUM=""
SIGN_IDENTITY="-"
DRY_RUN=1
DRY_RUN_LOCAL=0
PUBLISH=0
CASK_ONLY=0
EXPECTED_TAG=""
CHECK_TAG=0
CHECK_TAG_ONLY=0
FIRST_RELEASE=0
PUBLIC_BRANCH=""
APPCAST_SHA=""
APPCAST_PREFLIGHT=0
INSPECT_MODE=""
VERSION=""
VERSION_CHANNEL=""
VERSION_SOURCE="VERSION file"
CHANGELOG_PATH="$REPO/CHANGELOG.md"
INSPECT_APPCAST=""
INSPECT_BUILT_DMG=""
INSPECT_BASE_APPCAST=""
INSPECT_DOWNLOAD_PREFIX=""
INSPECT_VERSION=""
INSPECT_BUILT_MINIMUM=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_CMD="${NOTARY_CMD:-xcrun notarytool}"
STAPLER_CMD="${STAPLER_CMD:-xcrun stapler}"
GH_CMD="${GH_CMD:-gh}"
PUBLIC_REPO="jaredatch/pensieve"
TAP_REPO="jaredatch/homebrew-tap"
DOWNLOAD_PREFIX="https://github.com/$PUBLIC_REPO/releases/download"

usage() {
  cat >&2 <<'USAGE'
usage: script/release.sh [--dry-run | --dry-run-local] [--sign IDENTITY]
                         [--notary-key P8 --notary-key-id ID --notary-issuer ID]
                         [--publish] [--expect-tag TAG]
       script/release.sh --check-tag TAG
       script/release.sh --notes-for VERSION [CHANGELOG]
       script/release.sh --print-release-args VERSION [CHANGELOG]
       script/release.sh [--expect-tag TAG] --publish-cask-only
       script/release.sh --print-cask-action VERSION
       script/release.sh --verify-appcast APPCAST BASE_APPCAST BUILT_DMG DOWNLOAD_PREFIX VERSION BUILT_MINIMUM
       bash -c 'source script/release.sh --inspect-functions; declare -F'

--inspect-functions is for bash -c only: sourcing sets shell options
(errexit, nounset, pipefail), configuration defaults and function definitions
in that disposable shell. The caller owns cleanup_appcast_base and EXIT traps.

--verify-appcast takes an empty BASE_APPCAST only when no base exists.

--first-release permits a missing appcast only after HTTP 404; its PUT is create-only.

--expect-tag requires TAG to match vVERSION before any release work.
--check-tag performs that same check and exits without preparing a release.
--publish-cask-only reads the live feed with GH_TOKEN and accesses the tap with TAP_GH_TOKEN.

Dry run is the default when --publish is absent. Dry run builds the app,
signs it ad-hoc by default, verifies it strictly, creates the final dmg, and
stops before notarization or publishing.

--dry-run-local additionally writes the bumped Homebrew cask to build/dist
without notarizing, publishing, or calling gh.
USAGE
}

RELEASE_OPTIONS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --check-tag)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      EXPECTED_TAG="$2"
      CHECK_TAG=1
      CHECK_TAG_ONLY=1
      shift 2
      ;;
    --expect-tag)
      RELEASE_OPTIONS=1
      [ "$#" -ge 2 ] || { usage; exit 64; }
      EXPECTED_TAG="$2"
      CHECK_TAG=1
      shift 2
      ;;
    --dry-run)
      RELEASE_OPTIONS=1
      DRY_RUN=1
      DRY_RUN_LOCAL=0
      shift
      ;;
    --dry-run-local)
      RELEASE_OPTIONS=1
      DRY_RUN=0
      DRY_RUN_LOCAL=1
      shift
      ;;
    --sign)
      RELEASE_OPTIONS=1
      [ "$#" -ge 2 ] || { usage; exit 64; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-key)
      RELEASE_OPTIONS=1
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_KEY="$2"
      shift 2
      ;;
    --notary-key-id)
      RELEASE_OPTIONS=1
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_KEY_ID="$2"
      shift 2
      ;;
    --notary-issuer)
      RELEASE_OPTIONS=1
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_ISSUER="$2"
      shift 2
      ;;
    --first-release)
      RELEASE_OPTIONS=1
      FIRST_RELEASE=1
      shift
      ;;
    --inspect-functions)
      INSPECT_MODE="functions"
      shift
      ;;
    --publish-cask-only)
      RELEASE_OPTIONS=1
      CASK_ONLY=1
      shift
      ;;
    --publish)
      RELEASE_OPTIONS=1
      PUBLISH=1
      DRY_RUN=0
      DRY_RUN_LOCAL=0
      shift
      ;;
    --notes-for)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 64; }
      INSPECT_MODE="notes"
      VERSION="$2"
      VERSION_SOURCE="$1 version argument"
      [ "$#" -eq 2 ] || CHANGELOG_PATH="$3"
      shift "$#"
      ;;
    --print-release-args)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 64; }
      INSPECT_MODE="release-args"
      VERSION="$2"
      VERSION_SOURCE="$1 version argument"
      [ "$#" -eq 2 ] || CHANGELOG_PATH="$3"
      shift "$#"
      ;;
    --print-cask-action)
      [ "$#" -eq 2 ] || { usage; exit 64; }
      INSPECT_MODE="cask-action"
      VERSION="$2"
      VERSION_SOURCE="$1 version argument"
      shift 2
      ;;
    --verify-appcast)
      [ "$#" -eq 7 ] || { usage; exit 64; }
      INSPECT_MODE="verify-appcast"
      INSPECT_APPCAST="$2"
      INSPECT_BASE_APPCAST="$3"
      INSPECT_BUILT_DMG="$4"
      INSPECT_DOWNLOAD_PREFIX="$5"
      INSPECT_VERSION="$6"
      INSPECT_BUILT_MINIMUM="$7"
      shift 7
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

if { [ -n "$INSPECT_MODE" ] || [ "$CHECK_TAG_ONLY" -eq 1 ]; } &&
    { [ "$RELEASE_OPTIONS" -eq 1 ] || { [ -n "$INSPECT_MODE" ] && [ "$CHECK_TAG_ONLY" -eq 1 ]; }; }; then
  usage
  exit 64
fi

notes_for() {
  local v="$1" f="$2" out
  out=$(awk -v ver="$v" '
    index($0, "## [" ver "]") == 1 { grab=1; next }
    grab && index($0, "## [") == 1 { exit }
    grab { print }
  ' "$f" | sed -e '/^[[:space:]]*$/d')
  if [ -z "$out" ]; then
    echo "release: no CHANGELOG.md section for $v" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

build_release_args() {
  local changelog="${1:-$REPO/CHANGELOG.md}"
  local notes_file
  notes_file="$(mktemp "${TMPDIR:-/tmp}/pensieve-release-notes.XXXXXX")" || return 1
  if ! notes_for "$VERSION" "$changelog" > "$notes_file"; then
    rm -f "$notes_file"
    return 1
  fi

  RELEASE_NOTES_FILE="$notes_file"
  RELEASE_ARGS=(
    release create "v$VERSION"
    --repo "$PUBLIC_REPO"
    "$DIST_DIR/Pensieve-$VERSION.dmg"
    --title "Pensieve $VERSION"
    --notes-file "$notes_file"
  )
  if is_prerelease; then
    RELEASE_ARGS+=(--prerelease)
  fi
}

is_prerelease() { [ -n "$VERSION_CHANNEL" ]; }

cask_action_for() {
  if is_prerelease; then printf 'skip\n'; else printf 'bump\n'; fi
}

run_command_seam() {
  local command_spec="$1"
  shift
  local -a command_parts
  read -r -a command_parts <<< "$command_spec"
  [ "${#command_parts[@]}" -gt 0 ] || { echo "release: empty command seam" >&2; exit 64; }
  "${command_parts[@]}" "$@"
}

# Parsed publication values and response bodies are escaped at the log boundary.
log_text() { state_tool log-text "$1"; }
log_response() { state_tool log-file "$1"; }

sign_path() {
  local path="$1"
  test -e "$path" || { echo "release: missing signing input $path" >&2; exit 1; }

  local -a codesign_args=(--force --options runtime --sign "$SIGN_IDENTITY")
  if [ "$SIGN_IDENTITY" != "-" ]; then
    codesign_args=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  fi

  codesign "${codesign_args[@]}" "$path"
}

package_app_only() {
  echo "release: phase i: package --app-only"
  # Always ad-hoc here; sign_inside_out (phase ii) applies the real identity to every
  # component --force, and sign_dmg (phase iv.b) covers the container.
  "$REPO/script/package.sh" --app-only
}

sign_inside_out() {
  echo "release: phase ii: inside-out codesign"

  local sparkle="$APP_PATH/Contents/Frameworks/Sparkle.framework"
  local sparkle_b="$sparkle/Versions/B"

  sign_path "$sparkle_b/XPCServices/Installer.xpc"
  sign_path "$sparkle_b/XPCServices/Downloader.xpc"
  sign_path "$sparkle_b/Autoupdate"
  sign_path "$sparkle_b/Updater.app"
  sign_path "$sparkle"
  sign_path "$APP_PATH/Contents/MacOS/pensieve-daemon"
  sign_path "$APP_PATH"
}

verify_app() {
  echo "release: phase iii: strict deep verification"
  codesign --verify --deep --strict "$APP_PATH"
}

# Gatekeeper needs the notarization ticket INSIDE the .app at first launch. A
# ticket stapled only to the dmg (phase v.b) does not travel with the bundle:
# Homebrew's cask, a drag-install, and Sparkle's extraction all copy the app out
# of the container, leaving it ticketless. Gatekeeper then has to reach Apple's
# notary service online, and every failed lookup — offline machine, blocked
# egress, Apple hiccup — shows the user "Apple could not verify Pensieve is free
# of malware", with Move to Trash as the only obvious way out. That is exactly
# what 0.13.0 shipped: brew installs quarantine the artifact and hit the live
# check, while Sparkle updates strip quarantine and silently skipped it.
#
# Must run BEFORE package_dmg_only so the dmg wraps the already-stapled bundle,
# and after verify_app so the bytes Apple scans are the bytes we verified. The
# re-verify below proves stapler's ticket file does not break the seal.
notarize_and_staple_app() {
  echo "release: phase iii.b: notarize and staple app"
  local zip_path="$DIST_DIR/Pensieve-$VERSION-notarize.zip"

  mkdir -p "$DIST_DIR"
  rm -f "$zip_path"
  ditto -c -k --keepParent "$APP_PATH" "$zip_path"
  run_command_seam "$NOTARY_CMD" submit "$zip_path" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
  rm -f "$zip_path"

  run_command_seam "$STAPLER_CMD" staple "$APP_PATH"
  run_command_seam "$STAPLER_CMD" validate "$APP_PATH"
  codesign --verify --deep --strict "$APP_PATH"
}

package_dmg_only() {
  echo "release: phase iv: package --dmg-only"
  "$REPO/script/package.sh" --dmg-only
  test -f "$DMG_PATH" || { echo "release: expected dmg missing at $DMG_PATH" >&2; exit 1; }
}

# The dmg container needs its own signature (18.6b's `spctl --assess --type open`
# gates on it); notarization accepts unsigned containers, so only spctl exposes a
# miss here. Must run before notarization so the ticket covers the signed bytes.
sign_dmg() {
  echo "release: phase iv.b: codesign dmg"
  local -a dmg_sign_args=(--force --sign "$SIGN_IDENTITY")
  if [ "$SIGN_IDENTITY" != "-" ]; then
    dmg_sign_args=(--force --timestamp --sign "$SIGN_IDENTITY")
  fi
  codesign "${dmg_sign_args[@]}" "$DMG_PATH"
  codesign --verify --strict "$DMG_PATH"
}

# The regression tooth for phase iii.b. Everything above operates on dmg-root;
# this opens the artifact users actually receive and validates the app as they
# receive it — extracted from the container, with no dmg ticket in play. A future
# reorder that drops or moves phase iii.b fails the release here instead of
# shipping a bundle whose first launch depends on a live Apple lookup. spctl runs
# too because stapler only proves a ticket is present, not that Gatekeeper
# accepts the bundle; with the ticket stapled this assessment is offline-capable.
verify_dmg_app_ticket() {
  echo "release: phase iv.c: validate stapled ticket on the app inside the dmg"
  local mount_point
  mount_point="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-dmg-verify.XXXXXX")"
  DMG_MINIMUM="$(
    trap 'trap_rc=$?; hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; exit "$trap_rc"' EXIT INT TERM
    hdiutil attach "$DMG_PATH" -mountpoint "$mount_point" -nobrowse -readonly -quiet >&2 || exit 1
    test -d "$mount_point/Pensieve.app" || { echo "release: no Pensieve.app inside $DMG_PATH" >&2; exit 1; }
    run_command_seam "$STAPLER_CMD" validate "$mount_point/Pensieve.app" >&2 || exit 1
    spctl --assess --type exec -vv "$mount_point/Pensieve.app" >&2 || exit 1
    python3 -B "$REPO/script/minimum_system.py" --app "$mount_point/Pensieve.app" || exit 1
  )" || { rmdir "$mount_point" 2>/dev/null || true; return 1; }
  rmdir "$mount_point" 2>/dev/null || true
}

find_generate_appcast() {
  if [ -n "${GENERATE_APPCAST_CMD:-}" ]; then
    printf '%s\n' "$GENERATE_APPCAST_CMD"
    return
  fi

  local found
  found="$(find "$REPO/build" -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -type f -print 2>/dev/null | sort | head -n 1 || true)"
  if [ -z "$found" ]; then
    echo "release: could not find Sparkle generate_appcast under build/" >&2
    exit 1
  fi
  printf '%s\n' "$found"
}

prepare_appcast_inputs() {
  [ "$APPCAST_PREFLIGHT" -eq 1 ] || {
    echo "release: appcast preflight required" >&2; return 1;
  }
  # SECURITY (signing oracle): the ONLY archive placed in the directory that
  # generate_appcast signs with the production EdDSA key is the dmg we built and
  # strictly verified this run. We deliberately do NOT re-download prior release
  # dmgs from the public repo. Re-signing arbitrary public-repo bytes would let
  # an untrusted archive become a signed update. Only the local build
  # enters the signing directory. Otherwise an attacker could supply a
  # high-version dmg that the approved job would sign and Sparkle would serve as
  # a valid update to every user. Prior versions are carried forward from the
  # already-signed, previously-published appcast.xml base (generate_appcast reuses
  # those signatures rather than regenerating them), so update history survives
  # without ever signing untrusted input.
  ditto "$DMG_PATH" "$APPCAST_INPUT_DIR/$(basename "$DMG_PATH")"

  if [ -n "$APPCAST_SHA" ]; then
    if [ -z "$APPCAST_BASE" ] || [ ! -s "$APPCAST_BASE" ]; then
      echo "release: missing preflight appcast base" >&2
      return 1
    fi
    ditto "$APPCAST_BASE" "$APPCAST_INPUT_DIR/appcast.xml"
  fi
}

verify_appcast_provenance() {
  state_tool provenance "$@"
}

generate_appcast() {
  echo "release: phase v.c: generate appcast"

  local tag="v$VERSION"
  local generate_appcast_cmd
  generate_appcast_cmd="$(find_generate_appcast)"

  prepare_appcast_inputs

  local -a appcast_args=(
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"
    --download-url-prefix "$DOWNLOAD_PREFIX/$tag/"
  )
  if is_prerelease; then
    appcast_args+=(--channel "$VERSION_CHANNEL")
  fi
  appcast_args+=("$APPCAST_INPUT_DIR")

  "$generate_appcast_cmd" "${appcast_args[@]}"
  test -f "$APPCAST_INPUT_DIR/appcast.xml" || { echo "release: generate_appcast did not create appcast.xml" >&2; exit 1; }

  # Backstop the signing-folder discipline: only VERSION's valid item is new.
  # Retained items and feed metadata must match the immutable preflight base.
  local built_dmg
  built_dmg="$(basename "$DMG_PATH")"
  if [ -z "$DMG_MINIMUM" ]; then
    echo "release: DMG app minimum has not been verified" >&2
    exit 1
  fi
  verify_appcast_provenance "$APPCAST_INPUT_DIR/appcast.xml" "$APPCAST_BASE" "$built_dmg" "$DOWNLOAD_PREFIX" "$VERSION" "$DMG_MINIMUM" || exit 1

  ditto "$APPCAST_INPUT_DIR/appcast.xml" "$DIST_DIR/appcast.xml"
}

http_status() {
  awk '/^HTTP\// {print $2; exit}' "$1"
}

tap_api() {
  if [ "$CASK_ONLY" -eq 1 ]; then
    GH_TOKEN="$CASK_TAP_TOKEN" run_command_seam "$GH_CMD" api "$@"
  else
    run_command_seam "$GH_CMD" api "$@"
  fi
}

contents_api() {
  local repo="$1"
  shift
  if [ "$repo" = "$TAP_REPO" ]; then
    tap_api "$@"
  else
    run_command_seam "$GH_CMD" api "$@"
  fi
}

publish_contents_file() (
  [ "$#" -eq 6 ] || { echo "release: contents writes require an explicit preflight SHA" >&2; return 64; }
  local repo="$1"
  local contents_path="$2"
  local local_file="$3"
  local message="$4"
  local branch="${5:-}"
  test -f "$local_file" || { echo "release: contents source missing at $local_file" >&2; exit 1; }

  local sha="$6" response

  local -a put_args=(
    -X PUT
    "repos/$repo/contents/$contents_path"
    -f "message=$message"
    -f "content=$(base64 -i "$local_file")"
  )
  if [ -n "$sha" ]; then
    put_args+=(-f "sha=$sha")
  fi
  if [ -n "$branch" ]; then
    put_args+=(-f "branch=$branch")
  fi

  response="$(mktemp "${TMPDIR:-/tmp}/pensieve-contents-response.XXXXXX")" || return 1
  trap 'rm -f "$response"' EXIT
  if contents_api "$repo" --include "${put_args[@]}" > "$response"; then
    log_response "$response" || true
    return 0
  else
    log_response "$response" >&2 || true
    if [ "$(http_status "$response")" = 409 ]; then
      echo "release: contents changed since preflight (HTTP 409); refusing to overwrite $repo/$contents_path. Read the current feed before retrying." >&2
    else
      echo "release: contents write failed: $repo/$contents_path" >&2
    fi
    return 1
  fi
)

resolve_public_branch() {
  local branch
  branch="$(run_command_seam "$GH_CMD" api "repos/$PUBLIC_REPO" --jq .default_branch)" || return 1
  case "$branch" in
    main|master) printf '%s\n' "$branch" ;;
    *) echo "release: invalid public default branch: $(log_text "$branch")" >&2; return 1 ;;
  esac
}

cleanup_appcast_base() {
  if [ -n "$APPCAST_BASE" ]; then
    rm -f "$APPCAST_BASE" || return 1
    APPCAST_BASE=""
  fi
}

# A single Contents-API read policy for signing, recheck and cask verification.
# Empty output selects SHA-only parsing. A known 404 is absent only when the
# caller explicitly permits it; transport, local I/O and parse failures stop.
read_live_appcast() {
  local branch="$1" output="$2" failure="$3" invalid="$4" allow_missing="${5:-0}" suffix="${6:-}"
  local response status
  LIVE_APPCAST_SHA=""
  LIVE_APPCAST_ABSENT=0
  response="$(mktemp "${TMPDIR:-/tmp}/pensieve-appcast-response.XXXXXX")" || return 1
  if run_command_seam "$GH_CMD" api -X GET "repos/$PUBLIC_REPO/contents/appcast.xml" \
      -f "ref=$branch" --include > "$response"; then
    if [ -n "$output" ]; then
      if ! LIVE_APPCAST_SHA="$(state_tool contents "$response" "$output")"; then
        rm -f "$response" || return 1
        echo "release: $invalid" >&2
        return 1
      fi
    elif ! LIVE_APPCAST_SHA="$(state_tool contents-sha "$response")"; then
      rm -f "$response" || return 1
      echo "release: $invalid" >&2
      return 1
    fi
  else
    status="$(http_status "$response")" || status=""
    log_response "$response" >&2 || true
    rm -f "$response" || {
      echo "release: $failure (HTTP $(log_text "${status:-unknown}"))$suffix" >&2
      return 1
    }
    if [ "$allow_missing" -eq 1 ] && [ "$status" = 404 ]; then
      LIVE_APPCAST_ABSENT=1
      return 0
    fi
    echo "release: $failure (HTTP $(log_text "${status:-unknown}"))$suffix" >&2
    return 1
  fi
  rm -f "$response" || return 1
}

release_preflight() {
  APPCAST_PREFLIGHT=0
  cleanup_appcast_base || return 1
  APPCAST_SHA=""
  PUBLIC_BRANCH="$(resolve_public_branch)" || return 1
  rm -rf "$APPCAST_INPUT_DIR" || return 1
  mkdir -p "$APPCAST_INPUT_DIR" || return 1
  # The immutable base is owned outside the signing folder. Its bytes and SHA
  # come from the same response before any copy is supplied to generate_appcast.
  APPCAST_BASE="$(mktemp "$DIST_DIR/appcast-base.XXXXXX")" || return 1
  read_live_appcast "$PUBLIC_BRANCH" "$APPCAST_BASE" "appcast base read failed" "invalid appcast base response" "$FIRST_RELEASE" || return 1
  if [ "$LIVE_APPCAST_ABSENT" -eq 1 ]; then
    cleanup_appcast_base || return 1
  else
    APPCAST_SHA="$LIVE_APPCAST_SHA"
  fi
  APPCAST_PREFLIGHT=1
}

verify_public_branch_unchanged() {
  local current
  current="$(resolve_public_branch)" || return 1
  if [ "$current" != "$PUBLIC_BRANCH" ]; then
    echo "release: public default branch changed from $PUBLIC_BRANCH to $current since preflight; stopping publication" >&2
    return 1
  fi
}

verify_appcast_unchanged() {
  local allow_missing=0
  if [ "$FIRST_RELEASE" -eq 1 ] && [ -z "$APPCAST_SHA" ]; then allow_missing=1; fi
  read_live_appcast "$PUBLIC_BRANCH" "" "appcast recheck failed" "invalid appcast recheck response" "$allow_missing" \
    "; stopping before GitHub Release creation" || return 1
  if [ "$LIVE_APPCAST_ABSENT" -eq 1 ]; then return 0; fi
  if [ "$LIVE_APPCAST_SHA" != "$APPCAST_SHA" ]; then
    echo "release: appcast changed since preflight; stopping before GitHub Release creation" >&2
    return 1
  fi
  return 0
}

publish_appcast() {
  [ "$APPCAST_PREFLIGHT" -eq 1 ] || { echo "release: appcast preflight required" >&2; return 1; }
  verify_public_branch_unchanged
  echo "release: phase v.e: publish appcast.xml to $PUBLIC_REPO $PUBLIC_BRANCH"
  publish_contents_file "$PUBLIC_REPO" "appcast.xml" "$DIST_DIR/appcast.xml" "appcast: v$VERSION" "$PUBLIC_BRANCH" "$APPCAST_SHA"
}

write_bumped_cask() {
  local cask_output="$1"
  local cask_template="$REPO/release/homebrew/pensieve.rb"
  local dmg_sha="$2"
  test "${#dmg_sha}" -eq 64 || { echo "release: invalid dmg sha256 for $DMG_PATH" >&2; exit 1; }

  mkdir -p "$(dirname "$cask_output")"
  state_tool rewrite-cask "$cask_template" "$cask_output" "$VERSION" "$dmg_sha"
}

dry_run_local() {
  echo "release: local dry run: write bumped Homebrew cask only"
  local cask_output="$DIST_DIR/homebrew/pensieve.rb"
  write_bumped_cask "$cask_output" "$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  echo "DRY RUN LOCAL: wrote bumped cask $cask_output; stopping before notarization/publishing."
}

cask_publication_status() {
  CASK_STATUS=skip
  ! is_prerelease || return 0
  [ "$CASK_PREFLIGHT" -eq 1 ] || cask_preflight || return 1
  local digest comparison=0
  CASK_OUTPUT="$DIST_DIR/homebrew/pensieve.rb"
  [ -z "$CASK_VERSION" ] || comparison="$(state_tool compare-versions "$CASK_VERSION" "$VERSION")" || return 1
  if [ "$comparison" -gt 0 ]; then
    CASK_STATUS=newer
    echo "release: cask already names newer version $(log_text "$CASK_VERSION"); refusing downgrade to $VERSION"
    return 0
  fi
  digest="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  if [ "$CASK_VERSION" = "$VERSION" ]; then
    [ "$CASK_DIGEST" = "$digest" ] || { echo "release: cask sha256 does not match DMG" >&2; return 1; }
  fi
  write_bumped_cask "$CASK_OUTPUT" "$digest" || return 1
  if [ -n "$CASK_SHA" ] && cmp -s "$CASK_OUTPUT" "$CASK_REMOTE"; then
    CASK_STATUS=done
    echo "release: cask done"
    return 0
  fi
  CASK_STATUS=pending
}

report_cask_publication() {
  if is_prerelease; then
    echo "release: cask skipped for prerelease $VERSION"
  else
    echo "release: cask step runs next with the verified artifact (--publish-cask-only)"
  fi
}

bump_cask() {
  cask_publication_status || return 1
  if [ "$CASK_STATUS" = skip ]; then report_cask_publication; return 0; fi
  [ "$CASK_STATUS" = pending ] || return 0
  echo "release: phase v.f: bump Homebrew cask in $TAP_REPO"
  publish_contents_file "$TAP_REPO" "Casks/pensieve.rb" "$CASK_OUTPUT" "cask: v$VERSION" "" "$CASK_SHA" || return 1
  echo "release: cask done"
}

notarize_and_publish() {
  local tag="v$VERSION"

  echo "release: phase v.a: notarize final dmg"
  run_command_seam "$NOTARY_CMD" submit "$DMG_PATH" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait

  echo "release: phase v.b: staple final dmg"
  run_command_seam "$STAPLER_CMD" staple "$DMG_PATH"

  generate_appcast

  echo "release: phase v.d: create GitHub release $tag"
  verify_public_branch_unchanged
  verify_appcast_unchanged
  publish_release_asset

  publish_appcast
  report_cask_publication
}

source "$REPO/script/release_recovery.sh"
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  trap cleanup_appcast_base EXIT
fi

if [ "$INSPECT_MODE" != functions ] && [ "$INSPECT_MODE" != verify-appcast ]; then
  if [ -z "$INSPECT_MODE" ]; then
    [ -f "$VERSION_FILE" ] || { echo "release: VERSION file missing" >&2; exit 3; }
    VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
  fi
  [ -n "$VERSION" ] || { echo "release: $VERSION_SOURCE must not be empty" >&2; exit 3; }
  VERSION_CHANNEL="$(state_tool channel "$VERSION")"
  DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"
  if [ "$CHECK_TAG" -eq 1 ] && [ "$EXPECTED_TAG" != "v$VERSION" ]; then
    echo "release: tag $(log_text "$EXPECTED_TAG") does not match VERSION v$VERSION" >&2
    exit 1
  fi
fi

if [ "$CHECK_TAG_ONLY" -eq 1 ]; then exit 0; fi

case "$INSPECT_MODE" in
  functions)
    return 0 2>/dev/null || exit 0
    ;;
  notes)
    notes_for "$VERSION" "$CHANGELOG_PATH"
    exit
    ;;
  release-args)
    build_release_args "$CHANGELOG_PATH"
    printf '%s\n' "${RELEASE_ARGS[@]+"${RELEASE_ARGS[@]}"}"
    exit
    ;;
  cask-action)
    cask_action_for
    exit
    ;;
  verify-appcast)
    verify_appcast_provenance "$INSPECT_APPCAST" "$INSPECT_BASE_APPCAST" "$INSPECT_BUILT_DMG" "$INSPECT_DOWNLOAD_PREFIX" "$INSPECT_VERSION" "$INSPECT_BUILT_MINIMUM"
    exit
    ;;
esac

if [ "${CASK_ONLY:-0}" -eq 1 ]; then
  if is_prerelease; then
    report_cask_publication
    exit 0
  fi
  [ -n "$CASK_TAP_TOKEN" ] || { echo "release: TAP_GH_TOKEN is required for cask publication" >&2; exit 1; }
  verify_cask_artifact
  bump_cask
  exit 0
fi

if [ "$PUBLISH" -eq 1 ]; then
  if [ "$SIGN_IDENTITY" = "-" ]; then
    echo "release: --publish requires --sign with a Developer ID Application identity" >&2
    exit 64
  fi
  if [ -z "$NOTARY_KEY" ] || [ -z "$NOTARY_KEY_ID" ] || [ -z "$NOTARY_ISSUER" ]; then
    echo "release: --publish requires --notary-key, --notary-key-id, and --notary-issuer" >&2
    exit 64
  fi
  if [ -z "${SPARKLE_PRIVATE_KEY_FILE:-}" ] || [ ! -f "$SPARKLE_PRIVATE_KEY_FILE" ]; then
    echo "release: --publish requires SPARKLE_PRIVATE_KEY_FILE to point at the Sparkle private key export" >&2
    exit 64
  fi
fi

if [ "$PUBLISH" -eq 1 ]; then
  release_preflight
  publication_preflight
  if [ "$APPCAST_ITEM" != absent ]; then
    recover_live_release
    exit 0
  fi
fi

package_app_only
sign_inside_out
verify_app

# Phases iii.b and iv.c are the only publish-gated steps before the dry-run stop.
# Both reach notarization seams, so both stay behind PUBLISH — this is what keeps
# 18.4b's stub tooth green (a dry run must never invoke NOTARY_CMD/STAPLER_CMD).
if [ "$PUBLISH" -eq 1 ]; then
  notarize_and_staple_app
fi

package_dmg_only
sign_dmg

if [ "$PUBLISH" -eq 1 ]; then
  verify_dmg_app_ticket
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN: built, signed, verified, and packaged $DMG_PATH; stopping before notarization/publishing."
  exit 0
fi

if [ "$DRY_RUN_LOCAL" -eq 1 ]; then
  dry_run_local
  exit 0
fi

notarize_and_publish
