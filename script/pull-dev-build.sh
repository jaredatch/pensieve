#!/usr/bin/env bash
#
# pull-dev-build.sh — build Pensieve on the dev host, run it on THIS Mac.
# Install as ~/bin/pensieve-dev on the Mac that will run the build.
#
# Runs FROM a Mac without the toolchain. It ssh's to the dev host, builds the
# current working tree headlessly, rsyncs the built Debug .app down to
# ~/Applications/PensieveDev.app together with script/dogfood.sh, and launches.
#
# THREE BUILDS, THREE IDENTITIES
#   /Applications/Pensieve.app      com.jaredatch.Pensieve          released, your real data
#   ~/Applications/PensieveDev.app  com.jaredatch.Pensieve.debug    dev build, your real data
#   ~/PensieveSandbox/Pensieve.app  com.jaredatch.Pensieve.dogfood  dev build, throwaway data
# They can all run at once. Each has its own prefs and Keychain items, so the
# first launch of a new identity re-asks for Accessibility and for a PAT.
# The released and dev builds SHARE ~/.pensieve, the SwiftData store, and the
# agent skill dirs; only the sandbox has its own.
#
# Set PENSIEVE_DEV_HOST to your build host, or pass --host HOST.
#
# USE CASES
#   pensieve-dev                          daily dogfood: latest master against your real data
#   pensieve-dev --sandbox --reset        empty store, first-run flow, welcome sheet — from nothing
#   pensieve-dev --sandbox                keep testing the sandbox you built up last time
#   pensieve-dev --sandbox --offline      same, but the run cannot reach any network (no sync)
#   pensieve-dev --no-build               relaunch what the host already built (no rebuild)
#   pensieve-dev --no-open                refresh the bundle only, launch later yourself
#   pensieve-dev --update                 refresh THIS script from the host, then exit
#
# OPTIONS
#   --sandbox    run against a throwaway home (~/PensieveSandbox/home) under a
#                kernel write fence (script/dogfood.sh). Nothing it writes can land
#                in ~/.pensieve, the real store, or the agent dirs. The fence is
#                write-only and network stays open unless --offline.
#   --reset      with --sandbox: wipe the sandbox home and its prefs first (true first run)
#   --offline    with --sandbox: also deny all network for the run
#   --no-build   skip the remote build; pull whatever is already built on the host
#   --no-open    sync the bundle, don't launch it
#   --host HOST  dev host (required unless PENSIEVE_DEV_HOST is set)
#   --yes        skip the first-install confirmation (live-data mode only)
#   --update     copy the host's current script/pull-dev-build.sh over this file and exit
#   -h, --help   this text
#
# ENVIRONMENT
#   PENSIEVE_DEV_HOST   ssh host (required unless --host is passed)
#   PENSIEVE_DEV_REPO   repo path on the host, relative to $HOME (Projects/pensieve)
#   PENSIEVE_DEV_APP    where the dev bundle lands (~/Applications/PensieveDev.app)
#   PENSIEVE_SANDBOX    sandbox root for --sandbox (~/PensieveSandbox)
#
# WHERE THINGS ARE AFTER A --sandbox RUN
#   ~/PensieveSandbox/home          the fake home: .pensieve, Library/Application Support, .claude/skills …
#   ~/PensieveSandbox/pensieve.log  the app's stderr
#   ~/PensieveSandbox/Pensieve.app  the staged .dogfood copy (regenerated every run)
#   Quit it with ⌘Q or `kill <pid>` (the script prints the pid). Deploys land in
#   ~/PensieveSandbox/home/.claude/skills, not the real one. Register projects
#   under ~/PensieveSandbox/ — a real project folder would be write-denied.
#
# Written for bash 3.2 (stock macOS) and openrsync (macOS 15+).
# Host-selection tests: python3 -B script/pull_dev_build_self_test.py

set -euo pipefail

HOST="${PENSIEVE_DEV_HOST:-}"
REMOTE_REPO="${PENSIEVE_DEV_REPO:-Projects/pensieve}"
APP="${PENSIEVE_DEV_APP:-$HOME/Applications/PensieveDev.app}"
REMOTE_PRODUCT="DerivedData/Build/Products/Debug/Pensieve.app"
REMOTE_DOGFOOD="script/dogfood.sh"
PROD_APP="/Applications/Pensieve.app"
EXEC_REL="Contents/MacOS/Pensieve"
DEV_BUNDLE_ID="com.jaredatch.Pensieve.debug"

DO_BUILD=1
DO_OPEN=1
ASSUME_YES=0
SANDBOX=0
SANDBOX_ARGS=""
SELF_UPDATE=0

die() { printf 'pull-dev-build: %s\n' "$1" >&2; exit 1; }
say() { printf '==> %s\n' "$1"; }

usage() {
  # Print the header comment block (everything from line 3 to the first non-comment line).
  awk 'NR >= 3 && !/^#/ { exit } NR >= 3 { sub(/^# ?/, ""); print }' "$0"
  exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-open)  DO_OPEN=0; shift ;;
    --no-build) DO_BUILD=0; shift ;;
    --yes|-y)   ASSUME_YES=1; shift ;;
    --host)     [ "$#" -ge 2 ] || die "--host needs a value"; HOST="$2"; shift 2 ;;
    --sandbox)  SANDBOX=1; shift ;;
    --reset)    SANDBOX_ARGS="$SANDBOX_ARGS --reset"; shift ;;
    --offline)  SANDBOX_ARGS="$SANDBOX_ARGS --offline"; shift ;;
    --update)   SELF_UPDATE=1; shift ;;
    -h|--help)  usage 0 ;;
    *)          printf 'unknown option: %s\n\n' "$1" >&2; usage 64 ;;
  esac
done

[ -n "$HOST" ] || die "set --host HOST or PENSIEVE_DEV_HOST to the dev host"

if [ "$SANDBOX" -eq 0 ] && [ -n "$SANDBOX_ARGS" ]; then
  die "--reset / --offline only make sense with --sandbox"
fi

# --- self-update: replace this file with the host's current copy -----------
if [ "$SELF_UPDATE" -eq 1 ]; then
  self="$0"
  case "$self" in /*) ;; *) self="$PWD/$self" ;; esac
  tmp="$self.new.$$"
  say "fetching $HOST:$REMOTE_REPO/script/pull-dev-build.sh → $self"
  scp -q "$HOST:$REMOTE_REPO/script/pull-dev-build.sh" "$tmp" || { rm -f "$tmp"; die "scp failed — nothing changed"; }
  bash -n "$tmp" || { rm -f "$tmp"; die "fetched script does not parse — nothing changed"; }
  if ! { chmod +x "$tmp" && mv -f "$tmp" "$self"; }; then
    rm -f "$tmp"; die "could not replace $self"
  fi
  say "updated: $(grep -m1 -o 'pull-dev-build.sh — .*' "$self")"
  exit 0
fi

case "$APP" in
  "$PROD_APP"|/Applications/Pensieve.app)
    die "refusing to overwrite the released app at $PROD_APP" ;;
esac
case "$APP" in
  *.app) ;;
  *) die "PENSIEVE_DEV_APP must end in .app (got: $APP)" ;;
esac
DOGFOOD="$(dirname "$APP")/pensieve-dogfood.sh"

# --- first install: the store migration is a one-way door -------------------
if [ ! -e "$APP" ] && [ "$ASSUME_YES" -eq 0 ] && [ "$SANDBOX" -eq 0 ]; then
  cat <<'WARN'
First install of the dev build on this Mac, against your LIVE data.

Once it writes, ~/.pensieve and the SwiftData store move to whatever schema
the dev tree carries. The released app refuses a newer manifest, so it may
not open this store again until the next release ships.

Back up first if you have not:
  cp -R ~/.pensieve ~/pensieve-backup-$(date +%Y%m%d)
  cp ~/Library/Application\ Support/default.store* ~/pensieve-backup-$(date +%Y%m%d)/

(Or run with --sandbox: a throwaway home, nothing touches your data.)

WARN
  if [ -t 0 ]; then
    printf 'Continue? [y/N] '
    read -r reply
    case "$reply" in
      y|Y|yes|YES) ;;
      *) die "aborted" ;;
    esac
  else
    say "non-interactive shell — continuing (pass --yes to silence this)"
  fi
fi

# --- remote build ----------------------------------------------------------
if [ "$DO_BUILD" -eq 1 ]; then
  say "building on $HOST:$REMOTE_REPO (headless)"
  ssh "$HOST" "export PATH=/opt/homebrew/bin:\$PATH; cd \"\$HOME/$REMOTE_REPO\" && ./script/build_and_run.sh --headless" \
    || die "remote build failed — nothing was copied"
fi

say "checking the remote build"
remote_state="$(ssh "$HOST" "cd \"\$HOME/$REMOTE_REPO\" && \
  test -d '$REMOTE_PRODUCT' && \
  git log -1 --format='%h %s' && \
  git status --porcelain | wc -l | tr -d ' '")" \
  || die "no built app at $REMOTE_REPO/$REMOTE_PRODUCT on $HOST (drop --no-build?)"

remote_head="$(printf '%s\n' "$remote_state" | sed -n '1p')"
remote_dirty="$(printf '%s\n' "$remote_state" | sed -n '2p')"
say "source: $remote_head"
if [ "${remote_dirty:-0}" != "0" ]; then
  say "note: $remote_dirty uncommitted change(s) in the remote tree"
fi

# --- quit the previous dev build (the released app is untouched) -----------
running_pids() {  # $1 = app bundle path
  pgrep -f "$1/$EXEC_REL" 2>/dev/null || true
}

quit_app() {  # $1 = label, $2 = pids
  say "quitting the $1 app"
  osascript -e "quit app id \"$DEV_BUNDLE_ID\"" >/dev/null 2>&1 || true
  n=0
  while [ "$n" -lt 20 ]; do
    still=""
    for pid in $2; do
      if kill -0 "$pid" 2>/dev/null; then still="yes"; fi
    done
    if [ -z "$still" ]; then return 0; fi
    sleep 0.5
    n=$((n + 1))
  done
  say "$1 app ignored the quit request — sending TERM"
  for pid in $2; do kill -TERM "$pid" 2>/dev/null || true; done
  sleep 2
  for pid in $2; do
    if kill -0 "$pid" 2>/dev/null; then
      die "$1 app (pid $pid) won't quit — quit it by hand and re-run"
    fi
  done
}

dev_pids="$(running_pids "$APP")"
if [ -n "$dev_pids" ]; then quit_app "dev" "$dev_pids"; fi

# --- pull ------------------------------------------------------------------
mkdir -p "$(dirname "$APP")"
say "syncing → $APP"
rsync -a --delete "$HOST:$REMOTE_REPO/$REMOTE_PRODUCT/" "$APP/" \
  || die "rsync failed — the local bundle may be half-written; re-run"
rsync -a "$HOST:$REMOTE_REPO/$REMOTE_DOGFOOD" "$DOGFOOD" \
  || die "rsync of $REMOTE_DOGFOOD failed"
chmod +x "$DOGFOOD"

xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign -v "$APP" 2>/dev/null || say "warning: signature check failed — if it won't launch, re-run to re-sync"

pulled_id="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
if [ "$pulled_id" != "$DEV_BUNDLE_ID" ]; then
  say "warning: pulled bundle id is '$pulled_id', expected $DEV_BUNDLE_ID — does the remote tree separate Debug and Release identities?"
fi

# --- launch ----------------------------------------------------------------
if [ "$DO_OPEN" -eq 0 ]; then
  if [ "$SANDBOX" -eq 1 ]; then
    say "done (not launching). Sandboxed run: '$DOGFOOD'$SANDBOX_ARGS '$APP'"
  else
    say "done (not launching). Run it with: open '$APP'"
  fi
  exit 0
fi

if [ "$SANDBOX" -eq 1 ]; then
  say "launching sandboxed"
  # shellcheck disable=SC2086  # SANDBOX_ARGS is a flag list by construction
  exec "$DOGFOOD" $SANDBOX_ARGS "$APP"
fi

say "launching against live data"
open "$APP"
sleep 2
launched="$(ps -Ao args= | grep -F "$EXEC_REL" | grep -v grep | grep -F "$APP" | head -1 || true)"
case "$launched" in
  "$APP"*) say "running the dev build: $APP" ;;
  *)       say "warning: no dev-build process found — check the Dock" ;;
esac

say "tell: About Pensieve shows the dev build's version; its bundle id is $DEV_BUNDLE_ID (defaults read '$APP/Contents/Info' CFBundleIdentifier)"
