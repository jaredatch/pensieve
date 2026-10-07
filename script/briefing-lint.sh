#!/usr/bin/env bash
# briefing-lint.sh: keeps the agent briefings short and free of duplicates. Each briefing has a word budget, each rule
# has one home, and a briefing cites evidence by ID instead of retelling it (templates/CLAUDE.md and templates/AGENTS.md
# headers). The close runs it over CLAUDE.md, AGENTS.md and docs/CHECKLISTS.md.
#
# Kit copy: install as script/briefing-lint.sh.
#
# Usage
#   briefing-lint.sh [--budget N] [--warn] [files…]   default files: CLAUDE.md AGENTS.md at the repo root
#   briefing-lint.sh --self-test                      two fixture files under mktemp sharing one sentence, one over
#                                                     budget; prints SELF-TEST OK
#
# Per file it prints the word count against the budget, every paragraph over 120 words (line number and first 60
# characters), and the count of PLAN-NN / DEC-NN mentions. Across the briefings it prints every sentence of 12+ words
# (lowercased, punctuation stripped, whitespace collapsed) that appears in more than one file, with both locations. A
# checklist (basename CHECKLISTS.md) gets the budget and paragraph checks but not the duplicate check, because a
# checklist line may echo a briefing line on purpose.
#
#   budget     --budget N for every file given; else BRIEFING_BUDGET_<NAME> (NAME = basename without extension,
#              uppercased, non-alphanumerics as _: BRIEFING_BUDGET_CLAUDE); else the defaults CLAUDE.md 1300,
#              AGENTS.md 1500, CHECKLISTS.md 2550. Any other file has no budget unless one is given.
#   words      `wc -w` over the whole file, fenced code and tables included.
#   paragraph  one line is one paragraph (no hard wraps). Fenced code, `|` table rows and 4-space-indented command blocks
#              are skipped by the paragraph and sentence checks.
#
# Exit codes: 0 pass · 1 a file over budget or a duplicate (0 with --warn) · 2 a tool failed (never a pass, --warn or not).
# Its work dir under TMPDIR goes on every exit, a TERM or Ctrl-C included.
set -eu   # NOT pipefail (the kit's rule): no producer sits on the left of a pipe — every count and read is captured, then checked
mktemp() {   # mktemp / mktemp -d with no template, under $TMPDIR: macOS's own ignores TMPDIR (it reads _CS_DARWIN_USER_TEMP_DIR), so a
  # session's per-plan TMPDIR (the launcher's) would never see the kit's temp files. A TMPDIR that isn't a writable folder falls back to /tmp
  local t="${TMPDIR:-}"; { [ -n "$t" ] && [ -d "$t" ] && [ -w "$t" ]; } || t=/tmp
  case "$#:${1:-}" in 0:|1:-d) command mktemp "$@" "${t%/}/xp.XXXXXXXX" ;; *) command mktemp "$@" ;; esac
}
BL_WORK=""   # lint's work dir (mktemp): removed on every exit, Ctrl-C and TERM included
trap '[ -z "$BL_WORK" ] || rm -rf "$BL_WORK"' EXIT; trap 'exit 130' INT; trap 'exit 143' TERM

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
budget_all=""; warn=0; selftest=0; files=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --budget)    budget_all="${2:-}"; shift 2 ;;
    --warn)      warn=1; shift ;;
    --self-test) selftest=1; shift ;;
    --*)         echo "briefing-lint: unknown arg: $1" >&2; exit 64 ;;
    *)           files="$files
$1"; shift ;;
  esac
done

budget_for() {   # $1 = file → budget or "" (none)
  local f="$1" name var v
  [ -n "$budget_all" ] && { echo "$budget_all"; return; }
  name="${f##*/}"; name="${name%.*}"
  name="$(tr 'a-z' 'A-Z' <<< "$name")" || return 2
  name="$(sed 's/[^A-Z0-9]/_/g' <<< "$name")" || return 2
  var="BRIEFING_BUDGET_$name"
  v="$(eval "printf '%s' \"\${$var:-}\"")"
  [ -n "$v" ] && { echo "$v"; return; }
  case "${f##*/}" in CLAUDE.md) echo 1300 ;; AGENTS.md) echo 1500 ;; CHECKLISTS.md) echo 2550 ;; *) echo "" ;; esac
}
count_matches() {   # $1 = ERE, $2 = file → how many matches (grep -o lines, counted in bash); 2 on a grep error, never 0
  local out rc=0 n=0 l
  out="$(grep -oE -e "$1" -- "$2")" || rc=$?
  [ "$rc" -le 1 ] || { echo "briefing-lint: grep failed (exit $rc) on $2" >&2; return 2; }
  [ -n "$out" ] || { echo 0; return 0; }
  while IFS= read -r l; do n=$((n+1)); done <<< "$out"
  echo "$n"
}

# prose lines only: line<TAB>text, skipping fenced code, table rows, indented command blocks
prose_lines() {   # $1 = file
  awk '
    /^```/ { fence = !fence; next }
    fence { next }
    /^[[:space:]]*\|/ { next }
    /^    / { next }
    /^[[:space:]]*$/ { next }
    { print NR "\t" $0 }
  ' "$1"
}

lint() {   # $@ = files → prints the report; returns 1 on over-budget or duplicates, 2 when a tool fails (called in an `||` context,
  # where set -e is off: every step below checks its own status)
  local bad=0 f words budget nplan ndec work rc=0
  work="$(mktemp -d)" || { echo "briefing-lint: mktemp failed" >&2; return 2; }
  BL_WORK="$work"
  : > "$work/sentences" || { rm -rf "$work"; return 2; }
  tool() { echo "briefing-lint: $1 failed on $f" >&2; rm -rf "$work"; }
  for f in "$@"; do
    [ -f "$f" ] || { echo "briefing-lint: no such file: $f" >&2; rm -rf "$work"; return 2; }
    words="$(wc -w < "$f")" || { tool "wc"; return 2; }; words="${words//[[:space:]]/}"; [ -n "$words" ] || { tool "wc"; return 2; }
    budget="$(budget_for "$f")" || { tool "reading the budget"; return 2; }
    nplan="$(count_matches 'PLAN-[0-9]+' "$f")" && ndec="$(count_matches 'DEC-[0-9]+' "$f")" || { tool "grep"; return 2; }
    if [ -n "$budget" ] && [ "$words" -gt "$budget" ]; then
      echo "$f: words=$words budget=$budget OVER BUDGET by $((words - budget)) plan-mentions=$nplan dec-mentions=$ndec"; bad=1
    else
      echo "$f: words=$words budget=${budget:-none} plan-mentions=$nplan dec-mentions=$ndec"
    fi
    prose_lines "$f" > "$work/prose" || { tool "awk (the prose lines)"; return 2; }
    awk -F'\t' '{ n = split($2, w, /[[:space:]]+/); c = 0; for (i=1;i<=n;i++) if (w[i] != "") c++
      if (c > 120) printf "  long paragraph L%s (%d words): %s\n", $1, c, substr($2, 1, 60) }' "$work/prose" || { tool "awk (the paragraph report)"; return 2; }
    case "${f##*/}" in CHECKLISTS.md) continue ;; esac   # a checklist: budget and paragraphs, never the duplicate check
    # sentences of 12+ words, normalized: norm<TAB>file:line
    awk -F'\t' -v file="$f" '
      { line = $1; s = $2 " "
        while (match(s, /[.!?]([[:space:]]|$)/)) {
          sent = substr(s, 1, RSTART); s = substr(s, RSTART + RLENGTH)
          emit(sent, line) }
        emit(s, line) }
      function emit(sent, line,   n, w, i, c, norm) {
        norm = tolower(sent); gsub(/[^a-z0-9]+/, " ", norm); sub(/^ +/, "", norm); sub(/ +$/, "", norm)
        n = split(norm, w, " "); if (n < 12) return
        print norm "\t" file ":" line }
    ' "$work/prose" >> "$work/sentences" || { tool "awk (the sentences)"; return 2; }
  done
  # duplicates across files
  awk -F'\t' '
    { norm = $1; loc = $2; file = loc; sub(/:[0-9]+$/, "", file)
      if (!((norm, file) in seenf)) { seenf[norm, file] = 1; nfiles[norm]++ }
      if (!(norm in first)) { order[++k] = norm; first[norm] = 1 }
      locs[norm] = locs[norm] "\n  " loc }
    END {
      for (i=1; i<=k; i++) { norm = order[i]
        if (nfiles[norm] > 1) { dups++; n = split(norm, w, " ")
          printf "DUPLICATE sentence (%d words): \"%s%s\"%s\n", n, substr(norm, 1, 60), (length(norm) > 60 ? "…" : ""), locs[norm] } }
      exit (dups > 0) ? 1 : 0 }
  ' "$work/sentences" || rc=$?
  case "${rc:-0}" in 0) ;; 1) bad=1 ;; *) f="the duplicate scan"; tool "awk (exit $rc)"; return 2 ;; esac
  rm -rf "$work"; BL_WORK=""
  return "$bad"
}

if [ "$selftest" -eq 1 ]; then
  d="$(mktemp -d)" || { echo "SELF-TEST FAIL: mktemp -d failed"; exit 1; }
  trap 'rm -rf "$d"' EXIT
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  shared="Every stage close runs lint, tests, the headless smoke, and the plan's own Verify blocks before the commit lands."
  { printf '# A\n\nShort intro about PLAN-01 and DEC-12.\n\n%s\n\n' "$shared"; printf 'word %.0s' $(seq 1 130); printf '\n'; } > "$d/A.md"
  printf '# B\n\nAnother file, mentions PLAN-02 twice: PLAN-02 and DEC-13.\n\nA lead-in sentence first. %s Then a trailer.\n\n    %s\n' "$shared" "$shared" > "$d/B.md"
  # A is over a budget of 100 (it carries a 130-word paragraph); B is under; they share one sentence (B's indented copy must not count)
  set +e; out="$(BRIEFING_BUDGET_A=100 BRIEFING_BUDGET_B=1000 "$BASH" "$0" "$d/A.md" "$d/B.md" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "should exit 1 (got $rc): $out"
  grep -Eq "^$d/A.md: words=[0-9]+ budget=100 OVER BUDGET by [0-9]+ plan-mentions=1 dec-mentions=1$" <<< "$out" || fail "A's report line differs: $out"
  grep -Eq "^$d/B.md: words=[0-9]+ budget=1000 plan-mentions=2 dec-mentions=1$" <<< "$out" || fail "B's report line differs: $out"
  grep -Eq '^  long paragraph L7 \(130 words\): word word' <<< "$out" || fail "long-paragraph line missing: $out"
  [ "$(grep -c '^DUPLICATE sentence' <<< "$out")" -eq 1 ] || fail "expected exactly one duplicate: $out"
  grep -Fq "  $d/A.md:5" <<< "$out" && grep -Fq "  $d/B.md:5" <<< "$out" || fail "duplicate locations missing: $out"
  # --warn downgrades; a clean pair exits 0; --budget overrides the env; the default budgets apply by basename
  BRIEFING_BUDGET_A=100 "$BASH" "$0" --warn "$d/A.md" "$d/B.md" >/dev/null 2>&1 || fail "--warn should exit 0"
  printf '# C\n\nNothing shared here, a short file.\n' > "$d/C.md"
  "$BASH" "$0" "$d/B.md" "$d/C.md" >/dev/null 2>&1 || fail "a clean pair should exit 0"
  set +e; "$BASH" "$0" --budget 5 "$d/C.md" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "--budget 5 should put C over budget"
  # duplicates alone must fail: both files comfortably under budget, one shared sentence
  set +e; BRIEFING_BUDGET_A=100000 BRIEFING_BUDGET_B=100000 "$BASH" "$0" "$d/A.md" "$d/B.md" >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a duplicate sentence alone should exit 1 (got $rc)"
  cp "$d/A.md" "$d/CLAUDE.md"
  out="$("$BASH" "$0" "$d/CLAUDE.md" 2>&1)" || true
  grep -Eq 'CLAUDE.md: words=[0-9]+ budget=1300 ' <<< "$out" || fail "default CLAUDE.md budget not applied: $out"
  # the checklist (M7): CHECKLISTS.md gets its default budget of 2550 by basename, wherever it lives, and BRIEFING_BUDGET_CHECKLISTS moves it;
  # over budget it fails, under it passes; a sentence it shares with a briefing is never a duplicate (budget only)
  mkdir -p "$d/docs"; { printf '# Checklists\n\n- [ ] %s\n\n' "$shared"; printf 'tick %.0s' $(seq 1 2560); printf '\n'; } > "$d/docs/CHECKLISTS.md"
  set +e; out="$("$BASH" "$0" "$d/B.md" "$d/docs/CHECKLISTS.md" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Eq "CHECKLISTS.md: words=[0-9]+ budget=2550 OVER BUDGET" <<< "$out" || fail "a checklist over 2550 words should fail on its default budget (rc=$rc): $out"
  grep -q '^DUPLICATE' <<< "$out" && fail "a sentence the checklist shares with a briefing was reported as a duplicate: $out"
  BRIEFING_BUDGET_CHECKLISTS=3000 "$BASH" "$0" "$d/B.md" "$d/docs/CHECKLISTS.md" >/dev/null 2>&1 || fail "BRIEFING_BUDGET_CHECKLISTS=3000 should pass the checklist (and no duplicate should be found)"
  printf '# Checklists\n\n- [ ] %s\n' "$shared" > "$d/docs/CHECKLISTS.md"
  out="$("$BASH" "$0" "$d/B.md" "$d/docs/CHECKLISTS.md" 2>&1)" && grep -Eq "CHECKLISTS.md: words=[0-9]+ budget=2550 plan" <<< "$out" || fail "a checklist under its budget should pass: $out"
  # a tool that fails is exit 2 — never a pass, not even under --warn (the harsher fault: the real tool's output, then status 73)
  mkdir -p "$d/fk"; for t in wc awk; do printf '#!/bin/sh\n"%s" "$@"; exit 73\n' "$(command -v "$t")" > "$d/fk/$t"; chmod +x "$d/fk/$t"; done
  for t in wc awk; do
    mkdir -p "$d/fk1"; rm -f "$d/fk1/"*; cp "$d/fk/$t" "$d/fk1/$t"
    set +e; out="$(PATH="$d/fk1:$PATH" "$BASH" "$0" --warn "$d/C.md" 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 2 ] || fail "a failing $t should exit 2 under --warn (got $rc): $out"
  done
  # a run stopped by TERM leaves no work dir in TMPDIR (the EXIT trap): a fake awk sends the signal to the running lint once, mid-run
  mkdir -p "$d/trt" "$d/trk" && printf '#!/bin/sh\nif [ ! -e "%s/trk/sent" ]; then ls -A "$TMPDIR" > "%s/trk/sent"; while [ ! -s "%s/trk/pid" ]; do sleep 0.05; done; kill -TERM "$(cat "%s/trk/pid")"; fi\nexec %s "$@"\n' \
    "$d" "$d" "$d" "$d" "$(command -v awk)" > "$d/trk/awk" && chmod +x "$d/trk/awk" || fail "the fake awk could not be written"
  TMPDIR="$d/trt" PATH="$d/trk:$PATH" "$BASH" "$0" "$d/B.md" "$d/C.md" >/dev/null 2>&1 & trp=$!
  echo "$trp" > "$d/trk/pid"; rc=0; wait "$trp" || rc=$?
  [ -s "$d/trk/sent" ] && [ "$rc" -ne 0 ] && [ -z "$(ls -A "$d/trt")" ] || fail "the work dir must be made under TMPDIR, and a TERM mid-run must leave none there (rc=$rc; held when signalled: $(cat "$d/trk/sent" 2>/dev/null); left: $(ls -A "$d/trt"))"
  echo "SELF-TEST OK"; exit 0
fi

if [ -z "$files" ]; then cd "$ROOT"; set -- CLAUDE.md AGENTS.md
else
  set --
  while IFS= read -r f; do [ -n "$f" ] && set -- "$@" "$f"; done <<< "$files"
fi
rc=0; lint "$@" || rc=$?
case "$rc" in 0) exit 0 ;; 1) ;; *) echo "briefing-lint: a tool failed — no verdict (exit 2, --warn or not)" >&2; exit 2 ;; esac
[ "$warn" -eq 1 ] && { echo "briefing-lint: findings above (warn mode)"; exit 0; }
exit 1
