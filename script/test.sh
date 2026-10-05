#!/usr/bin/env bash
set -euo pipefail

# A failed run keeps its result bundle, so a flake that doesn't reproduce can still be read afterwards (#61). Moves
# bundle $1 into dir $2 under a UTC-stamped name, prunes $2 to its newest five, and prints the kept path.
keep_failed_bundle() {
  local kept
  kept="$2/$(date -u +%Y%m%dT%H%M%SZ)-$$.xcresult"
  mkdir -p "$2" && mv "$1" "$kept" || return 1
  ls -1d "$2"/*.xcresult 2>/dev/null | sort -r | tail -n +6 | while IFS= read -r old; do rm -rf "$old"; done || true
  printf '%s\n' "$kept"
}

if [ "${1:-}" = "--self-test" ]; then
  st="$(mktemp -d "${TMPDIR:-/tmp}/pensieve-test-selftest.XXXXXX")"; trap 'rm -rf "$st"' EXIT
  fail() { echo "test.sh --self-test: FAIL: $1" >&2; exit 1; }
  for i in 1 2 3 4 5 6; do mkdir -p "$st/kept/2020010${i}T000000Z-1.xcresult"; done
  mkdir -p "$st/run.xcresult"; : > "$st/run.xcresult/marker"
  kept="$(keep_failed_bundle "$st/run.xcresult" "$st/kept")" || fail "keeping an existing bundle returned non-zero"
  [ -f "$kept/marker" ] || fail "the kept path doesn't hold the run's bundle: $kept"
  [ ! -e "$st/run.xcresult" ] || fail "the bundle was copied, not moved"
  [ "$(ls -1d "$st/kept"/*.xcresult | wc -l | tr -d ' ')" -eq 5 ] || fail "the kept dir isn't pruned to five"
  [ ! -e "$st/kept/20200102T000000Z-1.xcresult" ] || fail "the second-oldest bundle survived the prune"
  [ -e "$st/kept/20200103T000000Z-1.xcresult" ] || fail "a bundle inside the newest five was pruned"
  if keep_failed_bundle "$st/missing.xcresult" "$st/kept" >/dev/null 2>&1; then fail "a missing bundle reported kept"; fi
  [ "$(ls -1d "$st/kept"/*.xcresult | wc -l | tr -d ' ')" -eq 5 ] || fail "a missing bundle changed the kept dir"
  python3 -B "$(dirname "$0")/test_lifecycle_self_test.py" || fail "test lifecycle regressions"
  echo "test.sh --self-test: OK"
  exit 0
fi

# One test run per machine (the playbook's modules/macos-swift.md § Wrapper scripts): take the machine's test lock
# before anything else, so a second run from any checkout waits in line. The kernel drops it when the holder exits.
# Two lanes: a full suite first queues behind any other full suite on test-full.lock, and a --filter run skips that
# line, so a focused proof never waits behind every queued suite. The holder line and the wait go to stderr.
if [ -z "${XP_TEST_LOCK_HELD:-}" ]; then
  dir="$HOME/.local/state/execplan"; mkdir -p "$dir" || exit 2
  : "${XP_TEST_T0:=$(date +%s)}"; export XP_TEST_T0
  case " $* " in *" --filter "*) ;; *)   # a full suite queues in its own lane first
    if [ -z "${XP_TEST_FULL_HELD:-}" ]; then
      /usr/bin/lockf -k -s -t 0 "$dir/test-full.lock" true || echo "test.sh: waiting behind another full suite" >&2
      XP_TEST_FULL_HELD=1 exec /usr/bin/lockf -k "$dir/test-full.lock" "$0" "$@"
    fi ;; esac
  /usr/bin/lockf -k -s -t 0 "$dir/test.lock" true || echo "test.sh: waiting for this machine's test lock, held by: $(cat "$dir/test.lock.holder" 2>/dev/null)" >&2
  XP_TEST_LOCK_HELD=1 exec /usr/bin/lockf -k "$dir/test.lock" "$0" "$@"
fi
if [ -n "${XP_TEST_T0:-}" ]; then   # this run took the lock itself (a caller holding it, like the self-test, skips this)
  printf 'pid %s in %s: test.sh %s\n' "$$" "$PWD" "$*" > "$HOME/.local/state/execplan/test.lock.holder"   # before HOME moves below
  echo "test.sh: waited $(( $(date +%s) - XP_TEST_T0 )) s for the test lock" >&2
fi

REPO="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="platform=macOS,arch=arm64"
DERIVED_DATA="$REPO/DerivedData"
export HOME="$DERIVED_DATA/Home"
export CLANG_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFT_MODULE_CACHE_PATH="$DERIVED_DATA/ModuleCache.noindex"
export SWIFTPM_MODULECACHE_OVERRIDE="$DERIVED_DATA/ModuleCache.noindex"
export XDG_CACHE_HOME="$DERIVED_DATA/XDGCache"
SCHEME="Pensieve"
# Only failing timeout tests create this directory; TEST_RUNNER_ forwards it into each host.
export TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR="${TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR:-$DERIVED_DATA/TestDiagnostics}"

usage() {
  echo "usage: $0 [--filter TEST_IDENTIFIER] | --self-test" >&2
}

FILTER_ARGS=()
case "${1:-}" in
  "")
    ;;
  "--filter")
    if [ "$#" -ne 2 ]; then
      usage
      exit 64
    fi
    filter="$2"
    case "$filter" in
      */*)
        ;;
      *)
        filter="PensieveTests/$filter"
        ;;
    esac
    FILTER_ARGS=(-only-testing "$filter")
    ;;
  *)
    usage
    exit 64
    ;;
esac

if [ "${1:-}" != "--filter" ] && [ "$#" -ne 0 ]; then
  usage
  exit 64
fi

cd "$REPO"
xcodegen generate
mkdir -p "$HOME" "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME"

# The suite runs in parallel, one test class per worker. A parallel run prints no "Executed N tests" line, so the
# count comes from the result bundle. xcodebuild refuses a bundle path that already exists: it goes in a fresh dir.
# Keep in-progress bundles where CI can upload them even if the step kills this wrapper.
mkdir -p "$DERIVED_DATA/TestRuns"
python3 "$REPO/script/test_runs.py" "$DERIVED_DATA/TestRuns"
# Prune only older evidence. Every report written by this run survives for CI upload.
if ! python3 "$REPO/script/test_diagnostics.py" --prune "$TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR"; then
  echo "test.sh: warning: timeout diagnostics pruning failed; continuing the test run" >&2
fi
rdir="$(mktemp -d "$DERIVED_DATA/TestRuns/run.XXXXXX")"
# Foundation ignores TMPDIR on macOS. The fixture helper reads this forwarded variable instead.
export TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT="$rdir/tmp"
mkdir "$TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT"
# A missing or damaged fixture repo must not discover this checkout above TestRuns.
export TEST_RUNNER_GIT_CEILING_DIRECTORIES="$TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT"
# Xcode buffers parallel hosts' stdout. Relay completed reports while tests are still running.
python3 -u "$REPO/script/test_diagnostics.py" "$TEST_RUNNER_PENSIEVE_TEST_DIAGNOSTICS_DIR" "$$" --ready "$rdir/.diagnostics-ready" &
relay_pid=$!
finish_relay() { kill -TERM "$relay_pid" 2>/dev/null || true; wait "$relay_pid" 2>/dev/null || true; }
trap finish_relay EXIT
relay_start=$SECONDS
until [ -f "$rdir/.diagnostics-ready" ]; do
  if ! kill -0 "$relay_pid" 2>/dev/null || [ "$((SECONDS - relay_start))" -ge 30 ]; then
    echo "test.sh: timeout diagnostic relay did not become ready" >&2
    exit 1
  fi
  sleep 0.05
done
rm -f "$rdir/.diagnostics-ready"
bundle="$rdir/run.xcresult"
status=0
set +e
# This lock holder outlives a killed wrapper until xcodebuild exits. Pruning never breaks its lock.
/usr/bin/lockf -k "$rdir/.active.lock" xcodebuild test \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  -parallel-testing-enabled YES \
  -test-timeouts-enabled YES \
  -default-test-execution-time-allowance 180 \
  -maximum-test-execution-time-allowance 180 \
  -resultBundlePath "$bundle" \
  CLANG_MODULE_CACHE_PATH="$CLANG_MODULE_CACHE_PATH" \
  SWIFT_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE_PATH" \
  ${FILTER_ARGS[@]+"${FILTER_ARGS[@]}"} 2>&1
status="$?"
set -e

count=""
if [ -d "$bundle" ]; then
  count="$(xcrun xcresulttool get test-results summary --path "$bundle" --compact | jq -r '.totalTestCount // empty')" || count=""
fi
# Xcode and Foundation leave empty temporary directories outside TMPDIR. The shallow sweep is bounded and best-effort.
if system_temp="$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null)" && [ -d "$system_temp" ]; then
  python3 "$REPO/script/test_temp_cleanup.py" "$system_temp" >/dev/null 2>&1 || true
fi
# Completed runs need no fixture leftovers. Interrupted runs keep theirs under TestRuns' existing pruning.
rm -rf "$TEST_RUNNER_PENSIEVE_TEST_TEMP_ROOT"
unread=0
case "$count" in
  ''|*[!0-9]*)
    unread=1
    count=0
    ;;
esac

# A failed run's bundle goes to DerivedData/FailedRuns (keep_failed_bundle, top) and its failures are printed here;
# `xcrun xcresulttool get test-results activities --test-id <id> --path <bundle>` reads a test's activity log.
# Messages go to stderr: the count line must stay stdout's last line.
if [ "$status" -ne 0 ] && [ -d "$bundle" ]; then
  if kept="$(keep_failed_bundle "$bundle" "$DERIVED_DATA/FailedRuns")"; then
    rm -f "$rdir/.active.lock"
    rmdir "$rdir" 2>/dev/null || true
    echo "test.sh: the failed run's result bundle is kept at $kept" >&2
    xcrun xcresulttool get test-results summary --path "$kept" --compact 2>/dev/null \
      | jq -r '.testFailures[]? | "test.sh: failed \(.testIdentifierString // .testName): \(.failureText // "")"' >&2 || true
  fi
fi

# Flush evidence before the count marker. On interruption, the EXIT trap stops the relay;
# the in-progress bundle stays in TestRuns instead of being deleted.
finish_relay
trap - EXIT
if [ "$status" -eq 0 ]; then rm -rf "$rdir"; fi
printf 'PENSIEVE_TEST_COUNT=%s\n' "$count"

# A passing run whose count can't be read is refused, never reported as 0 tests passing.
if [ "$unread" -eq 1 ] && [ "$status" -eq 0 ]; then
  echo "test.sh: the run passed but its test count could not be read from the result bundle" >&2
  exit 1
fi

# A --filter that matches no test class/method makes xcodebuild exit 0 having run nothing — a vacuous pass a
# Verify block would read as green. Refuse it. The full run (no filter) is untouched: a zero count there is
# the suite's own business and the count floor (ratchet.sh) catches it.
if [ -n "${filter:-}" ] && [ "$count" -eq 0 ] && [ "$status" -eq 0 ]; then
  echo "test.sh: --filter matched zero tests (vacuous pass refused)" >&2
  exit 1
fi
exit "$status"
