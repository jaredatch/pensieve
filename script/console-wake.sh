#!/bin/bash
# console-wake.sh — wake the Mac's console before a cua-driver gate; tell a sleeping display from a real lock.
#
# On macOS 26 the display turning off sets CGSSessionScreenIsLocked on the console session even with the
# password lock off (sysadminctl -screenLock status = off); cua-driver then reports the console locked and
# reads no windows and no pixels. Declaring user activity clears the flag in seconds. A real lock — Apple
# menu › Lock Screen, a password prompt — survives the wake, and that is the only case that stops a run.
# Proven 2026-09-22 (display off 20:04 CDT → flagged; caffeinate -u → clear in 4 s). The screen saver's own
# flag, and whether a display hold keeps it off, are unproven — read the flag again if a gate stalls.
#
#   script/console-wake.sh              wake if flagged, then hold the display awake (default 4 h)
#   script/console-wake.sh --check      report only, no wake: 0 clear, 1 flagged
#   script/console-wake.sh --hold SECS  hold length after the wake (0 = no hold)
#   script/console-wake.sh --self-test
#
# Exit 0: console clear (the hold running).  1: still locked after the wake — a real lock; stop, ask the user.
# 2: a tool failed or an argument is wrong — never read as clear.

set -u

# Prints "locked" or "clear" for the console session in an `ioreg -n Root -d1` IOConsoleUsers line;
# returns 2 when the line names no console session.
flag_from() {
  case "$1" in
    *'"kCGSSessionOnConsoleKey"=Yes'*) ;;
    *) return 2 ;;
  esac
  case "$1" in
    *'"CGSSessionScreenIsLocked"=Yes'*) echo locked ;;
    *) echo clear ;;
  esac
}

read_flag() {
  local line
  line="$(ioreg -n Root -d1 2>/dev/null | grep -e '"IOConsoleUsers" = ')" || return 2
  flag_from "$line"
}

self_test() {
  local fails=0 out
  check() { if [ "$1" = "$2" ]; then echo "ok   $3"; else echo "FAIL $3: want [$1] got [$2]"; fails=$((fails+1)); fi; }
  out="$(flag_from '"IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserNameKey"="user","CGSSessionScreenIsLocked"=Yes})')"
  check locked "$out" "flagged line reads locked"
  out="$(flag_from '"IOConsoleUsers" = ({"kCGSSessionOnConsoleKey"=Yes,"kCGSSessionUserNameKey"="user"})')"
  check clear "$out" "line without the flag reads clear"
  out="$(flag_from '"IOConsoleUsers" = ({"kCGSSessionUserNameKey"="user"})' 2>/dev/null)"; local rc=$?
  check 2 "$rc" "no console session is exit 2, not clear"
  "$0" --hold >/dev/null 2>&1; check 2 "$?" "bare --hold refuses"
  "$0" --hold 4h >/dev/null 2>&1; check 2 "$?" "--hold 4h refuses (seconds only)"
  "$0" --bogus >/dev/null 2>&1; check 2 "$?" "unknown argument refuses"
  "$0" --check >/dev/null 2>&1; rc=$?
  if [ "$rc" = 2 ]; then rc="fail"; else rc="read"; fi
  check "read" "$rc" "--check reads the live session (0 or 1, never 2)"
  echo "console-wake self-test: $fails failure(s)"
  [ "$fails" -eq 0 ]
}

mode=wake hold=14400
while [ $# -gt 0 ]; do
  case "$1" in
    --check) mode=check ;;
    --self-test) mode=selftest ;;
    --hold)
      [ $# -ge 2 ] || { echo "console-wake: --hold needs SECS" >&2; exit 2; }
      case "$2" in ''|*[!0-9]*) echo "console-wake: --hold takes whole seconds, got: $2" >&2; exit 2 ;; esac
      hold="$2"; shift ;;
    -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
    *) echo "console-wake: unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$mode" = selftest ]; then self_test; exit $?; fi

state="$(read_flag)" || { echo "console-wake: could not read the console session (ioreg)" >&2; exit 2; }

if [ "$mode" = check ]; then
  echo "console: $state"
  [ "$state" = clear ] && exit 0
  exit 1
fi

if [ "$state" = locked ]; then
  caffeinate -u -t 5 || { echo "console-wake: caffeinate -u failed" >&2; exit 2; }
  i=0
  while [ "$i" -lt 10 ]; do
    state="$(read_flag)" || { echo "console-wake: could not re-read the console session" >&2; exit 2; }
    [ "$state" = clear ] && break
    sleep 1; i=$((i+1))
  done
  if [ "$state" != clear ]; then
    echo "console: still locked after the wake — a real lock (Lock Screen or a password prompt); stop and ask the user"
    exit 1
  fi
  echo "console: woken (the display-off flag cleared)"
else
  echo "console: clear"
fi

if [ "$hold" -gt 0 ]; then
  nohup caffeinate -d -t "$hold" >/dev/null 2>&1 &
  echo "display: held awake for ${hold}s (caffeinate -d, pid $!)"
fi
exit 0
