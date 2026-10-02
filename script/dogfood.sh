#!/usr/bin/env bash
#
# dogfood.sh — run a DEBUG build of Pensieve against a throwaway home, fenced.
#
# Most people reach this through `pensieve-dev --sandbox …` (script/pull-dev-build.sh),
# which pulls the build and this script and hands off. You can also run it directly
# on any Mac with a local Debug Pensieve.app under DerivedData/Build/Products/Debug.
#
# WHAT IT DOES — two OS mechanisms, no app code
#   redirect  CFFIXED_USER_HOME + HOME point every Foundation home API, the
#             SwiftData store, the agent skill dirs, and child git at the fake home
#   fence     a sandbox-exec profile denies filesystem writes outside it (bar the
#             tolerances under WHAT IT DOES NOT DO) — kernel-enforced, inherited
#             by git and every other child process
#   identity  a copy of the app is staged under the sandbox root re-identified as
#             com.jaredatch.Pensieve.dogfood (Info.plist edit + ad-hoc re-seal), so
#             UserDefaults and Keychain — written by cfprefsd/securityd, out of the
#             fence's reach — are separate from both the released app and the
#             live-data dev build, and --reset can wipe them too
#   flag      PENSIEVE_DOGFOOD=1 tells the app to skip Sparkle and the legacy
#             launchd-agent migration, the two paths the fence cannot see
# The fence is self-tested before each launch: a write into the real home must
# fail, a write into the fake home must succeed, or the script refuses to run.
#
# WHAT IT DOES NOT DO
#   The fence is write-only: the app can still READ any file an absolute path
#   names. The per-user temp/cache dirs and a few /dev nodes stay writable
#   (Foundation needs them at launch). Network stays open unless --offline — a
#   sandbox run handed the production sync remote could still push to it.
#
# USE CASES
#   dogfood.sh App.app                    launch against the sandbox home (created empty on first use)
#   dogfood.sh --reset App.app            wipe the sandbox home, prefs, and Keychain items: true first run
#   dogfood.sh --offline App.app          no network at all: safe with any remote configured
#   dogfood.sh --foreground App.app       attached to this terminal, Ctrl-C quits (agent-driven runs)
#   dogfood.sh --dry-run App.app          show the profile and the launch command, launch nothing
#   dogfood.sh --home /Volumes/X/h App.app  a different fake home (never under /tmp or /var)
#
# OPTIONS
#   --reset        wipe the fake home, the dogfood prefs domain, and the dogfood Keychain items first
#   --offline      also deny all network (no sync, no remotes)
#   --foreground   run attached to this terminal (Ctrl-C quits) instead of detached
#   --home DIR     fake home (default: ~/PensieveSandbox/home, or $PENSIEVE_SANDBOX/home)
#   --dry-run      print the profile and the launch command; launch nothing
#   -h, --help     this text
#
# ENVIRONMENT
#   PENSIEVE_SANDBOX   sandbox root (default ~/PensieveSandbox); holds home/, Pensieve.app,
#                      pensieve.log, and one fence.<pid>.sb per launch
#
# GUARDS (each exits 1)
#   the app is not a Debug build (bundle id must end in .debug, or already be .dogfood)
#   the fake home resolves to the real home, contains it, or lives under /tmp or /var
#   --reset on a directory without the marker this script writes
#   the fence self-test fails in either direction
#
# Launch through this script only: `open`, Finder, and Xcode Run go through
# LaunchServices and drop the fence. Attach a debugger with Xcode's Attach to
# Process. Quit with ⌘Q or `kill <pid>`; an AppleScript `quit app id` to the
# dogfood identity is auto-denied from a headless shell.
#
# Written for bash 3.2 (stock macOS).

set -euo pipefail

SANDBOX_ROOT="${PENSIEVE_SANDBOX:-$HOME/PensieveSandbox}"
FAKE_HOME="$SANDBOX_ROOT/home"
MARKER=".pensieve-dogfood-home"
EXEC_REL="Contents/MacOS/Pensieve"
DOGFOOD_ID="com.jaredatch.Pensieve.dogfood"

DO_RESET=0
OFFLINE=0
FOREGROUND=0
DRY_RUN=0
APP=""

die() { printf 'dogfood: %s\n' "$1" >&2; exit 1; }
say() { printf '==> %s\n' "$1"; }

usage() {
  awk 'NR >= 3 && !/^#/ { exit } NR >= 3 { sub(/^# ?/, ""); print }' "$0"
  exit "${1:-0}"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reset)      DO_RESET=1; shift ;;
    --offline)    OFFLINE=1; shift ;;
    --foreground) FOREGROUND=1; shift ;;
    --dry-run)    DRY_RUN=1; shift ;;
    --home)       [ "$#" -ge 2 ] || die "--home needs a value"; FAKE_HOME="$2"; shift 2 ;;
    -h|--help)    usage 0 ;;
    -*)           printf 'unknown option: %s\n\n' "$1" >&2; usage 64 ;;
    *)            [ -z "$APP" ] || die "one app path only"; APP="$1"; shift ;;
  esac
done

[ -n "$APP" ] || usage 64
[ -x /usr/bin/sandbox-exec ] || die "/usr/bin/sandbox-exec is missing on this macOS — cannot enforce the filesystem write fence"

# --- the app: must exist, must be a Debug build ------------------------------
case "$APP" in */) APP="${APP%/}" ;; esac
# absolute path: `defaults read` treats an argument with no leading slash as a domain name, not a file
case "$APP" in /*) ;; *) APP="$PWD/$APP" ;; esac
[ -d "$APP" ] || die "no app bundle at $APP"
[ -x "$APP/$EXEC_REL" ] || die "no executable at $APP/$EXEC_REL"
bundle_id="$(defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
case "$bundle_id" in
  *.debug|"$DOGFOOD_ID") ;;
  "")      die "cannot read CFBundleIdentifier from $APP/Contents/Info.plist" ;;
  *)       die "$APP is not a Debug build (bundle id $bundle_id) — its prefs would land in the production domain; refusing" ;;
esac

# --- the fake home: canonical, never an alias, never the real home ----------
canon() { (cd "$1" 2>/dev/null && pwd -P); }

if [ "$DO_RESET" -eq 1 ] && [ -d "$FAKE_HOME" ]; then
  [ -f "$FAKE_HOME/$MARKER" ] || die "refusing to reset $FAKE_HOME: no $MARKER marker (not a dogfood home this script created)"
  say "resetting $FAKE_HOME"
  rm -rf "$FAKE_HOME"
fi
if [ "$DO_RESET" -eq 1 ]; then
  say "resetting the $DOGFOOD_ID prefs domain"
  defaults delete "$DOGFOOD_ID" >/dev/null 2>&1 || true
  # Keychain items the dogfood identity stored (service "<id>.git.<host>"); dump-keychain
  # without -d lists attributes only and never prompts. Delete each service until none match.
  for svc in $(security dump-keychain 2>/dev/null | sed -n "s/.*\"svce\"<blob>=\"\($DOGFOOD_ID\.git\.[^\"]*\)\".*/\1/p" | sort -u); do
    say "removing Keychain item $svc"
    while security delete-generic-password -s "$svc" >/dev/null 2>&1; do :; done
    if security find-generic-password -s "$svc" >/dev/null 2>&1; then
      say "warning: $svc survived (keychain locked?) — a stored PAT may carry into this run"
    fi
  done
fi

first_run=0
if [ ! -d "$FAKE_HOME" ]; then
  first_run=1
  mkdir -p "$FAKE_HOME"
fi
FAKE_HOME="$(canon "$FAKE_HOME")" || die "cannot resolve $FAKE_HOME"

real_home="$(canon "$HOME")"
case "$FAKE_HOME" in
  /|/tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/*|/private/var/*)
    die "fake home must not live under /tmp or /var (CoreFoundation strips /private and Seatbelt matches canonical paths): $FAKE_HOME" ;;
esac
[ "$FAKE_HOME" != "$real_home" ] || die "fake home resolves to the real home"
case "$real_home/" in "$FAKE_HOME"/*) die "fake home contains the real home" ;; esac

if [ "$first_run" -eq 1 ]; then
  say "first run: seeding an empty home at $FAKE_HOME"
  # Empty agent dirs so agent detection sees "installed, nothing deployed".
  for d in .claude/skills .codex/skills .openclaw/skills .hermes/skills .cursor/rules \
           Library/Application\ Support Library/Preferences Library/Caches; do
    mkdir -p "$FAKE_HOME/$d"
  done
  printf 'created by script/dogfood.sh %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$FAKE_HOME/$MARKER"
fi
[ -f "$FAKE_HOME/$MARKER" ] || die "$FAKE_HOME exists but has no $MARKER marker — pick another --home or reset by hand"

# --- stage the app under its dogfood identity --------------------------------
# A copy, never the source bundle: the Info.plist edit and re-seal must not touch
# the build product pull-dev-build.sh manages or the tree a build wrote.
mkdir -p "$SANDBOX_ROOT"
if [ "$bundle_id" = "$DOGFOOD_ID" ]; then
  STAGED="$APP"
else
  STAGED="$SANDBOX_ROOT/Pensieve.app"
  # Never rsync over a running bundle: stop a previous sandbox run first (TERM, wait, refuse).
  old_pids="$(pgrep -f "$STAGED/$EXEC_REL" 2>/dev/null || true)"
  if [ -n "$old_pids" ]; then
    say "a previous sandbox run is still up (pid $old_pids) — stopping it"
    for pid in $old_pids; do kill -TERM "$pid" 2>/dev/null || true; done
    n=0
    while [ "$n" -lt 20 ]; do
      still=""
      for pid in $old_pids; do kill -0 "$pid" 2>/dev/null && still="yes"; done
      [ -n "$still" ] || break
      sleep 0.5; n=$((n + 1))
    done
    [ -z "$still" ] || die "previous sandbox run (pid $old_pids) will not quit — quit it by hand and re-run"
  fi
  say "staging $APP → $STAGED as $DOGFOOD_ID"
  rsync -a --delete "$APP/" "$STAGED/" || die "could not stage the app"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $DOGFOOD_ID" "$STAGED/Contents/Info.plist" \
    || die "could not rewrite CFBundleIdentifier"
  # Ad-hoc re-seal of the outer bundle after the plist edit; nested code keeps its own signature.
  codesign --force --sign - "$STAGED" >/dev/null 2>&1 || die "ad-hoc re-seal failed"
  staged_id="$(defaults read "$STAGED/Contents/Info" CFBundleIdentifier 2>/dev/null || true)"
  [ "$staged_id" = "$DOGFOOD_ID" ] || die "staged bundle id is '$staged_id', expected $DOGFOOD_ID"
  codesign --verify "$STAGED" >/dev/null 2>&1 || die "staged bundle does not verify after re-seal"
fi

# --- the fence ---------------------------------------------------------------
user_tmp="$(canon "$(getconf DARWIN_USER_TEMP_DIR)")"   || die "no DARWIN_USER_TEMP_DIR"
user_cache="$(canon "$(getconf DARWIN_USER_CACHE_DIR)")" || die "no DARWIN_USER_CACHE_DIR"
user_dir="$(canon "$(getconf DARWIN_USER_DIR)")"         || die "no DARWIN_USER_DIR"

# One profile per invocation: the self-test and the launch must read the same file, and two
# overlapping runs sharing SANDBOX_ROOT must not rewrite each other's profile in between.
PROFILE="$SANDBOX_ROOT/fence.$$.sb"
find "$SANDBOX_ROOT" -maxdepth 1 -name 'fence.*.sb' -mtime +1 -delete 2>/dev/null || true
{
  echo '(version 1)'
  echo '(allow default)'
  echo '(deny file-write*)'
  echo "(allow file-write* (subpath \"$FAKE_HOME\"))"
  echo "(allow file-write* (subpath \"$user_tmp\") (subpath \"$user_cache\") (subpath \"$user_dir\"))"
  echo '(allow file-write* (literal "/dev/null") (literal "/dev/zero") (literal "/dev/dtracehelper") (regex #"^/dev/tty") (regex #"^/dev/ptmx"))'
  if [ "$OFFLINE" -eq 1 ]; then
    echo '(deny network*)'
    echo '(allow network* (local unix-socket) (remote unix-socket))'
  fi
} > "$PROFILE"

# --- prove the fence before trusting it --------------------------------------
probe_out="$FAKE_HOME/.fence-probe"
probe_leak="$real_home/.pensieve-dogfood-fence-probe"
rm -f "$probe_out" "$probe_leak"
if ! /usr/bin/sandbox-exec -f "$PROFILE" /bin/sh -c "echo ok > '$probe_out'" 2>/dev/null; then
  die "fence self-test: a write INSIDE the fake home was denied — profile is wrong ($PROFILE)"
fi
if /usr/bin/sandbox-exec -f "$PROFILE" /bin/sh -c "echo leak > '$probe_leak'" 2>/dev/null; then
  rm -f "$probe_leak"
  die "fence self-test: a write into the REAL home succeeded — the fence is not holding; refusing to launch"
fi
[ ! -e "$probe_leak" ] || { rm -f "$probe_leak"; die "fence self-test: probe file appeared in the real home"; }
rm -f "$probe_out"
say "fence holds: real home denied, fake home allowed"

# --- launch ------------------------------------------------------------------
LOG="$SANDBOX_ROOT/pensieve.log"
version="$(defaults read "$STAGED/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo '?')"
say "app: $STAGED ($DOGFOOD_ID $version, from $APP)"
say "home: $FAKE_HOME"
[ "$OFFLINE" -eq 0 ] || say "network: denied (--offline)"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "--- $PROFILE"; cat "$PROFILE"; echo "---"
  echo "env HOME='$FAKE_HOME' CFFIXED_USER_HOME='$FAKE_HOME' PENSIEVE_DOGFOOD=1 /usr/bin/sandbox-exec -f '$PROFILE' '$STAGED/$EXEC_REL'"
  exit 0
fi

if [ "$FOREGROUND" -eq 1 ]; then
  say "running in the foreground (Ctrl-C quits)"
  exec env HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" PENSIEVE_DOGFOOD=1 \
    /usr/bin/sandbox-exec -f "$PROFILE" "$STAGED/$EXEC_REL"
fi

nohup env HOME="$FAKE_HOME" CFFIXED_USER_HOME="$FAKE_HOME" PENSIEVE_DOGFOOD=1 \
  /usr/bin/sandbox-exec -f "$PROFILE" "$STAGED/$EXEC_REL" > "$LOG" 2>&1 < /dev/null &
pid=$!
disown "$pid" 2>/dev/null || true
sleep 2
if kill -0 "$pid" 2>/dev/null; then
  say "running: pid $pid (stop with ⌘Q or: kill $pid)"
  say "prefs: defaults read $DOGFOOD_ID   (wiped by --reset)"
  say "log: $LOG"
  say "denials, live: log stream --predicate 'sender == \"Sandbox\" AND eventMessage CONTAINS \"deny(1) file-write\"'"
else
  say "the app exited within 2 s — last lines of $LOG:"
  tail -20 "$LOG" >&2 || true
  exit 1
fi
