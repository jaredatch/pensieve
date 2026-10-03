# Sourced by release.sh. Remote reads are checked before build or publication.
RELEASE_STATE="absent"
APPCAST_ITEM="absent"
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

read_release_state() {
  local response="$DIST_DIR/release-response.txt" status
  if run_command_seam "$GH_CMD" api --include "repos/$PUBLIC_REPO/releases/tags/v$VERSION" > "$response"; then
    RELEASE_STATE="$(state_tool release "$response" "$VERSION")" || return 1
  else
    status="$(http_status "$response")"
    [ "$status" = 404 ] || { echo "release: release read failed (HTTP ${status:-unknown})" >&2; return 1; }
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
  local response="$DIST_DIR/cask-response.txt" fields status
  mkdir -p "$DIST_DIR/homebrew"
  CASK_TEMPLATE="$DIST_DIR/homebrew/base.rb"
  if run_command_seam "$GH_CMD" api --include -X GET "repos/$TAP_REPO/contents/Casks/pensieve.rb" > "$response"; then
    CASK_SHA="$(state_tool contents "$response" "$CASK_TEMPLATE")" || {
      echo "release: invalid cask contents response" >&2; return 1;
    }
  else
    status="$(http_status "$response")"
    [ "$status" = 404 ] || { echo "release: cask read failed (HTTP ${status:-unknown})" >&2; return 1; }
    CASK_SHA=""
    ditto "$REPO/release/homebrew/pensieve.rb" "$CASK_TEMPLATE"
  fi
  fields="$(state_tool cask "$CASK_TEMPLATE")" || return 1
  read -r CASK_VERSION CASK_DIGEST <<< "$fields"
  CASK_PREFLIGHT=1
}

publication_preflight() {
  read_release_state
  verify_tag_target
  if [ -f "$APPCAST_INPUT_DIR/appcast.xml" ]; then
    APPCAST_ITEM="$(state_tool appcast "$APPCAST_INPUT_DIR/appcast.xml" "$VERSION")" || return 1
  fi
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
  local digest
  digest="$(shasum -a 256 "$DMG_PATH" | awk '{print $1}')"
  if [ "$CASK_VERSION" = "$VERSION" ] && [ "$CASK_DIGEST" != "$digest" ]; then
    echo "release: cask sha256 does not match verified published DMG" >&2; return 1
  fi
  if [ "$(cask_action_for "$VERSION")" = skip ]; then
    echo "release: cask skipped for prerelease $VERSION"
  elif [ "$CASK_VERSION" = "$VERSION" ]; then
    echo "release: cask done; everything published"
  else
    echo "release: cask pending; run --publish-cask-only with the verified artifact"
  fi
}

publish_release_asset() {
  local expected="$RELEASE_STATE"
  verify_tag_target
  read_release_state
  [ "$RELEASE_STATE" = "$expected" ] || { echo "release: release changed since preflight; stopping" >&2; return 1; }
  if [ "$RELEASE_STATE" = absent ]; then
    build_release_args "$VERSION" "$CHANGELOG_PATH"
    run_command_seam "$GH_CMD" "${RELEASE_ARGS[@]+"${RELEASE_ARGS[@]}"}"
    rm -f "$RELEASE_NOTES_FILE"
  else
    echo "release: replacing unpublished DMG asset in existing release"
    run_command_seam "$GH_CMD" release upload "v$VERSION" "$DMG_PATH" --repo "$PUBLIC_REPO" --clobber
  fi
}
