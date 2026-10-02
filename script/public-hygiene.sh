#!/usr/bin/env bash
# Check staged additions (default), the tracked working tree (--tree), or --range BASE..HEAD.
# --project-check uses Git's hook index or the kit replay's stdin diff.
# --self-test uses throwaway repositories. Exit 1 means a refusal; 2 means an incomplete scan.
set -eu
here="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$here/public_hygiene.py" "$@"
