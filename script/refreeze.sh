#!/usr/bin/env bash
# refreeze.sh: stamps a plan's frozen acceptance section, and re-stamps a closed plan after an extractor change. It hashes through
# ratchet.sh's one extraction, so what it stamps is exactly what the guard checks. It's a convenience, not a gate: the
# ratchet still refuses any edit that isn't re-stamped. Rule: protocol/verification.md § Enforce the freeze.
#
# Kit copy: install as script/refreeze.sh beside ratchet.sh and acceptance-extract.awk.
#
# Usage
#   refreeze.sh PLAN-NN --initial         the freeze, which is the close's stamp: append `PLAN-NN <sha256>   # frozen <date>`
#                                         to the ledger. Commit it in the plan's `PLAN-NN / close` commit, with PLAN.md's row
#                                         flipping to `complete`.
#   refreeze.sh PLAN-NN --reason "<text>" re-stamp a closed plan whose criteria didn't change, after an extractor change moved
#                                         its hash: rewrite the plan's ledger line and append `<date>  PLAN-NN  <sha256>  <reason>`
#                                         to the amends ledger. Commit both ledgers, and nothing in the plan, as
#                                         `PLAN-NN / refreeze: <reason>`. A closed plan's criteria are never edited.
#   refreeze.sh --self-test
#
# Refuses (exit 1) when there isn't exactly one plan file for PLAN-NN, the extractor isn't beside this script and
# tracked, the extraction is empty, the ledger holds a malformed row, --initial finds the plan already stamped or no plan
# read on record, or --reason finds it not stamped yet. A plan read is on record when round 1's plan-read verdict exists and
# isn't empty: tmp/PLAN-NN/prefreeze-read-verdict.md (the launcher writes it for `--read PLAN-NN tmp/PLAN-NN/prefreeze-prompt.md`),
# or <plans dir>/PLAN-NN-review/reviews/prefreeze-read-verdict.md, where tmp-tidy.sh tracks it, so a close that tidied first still
# stamps (protocol/execution-loop.md § Transitions: the close's gate). The gate is Standard and Full's: a `tier: lite` line in the
# .execplan stamp skips it, and a missing stamp or tier line keeps it.
# A tool failure is exit 2. Usage error: 64.
# Reads ratchet.sh's configuration (RATCHET_PLANS_DIR, RATCHET_HASHES, RATCHET_AMENDS, RATCHET_EXTRACT, RATCHET_RECORDS).
# Split-repo mode (RATCHET_RECORDS set, modules/split-repo.md): run it from the code repo as always. The plans and both ledgers
# are the records repo's (it must be a repo of its own at $RATCHET_RECORDS, else exit 2), the plan-read verdict is the code repo's
# tmp/PLAN-NN/ or the records repo's review dir, the extractor must be tracked in the code repo, and the .execplan stamp is read from the records repo, else the
# code repo. The stamp's commit goes in the records repo.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
RATCHET_LIB=1 . "$HERE/ratchet.sh"
cd "$HERE/.."
RF_SPLIT=0; RF_CODE_ROOT="."   # one-repo: every path below is relative to the repo root
if [ "${1:-}" != "--self-test" ]; then
  ratchet_roots || exit 2
  if [ "$RATCHET_SIDE" = code ]; then   # split-repo mode: work in the records repo, reach back to the code repo for tmp/ and the extractor
    records_root_check || exit 2
    case "$RATCHET_EXTRACT" in /*) ;; *) RATCHET_EXTRACT="$RATCHET_CODE_ROOT/$RATCHET_EXTRACT" ;; esac   # a relative extractor is the code repo's
    RF_SPLIT=1; RF_CODE_ROOT="$RATCHET_CODE_ROOT"; cd "$RATCHET_RECORDS_ROOT"
  fi
fi

stamp_tier() {   # → the tier the project's .execplan stamp names (its first word, lowercased); "" with no stamp or no tier line;
  # 2 when the stamp exists but can't be read (never read as "no stamp")
  local line t rc=0 st=.execplan
  [ -e "$st" ] || [ "$RF_SPLIT" -eq 0 ] || st="$RF_CODE_ROOT/.execplan"   # split-repo mode: the records repo's stamp, else the code repo's
  [ -e "$st" ] || { echo ""; return 0; }
  [ -r "$st" ] || { echo "refreeze: cannot read the .execplan stamp" >&2; return 2; }
  line="$(grep -E -e '^[[:space:]]*tier:' "$st")" || rc=$?
  case "$rc" in 0) ;; 1) echo ""; return 0 ;; *) echo "refreeze: reading the .execplan stamp failed (grep exit $rc)" >&2; return 2 ;; esac
  line="${line%%$'\n'*}"; t="${line#*tier:}"; set -f; set -- $t; set +f
  printf '%s\n' "$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')"
}

rf_where() { [ "$RF_SPLIT" -eq 0 ] || printf ' — commit it in the records repo, %s' "$PWD"; }
usage() { echo 'usage: refreeze.sh PLAN-NN --initial | --reason "<text>"   |   --self-test' >&2; exit 64; }

stamp() {   # $1 = PLAN-NN, $2 = initial|reason, $3 = reason text; runs in $PWD = repo root; honors RATCHET_* config
  local plan="$1" mode="$2" reason="$3" f sec new ts tmp
  case "$plan" in PLAN-[0-9]*) ;; *) usage ;; esac
  f="$(plan_file_for "$plan")" || { echo "refreeze: expected exactly one $RATCHET_PLANS_DIR/$plan-*.md" >&2; return 1; }
  [ -f "$RATCHET_EXTRACT" ] || { echo "refreeze: no extractor at $RATCHET_EXTRACT — install the kit's acceptance-extract.awk beside this script first" >&2; return 1; }
  if [ "$mode" = initial ]; then
    ( { [ "$RF_SPLIT" -eq 0 ] || cd "$RF_CODE_ROOT"; } && git ls-files --error-unmatch -- "$RATCHET_EXTRACT" >/dev/null 2>&1 ) \
      || { echo "refreeze: $RATCHET_EXTRACT is not tracked — commit the extractor before the first stamp (the guard that checks this stamp must read the same file)" >&2; return 1; }
    local tier vrel="tmp/$plan/prefreeze-read-verdict.md" vf where="" rv="$RATCHET_PLANS_DIR/$plan-review/reviews/prefreeze-read-verdict.md"
    vf="$vrel"; [ "$RF_SPLIT" -eq 0 ] || { vf="$RF_CODE_ROOT/$vrel"; where=" in the code repo ($RF_CODE_ROOT)"; }
    tier="$(stamp_tier)" || return 2
    if [ "$tier" != lite ]; then   # Standard and Full, and any stamp that doesn't say lite (fail closed): the plan read is owed
      [ -s "$vf" ] || [ -s "$rv" ] || { echo "refreeze: no plan read on record — $vrel$where and $rv are missing or empty. Run round 1's plan read before the close (protocol/execution-loop.md § Transitions)." >&2; return 1; }
    fi
  fi
  sec="$(awk -f "$RATCHET_EXTRACT" "$f")"
  [ -n "$sec" ] || { echo "refreeze: $plan extracts an EMPTY acceptance section — refusing to stamp (is the '## Validation and Acceptance' heading exact?)" >&2; return 1; }
  new="$(acc_hash "$f")"
  [ -n "$new" ] || { echo "refreeze: hashing failed — refusing to stamp" >&2; return 1; }
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { echo "refreeze: reading the clock failed" >&2; return 2; }
  mkdir -p "$(dirname "$RATCHET_HASHES")" && touch "$RATCHET_HASHES" || { echo "refreeze: cannot create $RATCHET_HASHES" >&2; return 2; }
  local rows rc=0; rows="$(ledger_rows < "$RATCHET_HASHES")" || rc=$?   # the same parser the guard uses (space or tab)
  case "$rc" in 0) ;; 1) echo "refreeze: $RATCHET_HASHES holds a malformed row — fix it by hand before stamping" >&2; return 1 ;;
    *) echo "refreeze: reading $RATCHET_HASHES failed — nothing written" >&2; return 2 ;; esac
  rc=0; stamped "$plan" "$rows" || rc=$?   # three ways: 0 stamped, 1 not, 2 grep failed (never read as either)
  [ "$rc" -le 1 ] || return 2
  if [ "$mode" = initial ]; then
    [ "$rc" -eq 1 ] || { echo "refreeze: $plan is already stamped — a re-stamp after an extractor change is --reason, never a second --initial" >&2; return 1; }
    printf '%s %s   # frozen %s\n' "$plan" "$new" "${ts%T*}" >> "$RATCHET_HASHES" || { echo "refreeze: appending to $RATCHET_HASHES failed — check it before stamping again" >&2; return 2; }
    echo "refreeze: $plan stamped -> $new (commit $RATCHET_HASHES in the plan's close commit, with PLAN.md's row flipping to \`complete\` — the ratchet refuses a first stamp without PLAN.md)$(rf_where)"
  else
    [ -n "$reason" ] || { echo "refreeze: --reason is required" >&2; return 1; }
    [ "$rc" -eq 0 ] || { echo "refreeze: $plan not stamped yet — freeze it first (--initial)" >&2; return 1; }
    restamp "$plan" "$new" "$reason" "$ts" || return 2
    echo "refreeze: $plan re-stamped -> $new (commit both ledgers, and no criterion edit, subject: $plan / refreeze: $reason)$(rf_where)"
  fi
}

stamped() {   # $1 = PLAN-NN, $2 = the ledger's rows → 0 stamped, 1 not; 2 when grep fails (a `! grep` once read an error as "not stamped")
  local rc=0
  printf '%s\n' "$2" | grep -qE "^$1 " || rc=$?
  case "$rc" in 0|1) return "$rc" ;; *) echo "refreeze: reading $RATCHET_HASHES's rows failed (grep exit $rc) — nothing written" >&2; return 2 ;; esac
}

restamp() {   # $1 = PLAN-NN, $2 = the new hash, $3 = the reason, $4 = the time → both ledgers rewritten, or neither: each new copy is built in a
  # temp file beside its ledger and checked, then moved in; a failed move of the second restores the first. 2 on any failure, naming it
  local plan="$1" new="$2" reason="$3" ts="$4" th ta to
  th="$(mktemp "$RATCHET_HASHES.XXXXXX")" || { echo "refreeze: cannot make a temp file beside $RATCHET_HASHES — nothing written" >&2; return 2; }
  to="$(mktemp "$RATCHET_HASHES.XXXXXX")" || { rm -f "$th"; echo "refreeze: cannot make a temp file beside $RATCHET_HASHES — nothing written" >&2; return 2; }
  ta="$(mktemp "$RATCHET_AMENDS.XXXXXX")" || { rm -f "$th" "$to"; echo "refreeze: cannot make a temp file beside $RATCHET_AMENDS — nothing written" >&2; return 2; }
  if ! awk -v p="$plan" -v h="$new" -v r="$reason" -v t="$ts" '
      $1==p { idx=index($0,"#"); cmt=(idx>0)?substr($0,idx):"#"; print p" "h"   "cmt"; re-stamped "t": "r; next }
      { print }
    ' "$RATCHET_HASHES" > "$th" \
    || ! cp -p "$RATCHET_HASHES" "$to" \
    || { [ -e "$RATCHET_AMENDS" ] && ! cat "$RATCHET_AMENDS" > "$ta"; } \
    || ! printf '%s  %s  %s  %s\n' "$ts" "$plan" "$new" "$reason" >> "$ta"; then
    rm -f "$th" "$to" "$ta"; echo "refreeze: building the new ledgers failed — both left as they were" >&2; return 2
  fi
  mv -f "$th" "$RATCHET_HASHES" || { rm -f "$th" "$to" "$ta"; echo "refreeze: moving the new $RATCHET_HASHES into place failed — both ledgers left as they were" >&2; return 2; }
  if ! mv -f "$ta" "$RATCHET_AMENDS"; then
    if mv -f "$to" "$RATCHET_HASHES"; then rm -f "$ta"; echo "refreeze: moving the new $RATCHET_AMENDS into place failed — $RATCHET_HASHES restored, both left as they were" >&2
    else echo "refreeze: moving the new $RATCHET_AMENDS into place failed, and restoring $RATCHET_HASHES failed too — its old copy is $to; fix both by hand" >&2; fi
    return 2
  fi
  rm -f "$to" || true   # the rollback copy; a leftover is harmless noise beside the ledger
}

if [ "${1:-}" = "--self-test" ]; then
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  ( cd "$d" && git init -q . && git config user.email t@t && git config user.name t && mkdir -p docs/plans script \
    && cp "$HERE/acceptance-extract.awk" "$HERE/ratchet.sh" script/ \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After X, Y.\n\n## Outcomes\n' > docs/plans/PLAN-01-x.md \
    && printf '# PLAN-02\n\n## Validation and Acceptanse\n\n- x\n' > docs/plans/PLAN-02-y.md && git add -A . && git commit -qm init \
    && mkdir -p tmp/PLAN-01 tmp/PLAN-02 tmp/PLAN-04 \
    && printf 'PLAN READY\n' | tee tmp/PLAN-02/prefreeze-read-verdict.md > tmp/PLAN-04/prefreeze-read-verdict.md )
  R="$d/script/ratchet.sh"; export RATCHET_EXTRACT="$d/script/acceptance-extract.awk"
  # the probes prove the CODE: the project's ratchet.conf (a Lite LOG.md, an empty plans dir) is overridden by fixed defaults here
  run() { ( cd "$d" && RATCHET_LIB=1 . "$R" && RATCHET_PLANS_DIR=docs/plans RATCHET_HASHES=docs/plans/.acceptance-hashes RATCHET_AMENDS=docs/plans/.acceptance-amends RATCHET_EXTRACT="$d/script/acceptance-extract.awk" && stamp "$@" ); }
  # the freeze gate's plan read is round 1's verdict file: missing, empty, and a round table that only SAYS `plan read 3` each refuse,
  # naming the file; with no stamp, and with a stamp naming no tier or tier: full, the gate holds (fail closed); tier: lite skips it;
  # an unreadable stamp is a tool failure (2)
  so="$(run PLAN-01 initial "" 2>&1)" && fail "a first stamp with no plan-read verdict was accepted"
  grep -Fq "no plan read on record — tmp/PLAN-01/prefreeze-read-verdict.md and docs/plans/PLAN-01-review/reviews/prefreeze-read-verdict.md are missing or empty" <<< "$so" || fail "the missing plan read was not named: $so"
  printf '| 1 | ... | plan read 3 · stage reads 2 | 5 / 0 | 5 / 0 |\n' > "$d/tmp/PLAN-01/prefreeze-prompt.md"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "a round table naming 'plan read 3' with no verdict file was accepted"
  : > "$d/tmp/PLAN-01/prefreeze-read-verdict.md"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "an empty plan-read verdict was accepted"
  printf 'execplan: 0.24.0\nmodules: macos-swift\n' > "$d/.execplan"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "a stamp with no tier line skipped the gate"
  printf 'execplan: 0.24.0\ntier: full   # a comment\n' > "$d/.execplan"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "tier: full skipped the gate"
  chmod 000 "$d/.execplan"; rc=0; run PLAN-01 initial "" >/dev/null 2>&1 || rc=$?; chmod 644 "$d/.execplan"
  [ "$rc" -eq 2 ] || fail "an unreadable .execplan stamp must be a tool failure (2), got $rc"
  [ ! -s "$d/docs/plans/.acceptance-hashes" ] || fail "a refused stamp wrote the ledger"
  printf 'execplan: 0.24.0\ntier: Lite\n' > "$d/.execplan"
  run PLAN-01 initial "" >/dev/null 2>&1 || fail "tier: lite must skip the plan-read gate (Lite's review is optional)"
  : > "$d/docs/plans/.acceptance-hashes"; printf 'execplan: 0.24.0\ntier: standard\n' > "$d/.execplan"
  # a close that tidied first: the verdict is in the review dir, where tmp-tidy tracks it, and the stamp still lands
  mkdir -p "$d/docs/plans/PLAN-01-review/reviews" && : > "$d/docs/plans/PLAN-01-review/reviews/prefreeze-read-verdict.md"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "an empty plan-read verdict in the review dir was accepted"
  printf 'PLAN READY\n' > "$d/docs/plans/PLAN-01-review/reviews/prefreeze-read-verdict.md"
  so="$(run PLAN-01 initial "" 2>&1)" || fail "a plan-read verdict tracked in the review dir was refused: $so"
  : > "$d/docs/plans/.acceptance-hashes"; rm -r "$d/docs/plans/PLAN-01-review"
  printf 'PLAN READY — no blocking finding\n' > "$d/tmp/PLAN-01/prefreeze-read-verdict.md"
  so="$(run PLAN-01 initial "")" || fail "initial stamp refused"
  grep -Fq 'in the plan'"'"'s close commit, with PLAN.md'"'"'s row flipping to `complete`' <<< "$so" || fail "the first stamp's hint should name the commit it belongs in and the row it leaves: $so"
  grep -Fq 'in-progress (frozen)' <<< "$so" && fail "the first stamp's hint still names the retired in-progress (frozen) status: $so"
  grep -Fq 'ready-to-execute' <<< "$so" && fail "the first stamp's hint still names the retired ready-to-execute status: $so"
  grep -q '^PLAN-01 [0-9a-f]\{64\}   # frozen' "$d/docs/plans/.acceptance-hashes" || fail "ledger line malformed: $(cat "$d/docs/plans/.acceptance-hashes")"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "a second --initial was accepted"
  run PLAN-02 initial "" >/dev/null 2>&1 && fail "an empty extraction was stamped"
  run PLAN-01 reason "" >/dev/null 2>&1 && fail "a re-stamp with no reason was accepted"
  before="$(cut -d' ' -f2 "$d/docs/plans/.acceptance-hashes")"
  sed 's/After X, Y./After X, Z./' "$d/docs/plans/PLAN-01-x.md" > "$d/t" && mv "$d/t" "$d/docs/plans/PLAN-01-x.md"
  so="$(run PLAN-01 reason "criterion narrowed" 2>&1)" || fail "a traced re-stamp was refused: $so"
  after="$(grep '^PLAN-01 ' "$d/docs/plans/.acceptance-hashes" | cut -d' ' -f2)"
  [ "$before" != "$after" ] || fail "the re-stamp did not change the hash"
  grep -q 're-stamped' "$d/docs/plans/.acceptance-hashes" || fail "the ledger comment carries no re-stamp note"
  grep -q "PLAN-01  $after  criterion narrowed" "$d/docs/plans/.acceptance-amends" || fail "the amends ledger line is missing: $(cat "$d/docs/plans/.acceptance-amends")"
  run PLAN-03 reason "x" >/dev/null 2>&1 && fail "a re-stamp of an unstamped plan was accepted"
  # a tab-separated existing row is still found (the guard's parser is whitespace-agnostic; so is the stamp's)
  sed "s/^PLAN-01 /PLAN-01\t/" "$d/docs/plans/.acceptance-hashes" > "$d/t" && mv "$d/t" "$d/docs/plans/.acceptance-hashes"
  run PLAN-01 initial "" >/dev/null 2>&1 && fail "a tab-separated existing stamp was not seen by --initial"
  run PLAN-01 reason "again" >/dev/null || fail "a tab-separated existing stamp was not seen by --reason"
  # a tool failure on the ledgers is exit 2 with both ledgers exactly as they were: a grep error in the "already stamped?" read (once
  # `! grep`, which read an error as "not stamped" and appended a second row), a failed rewrite, and a failed move of either ledger
  mkdir -p "$d/shim-grep" "$d/shim-awk" "$d/shim-mvh" "$d/shim-mva"
  printf '#!/bin/sh\ncase "$1$2" in "-qE^PLAN-"*) exit 2 ;; esac\nexec /usr/bin/grep "$@"\n' > "$d/shim-grep/grep"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in p=*) exit 3 ;; esac; done\nexec /usr/bin/awk "$@"\n' > "$d/shim-awk/awk"
  printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\ncase "$last" in *.acceptance-hashes) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$d/shim-mvh/mv"
  printf '#!/bin/sh\nfor a in "$@"; do last="$a"; done\ncase "$last" in *.acceptance-amends) exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$d/shim-mva/mv"
  chmod +x "$d"/shim-*/*
  cp "$d/docs/plans/.acceptance-hashes" "$d/h0"; cp "$d/docs/plans/.acceptance-amends" "$d/a0"
  sed 's/After X, Z./After X, W./' "$d/docs/plans/PLAN-01-x.md" > "$d/t" && mv "$d/t" "$d/docs/plans/PLAN-01-x.md"
  for sh in grep:initial awk:reason mvh:reason mva:reason; do
    rc=0; so="$(PATH="$d/shim-${sh%%:*}:$PATH" run PLAN-01 "${sh#*:}" "why" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] || fail "a failing ${sh%%:*} in --${sh#*:} must be exit 2, got $rc: $so"
    cmp -s "$d/h0" "$d/docs/plans/.acceptance-hashes" || fail "a failing ${sh%%:*} in --${sh#*:} changed the hash ledger"
    cmp -s "$d/a0" "$d/docs/plans/.acceptance-amends" || fail "a failing ${sh%%:*} in --${sh#*:} changed the amends ledger"
    [ -z "$(ls "$d/docs/plans" | grep -E '\.acceptance-(hashes|amends)\.' || true)" ] || fail "a failing ${sh%%:*} left a temp ledger behind: $(ls -a "$d/docs/plans")"
  done
  run PLAN-01 reason "after the faults" >/dev/null || fail "a clean re-stamp after the faults was refused"
  # the extractor must be tracked before the first stamp
  ( cd "$d" && git rm -q --cached script/acceptance-extract.awk && printf '# PLAN-04\n\n## Validation and Acceptance\n\n- a\n' > docs/plans/PLAN-04-z.md )
  so="$(run PLAN-04 initial "" 2>&1)" && fail "a first stamp with an untracked extractor was accepted"
  grep -q 'not tracked' <<< "$so" || fail "the untracked extractor was not named: $so"
  # split-repo mode (modules/split-repo.md), through the script as a project runs it — from the code repo: the verdict is read from
  # the code repo's tmp/, the stamp lands in the records repo's ledger, the extractor must be tracked in the code repo, the records
  # repo's .execplan outranks the code repo's, and a records dir that isn't a repo of its own is exit 2
  s="$d/split"; mkdir -p "$s/code/script"
  ( cd "$s/code" && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$HERE/acceptance-extract.awk" "$HERE/ratchet.sh" "$HERE/refreeze.sh" script/ && printf 'RATCHET_RECORDS=private\n' > script/ratchet.conf \
    && printf '/private\n/tmp/\n' > .gitignore && git add -A . && git commit -qm init \
    && git init -q private && cd private && git config user.email t@t && git config user.name t && mkdir -p docs/plans tmp/PLAN-01 \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After X, Y.\n' > docs/plans/PLAN-01-x.md && printf 'PLAN READY\n' > tmp/PLAN-01/prefreeze-read-verdict.md \
    && git add docs && git commit -qm init ) >/dev/null || fail "fixture: the split-repo pair"
  rf() { rc=0; so="$(env -u RATCHET_EXTRACT bash "$s/code/script/refreeze.sh" PLAN-01 $1 2>&1)" || rc=$?; }
  rf --initial; [ "$rc" -eq 1 ] && grep -Fq "tmp/PLAN-01/prefreeze-read-verdict.md in the code repo" <<< "$so" || fail "a verdict only in the records repo's tmp/ passed the gate (rc=$rc): $so"
  mkdir -p "$s/code/private/docs/plans/PLAN-01-review/reviews" && printf 'PLAN READY\n' > "$s/code/private/docs/plans/PLAN-01-review/reviews/prefreeze-read-verdict.md"
  rf --initial; [ "$rc" -eq 0 ] || fail "a verdict tracked in the records repo's review dir was refused (rc=$rc): $so"
  rm -r "$s/code/private/docs/plans/PLAN-01-review" "$s/code/private/docs/plans/.acceptance-hashes"
  mkdir -p "$s/code/tmp/PLAN-01" && printf 'PLAN READY\n' > "$s/code/tmp/PLAN-01/prefreeze-read-verdict.md"
  ( cd "$s/code" && git rm -q --cached script/acceptance-extract.awk )
  rf --initial; [ "$rc" -eq 1 ] && grep -q 'not tracked' <<< "$so" || fail "an extractor untracked in the code repo passed (rc=$rc): $so"
  ( cd "$s/code" && git add script/acceptance-extract.awk )
  printf 'tier: lite\n' > "$s/code/.execplan"; printf 'tier: full\n' > "$s/code/private/.execplan"; rm "$s/code/tmp/PLAN-01/prefreeze-read-verdict.md"
  rf --initial; [ "$rc" -eq 1 ] || fail "the code repo's tier: lite outranked the records repo's tier: full (rc=$rc): $so"
  rm "$s/code/private/.execplan"; rf --initial; [ "$rc" -eq 0 ] || fail "with no records stamp the code repo's tier: lite must skip the gate (rc=$rc): $so"
  grep -q '^PLAN-01 [0-9a-f]\{64\}' "$s/code/private/docs/plans/.acceptance-hashes" || fail "the stamp did not land in the records repo's ledger"
  [ ! -e "$s/code/docs" ] || fail "the stamp wrote into the code repo"
  grep -Fq "commit it in the records repo" <<< "$so" || fail "the stamp's hint did not name the records repo: $so"
  sed 's/After X, Y./After X, Z./' "$s/code/private/docs/plans/PLAN-01-x.md" > "$d/t" && mv "$d/t" "$s/code/private/docs/plans/PLAN-01-x.md"
  rf "--reason narrowed"; [ "$rc" -eq 0 ] && grep -q 'PLAN-01 .* narrowed' "$s/code/private/docs/plans/.acceptance-amends" || fail "a split-repo re-stamp did not write the records repo's amends ledger (rc=$rc): $so"
  mv "$s/code/private" "$s/held" && mkdir -p "$s/code/private"; rf --initial; rmdir "$s/code/private" && mv "$s/held" "$s/code/private"
  [ "$rc" -eq 2 ] || fail "a records dir that isn't a repo of its own must be exit 2 (rc=$rc): $so"
  echo "SELF-TEST OK"; exit 0
fi

plan="${1:-}"; [ -n "$plan" ] || usage; shift
mode=""; reason=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --initial) mode=initial; shift ;;
    --reason)  mode=reason; reason="${2:-}"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$mode" ] || usage
stamp "$plan" "$mode" "$reason"
