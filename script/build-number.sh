#!/usr/bin/env bash
# Package-time version: history count plus the committed offset.
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
offset="$(cat "$repo/BUILD_NUMBER_OFFSET")"
case "$offset" in ''|*[!0-9]*) echo 'build-number: invalid BUILD_NUMBER_OFFSET' >&2; exit 1 ;; esac
count="$(git -C "$repo" rev-list --count HEAD)"
printf '%s\n' "$((count + 10#$offset))"
