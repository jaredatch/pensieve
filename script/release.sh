#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_FILE="$REPO/VERSION"
DIST_DIR="$REPO/build/dist"
APPCAST_INPUT_DIR="$DIST_DIR/appcast-input"
DMG_ROOT="$DIST_DIR/dmg-root"
APP_PATH="$DMG_ROOT/Pensieve.app"
DMG_PATH=""
SIGN_IDENTITY="-"
DRY_RUN=1
DRY_RUN_LOCAL=0
PUBLISH=0
CASK_ONLY=0
FIRST_RELEASE=0
PUBLIC_BRANCH=""
APPCAST_SHA=""
APPCAST_PREFLIGHT=0
INSPECT_MODE=""
INSPECT_VERSION=""
CHANGELOG_PATH="$REPO/CHANGELOG.md"
INSPECT_APPCAST=""
INSPECT_BUILT_DMG=""
INSPECT_BASE_LIST_FILE=""
NOTARY_KEY=""
NOTARY_KEY_ID=""
NOTARY_ISSUER=""
NOTARY_CMD="${NOTARY_CMD:-xcrun notarytool}"
STAPLER_CMD="${STAPLER_CMD:-xcrun stapler}"
GH_CMD="${GH_CMD:-gh}"
PUBLIC_REPO="jaredatch/pensieve"
TAP_REPO="jaredatch/homebrew-tap"

usage() {
  cat >&2 <<'USAGE'
usage: script/release.sh [--dry-run | --dry-run-local] [--sign IDENTITY]
                         [--notary-key P8 --notary-key-id ID --notary-issuer ID]
                         [--publish]
       script/release.sh --notes-for VERSION [CHANGELOG]
       script/release.sh --print-release-args VERSION [CHANGELOG]
       script/release.sh --publish-cask-only
       script/release.sh --print-cask-action VERSION
       script/release.sh --verify-appcast APPCAST BUILT_DMG BASE_LIST
       bash -c 'source script/release.sh --inspect-functions; declare -F'

--inspect-functions is for bash -c only: sourcing sets shell options
(errexit, nounset, pipefail) and release variables in that disposable shell.

--first-release permits a missing appcast only after HTTP 404; its PUT is create-only.

Dry run is the default when --publish is absent. Dry run builds the app,
signs it ad-hoc by default, verifies it strictly, creates the final dmg, and
stops before notarization or publishing.

--dry-run-local additionally writes the bumped Homebrew cask to build/dist
without notarizing, publishing, or calling gh.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      DRY_RUN_LOCAL=0
      shift
      ;;
    --dry-run-local)
      DRY_RUN=0
      DRY_RUN_LOCAL=1
      shift
      ;;
    --sign)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      SIGN_IDENTITY="$2"
      shift 2
      ;;
    --notary-key)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_KEY="$2"
      shift 2
      ;;
    --notary-key-id)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_KEY_ID="$2"
      shift 2
      ;;
    --notary-issuer)
      [ "$#" -ge 2 ] || { usage; exit 64; }
      NOTARY_ISSUER="$2"
      shift 2
      ;;
    --first-release)
      FIRST_RELEASE=1
      shift
      ;;
    --inspect-functions)
      INSPECT_MODE="functions"
      shift
      ;;
    --publish-cask-only)
      CASK_ONLY=1
      shift
      ;;
    --publish)
      PUBLISH=1
      DRY_RUN=0
      DRY_RUN_LOCAL=0
      shift
      ;;
    --notes-for)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 64; }
      INSPECT_MODE="notes"
      INSPECT_VERSION="$2"
      [ "$#" -eq 2 ] || CHANGELOG_PATH="$3"
      shift "$#"
      ;;
    --print-release-args)
      [ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 64; }
      INSPECT_MODE="release-args"
      INSPECT_VERSION="$2"
      [ "$#" -eq 2 ] || CHANGELOG_PATH="$3"
      shift "$#"
      ;;
    --print-cask-action)
      [ "$#" -eq 2 ] || { usage; exit 64; }
      INSPECT_MODE="cask-action"
      INSPECT_VERSION="$2"
      shift 2
      ;;
    --verify-appcast)
      [ "$#" -eq 4 ] || { usage; exit 64; }
      INSPECT_MODE="verify-appcast"
      INSPECT_APPCAST="$2"
      INSPECT_BUILT_DMG="$3"
      INSPECT_BASE_LIST_FILE="$4"
      shift 4
      ;;
    *)
      usage
      exit 64
      ;;
  esac
done

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
  local version="$1"
  local changelog="${2:-$REPO/CHANGELOG.md}"
  local notes_file
  notes_file="$(mktemp "${TMPDIR:-/tmp}/pensieve-release-notes.XXXXXX")" || return 1
  if ! notes_for "$version" "$changelog" > "$notes_file"; then
    rm -f "$notes_file"
    return 1
  fi

  RELEASE_NOTES_FILE="$notes_file"
  RELEASE_ARGS=(
    release create "v$version"
    --repo "$PUBLIC_REPO"
    "$DIST_DIR/Pensieve-$version.dmg"
    --title "Pensieve $version"
    --notes-file "$notes_file"
  )
  if [[ "$version" == *-* ]]; then
    RELEASE_ARGS+=(--prerelease)
  fi
}

cask_action_for() {
  case "$1" in
    *-*) printf 'skip\n' ;;
    *) printf 'bump\n' ;;
  esac
}

run_command_seam() {
  local command_spec="$1"
  shift
  local -a command_parts
  read -r -a command_parts <<< "$command_spec"
  [ "${#command_parts[@]}" -gt 0 ] || { echo "release: empty command seam" >&2; exit 64; }
  "${command_parts[@]}" "$@"
}

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
  (
    trap 'trap_rc=$?; hdiutil detach "$mount_point" -force >/dev/null 2>&1 || true; exit "$trap_rc"' EXIT INT TERM
    hdiutil attach "$DMG_PATH" -mountpoint "$mount_point" -nobrowse -readonly -quiet || exit 1
    test -d "$mount_point/Pensieve.app" || { echo "release: no Pensieve.app inside $DMG_PATH" >&2; exit 1; }
    run_command_seam "$STAPLER_CMD" validate "$mount_point/Pensieve.app" || exit 1
    spctl --assess --type exec -vv "$mount_point/Pensieve.app" || exit 1
  )
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

  if [ -n "$APPCAST_SHA" ] && [ ! -s "$APPCAST_INPUT_DIR/appcast.xml" ]; then
    echo "release: missing preflight appcast base" >&2
    return 1
  fi
}

# Extract the .dmg enclosure basenames from an appcast file (empty if absent).
appcast_dmg_basenames() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -oE 'url="[^"]+\.dmg"' "$file" \
    | sed -E 's#.*/([^/"]+\.dmg)"#\1#' \
    | sort -u || true
}

verify_appcast_provenance() {
  local appcast_file="$1"
  local built_dmg="$2"
  local base_dmgs="$3"
  local fn
  while IFS= read -r fn; do
    [ -n "$fn" ] || continue
    [ "$fn" = "$built_dmg" ] && continue
    grep -qxF "$fn" <<< "$base_dmgs" && continue
    echo "release: generated appcast references an unexpected archive: $fn (not built this run and not in the signed base) — aborting" >&2
    return 1
  done <<< "$(appcast_dmg_basenames "$appcast_file")"
}

generate_appcast() {
  echo "release: phase v.c: generate appcast"

  local tag="v$VERSION"
  local generate_appcast_cmd
  generate_appcast_cmd="$(find_generate_appcast)"

  prepare_appcast_inputs

  # Capture the already-signed base enclosures BEFORE generate_appcast overwrites
  # appcast.xml, so the post-check below can distinguish "carried forward from the
  # trusted base" from "newly signed this run".
  local base_dmgs
  base_dmgs="$(appcast_dmg_basenames "$APPCAST_INPUT_DIR/appcast.xml")"

  local -a appcast_args=(
    --ed-key-file "$SPARKLE_PRIVATE_KEY_FILE"
    --download-url-prefix "https://github.com/jaredatch/pensieve/releases/download/$tag/"
  )
  if [[ "$VERSION" == *-* ]]; then
    appcast_args+=(--channel beta)
  fi
  appcast_args+=("$APPCAST_INPUT_DIR")

  "$generate_appcast_cmd" "${appcast_args[@]}"
  test -f "$APPCAST_INPUT_DIR/appcast.xml" || { echo "release: generate_appcast did not create appcast.xml" >&2; exit 1; }

  # SECURITY defense-in-depth: abort if the generated appcast references any dmg
  # we did not build this run and that was not already in the signed base. This
  # backstops the input-directory discipline above — generate_appcast must never
  # emit an item for an archive of unknown provenance.
  local built_dmg
  built_dmg="$(basename "$DMG_PATH")"
  verify_appcast_provenance "$APPCAST_INPUT_DIR/appcast.xml" "$built_dmg" "$base_dmgs" || exit 1

  ditto "$APPCAST_INPUT_DIR/appcast.xml" "$DIST_DIR/appcast.xml"
}

http_status() {
  awk '/^HTTP\// {print $2; exit}' "$1"
}

publish_contents_file() {
  local repo="$1"
  local contents_path="$2"
  local local_file="$3"
  local message="$4"
  local branch="${5:-}"
  test -f "$local_file" || { echo "release: contents source missing at $local_file" >&2; exit 1; }

  local sha response
  # An explicitly supplied empty SHA means create-only. Only the tap caller
  # omits this argument and reads its current SHA here.
  if [ "$#" -ge 6 ]; then
    sha="$6"
  else
    sha="$(run_command_seam "$GH_CMD" api -X GET "repos/$repo/contents/$contents_path" --jq .sha)" || {
      echo "release: contents read failed: $repo/$contents_path" >&2; return 1;
    }
    [ -n "$sha" ] && [ "$sha" != null ] || {
      echo "release: contents read returned no SHA: $repo/$contents_path" >&2; return 1;
    }
  fi

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
  if run_command_seam "$GH_CMD" api --include "${put_args[@]}" > "$response"; then
    cat "$response"
    rm -f "$response"
  else
    cat "$response" >&2
    if [ "$(http_status "$response")" = 409 ]; then
      echo "release: contents changed since preflight (HTTP 409); refusing to overwrite $repo/$contents_path. Read the current feed before retrying." >&2
    else
      echo "release: contents write failed: $repo/$contents_path" >&2
    fi
    rm -f "$response"
    return 1
  fi
}

resolve_public_branch() {
  local branch
  branch="$(run_command_seam "$GH_CMD" api "repos/$PUBLIC_REPO" --jq .default_branch)" || return 1
  case "$branch" in
    main|master) printf '%s\n' "$branch" ;;
    *) echo "release: invalid public default branch: $branch" >&2; return 1 ;;
  esac
}

release_preflight() {
  APPCAST_PREFLIGHT=0
  APPCAST_SHA=""
  PUBLIC_BRANCH="$(resolve_public_branch)" || return 1
  local response status
  rm -rf "$APPCAST_INPUT_DIR"
  mkdir -p "$APPCAST_INPUT_DIR"
  response="$(mktemp "${TMPDIR:-/tmp}/pensieve-appcast-response.XXXXXX")" || return 1
  if run_command_seam "$GH_CMD" api -X GET "repos/$PUBLIC_REPO/contents/appcast.xml" \
      -f "ref=$PUBLIC_BRANCH" --include > "$response"; then
    # Decode directly to generate_appcast's input, preserving every byte. The
    # content and SHA come from this same response. The later recheck never
    # replaces the SHA used by PUT.
    if ! APPCAST_SHA="$(ruby -rjson -e '
      response = File.binread(ARGV[0])
      body = response.split(/\r?\n\r?\n/, 2).fetch(1)
      value = JSON.parse(body)
      abort "release: appcast response has no SHA" unless value["sha"].is_a?(String) && !value["sha"].empty?
      abort "release: appcast response is not base64" unless value["encoding"] == "base64"
      content = value.fetch("content").delete("\r\n").unpack1("m0")
      abort "release: empty appcast base" if content.empty?
      File.binwrite(ARGV[1], content)
      puts value["sha"]
    ' "$response" "$APPCAST_INPUT_DIR/appcast.xml")"; then
      rm -f "$response"
      echo "release: invalid appcast base response" >&2
      return 1
    fi
  else
    status="$(http_status "$response")"
    cat "$response" >&2
    rm -f "$response"
    if [ "$FIRST_RELEASE" -eq 1 ] && [ "$status" = 404 ]; then
      APPCAST_PREFLIGHT=1
      return 0
    fi
    echo "release: appcast base read failed (HTTP ${status:-unknown})" >&2
    return 1
  fi
  rm -f "$response"
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
  local response current status
  response="$(mktemp "${TMPDIR:-/tmp}/pensieve-appcast-response.XXXXXX")" || return 1
  if run_command_seam "$GH_CMD" api -X GET "repos/$PUBLIC_REPO/contents/appcast.xml" \
      -f "ref=$PUBLIC_BRANCH" --include > "$response"; then
    if ! current="$(ruby -rjson -e '
      body = File.binread(ARGV[0]).split(/\r?\n\r?\n/, 2).fetch(1)
      sha = JSON.parse(body)["sha"]
      abort "release: appcast response has no SHA" unless sha.is_a?(String) && !sha.empty?
      puts sha
    ' "$response")"; then
      rm -f "$response"
      return 1
    fi
  else
    status="$(http_status "$response")"
    cat "$response" >&2
    rm -f "$response"
    if [ "$FIRST_RELEASE" -eq 1 ] && [ -z "$APPCAST_SHA" ] && [ "$status" = 404 ]; then
      return 0
    fi
    echo "release: appcast recheck failed (HTTP ${status:-unknown}); stopping before GitHub Release creation" >&2
    return 1
  fi
  rm -f "$response"
  if [ "$current" != "$APPCAST_SHA" ]; then
    echo "release: appcast changed since preflight; stopping before GitHub Release creation" >&2
    return 1
  fi
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
  local dmg_sha
  dmg_sha="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  test "${#dmg_sha}" -eq 64 || { echo "release: invalid dmg sha256 for $DMG_PATH" >&2; exit 1; }

  mkdir -p "$(dirname "$cask_output")"
  awk -v version="$VERSION" -v sha="$dmg_sha" '
    /^  version "/ {
      print "  version \"" version "\""
      next
    }
    /^  sha256 / {
      print "  sha256 \"" sha "\""
      next
    }
    { print }
  ' "$cask_template" > "$cask_output"

  grep -q "  version \"$VERSION\"" "$cask_output" || exit 1
  grep -q "  sha256 \"$dmg_sha\"" "$cask_output" || exit 1
}

dry_run_local() {
  echo "release: local dry run: write bumped Homebrew cask only"
  local cask_output="$DIST_DIR/homebrew/pensieve.rb"
  write_bumped_cask "$cask_output"
  echo "DRY RUN LOCAL: wrote bumped cask $cask_output; stopping before notarization/publishing."
}

bump_cask() {
  [ "$(cask_action_for "$VERSION")" = "bump" ] || { echo "release: phase v.f skipped: prerelease $VERSION does not bump the Homebrew cask"; return 0; }
  echo "release: phase v.f: bump Homebrew cask in $TAP_REPO"

  local cask_output="$DIST_DIR/homebrew/pensieve.rb"
  write_bumped_cask "$cask_output"
  publish_contents_file "$TAP_REPO" "Casks/pensieve.rb" "$cask_output" "cask: v$VERSION"
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
  build_release_args "$VERSION" "$CHANGELOG_PATH"
  run_command_seam "$GH_CMD" "${RELEASE_ARGS[@]+"${RELEASE_ARGS[@]}"}"
  rm -f "$RELEASE_NOTES_FILE"

  publish_appcast
}

case "$INSPECT_MODE" in
  functions)
    return 0 2>/dev/null || exit 0
    ;;
  notes)
    notes_for "$INSPECT_VERSION" "$CHANGELOG_PATH"
    exit
    ;;
  release-args)
    build_release_args "$INSPECT_VERSION" "$CHANGELOG_PATH"
    printf '%s\n' "${RELEASE_ARGS[@]+"${RELEASE_ARGS[@]}"}"
    exit
    ;;
  cask-action)
    cask_action_for "$INSPECT_VERSION"
    exit
    ;;
  verify-appcast)
    INSPECT_BASE_LIST="$(cat "$INSPECT_BASE_LIST_FILE")" || exit 1
    verify_appcast_provenance "$INSPECT_APPCAST" "$INSPECT_BUILT_DMG" "$INSPECT_BASE_LIST"
    exit
    ;;
esac

[ -f "$VERSION_FILE" ] || { echo "release: VERSION file missing" >&2; exit 3; }
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
[ -n "$VERSION" ] || { echo "release: VERSION must not be empty" >&2; exit 3; }
DMG_PATH="$DIST_DIR/Pensieve-$VERSION.dmg"
if [ "${CASK_ONLY:-0}" -eq 1 ]; then
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
