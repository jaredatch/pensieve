# Sourced by release.sh. Remote reads are checked before build or publication.
RELEASE_STATE="absent"
APPCAST_ITEM="absent"
APPCAST_NEWER="absent"
APPCAST_BASE=""
trap cleanup_appcast_base EXIT
CASK_SHA=""
CASK_VERSION=""
CASK_DIGEST=""
CASK_PREFLIGHT=0

state_tool() { python3 "$REPO/script/release_state.py" "$@"; }

verify_update_archive() {
  if [ -n "${VERIFY_UPDATE_CMD:-}" ]; then
    run_command_seam "$VERIFY_UPDATE_CMD" "$@"
  else
    /usr/bin/swift "$REPO/script/verify_update.swift" "$@"
  fi
}

verify_cask_artifact() (
  ! is_prerelease || return 0
  # Own a read-only snapshot outside build/dist. This path never prepares or
  # changes the signing folder, and GH_TOKEN here is the public-read credential.
  # Explicit returns also stop callers that disable errexit with an if/OR list.
  local read_dir live_feed branch publication length signature public_key
  read_dir="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-cask-appcast.XXXXXX")" || return 1
  trap 'rm -rf "$read_dir"' EXIT
  live_feed="$read_dir/appcast.xml"
  branch="$(resolve_public_branch)" || return 1
  read_live_appcast "$branch" "$live_feed" "cask appcast read failed" "invalid cask appcast contents response" || return 1
  publication="$(state_tool appcast "$live_feed" "$VERSION" "$DOWNLOAD_PREFIX")" || return 1
  read -r length signature <<< "$publication"
  [ "$length" != absent ] || { echo "release: cask requires a live appcast item for $VERSION" >&2; return 1; }
  public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$REPO/Pensieve/Info.plist")" || return 1
  if ! verify_update_archive "$DMG_PATH" "$length" "$signature" "$public_key"; then
    echo "release: cask artifact length or EdDSA signature does not match live appcast" >&2
    return 1
  fi
)

read_release_state() {
  local response="$DIST_DIR/release-response.txt" status mode=unpublished
  [ "$APPCAST_ITEM" = absent ] || mode=live
  if run_command_seam "$GH_CMD" api --include "repos/$PUBLIC_REPO/releases/tags/v$VERSION" > "$response"; then
    RELEASE_STATE="$(state_tool release "$response" "$VERSION" "$mode")" || return 1
  else
    status="$(http_status "$response")"
    [ "$status" = 404 ] || { echo "release: release read failed (HTTP $(log_text "${status:-unknown}"))" >&2; return 1; }
    RELEASE_STATE="absent"
  fi
}

verify_tag_target() {
  local response="$DIST_DIR/tag-response.txt" target kind sha depth=0
  local endpoint="repos/$PUBLIC_REPO/git/ref/tags/v$VERSION"
  while :; do
    run_command_seam "$GH_CMD" api --include "$endpoint" > "$response" || {
      echo "release: tag target read failed" >&2; return 1;
    }
    target="$(state_tool tag "$response")" || return 1
    read -r kind sha <<< "$target"
    if [ "$kind" = commit ]; then
      [ "$sha" = "$(git -C "$REPO" rev-parse HEAD)" ] || {
        echo "release: tag target differs from this checkout" >&2; return 1;
      }
      return 0
    fi
    depth=$((depth + 1))
    [ "$depth" -le 8 ] || { echo "release: tag target nesting is too deep" >&2; return 1; }
    endpoint="repos/$PUBLIC_REPO/git/tags/$sha"
  done
}

cask_preflight() {
  ! is_prerelease || { CASK_PREFLIGHT=1; return 0; }
  local response="$DIST_DIR/cask-response.txt" fields status
  mkdir -p "$DIST_DIR/homebrew"
  CASK_REMOTE="$DIST_DIR/homebrew/base.rb"
  CASK_VERSION=""; CASK_DIGEST=""
  if tap_api --include -X GET "repos/$TAP_REPO/contents/Casks/pensieve.rb" > "$response"; then
    CASK_SHA="$(state_tool contents "$response" "$CASK_REMOTE")" || {
      echo "release: invalid cask contents response" >&2; return 1;
    }
    fields="$(state_tool cask "$CASK_REMOTE")" || return 1
    read -r CASK_VERSION CASK_DIGEST <<< "$fields"
  else
    status="$(http_status "$response")"
    [ "$status" = 404 ] || { echo "release: cask read failed (HTTP $(log_text "${status:-unknown}"))" >&2; return 1; }
    CASK_SHA=""
    rm -f "$CASK_REMOTE"
  fi
  CASK_PREFLIGHT=1
}

publication_preflight() {
  local appcast_state
  if [ -n "$APPCAST_BASE" ]; then
    appcast_state="$(state_tool appcast "$APPCAST_BASE" "$VERSION" "$DOWNLOAD_PREFIX")" || return 1
    { read -r APPCAST_ITEM; read -r APPCAST_NEWER; } <<< "$appcast_state"
  fi
  if [ "$APPCAST_NEWER" != absent ]; then
    echo "release: appcast already names newer version $(log_text "$APPCAST_NEWER"); keeping it"
    [ "$APPCAST_ITEM" != absent ] || { echo "release: refusing older appcast publication for $VERSION" >&2; return 1; }
  fi
  read_release_state
  verify_tag_target
  cask_preflight
  if [ "$APPCAST_ITEM" != absent ] && [ "$RELEASE_STATE" = absent ]; then
    echo "release: appcast item exists but GitHub release/DMG is missing" >&2; return 1
  fi
  if [ "$APPCAST_ITEM" = absent ] && [ "$CASK_VERSION" = "$VERSION" ]; then
    echo "release: cask names this version before its appcast item exists" >&2; return 1
  fi
}

recover_live_release() {
  local download_dir length signature public_key
  download_dir="$(mktemp -d "$DIST_DIR/recovery.XXXXXX")" || return 1
  # Downloaded bytes stay outside appcast-input and never reach generate_appcast.
  if ! run_command_seam "$GH_CMD" release download "v$VERSION" --repo "$PUBLIC_REPO" \
      --pattern "Pensieve-$VERSION.dmg" --dir "$download_dir"; then
    rm -rf "$download_dir"
    echo "release: published DMG download failed or asset missing" >&2; return 1
  fi
  read -r length signature <<< "$APPCAST_ITEM"
  public_key="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$REPO/Pensieve/Info.plist")" || return 1
  if ! verify_update_archive "$download_dir/Pensieve-$VERSION.dmg" "$length" "$signature" "$public_key"; then
    rm -rf "$download_dir"
    echo "release: published DMG length or EdDSA signature does not match appcast" >&2; return 1
  fi
  ditto "$download_dir/Pensieve-$VERSION.dmg" "$DMG_PATH"
  rm -rf "$download_dir"
  # The cask step uses this verified artifact with its separate tap credential.
  echo "release: GitHub release and appcast done; verified published DMG"
  report_cask_publication
}

publish_release_asset() {
  local expected="$RELEASE_STATE"
  verify_tag_target
  read_release_state
  [ "$RELEASE_STATE" = "$expected" ] || { echo "release: release changed since preflight; stopping" >&2; return 1; }
  if [ "$RELEASE_STATE" = absent ]; then
    build_release_args "$CHANGELOG_PATH"
    run_command_seam "$GH_CMD" "${RELEASE_ARGS[@]+"${RELEASE_ARGS[@]}"}"
    rm -f "$RELEASE_NOTES_FILE"
  else
    echo "release: replacing unpublished DMG asset in existing release"
    run_command_seam "$GH_CMD" release upload "v$VERSION" "$DMG_PATH" --repo "$PUBLIC_REPO" --clobber
  fi
}
