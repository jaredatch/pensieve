#!/usr/bin/env bash
# Attach files to a GitHub issue: upload each to the repo's orphan `attachments` branch under issues/<N>/ and print a
# Markdown line that embeds it (an image) or links it (anything else). Paste the lines into the issue body or a comment.
# GitHub has no API for issue attachments, so the files live on that branch; a private repo's images render only for
# people with access to it. The branch shares no history with the default branch, and pushes to it run no workflow
# whose trigger is limited to the default branch.
#
#   script/gh-attach.sh -R owner/repo ISSUE FILE...
#
# Acts as kramer-bot unless GH_TOKEN is already set. Re-uploading a name replaces that file. Bash 3.2.
set -euo pipefail

usage() { echo "usage: script/gh-attach.sh -R owner/repo ISSUE FILE..." >&2; exit 64; }
[ "${1:-}" = "-R" ] && [ -n "${2:-}" ] || usage
repo="$2"; shift 2
issue="${1:-}"; shift || usage
case "$issue" in ''|*[!0-9]*) usage ;; esac
[ "$#" -gt 0 ] || usage

branch=attachments
max_bytes=$((25 * 1024 * 1024))
if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$(gh auth token --user kramer-bot)" || { echo "gh-attach: no kramer-bot token in gh's keyring" >&2; exit 1; }
fi
export GH_TOKEN

for f in "$@"; do
  [ -f "$f" ] || { echo "gh-attach: not a file: $f" >&2; exit 1; }
  size="$(wc -c < "$f" | tr -d ' ')"
  [ "$size" -le "$max_bytes" ] || { echo "gh-attach: $f is over 25 MB" >&2; exit 1; }
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The branch starts as an orphan commit holding one README, so it never carries the default branch's tree.
if ! gh api "repos/$repo/git/ref/heads/$branch" > /dev/null 2>&1; then
  readme="Files attached to this repo's issues by script/gh-attach.sh, one folder per issue. No code lives here."
  blob="$(gh api "repos/$repo/git/blobs" -f content="$readme" -f encoding=utf-8 --jq .sha)"
  tree="$(gh api "repos/$repo/git/trees" -f "tree[][path]=README.md" -f "tree[][mode]=100644" -f "tree[][type]=blob" -f "tree[][sha]=$blob" --jq .sha)"
  commit="$(gh api "repos/$repo/git/commits" -f message="Start the attachments branch" -f tree="$tree" --jq .sha)"
  gh api "repos/$repo/git/refs" -f ref="refs/heads/$branch" -f sha="$commit" > /dev/null
fi

for f in "$@"; do
  name="$(basename "$f")"
  path="issues/$issue/$name"
  base64 < "$f" | tr -d '\n' > "$work/content"
  existing="$(gh api "repos/$repo/contents/$path?ref=$branch" --jq .sha 2>/dev/null || true)"
  if [ -n "$existing" ]; then
    jq -n --rawfile c "$work/content" --arg m "Issue #$issue: replace $name" --arg b "$branch" --arg s "$existing" \
      '{message:$m, content:$c, branch:$b, sha:$s}' > "$work/body.json"
  else
    jq -n --rawfile c "$work/content" --arg m "Issue #$issue: attach $name" --arg b "$branch" \
      '{message:$m, content:$c, branch:$b}' > "$work/body.json"
  fi
  gh api -X PUT "repos/$repo/contents/$path" --input "$work/body.json" > /dev/null
  url="https://github.com/$repo/blob/$branch/$path?raw=true"
  case "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" in
    *.png|*.jpg|*.jpeg|*.gif|*.webp) printf '![%s](%s)\n' "$name" "$url" ;;
    *) printf '[%s](%s)\n' "$name" "$url" ;;
  esac
done
