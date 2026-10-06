#!/usr/bin/env bash
# ratchet.sh: the project's guards in one script, one decision function per rule. The git hooks run it on every commit,
# and ci-replay.sh sources it (`RATCHET_LIB=1 . script/ratchet.sh`) to run the same functions over each commit in CI, so the
# hook and CI can't disagree. Rules: protocol/verification.md § The test ratchet, § Enforce the freeze, § The docs-commit
# guard; protocol/context-discipline.md § Workspace. The stack's values: modules/<stack>.md.
#
# Kit copy: install as script/ratchet.sh beside acceptance-extract.awk and tmp-tidy.sh, and wire the hooks with
# install-hooks.sh.
#
# Usage
#   ratchet.sh                     pre-commit, over the index: refuses a newly skipped test (outside the allowlist), a
#                                  secret, a tmp/ cite from a plan that isn't in flight (on a merge, only a cite new against
#                                  every parent), a frozen acceptance section whose hash no longer matches, a change the
#                                  project's own check refuses (RATCHET_PROJECT_CHECK), a file still holding conflict markers
#                                  (an opening `<<<<<<<` and a closing `>>>>>>>` line both added), and a test count below the floor. The
#                                  count floor runs last; a docs-only diff skips it.
#   ratchet.sh --commit-msg FILE   commit-msg: a stage commit carries the LOG and the plan file; LOG growth needs a subject
#                                  form (`PLAN-NN / review|close|patch|refreeze|fix`, the word ending at a non-alphanumeric,
#                                  or a subject opening `note:`); a close carries the tidied workspace (a merge of a branch
#                                  that already ran its own close is judged on the tracked half only); a changed stamp needs
#                                  the refreeze form and its amends line; a builder commit (a stage claim, fix or patch)
#                                  leaves an unstamped plan's Validation and Acceptance alone.
#   ratchet.sh --cite-check PLAN   the tmp/ cite check alone. stdin: a unified diff (-U0 --no-prefix); PLAN: the PLAN.md
#                                  to read statuses from.
#   ratchet.sh --recount           run the suite once (output streamed), raise the floor to the new count (never lower), and
#                                  record the green run so the next commit's hook reuses it when the index holds exactly
#                                  the tested code. This is the stage-close ritual's one suite run, and the integration
#                                  merge's run on the merged tree. Inside a merge the floor is computed, base + (ours −
#                                  base) + (theirs − base), from each side's committed count file, so a side that removed
#                                  tests on purpose settles right and a conflicted .test-count needs no hand edit.
#   ratchet.sh --merge-log B A T   git's merge driver for the LOG (install-hooks.sh wires it): both sides' entries, newest
#                                  first, each once. An entry-shaped `## <timestamp>` line inside a code fence is an example,
#                                  never a boundary. A LOG that isn't append-only on both sides, or that leaves a fence open,
#                                  falls back to git merge-file.
#   ratchet.sh --self-test         hermetic probes of every decision, both ways (mktemp; no project state touched)
#
# Count floor details: with no matching run record and a working tree whose code differs from the index, the suite runs
# on the staged tree in a throwaway worktree. CI skips the floor (RATCHET_SKIP_COUNT_FLOOR=1) and runs its own Test step.
#
# Exit codes: 0 pass · 1 refused (the message says which rule) · 2 a tool failed (never read as clean)
#
# Configuration: environment, or script/ratchet.conf beside this script (a plain KEY=value file, sourced first).
#   RATCHET_LOG              docs/LOG.md          the LOG (Lite: LOG.md)
#   RATCHET_PLANS_DIR        docs/plans           the plan files. Empty for Lite's inline plans: a stage commit then needs
#                                                 PLAN.md staged, a close needs only a clean tmp/, and the hash and
#                                                 refreeze checks are off, because an inline plan is never stamped.
#   RATCHET_HASHES           $PLANS_DIR/.acceptance-hashes   the freeze ledger; RATCHET_AMENDS is its refreeze ledger
#   RATCHET_TEST_CMD         ./script/test.sh     prints `<PROJECT>_TEST_COUNT=<n>` as its last line
#   RATCHET_TEST_COUNT_FILE  .test-count          the committed floor
#   RATCHET_TEST_PATH_REGEX  Tests/|Tests\.swift$ which staged paths are test files
#   RATCHET_SKIP_REGEX       (Swift: XCTSkip / .disabled / @Test(.disabled))   an added line that skips a test
#   RATCHET_ALLOWLIST        docs/test-allowlist.md   test names allowed to skip
#   RATCHET_SECRET_FILE_REGEX / RATCHET_SECRET_REGEX  secret file names and added-line patterns. A fixture line that must
#                                                 carry a fake key ends with `ratchet:allow-secret`.
#   RATCHET_RESUME_NOTE      tmp/resume-note.md   the one tmp/ path outside a plan's folder that a doc may cite
#   RATCHET_EXTRACT / RATCHET_TMP_TIDY            the extractor and tmp-tidy (default: beside this script)
#   RATCHET_PROJECT_CHECK    (empty)              a project's own check over the change's diff (the contract below). One-repo
#                                                 and the code side.
#   RATCHET_RECORDS          (empty)              split-repo mode (modules/split-repo.md): the records repo's path relative to the
#                                                 code repo's top, e.g. `private`. Empty = one-repo, every rule as above. A
#                                                 non-empty environment value outranks the conf (the one key that does, so every
#                                                 kit script, kit/herdr's included, reads it the same way).
#   RATCHET_ROOT             (this script's parent)   the repo to check; the hooks set it to the committing repo's top
#
# Split-repo mode. The code repo holds the code, the tests, script/ (this kit) and tmp/; the records repo, nested at
# $RATCHET_RECORDS and a git repo of its own, holds PLAN.md, the LOG, the plans and the ledgers — RATCHET_LOG, _PLANS_DIR,
# _HASHES and _AMENDS are relative to it. Its hooks run this same script (install-hooks.sh wires both repos). The hooks pass the
# committing repo's top as RATCHET_ROOT. Exactly two roots have a side: the kit's code repo (this script's parent) is the code side,
# and <that>/$RATCHET_RECORDS is the records side. Any other root is exit 2, never a guess, and so is a symlink along the records
# path (git would run a linked repo's hooks from another kit). A records path that exists must be the top of a git work tree of
# its own, else exit 2 (an ordinary folder there would quiet the record guards); a missing one leaves the code side working (code
# CI, a contributor without the records clone). $RATCHET_RECORDS: a non-empty environment value wins over the conf;
# trailing slashes are dropped; an absolute path, a . or .. part, or an empty part is exit 2. Which rules run where:
#   rule                                     one-repo   code side   records side
#   skip scan, project check, count floor    on         on          off — no suite
#   secrets, tmp/ cites, LOG growth's form   on         on (a)      on
#   stage claim's LOG + plan file            on         off (b)     on
#   hashes, refreeze trace, criteria         on         off (c)     on (d)
#   close ritual                             on         off (e)     on, plus the pairing (f)
#   (a) no PLAN.md here, so every tmp/PLAN-NN cite is refused: code-side docs never cite the records' scratch
#   (b) the LOG entry and the plan file are the records repo's commit for the Stage, paired at the close
#   (c) the LOG, the ledgers and the plans are the records repo's: a ledger file in the code repo (or its deletion, when a one-repo
#       project moves its records out) is no freeze record, in the hook and in ci-replay alike
#   (d) the extractor is the code repo's kit's file on disk, read where it lives: the records repo's index can't hold it, so an
#       uncommitted edit to the code repo's acceptance-extract.awk hashes the records side's freeze and close, and CI's records replay
#       hashes with the kit of the code checkout it runs from (one-repo, the index's copy decides, as before)
#   (e) `PLAN-NN / close` carries the harvest (a code-side briefing, CHANGELOG); no MANIFEST is asked for
#   (f) the on-disk half finds tmp/PLAN-NN in the code repo and archive/ in the records repo. The pairing: every commit in the
#       code repo's HEAD history whose SUBJECT builder_claim reads as this plan's `NN.X`, `fix` or `patch` (anywhere in the subject,
#       as the hooks read it) is named by a line starting `Code: <sha>` (tokens of 7-40 hex, space- or comma-separated, each a prefix
#       of a sha) in the staged LOG or its rotated months (<LOG's dir>/log/*.md). No exemption: a plan never straddles the split.
# RATCHET_PROJECT_CHECK's contract: a shell command (sh -c), run from the code repo's top with the change's unified diff
# (-U0 --no-prefix) on stdin — the staged diff in the hook, each commit against its first parent (a root commit against the
# empty tree) in ci-replay.sh. Exit 0 passes, 1 refuses the commit, anything else is a tool failure (the ratchet exits 2).
#
# Shell rules: bash 3.2 and BSD tools. `set -eu`, never pipefail (a `grep -q` closing a pipeline early would SIGPIPE the
# writer into a false failure). A grep whose no-match is fine carries `|| true` on the grep alone, never on a pipeline that
# holds a git call. Herestrings over `printf | grep -q`. Per-run mktemp paths.
# (`set -eu` is applied after the library boundary below, so sourcing changes no caller's shell options.)

RATCHET_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
RATCHET_SELF="$RATCHET_DIR/$(basename "${BASH_SOURCE[0]:-$0}")"   # this file, absolute — resolved before any cd
RATCHET_TEST_CMD_PRECONF="${RATCHET_TEST_CMD-}"   # the environment's value, before this checkout's conf: the staged-tree run resolves the STAGED conf over it
RATCHET_RECORDS_ENV="${RATCHET_RECORDS:-}"   # a non-empty environment value outranks the conf for this one key, as kit/herdr's lib.sh reads it
[ -f "$RATCHET_DIR/ratchet.conf" ] && . "$RATCHET_DIR/ratchet.conf"
[ -z "$RATCHET_RECORDS_ENV" ] || RATCHET_RECORDS="$RATCHET_RECORDS_ENV"
RATCHET_TEST_CMD_FROM_CONF=""; [ "${RATCHET_TEST_CMD-}" = "$RATCHET_TEST_CMD_PRECONF" ] || RATCHET_TEST_CMD_FROM_CONF=1
: "${RATCHET_LOG:=docs/LOG.md}"
: "${RATCHET_PLANS_DIR=docs/plans}"   # `=` not `:=`: an explicit EMPTY value (Lite, inline plans) must survive
: "${RATCHET_HASHES:=${RATCHET_PLANS_DIR:+$RATCHET_PLANS_DIR/}.acceptance-hashes}"
: "${RATCHET_AMENDS:=${RATCHET_PLANS_DIR:+$RATCHET_PLANS_DIR/}.acceptance-amends}"
: "${RATCHET_TEST_CMD:=./script/test.sh}"
: "${RATCHET_TEST_COUNT_FILE:=.test-count}"
[ -n "${RATCHET_TEST_PATH_REGEX:-}" ]   || RATCHET_TEST_PATH_REGEX='Tests/|Tests\.swift$'
# (regex defaults are assigned with `if`, not `${VAR:=…}` — a `}` inside a default ends the expansion early)
[ -n "${RATCHET_SKIP_REGEX:-}" ]        || RATCHET_SKIP_REGEX='XCTSkip(If|Unless)?\(|\.disabled\(|@Test\([^)]*\.disabled'
: "${RATCHET_ALLOWLIST:=docs/test-allowlist.md}"
[ -n "${RATCHET_SECRET_FILE_REGEX:-}" ] || RATCHET_SECRET_FILE_REGEX='\.(p8|p12|pem|key|cer|mobileprovision|provisionprofile)$|(^|/)\.env(\.[A-Za-z0-9_-]+)?$|(^|/)id_(rsa|ed25519|ecdsa)$'
[ -n "${RATCHET_SECRET_REGEX:-}" ]      || RATCHET_SECRET_REGEX='-----BEGIN [A-Z ]*PRIVATE KEY-----|AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{22,}|sk-[A-Za-z0-9_-]{20,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}'
: "${RATCHET_RESUME_NOTE:=tmp/resume-note.md}"
: "${RATCHET_EXTRACT:=$RATCHET_DIR/acceptance-extract.awk}"
: "${RATCHET_TMP_TIDY:=$RATCHET_DIR/tmp-tidy.sh}"
: "${RATCHET_RECORDS=}"          # split-repo mode's records repo, relative to the code repo's top; empty = one-repo
: "${RATCHET_PROJECT_CHECK=}"    # a project's own check over the change's diff; empty = none
RATCHET_SIDE="one"; RATCHET_CODE_ROOT=""; RATCHET_RECORDS_ROOT=""   # set by ratchet_roots after the cd (library callers call it themselves)
TAB="$(printf '\t')"
for re in "$RATCHET_TEST_PATH_REGEX" "$RATCHET_SKIP_REGEX" "$RATCHET_SECRET_FILE_REGEX" "$RATCHET_SECRET_REGEX"; do   # a regex that does not compile would
  rc=0; printf '' | grep -E -e "$re" >/dev/null 2>&1 || rc=$?
  [ "$rc" -le 1 ] || { echo "ratchet: a configured regex does not compile: $re" >&2; exit 2; }   # read as "no match" = clean: fail loud instead
done

# ---------- extraction + hashing ----------
acc_hash_stdin() {   # stdin = a plan file's content → sha256 of the extracted section's RAW bytes, trailing newlines included, so a
  # hand-made `awk -f extract plan | shasum` stamp reproduces (a re-printed capture strips them and would silently re-digest every
  # such ledger — the reference project's 28 stamps at its 0.16.1 upgrade); empty section → empty hash; a tool failure → non-zero, never a digest
  local sec h
  sec="$(awk -f "$RATCHET_EXTRACT" && printf x)" || return 2   # the sentinel carries the section's trailing newlines through the capture
  case "$sec" in *x) sec="${sec%x}" ;; *) return 2 ;; esac
  [ -n "$sec" ] || { echo ""; return 0; }
  h="$(printf '%s' "$sec" | shasum -a 256)" || return 2
  printf '%s\n' "${h%% *}"
}
acc_hash() { acc_hash_stdin < "$1"; }   # $1 = a plan file on disk

lines_of() {   # $1 = text → LINES_OF, an array of its non-empty lines, verbatim. No here-string, no fork: bash 3.2 feeds a here-string
  # through a temp file, and a loop or a `grep -q` whose redirection fails is skipped (or reads "no match") with no error a caller sees —
  # a skipped check read as a pass. The rule the self-test holds the whole script to: a here-string never feeds a loop, a `grep -q`
  # test or a pipeline; one feeding a command substitution is checked where it's captured.
  local IFS=$'\n' f=1
  case "$-" in *f*) f=0 ;; esac
  set -f; LINES_OF=($1); [ "$f" -eq 0 ] || set +f
}
# check_acceptance_hashes LEDGER_CONTENT READER — READER is a function name: `READER PLAN-NN` prints that plan's content
# (the index copy in the hook, the commit's blob in CI, a fixture in the self-test) or fails when there is none.
check_acceptance_hashes() {
  local ledger="$1" reader="$2" plan hash cur content rows row
  rows="$(ledger_rows <<< "$ledger")" || return 1
  lines_of "$rows"
  for row in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    plan="${row%% *}"; hash=""; case "$row" in *" "*) hash="${row#* }" ;; esac
    [ -n "${plan:-}" ] || continue
    content="$("$reader" "$plan" && printf x)" || { echo "ratchet: no file for $plan in the index (a stamped plan must be tracked and staged — never read from the working tree)"; return 1; }
    content="${content%x}"   # the sentinel keeps the file's exact trailing bytes (a section that ends the file keeps its blank lines)
    cur="$(printf '%s' "$content" | acc_hash_stdin)" || { echo "ratchet: hashing $plan failed (extractor or shasum error) — refusing to read that as a pass"; return 1; }
    [ -n "$cur" ] || { echo "ratchet: $plan extracts an EMPTY acceptance section (the section heading is missing or misspelled)"; return 1; }
    [ "$cur" = "$hash" ] || { echo "ratchet: acceptance hash mismatch for $plan (the frozen section changed; a sanctioned change goes through refreeze.sh --reason)"; return 1; }
  done
  return 0
}
plan_file_for() {   # $1 = PLAN-NN → the one plan file path under RATCHET_PLANS_DIR, or fail
  local f
  [ -n "$RATCHET_PLANS_DIR" ] || return 1
  f="$(ls "$RATCHET_PLANS_DIR/$1"-*.md 2>/dev/null || true)"
  [ "$(printf '%s\n' "$f" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$f"
}
plan_file_index() {   # $1 = PLAN-NN → the one plan path in the INDEX (never the working tree), or fail
  local f
  [ -n "$RATCHET_PLANS_DIR" ] || return 1
  f="$(git ls-files --cached -- "$RATCHET_PLANS_DIR/$1-*.md" 2>/dev/null | grep -E "^$RATCHET_PLANS_DIR/$1-[^/]*\.md\$" || true)"
  [ "$(printf '%s\n' "$f" | grep -c .)" -eq 1 ] || return 1
  printf '%s\n' "$f"
}
plan_content_index() { local f; f="$(plan_file_index "$1")" || return 1; git show ":$f" 2>/dev/null; }   # the index copy ONLY — a plan absent from the index is a missing file, never a disk read

ledger_rows() {   # stdin = a ledger → `PLAN-NN digest` per row, whitespace-normalized (space or tab), comments dropped; a
  # row that is not exactly `PLAN-NN <64 hex>` after that is MALFORMED → named, exit 1 (never silently dropped or half-read);
  # a tool failure on the way is exit 2 (never an empty, valid ledger)
  local norm rows bad
  norm="$(sed -e 's/#.*$//' -e 's/[[:space:]][[:space:]]*/ /g' -e 's/^ //' -e 's/ $//')" || { echo "ratchet: ledger normalization failed" >&2; return 2; }
  rows="$(grep_hits '.' <<< "$norm")" || return 2
  bad="$(grep_hits -v '^PLAN-[0-9]+ [0-9a-f]{64}$' <<< "$rows")" || return 2
  [ -z "$bad" ] || { echo "ratchet: malformed ledger row(s) — each is 'PLAN-NN <sha256>' with an optional # comment:" >&2; printf '%s\n' "$bad" | sed 's/^/  /' >&2; return 1; }
  [ -z "$rows" ] || printf '%s\n' "$rows"
}
# refreeze_trace_ok SUBJECT OLD_LEDGER NEW_LEDGER AMENDS_ADDED PLANMD_STAGED — the two ledger CONTENTS (the parent's and the
# staged/committed one), not diff lines, so a reformatted or deleted row cannot hide: a stamp that disappears is refused
# (once stamped, always stamped); a stamp whose digest changed needs the `PLAN-NN / refreeze` form in the SUBJECT and a
# new amends line for that plan; a stamp that appears (the freeze) needs PLAN.md in the same commit (the flip).
refreeze_trace_ok() {
  local subject="$1" old="$2" new="$3" ad="$4" planstaged="$5" plan od nd row
  old="$(ledger_rows <<< "$old")" || return 1; new="$(ledger_rows <<< "$new")" || return 1
  [ "$old" != "$new" ] || return 0
  lines_of "$old"
  for row in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    plan="${row%% *}"; od=""; case "$row" in *" "*) od="${row#* }" ;; esac
    [ -n "$plan" ] || continue
    nd="$(printf '%s\n' "$new" | grep -E "^$plan " | cut -d' ' -f2 || true)"
    [ -n "$nd" ] || { echo "ratchet: $plan's stamp is gone from $RATCHET_HASHES — once stamped, always stamped (history stays guarded through complete)"; return 1; }
    [ "$nd" = "$od" ] && continue
    printf '%s\n' "$subject" | grep -qE "$plan / refreeze([^A-Za-z0-9]|\$)" \
      || { echo "ratchet: $plan's frozen hash changed with no '$plan / refreeze' in the commit SUBJECT (a sanctioned re-stamp is refreeze.sh $plan --reason …; the subject form is the trace)"; return 1; }
    printf '%s\n' "$ad" | grep -qE "(^|[[:space:]])$plan([[:space:]]|\$)" \
      || { echo "ratchet: $plan's frozen hash changed with no new line for it in $RATCHET_AMENDS (refreeze.sh writes it; stage both ledgers)"; return 1; }
  done
  lines_of "$new"
  for row in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    plan="${row%% *}"
    [ -n "$plan" ] || continue
    printf '%s\n' "$old" | grep -qE "^$plan " && continue
    [ "$planstaged" = 1 ] \
      || { echo "ratchet: $plan gains its first stamp but PLAN.md is not in the commit (the freeze flips the row and stamps in ONE commit)"; return 1; }
  done
  return 0
}
# ---------- the draft's criteria: a builder commit leaves an unstamped plan's Validation and Acceptance alone ----------
# Under build first the criteria prose lands in the draft commit, before any code, and stays unstamped while the plan is built;
# until this leg only the plan read's first check (the section's diff against the draft) kept a builder commit from rewriting
# what it is judged against. A BUILDER commit — a stage claim, or the `fix` / `patch` form — may not change the section of any
# plan whose file it touches that has no stamp in the PARENT's ledger (a stamp guards from the commit after it lands, so a stage
# commit that stamps and edits at once is judged here). A plan stamped in the parent is the hash leg's alone: one refusal, never
# two. `note:` carries every sanctioned edit — the draft, the Verify: blocks, the plan read's criteria fix — and review / close /
# refreeze are the Planner's record forms (close and refreeze follow the stamp). A section that APPEARS in a builder commit is a
# change (criteria written after the code are what the draft commit's order exists to rule out); a plan with no section before
# and after has nothing to protect. A merge is no builder commit (the callers skip it): its first-parent diff carries its
# branch's note: commits, each judged when it was made and again by CI.
first_match() {   # first_match <regex> <<< text → the first match, empty when none; exit 2 on a grep error
  local o rc=0
  o="$(grep -oE -e "$1")" || rc=$?
  [ "$rc" -le 1 ] || return 2
  [ "$rc" -eq 0 ] || return 0
  printf '%s\n' "${o%%$'\n'*}"
}
builder_claim() {   # $1 = the commit SUBJECT, $2 = the whole message → the builder form it carries (`PLAN-NN / NN.X`, `PLAN-NN / fix`,
  # `PLAN-NN / patch`), empty when the commit is not a builder's; exit 2 on a grep error. The SUBJECT decides first — a `note:`
  # subject is a note whatever its body mentions (a block commit may name the Stage it proves); a record form in the subject
  # outranks a stage named only in the body; a stage claim in the body alone still claims (docs_commit_ok reads it so too)
  local o
  case "$1" in note:*) return 0 ;; esac
  o="$(first_match 'PLAN-[0-9]+ / [0-9]+\.[0-9]+' <<< "$1")" || return 2
  [ -z "$o" ] || { printf '%s\n' "$o"; return 0; }
  o="$(first_match 'PLAN-[0-9]+ / (fix|patch)([^A-Za-z0-9]|$)' <<< "$1")" || return 2
  [ -z "$o" ] || { printf '%s\n' "${o%[!A-Za-z0-9]}"; return 0; }
  o="$(first_match 'PLAN-[0-9]+ / (review|close|refreeze)([^A-Za-z0-9]|$)' <<< "$1")" || return 2
  [ -z "$o" ] || return 0
  o="$(first_match 'PLAN-[0-9]+ / [0-9]+\.[0-9]+' <<< "$2")" || return 2
  [ -z "$o" ] || printf '%s\n' "$o"
  return 0
}
unstamped_changed_plans() {   # $1 = the PARENT's ledger content, $2 = the commit's changed paths → the PLAN-NN of every plan file
  # the commit changes that has no stamp in that ledger, sorted unique (empty with no plans dir); 1 on a malformed ledger; 2 on a tool error
  local rows paths ids id hit out=""
  [ -n "$RATCHET_PLANS_DIR" ] || return 0
  rows="$(ledger_rows <<< "$1")" || return $?
  paths="$(grep_hits "^$RATCHET_PLANS_DIR/PLAN-[0-9]+-[^/]*\\.md\$" <<< "$2")" || return 2
  [ -n "$paths" ] || return 0
  ids="$(sed -E 's|^.*/(PLAN-[0-9]+)-[^/]*$|\1|' <<< "$paths")" || return 2
  ids="$(sort -u <<< "$ids")" || return 2
  lines_of "$ids"
  for id in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    hit="$(grep_hits "^$id " <<< "$rows")" || return 2
    [ -n "$hit" ] || out="$out$id"$'\n'
  done
  printf '%s' "$out"
}
plan_path_of() {   # $1 = a tree's paths (one per line), $2 = PLAN-NN → that plan's one file, empty when the tree has none; 1 (named) when two claim it; 2 on a grep error
  local hits l n=0
  hits="$(grep_hits "^$RATCHET_PLANS_DIR/$2-[^/]*\\.md\$" <<< "$1")" || return 2
  lines_of "$hits"; n=${#LINES_OF[@]}
  [ "$n" -le 1 ] || { echo "ratchet: two plan files claim $2 — its criteria cannot be judged:" >&2; printf '%s\n' "$hits" | sed 's/^/  /' >&2; return 1; }   # stderr: the caller captures stdout
  printf '%s' "$hits"
}
# criteria_unchanged_ok CLAIM PLANS OLD_PATHS NEW_PATHS SHOW — PLANS from unstamped_changed_plans; OLD_PATHS / NEW_PATHS the parent's and
# the commit's plan listings; `SHOW old|new <path>` prints that side's blob (the hook: HEAD and the index; CI: the parent and the commit).
# Hashes with $RATCHET_EXTRACT, which the caller points at the PARENT's extractor where the parent holds one (a builder commit cannot
# weaken the check it is judged by) → 0 when no section changed; 1 refused, naming the plan file; 2 on a tool error (never "unchanged")
criteria_unchanged_ok() {
  local claim="$1" plans="$2" olds="$3" news="$4" show="$5" id op np oc nc oh nh
  lines_of "$plans"
  for id in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    op="$(plan_path_of "$olds" "$id")" || return $?
    np="$(plan_path_of "$news" "$id")" || return $?
    oc=""; nc=""
    if [ -n "$op" ]; then oc="$("$show" old "$op" && printf x)" || { echo "ratchet: reading $op before the commit failed — $id's criteria cannot be judged" >&2; return 2; }; oc="${oc%x}"; fi
    if [ -n "$np" ]; then nc="$("$show" new "$np" && printf x)" || { echo "ratchet: reading $np in the commit failed — $id's criteria cannot be judged" >&2; return 2; }; nc="${nc%x}"; fi
    oh="$(printf '%s' "$oc" | acc_hash_stdin)" || { echo "ratchet: extracting $id's Validation and Acceptance failed (the extractor or shasum) — never read as unchanged" >&2; return 2; }
    nh="$(printf '%s' "$nc" | acc_hash_stdin)" || { echo "ratchet: extracting $id's Validation and Acceptance failed (the extractor or shasum) — never read as unchanged" >&2; return 2; }
    [ "$oh" != "$nh" ] || continue
    echo "ratchet: $claim changes the Validation and Acceptance section of ${np:-$op} — $id has no stamp yet, so its criteria are the draft's and a builder commit never edits them (protocol/verification.md § Enforce the freeze). Commit the criteria change on its own as 'note:' (a Verify: block, a fix the plan read asked for), or leave it to the plan read."
    return 1
  done
  return 0
}

# ---------- count floor ----------
is_docs_path() {   # $1 = one path → 0 iff the docs-only rule treats it as docs (the floor's docs-only skip; the suite-run fingerprint reads the NARROWER is_record_path)
  case "$1" in
    .execplan|"$RATCHET_HASHES"|"$RATCHET_AMENDS") return 0 ;;   # the stamp + the guard's own ledgers (a re-stamp can't lower a count)
    docs/*.md) return 0 ;;                                       # any .md UNDER docs/ (any depth)
    */*) return 1 ;;                                             # any OTHER slashed path is NOT docs-only — incl. test fixtures (*Tests/Fixtures/*.md)
    *.md) return 0 ;;                                            # a repo-ROOT .md (PLAN.md, AGENTS.md, README.md, root LOG.md/TESTING.md)
    *) return 1 ;;                                               # a repo-root non-.md (project.yml, .gitignore, …) → run the suite
  esac
}
is_docs_only() {   # $1 = newline-separated staged file list; 0 iff NON-empty and every path is docs-only
  [ -n "$1" ] || return 1                          # an empty staged diff is NOT a docs-only commit
  local file
  lines_of "$1"
  for file in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    is_docs_path "$file" || return 1
  done
  return 0
}
suite_count() {   # [show] — runs $RATCHET_TEST_CMD (output captured, then read) → sets SUITE_COUNT to the LAST `<PROJECT>_TEST_COUNT=<n>` marker;
  # `show` streams the output to the terminal as it runs (--recount: the ritual's one run is the builder's view of the suite), the
  # command's own status kept through the pipe by a status file. 1 when the capture file cannot be made, the suite fails (its output
  # kept at the named path), the marker read fails (same), or no marker — the one reader the floor and --recount share
  local out marks st rc
  out="$(mktemp)" || { echo "ratchet: mktemp failed (exit $?) — the suite's output cannot be captured, so no count is read"; return 1; }   # checked: this function runs in `||` contexts where set -e does not, and a mktemp that printed a path before failing once read as a count
  if [ "${1:-}" = show ]; then
    st="$(mktemp)" || { echo "ratchet: mktemp failed (exit $?) — the suite's status cannot be kept"; return 1; }
    { $RATCHET_TEST_CMD 2>&1; echo "$?" > "$st"; } | tee "$out" || { echo "ratchet: tee failed (exit $?) — the suite's output was not captured (output so far in $out)"; rm -f "$st"; return 1; }
    rc="$(cat "$st")" || { echo "ratchet: the suite's status could not be read (cat exit $?)"; rm -f "$st"; return 1; }
    rm -f "$st"
    [ "$rc" = 0 ] || { echo "ratchet: test suite failed ($RATCHET_TEST_CMD, exit ${rc:-unknown}; output in $out)"; return 1; }
  else
    $RATCHET_TEST_CMD > "$out" 2>&1 || { echo "ratchet: test suite failed ($RATCHET_TEST_CMD; output in $out)"; return 1; }
  fi
  marks="$(sed -n 's/^[A-Z_]*TEST_COUNT=//p' "$out")" || { echo "ratchet: reading the marker from $RATCHET_TEST_CMD's output failed (sed exit $?; output in $out) — refusing to read that as a count"; return 1; }   # captured, then checked: a `sed | tail` dropped sed's status
  rm -f "$out"
  SUITE_COUNT="${marks##*$'\n'}"   # the last marker, by expansion over the captured value
  [ -n "${SUITE_COUNT:-}" ] || { echo "ratchet: $RATCHET_TEST_CMD printed no <PROJECT>_TEST_COUNT=<n> marker — the wrapper contract (the module) is broken, so the floor cannot be read"; return 1; }
}
suite_count_staged() {   # runs the suite on the INDEX's content in a throwaway detached worktree → sets SUITE_COUNT; 1 on any failure.
  # For a commit whose working tree holds code the index leaves out (a partial staging, work-in-progress): the suite in place would
  # count the working tree, not the commit. The whole worktree lifecycle runs in ONE subshell whose EXIT/INT/TERM traps remove it on
  # every path — a failing suite, Ctrl-C, a TERM — (`git worktree remove --force`, then the directory, then `git worktree prune`), the
  # status kept; being a subshell's, the traps never touch a trap the caller set. git's hook variables (GIT_INDEX_FILE may name the
  # commit's own index or its lock) are unset for everything that touches it. The test command is the STAGED checkout's: the
  # environment's value, then that checkout's own ratchet.conf, then the default — never the working tree's conf. Submodules are
  # initialized at their staged revisions (a failure refuses). A fresh worktree is a fresh build — slower — and holds only tracked
  # files; the test command runs from its root, so it must be repo-relative (the module's wrapper is)
  local tree commit out rc=0 listing gl confrel root
  tree="$(git write-tree)" || { echo "ratchet: git write-tree failed (exit $?) — the staged tree cannot be tested"; return 1; }
  [ -n "$tree" ] || { echo "ratchet: git write-tree printed no tree — the staged tree cannot be tested"; return 1; }
  commit="$(GIT_AUTHOR_NAME=ratchet GIT_AUTHOR_EMAIL=ratchet@localhost GIT_COMMITTER_NAME=ratchet GIT_COMMITTER_EMAIL=ratchet@localhost \
    git commit-tree "$tree" -m "ratchet: the staged tree, for a test run")" || { echo "ratchet: git commit-tree failed (exit $?) — the staged tree cannot be tested"; return 1; }
  [ -n "$commit" ] || { echo "ratchet: git commit-tree printed no commit — the staged tree cannot be tested"; return 1; }   # unreferenced: gc takes it; an unborn HEAD needs no parent
  listing="$(git ls-tree -r "$tree")" || { echo "ratchet: listing the staged tree failed (exit $?) — the staged tree cannot be tested"; return 1; }
  gl="$(grep_hits '^160000 ' <<< "$listing")" || return 1   # gitlinks: submodules to initialize in the worktree
  confrel="${RATCHET_DIR##*/}/ratchet.conf"; root="$(pwd -P)" || { echo "ratchet: pwd failed — the staged tree cannot be tested"; return 1; }
  echo "ratchet: the working tree's code differs from the index being committed — testing the STAGED tree in a fresh worktree (a fresh build — slower)"
  out="$(
    unset GIT_INDEX_FILE GIT_WORK_TREE
    base=""; wt=""; wtreal=""
    staged_cleanup() {
      local left
      cd "$root" 2>/dev/null || cd / || true
      if [ -n "$wt" ] && { [ -d "$wt" ] || [ -f "$wt" ]; }; then
        git worktree remove --force "$wt" >/dev/null 2>&1 || :   # a worktree holding submodules refuses; the rm and the prune below finish it, and the check after says if not
      fi
      if [ -n "$base" ]; then rm -rf "$base" || echo "ratchet: removing $base failed (cleanup only)" >&2; fi
      git worktree prune >/dev/null 2>&1 || echo "ratchet: git worktree prune failed (cleanup only — run it by hand)" >&2   # after the directory is gone
      [ -n "$wt" ] || return 0
      left="$(git worktree list --porcelain)" || { echo "ratchet: git worktree list failed — check that $wt is gone" >&2; return 0; }
      if [[ "$left" == *"$wt"* ]] || [[ "$left" == *"${wtreal:-$wt}"* ]]; then echo "ratchet: the test worktree $wt is still registered — run: git worktree remove --force $wt; git worktree prune" >&2; fi
    }
    trap 'st=$?; trap - EXIT INT TERM; staged_cleanup; exit $st' EXIT
    trap 'exit 130' INT; trap 'exit 143' TERM
    base="$(mktemp -d)" || { echo "ratchet: mktemp -d failed — the staged tree cannot be tested" >&2; exit 1; }
    wt="$base/wt"
    git worktree add -q --detach "$wt" "$commit" >/dev/null 2>&1 || { echo "ratchet: git worktree add failed (exit $?) — the staged tree cannot be tested" >&2; exit 1; }
    wtreal="$(cd "$wt" && pwd -P)" || wtreal="$wt"
    if [ -n "$gl" ]; then
      git -C "$wt" submodule update --init --recursive >/dev/null 2>&1 \
        || { echo "ratchet: initializing the staged tree's submodules failed (exit $?) — the staged tree cannot be tested" >&2; exit 1; }
    fi
    cd "$wt" || { echo "ratchet: cd into the test worktree failed" >&2; exit 1; }
    unset GIT_DIR
    [ -z "$RATCHET_TEST_CMD_FROM_CONF" ] || RATCHET_TEST_CMD="$RATCHET_TEST_CMD_PRECONF"   # drop the value the WORKING conf set
    if [ -f "$confrel" ]; then . "./$confrel" || { echo "ratchet: sourcing the staged $confrel failed" >&2; exit 1; }; fi
    [ -n "${RATCHET_TEST_CMD:-}" ] || RATCHET_TEST_CMD=./script/test.sh
    suite_count >&2 || exit 1
    printf '%s\n' "$SUITE_COUNT"
  )" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  SUITE_COUNT="$out"
  case "$SUITE_COUNT" in ''|*[!0-9]*) echo "ratchet: the staged-tree run returned no count"; return 1 ;; esac
}
submodules_clean() {   # → 0 when the index holds no submodule, or every one is initialized, at its recorded commit, with no local
  # changes (modified or untracked content, recursively); 1 otherwise; 2 on a tool error. A submodule's uncommitted content is
  # invisible to a fingerprint (its gitlink does not change): a run over it is never recorded, and never stands in for the commit
  local listing gl st bad dirty
  listing="$(git ls-files -s)" || return 2
  gl="$(grep_hits '^160000 ' <<< "$listing")" || return 2
  [ -n "$gl" ] || return 0
  st="$( unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE; git submodule status --recursive )" || return 2
  bad="$(grep_hits '^[-+U]' <<< "$st")" || return 2
  [ -z "$bad" ] || return 1
  dirty="$( unset GIT_INDEX_FILE GIT_DIR GIT_WORK_TREE; git submodule foreach --quiet --recursive 'git status --porcelain --ignore-submodules=none' )" || return 2
  [ -z "$dirty" ] || return 1
  return 0
}
# ---------- the suite-run record: one suite run per stage commit ----------
# `--recount` (the ritual's one run) records `<fingerprint> <count>` on green; the pre-commit floor reuses it when the COMMIT's code is
# the code that was tested, instead of running the same suite on the same tree a second time.
# Two readings of one fingerprint — the CODE: every entry minus the record files the ritual writes AFTER the run
# (is_record_path: the LOG, the plan files and review dirs, PLAN.md, the count file), so the LOG entry, the plan's Progress, and the
# floor bump don't invalidate it. Deliberately narrower than the docs-only skip's is_docs_path: any other markdown — a root README a
# test opens, a `.md` the test command runs — is code to the record, and a change to it after the run runs the suite again. `--recount` reads
# the TESTED tree: a throwaway index SEEDED from the real one (a tracked file an ignore rule now matches stays in), then `git add -A`.
# The commit's floor reads the INDEX being committed (`git ls-files -s`, the index git hands the hook). They match only when every
# code path the commit holds is what the suite ran on — a partial staging, a code edit after the run, an untracked file the suite
# saw but the commit leaves out: the suite runs. A dirty or off-commit submodule is never recorded (submodules_clean). Residuals: the
# record lives under the git dir and can be forged like `--no-verify` can be typed (the Never list); the fingerprint covers what git
# tracks — an ignored, untracked file the suite reads is outside it, and so is the target of an absolute symlink (declared, v0.19);
# CI's Test step runs the suite on the pushed head either way.
is_record_path() {   # $1 = one path → 0 iff it is a record file the stage-close ritual writes after its suite run — $RATCHET_LOG, anything
  # under $RATCHET_PLANS_DIR/ (plan files, review dirs, ledgers), PLAN.md, $RATCHET_TEST_COUNT_FILE (Lite: the LOG and PLAN.md) — the ONLY
  # paths the suite-run fingerprint leaves out
  case "$1" in "$RATCHET_TEST_COUNT_FILE"|"$RATCHET_LOG"|PLAN.md) return 0 ;; esac
  if [ -n "$RATCHET_PLANS_DIR" ]; then case "$1" in "$RATCHET_PLANS_DIR"/*) return 0 ;; esac; fi
  return 1
}
suite_record_path() { git rev-parse --git-path ratchet-suite-run; }   # per worktree (a linked worktree keeps its own)
code_fingerprint() {   # [index] → a hash of the code content (see above): the TESTED tree (default — --recount), or with `index` the
  # index being committed (the floor); 2 on any tool error — an error is never a match
  local idx src listing kept line path fp
  if [ "${1:-}" = index ]; then
    listing="$(git -c core.quotePath=false ls-files -s)" || return 2   # GIT_INDEX_FILE, when git set it for the hook, is the one committed
  else
    idx="$(mktemp)" || return 2; rm -f "$idx" || return 2
    src="${GIT_INDEX_FILE:-}"; [ -n "$src" ] || src="$(git rev-parse --git-path index)" || return 2
    if [ -f "$src" ]; then cp -p "$src" "$idx" || { rm -f "$idx"; return 2; }; fi   # seeded: the tracked set survives an ignore rule; no index yet → git builds one.
    # `-p` keeps the index's mtime, so git's racy-clean check behaves as on the real index: a plain copy's newer mtime once made a same-second,
    # same-size edit read as unchanged, and the fingerprint kept the old content
    GIT_INDEX_FILE="$idx" git add -A . >/dev/null 2>&1 || { rm -f "$idx"; return 2; }
    listing="$(GIT_INDEX_FILE="$idx" git -c core.quotePath=false ls-files -s)" || { rm -f "$idx"; return 2; }
    rm -f "$idx" || return 2
  fi
  kept=""
  lines_of "$listing"
  for line in ${LINES_OF[@]+"${LINES_OF[@]}"}; do                                              # `<mode> <sha> <stage>\t<path>`
    path="${line#*$'\t'}"
    is_record_path "$path" && continue
    kept="$kept$line"$'\n'
  done
  fp="$(printf 'cmd=%s\n%s' "$RATCHET_TEST_CMD" "$kept" | git hash-object --stdin)" || return 2
  [ -n "$fp" ] || return 2
  printf '%s\n' "$fp"
}
recorded_count() {   # $1 = the current fingerprint → the recorded count when the record matches it; exit 1 when there is no usable
  # record (absent, stale, or malformed — a malformed record is never a pass); 2 on a tool error
  local rp rec fp n
  rp="$(suite_record_path)" || return 2
  [ -f "$rp" ] || return 1
  rec="$(cat "$rp")" || return 2
  fp="${rec%% *}"; n="${rec#* }"
  case "$fp" in ''|*[!0-9a-f]*) return 1 ;; esac
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#n}" -le 18 ] || return 1
  [ "$fp" = "$1" ] || return 1
  printf '%s\n' "$n"
}
count_floor() {   # $1 = staged file list; docs-only → skip; else read the floor, then the count — from the suite-run record when it
  # matches the COMMITTED code (--recount ran the suite on exactly the code this index holds), else by running the suite — and compare
  # it against the floor: the higher of the index's copy (what the commit carries) and the working file's, each read checked
  if is_docs_only "$1"; then echo "ratchet: docs-only staged diff — skipping count floor"; return 0; fi
  local have want staged fp rc fprc wfp wrc src
  want="$(floor_read)" || return 1   # the one floor reader (absent file → 0; a read that fails or a malformed line → a refusal, before the suite runs) — a `cat … || echo 0` here read every failed read as floor 0, and a count of 9 passed it
  staged="$(floor_read_staged)" || return 1   # the floor the commit carries: a working file edited below the staged one never loosens the check
  [ "$staged" -le "$want" ] || want="$staged"
  have=""; fprc=0; fp="$(code_fingerprint index)" || fprc=$?
  if [ "$fprc" -ne 0 ]; then echo "ratchet: the code fingerprint failed — the suite-run record is not read; running the suite"
  else rc=0; have="$(recorded_count "$fp")" || rc=$?
       case "$rc" in
         0) echo "ratchet: the suite ran on exactly the code this commit holds (script/ratchet.sh --recount, count $have) — not re-run" ;;
         1) have="" ;;
         *) have=""; echo "ratchet: reading the suite-run record failed — running the suite" ;;
       esac
  fi
  if [ -z "$have" ]; then   # the suite runs — on the working tree only when its code IS the index's (else on the staged tree, in a throwaway worktree)
    wrc=0; wfp="$(code_fingerprint)" || wrc=$?
    src=0; submodules_clean || src=$?   # a dirty submodule is invisible to both fingerprints: its run in place would not be the commit's
    if [ "$fprc" -eq 0 ] && [ "$wrc" -eq 0 ] && [ "$wfp" = "$fp" ] && [ "$src" -eq 0 ]; then suite_count || return 1
    else suite_count_staged || return 1; fi
    have="$SUITE_COUNT"
  fi
  [ "$have" -ge "$want" ] || { echo "ratchet: test count $have < floor $want (bump $RATCHET_TEST_COUNT_FILE only in the commit that adds tests)"; return 1; }
}
floor_read() {   # → the committed floor: $RATCHET_TEST_COUNT_FILE's integer line; 0 when the file is absent; a file a merge left in
  # CONFLICT holds both sides' floors between its markers and reads as the HIGHER (a recount may not go below either side); a file
  # with no integer line, one that cannot be read, or an integer line `[` cannot compare (more than 18 digits — a 24-digit row once
  # tripped `[`, the `if` read that as "not greater", and the LOWER side became the floor) is an error (exit 1 / 2), never 0, never the lower side
  [ -f "$RATCHET_TEST_COUNT_FILE" ] || { echo 0; return 0; }
  floor_parse < "$RATCHET_TEST_COUNT_FILE"
}
floor_read_staged() {   # → the floor the INDEX carries (the commit's copy of the count file), parsed as floor_read parses the file; 0 when the
  # index holds none; a failed listing or read is exit 2 (a line naming it), never 0 — presence by a checked listing, never a suppressed read
  local has content
  has="$(git ls-files --cached -- "$RATCHET_TEST_COUNT_FILE")" || { echo "ratchet: listing the staged $RATCHET_TEST_COUNT_FILE failed — the floor cannot be read" >&2; return 2; }
  [ -n "$has" ] || { echo 0; return 0; }
  content="$(git show ":$RATCHET_TEST_COUNT_FILE")" || { echo "ratchet: reading the staged $RATCHET_TEST_COUNT_FILE failed — the floor cannot be read" >&2; return 2; }
  printf '%s\n' "$content" | floor_parse
}
floor_parse() {   # stdin = a count file's content → its floor, by the rules above
  local rows n max="" rc
  rows="$(grep_hits '^[0-9]+$')" || return 2
  [ -n "$rows" ] || { echo "ratchet: $RATCHET_TEST_COUNT_FILE holds no integer line — the floor cannot be read" >&2; return 1; }
  lines_of "$rows"
  for n in ${LINES_OF[@]+"${LINES_OF[@]}"}; do   # the maximum by bash alone — a `sort -n | tail -1` dropped sort's status, and a sort that printed the lower side before failing read as the floor
    [ -n "$n" ] || continue
    [ "${#n}" -le 18 ] || { echo "ratchet: $RATCHET_TEST_COUNT_FILE holds a malformed floor line ($n: ${#n} digits, more than a count bash can compare) — the floor cannot be read" >&2; return 1; }
    n="${n#"${n%%[!0]*}"}"; [ -n "$n" ] || n=0   # a count is decimal: `0070` is 70, never octal 56 in the merge's arithmetic, and `08` never an arithmetic error
    [ -n "$max" ] || { max="$n"; continue; }
    rc=0; [ "$n" -gt "$max" ] 2>/dev/null || rc=$?   # three ways: 0 greater, 1 not greater, anything else is `[` itself failing — an error, never "not greater"
    case "$rc" in 0) max="$n" ;; 1) ;; *) echo "ratchet: comparing the floor lines $n and $max failed ([ exit $rc) — the floor cannot be read" >&2; return 1 ;; esac
  done
  printf '%s\n' "$max"
}

# ---------- diff helpers ----------
added_lines() {   # stdin = a unified diff (-U0, --no-prefix) → the CONTENT of every added line (leading `+` stripped), by
  # HUNK STATE: content lines exist only after a `@@` hunk header and before the next `diff ` header, so `--- `/`+++ `
  # file headers are never content and an added content line that itself begins with `+` (`++x`, a credential starting
  # with `+`) or a `-- x` → `++ y` replacement pair is scanned like any other (a header-lookalike filter dropped both).
  awk '/^diff / { h = 0; next } /^@@/ { h = 1; next } h && /^\+/ { print substr($0, 2) }'
}
grep_hits() {   # grep_hits [-v] <regex> <<< text → the matching lines; exit 0 (matches or none), exit 2 on a grep ERROR (never "clean")
  local out rc=0 inv=""
  [ "$1" = -v ] && { inv=-v; shift; }
  out="$(grep -E $inv -e "$1" 2>&1)" || rc=$?
  [ "$rc" -le 1 ] || { echo "ratchet: grep failed (exit $rc) on pattern: $1" >&2; return 2; }
  [ "$rc" -eq 0 ] && printf '%s\n' "$out"
  return 0
}

# ---------- skip markers ----------
skip_scan() {   # $1 = the unified diff of the staged TEST files; $2 = allowlist content → 0 iff clean; 2 on a tool error
  local hits line name
  local lines; lines="$(added_lines <<< "$1")" || return 2
  hits="$(grep_hits "$RATCHET_SKIP_REGEX" <<< "$lines")" || return 2
  [ -n "$hits" ] || return 0
  lines_of "$hits"
  for line in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    name="$(printf '%s\n' "$line" | grep -oE 'test[A-Za-z0-9_]+' | awk 'NR==1' || true)"
    { [ -n "$name" ] && printf '%s\n' "$2" | grep -qE "(^|[^A-Za-z0-9_])$name([^A-Za-z0-9_]|\$)"; } || { echo "ratchet: unlisted skip: $line"; return 1; }
  done
  return 0
}

# ---------- secrets (the Never list, wired) ----------
secret_scan() {   # $1 = the ADDED/MODIFIED file list (deletions excluded — removing a key file is the fix); $2 = the unified diff → 0 iff clean; 2 on a tool error
  local bad
  bad="$(grep_hits "$RATCHET_SECRET_FILE_REGEX" <<< "$1")" || return 2
  [ -z "$bad" ] || { echo "ratchet: a secret-shaped file is staged (never commit keys, certificates, profiles, .env):"; printf '%s\n' "$bad" | sed 's/^/  /'; return 1; }
  local lines; lines="$(added_lines <<< "$2")" || return 2
  bad="$(grep_hits "$RATCHET_SECRET_REGEX" <<< "$lines")" || return 2
  bad="$(grep_hits -v 'ratchet:allow-secret[[:space:]]*$' <<< "$bad")" || return 2
  bad="$(cut -c1-80 <<< "$bad")" || return 2
  [ -z "$bad" ] || { echo "ratchet: an added line looks like a credential (a fixture that must carry a fake one ends the line with 'ratchet:allow-secret'):"; printf '%s\n' "$bad" | sed 's/^/  /'; return 1; }
  return 0
}

# ---------- conflict markers ----------
conflict_scan() {   # $1 = the unified diff (-U0, --no-prefix) → 0 iff no file in it adds both an opening (`<<<<<<<`) and a closing
  # (`>>>>>>>`) conflict marker at column 0; 1 (named) otherwise; 2 on a tool error. Both are required, so a lone `=======` (a setext
  # heading) or a marker quoted inside a line never trips it. Files are told apart by their `diff ` header, lines by hunk state.
  local bad prog='function done_() { if (o && c) print f } /^diff / { done_(); f = $NF; o = c = 0; h = 0; next } /^@@/ { h = 1; next }
    h && /^[+][<][<][<][<][<][<][<]( |$)/ { o = 1 } h && /^[+][>][>][>][>][>][>][>]( |$)/ { c = 1 } END { done_() }'   # [<] spelled out: the here-string lint reads three <s as one
  bad="$(awk "$prog" <<< "$1")" || { echo "ratchet: awk failed scanning for conflict markers" >&2; return 2; }
  [ -z "$bad" ] || { echo "ratchet: a staged file still holds conflict markers (resolve it, then stage it again; an example in a doc indents its markers):"; printf '%s\n' "$bad" | sed 's/^/  /'; return 1; }
  return 0
}

# ---------- docs-commit forms ----------
plan_status() {   # $1 = PLAN.md content, $2 = PLAN-NN → the §2 row's status token | no-row | unknown
  local row status
  row="$(printf '%s\n' "$1" | grep -E "^\| \*\*$2\*\*" | awk 'NR==1')" || true
  [ -n "$row" ] || { echo no-row; return 0; }
  status="$(printf '%s\n' "$row" | grep -oE '\| (drafted|ready-to-execute|in-progress|blocked-on-review|complete|superseded)( \([^)|]*\))? \|' \
    | awk 'NR==1' | sed -E 's/^\| //; s/ \|$//; s/ \(.*//')"
  echo "${status:-unknown}"
}
first_paragraph() {   # stdin = a message → its first paragraph joined by single spaces, trimmed — what git's `%s` reports as the subject
  awk 'BEGIN { n = 0 } { line = $0; sub(/^[ \t]+/, "", line); sub(/[ \t]+$/, "", line) }
       line == "" { if (n) exit; next } { printf "%s%s", (n++ ? " " : ""), line } END { printf "\n" }'
}
# subject_readings MSG → sets SUBJ_N (1 or 2), SUBJ_1, SUBJ_2: the subject(s) git may commit from the hook's message file, by THIS
# repo's cleanup rules. Git drops comment lines (`core.commentChar`, default `#`) under `commit.cleanup=strip`, and under the
# default only when an EDITOR ran — a `-m`/`-F` message keeps a `#`-led first line. The hook cannot see whether an editor
# will run, so under the default it returns BOTH readings when they differ (an EMPTY reading included — an empty subject is a
# reading git can commit), and the caller requires every decision to hold for each: whichever line git commits was already
# judged. A tool failure is exit 2. CI never calls this: it reads the committed subject (`git show -s --format=%s`).
subject_readings() {
  local cc mode kept stripped body
  mode="$(git config commit.cleanup 2>/dev/null || true)"; cc="$(git config core.commentChar 2>/dev/null || true)"
  [ -n "$cc" ] && [ "$cc" != auto ] || cc='#'
  local cut
  kept="$(first_paragraph <<< "$1")" || return 2
  body="$(grep_hits -v "^[$cc]" <<< "$1")" || return 2
  stripped="$(first_paragraph <<< "$body")" || return 2
  case "$mode" in
    strip) SUBJ_N=1; SUBJ_1="$stripped"; SUBJ_2="" ;;
    verbatim|whitespace) SUBJ_N=1; SUBJ_1="$kept"; SUBJ_2="" ;;
    scissors)   # comments are kept, but an EDITED message is truncated at the scissors line — judge both the untruncated and the truncated reading
      cut="$(awk -v cc="$cc" 'index($0, cc " ------------------------ >8 ------------------------") == 1 { exit } { print }' <<< "$1")" || return 2
      cut="$(first_paragraph <<< "$cut")" || return 2
      SUBJ_1="$kept"; if [ "$kept" = "$cut" ]; then SUBJ_N=1; SUBJ_2=""; else SUBJ_N=2; SUBJ_2="$cut"; fi ;;
    *) SUBJ_1="$kept"; if [ "$kept" = "$stripped" ]; then SUBJ_N=1; SUBJ_2=""; else SUBJ_N=2; SUBJ_2="$stripped"; fi ;;
  esac
  return 0
}
subject_of_msg() { subject_readings "$1" || return 2; printf '%s\n' "$SUBJ_1"; }   # the first reading (the probes' single-subject view)
first_match_id() {   # first_match_id <regex> <<< text → the PLAN-NN of the first match, empty when none; exit 2 on a grep error
  local o rc=0
  o="$(grep -oE -e "$1")" || rc=$?
  [ "$rc" -le 1 ] || return 2
  [ "$rc" -eq 0 ] || return 0
  o="${o%%$'\n'*}"; printf '%s\n' "${o%% *}"
}
stage_ref() { first_match_id 'PLAN-[0-9]+ / [0-9]+\.[0-9]+' <<< "$1"; }   # $1 = the whole message → the claimed PLAN-NN, or empty
log_form_ok() {   # $1 = the commit SUBJECT: a non-stage form bounded by a non-alphanumeric, or `note:` opening it — never a body line
  printf '%s\n' "$1" | grep -qE 'PLAN-[0-9]+ / (review|close|patch|refreeze|fix)([^A-Za-z0-9]|$)' || printf '%s\n' "$1" | grep -qE '^note:'
}
# docs_commit_ok SUBJECT MSG FILES LOG_GREW(0/1) — the stage-claim and LOG-growth decision, shared by the hook and CI (on split-repo
# mode's code side a stage claim demands nothing: its artifacts are the records repo's commit, paired at the close), which
# each pass the subject THEY hold (the hook: every reading `subject_readings` returns, one call each; CI: the committed %s). A stage claim ANYWHERE in the
# message demands its artifacts (direction 1); LOG growth is satisfied only by the SUBJECT (direction 2 — the trace must show
# in `git log --oneline`).
docs_commit_ok() {
  local subject="$1" msg="$2" files="$3" grew="$4" plan
  plan="$(stage_ref "$msg")" || return 2
  if [ -n "$plan" ] && [ "${RATCHET_SIDE:-one}" != code ]; then   # split-repo mode's code side: the LOG and the plan file are the records repo's half
    printf '%s\n' "$subject" | grep -qE 'PLAN-[0-9]+ / [0-9]+\.[0-9]+' || { [ "$grew" = 1 ] && { echo "ratchet: $plan claim in the body only — the stage reference belongs in the SUBJECT (git log --oneline is the trace)"; return 1; }; }
    printf '%s\n' "$files" | grep -qx -- "$RATCHET_LOG" || { echo "ratchet: $plan claim, no $RATCHET_LOG staged"; return 1; }
    if [ -n "$RATCHET_PLANS_DIR" ]; then
      printf '%s\n' "$files" | grep -qE "^$RATCHET_PLANS_DIR/$plan-[^/]*\\.md\$" || { echo "ratchet: $plan claim, plan file untouched (a PLAN-NN-review/ edit is not the plan file)"; return 1; }
    else
      printf '%s\n' "$files" | grep -qx 'PLAN.md' || { echo "ratchet: $plan claim, PLAN.md (the inline plan) untouched"; return 1; }
    fi
    return 0
  fi
  if [ "$grew" = 1 ]; then
    log_form_ok "$subject" || { echo "ratchet: $RATCHET_LOG grew with no stage/review/close/patch/refreeze/fix/note form in the SUBJECT"; return 1; }
  fi
  return 0
}

# ---------- tmp/ citations (the workspace guard) ----------
tmp_cites() {   # stdin = lines → every `tmp/…` path they cite, one per line, as written (trailing sentence punctuation stripped); 2 on a tool error
  local raw rc=0
  raw="$(grep -oE '(^|[^/A-Za-z0-9_.-])tmp/[-A-Za-z0-9_.<{*[][^[:space:]`)|",;'"'"']*')" || rc=$?
  [ "$rc" -le 1 ] || return 2
  [ "$rc" -eq 0 ] || return 0
  sed -E 's/^[^t]*//; s/[.,:;]+$//' <<< "$raw" || return 2
}
cite_ok() {   # $1 = cite, $2 = PLAN.md content → 0 iff an ADDED docs line may carry it
  local plan
  [ "$1" = "$RATCHET_RESUME_NOTE" ] && return 0                # the resume carrier
  case "$1" in
    tmp/PLAN-[A-Z]*) return 0 ;;                               # the convention's own placeholder (tmp/PLAN-NN/…)
    tmp/PLAN-[0-9]*)
      plan="$(printf '%s\n' "$1" | grep -oE '^tmp/PLAN-[0-9]+' | cut -d/ -f2)"
      case "$(plan_status "$2" "$plan")" in
        complete|superseded|no-row|unknown) return 1 ;;        # fail closed: an unparseable row is a defect, not a pass
        *) return 0 ;;
      esac ;;
  esac
  return 1
}
tmp_cite_offenders() {   # stdin = cites; $1 = PLAN.md content → one `cite (why)` per offender
  local c plan
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    cite_ok "$c" "$1" && continue
    case "$c" in
      tmp/PLAN-[0-9]*) plan="$(printf '%s\n' "$c" | grep -oE '^tmp/PLAN-[0-9]+' | cut -d/ -f2)"
                       echo "$c ($plan is $(plan_status "$1" "$plan") — cite the tracked ${RATCHET_PLANS_DIR:-docs/plans}/$plan-review/ path or the archive)" ;;
      tmp/bounded|tmp/bounded/*) echo "$c (a small change's scratch is disposable and goes with its worktree — commit what the entry must keep, and cite that)" ;;
      *)               echo "$c (legacy bare path — in-flight scratch lives at tmp/PLAN-NN/<stage>-<kind>[-rN].<ext>; a path in another repo is written repo-qualified)" ;;
    esac
  done
}
diff_doc_lines() {   # stdin = unified diff (-U0 --no-prefix) → the changed content lines of in-scope docs, sign kept — by
  # HUNK STATE (a `diff ` line opens a file, its `+++ ` header names it, `@@` opens content), so a content line that begins
  # with `+` or `-` (`++see tmp/…`, `-- old`) is judged like any other
  awk '
    /^diff / { h = 0; inscope = 0; next }
    !h && /^\+\+\+ / { f = substr($0, 5); sub(/\t.*$/, "", f)
                      inscope = (f ~ /^(docs\/.*|[^\/]+)\.md$/ && f !~ /^docs\/(log|archive|research)\// && f !~ /^docs\/plans\/PLAN-[0-9]+-review\//); next }
    /^@@/ { h = 1; next }
    h && inscope && /^[-+]/ { print }
  '
}
fresh_cites() {   # stdin = unified diff → the NEW cites it adds to in-scope docs (added minus removed), sorted unique; 2 on a tool error
  local lines plus minus added removed
  lines="$(diff_doc_lines)" || return 2
  plus="$(grep_hits '^\+' <<< "$lines")" || return 2; minus="$(grep_hits '^-' <<< "$lines")" || return 2
  plus="$(cut -c2- <<< "$plus")" || return 2; added="$(tmp_cites <<< "$plus")" || return 2; added="$(sort -u <<< "$added")" || return 2
  minus="$(cut -c2- <<< "$minus")" || return 2; removed="$(tmp_cites <<< "$minus")" || return 2; removed="$(sort -u <<< "$removed")" || return 2
  comm -23 <(printf '%s\n' "$added") <(printf '%s\n' "$removed") || return 2
}
tmp_cite_guard() {   # stdin = unified diff (vs the first parent); $1 = PLAN.md content; $2… = a merge's fresh-cite lists vs its
  # OTHER parents (fresh_cites over each) — a cite is new on a merge only when it is new against EVERY parent, so the lines a
  # closed plan's branch wrote while open are inherited, not added → 0 iff no offending NEW cite; 2 on a tool error
  local fresh bad o pm="$1"; shift
  fresh="$(fresh_cites)" || return 2
  for o in ${1+"$@"}; do fresh="$(comm -12 <(printf '%s\n' "$fresh") <(printf '%s\n' "$o"))" || return 2; done
  bad="$(tmp_cite_offenders "$pm" <<< "$fresh")" || return 2
  [ -z "$bad" ] || { echo "ratchet: a docs line cites tmp/ scratch outside an open plan's tmp/PLAN-NN/ (drift):"; printf '%s\n' "$bad" | sed 's/^/  /'; return 1; }
  return 0
}
merge_heads() {   # → the in-progress merge's other parents (MERGE_HEAD, one per line; empty when no merge is in progress — the
  # path from `--git-path`, so a linked worktree reads its own); 2 on a tool error
  local mh; mh="$(git rev-parse --git-path MERGE_HEAD)" || return 2
  [ -f "$mh" ] || return 0
  cat "$mh" || return 2
}
merge_carries_close() {   # $1 = PLAN-NN, $2 = the merge's other parents → 0 iff a commit only they reach (HEAD..<parent>) closes
  # $1 in its SUBJECT — the branch's own close, whose hook ran the on-disk half where the plan was closed; 1 if none; 2 on a tool error
  local h subjects s c heads
  lines_of "$2"; heads=(${LINES_OF[@]+"${LINES_OF[@]}"})
  for h in ${heads[@]+"${heads[@]}"}; do
    subjects="$(git log --format=%s "HEAD..$h")" || return 2
    lines_of "$subjects"
    for s in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
      c="$(close_plan_in "$s")" || return 2
      [ "$c" != "$1" ] || return 0
    done
  done
  return 1
}

# ---------- the close ritual ----------
manifest_inventory() {   # stdin = a MANIFEST (or tmp-tidy's dry-run output) → its `- tracked:` paths, sorted unique; exit 2 on a tool error
  local lines inv
  lines="$(grep_hits '^- tracked: ' <<< "$(cat)")" || return 2
  inv="$(sed 's/^- tracked: //' <<< "$lines")" || return 2
  sort -u <<< "$inv" || return 2
}
# close_ritual_tracked_ok PLAN TREE MANIFEST — the half a bare checkout can see (CI replays it): the manifest is in the
# tree, carries its `## Tracked files` inventory, and every inventoried path is in the tree.
close_ritual_tracked_ok() {
  local plan="$1" tree="$2" manifest="$3" inv missing pdir="${RATCHET_PLANS_DIR:-docs/plans}"
  printf '%s\n' "$tree" | grep -qx -- "$pdir/$plan-review/MANIFEST.md" \
    || { echo "ratchet: $plan / close without tmp-tidy — $pdir/$plan-review/MANIFEST.md is not in the commit (run tmp-tidy.sh --plan $plan --dry-run, then --apply, and stage the review dir)"; return 1; }
  printf '%s\n' "$manifest" | grep -qx '## Tracked files' \
    || { echo "ratchet: $plan / close — the staged MANIFEST has no '## Tracked files' inventory: it predates the 0.15 tmp-tidy (re-run --apply and re-stage the review dir)"; return 1; }
  inv="$(manifest_inventory <<< "$manifest")" || return 2
  missing="$(lines_of "$inv"; for t in ${LINES_OF[@]+"${LINES_OF[@]}"}; do printf '%s\n' "$tree" | grep -qxF -- "$t" || echo "$t"; done)"
  [ -z "$missing" ] \
    || { echo "ratchet: $plan / close — the MANIFEST marks these tracked but they are not in the commit (unstaged, or ignored by a broad pattern — git add -f them):"; printf '%s\n' "$missing" | sed 's/^/  /'; return 1; }
  return 0
}
# close_ritual_local_ok PLAN ROOT MANIFEST — the on-disk half (hook only): archive beside a non-empty .list, tmp/PLAN gone,
# the guard's own dry run at zero UNRESOLVED and inventorying nothing the staged manifest lacks, tmp/ clean.
close_ritual_local_ok() {   # (split-repo mode's records side: ROOT is the records repo — archive/ is here — and tmp/ is the code repo's)
  local plan="$1" root="$2" manifest="$3" out inv fresh missing troot="$2" tdisp="tmp/$1" ta
  ta=(--root "$root")
  if [ "${RATCHET_SIDE:-one}" = records ]; then troot="$RATCHET_CODE_ROOT"; tdisp="$RATCHET_CODE_ROOT/tmp/$plan"; ta=(--root "$RATCHET_CODE_ROOT" --records "$RATCHET_RECORDS_ROOT"); fi
  [ -s "$root/archive/plans/$plan.list" ] \
    || { echo "ratchet: $plan / close without tmp-tidy — archive/plans/$plan.list is missing or empty (tmp-tidy --apply writes it)"; return 1; }
  [ -f "$root/archive/plans/$plan.tar.zst" ] || [ -f "$root/archive/plans/$plan.tar.gz" ] \
    || { echo "ratchet: $plan / close — archive/plans/$plan.list has no archive beside it (the list proves nothing without archive/plans/$plan.tar.zst|.tar.gz)"; return 1; }
  [ ! -e "$troot/tmp/$plan" ] \
    || { echo "ratchet: $plan / close — $tdisp still exists: tmp-tidy --apply did not finish (an UNRESOLVED cite keeps the dir; fix the cite, re-run --apply)"; return 1; }
  out="$("$RATCHET_TMP_TIDY" --plan "$plan" --dry-run "${ta[@]}" 2>&1)" \
    || { echo "ratchet: $plan / close with unresolved citations (tmp-tidy.sh --plan $plan --dry-run):"; printf '%s\n' "$out" | grep -E '^UNRESOLVED|^tmp-tidy:' | sed 's/^/  /'; return 1; }
  inv="$(manifest_inventory <<< "$manifest")" || return 2
  fresh="$(manifest_inventory <<< "$out")" || return 2
  missing="$(lines_of "$fresh"; for t in ${LINES_OF[@]+"${LINES_OF[@]}"}; do printf '%s\n' "$inv" | grep -qxF -- "$t" || echo "$t"; done)"
  [ -z "$missing" ] \
    || { echo "ratchet: $plan / close — the staged MANIFEST is stale: the review dir holds files its inventory does not list (re-stage the review dir after the last tmp-tidy --apply):"; printf '%s\n' "$missing" | sed 's/^/  /'; return 1; }
  out="$("$RATCHET_TMP_TIDY" --check "${ta[@]}" 2>&1)" \
    || { echo "ratchet: $plan / close with an untidy tmp/ (tmp-tidy.sh --check):"; printf '%s\n' "$out" | sed 's/^/  /'; return 1; }
  return 0
}
check_close_ritual() {   # $1 = PLAN-NN, $2 = the index's path list, $3 = repo root, $4 = the STAGED manifest's content
  if [ -z "$RATCHET_PLANS_DIR" ]; then   # Lite, inline plans: no review dir, no archive, no tidy to prove — only the stray scan
    local ta=(--root "$3"); [ "${RATCHET_SIDE:-one}" != records ] || ta=(--root "$RATCHET_CODE_ROOT" --records "$RATCHET_RECORDS_ROOT")
    local out; out="$("$RATCHET_TMP_TIDY" --check "${ta[@]}" 2>&1)" \
      || { echo "ratchet: $1 / close with an untidy tmp/ (tmp-tidy.sh --check):"; printf '%s\n' "$out" | sed 's/^/  /'; return 1; }
    return 0
  fi
  close_ritual_tracked_ok "$1" "$2" "$4" && close_ritual_local_ok "$1" "$3" "$4"
}
close_plan_in() {   # $1 = the commit SUBJECT → PLAN-NN when it carries `PLAN-NN / close` bounded (bare, docs:-prefixed, or the merge); `closeup` is not a close; exit 2 on a grep error
  first_match_id 'PLAN-[0-9]+ / close([^A-Za-z0-9]|$)' <<< "$1"
}

# ---------- the integration merge's floor, and the LOG merge driver (execution-loop.md § Parallel streams) ----------
floor_at() {   # $1 = a rev → the floor the count file holds there, parsed as floor_read parses it; 0 when the rev has no such file;
  # 2 on a failure — absence comes from a checked listing, never from a suppressed read
  local has content
  has="$(git ls-tree --name-only "$1" -- "$RATCHET_TEST_COUNT_FILE")" || { echo "ratchet: listing $RATCHET_TEST_COUNT_FILE at $1 failed — the merged floor cannot be computed" >&2; return 2; }
  [ -n "$has" ] || { echo 0; return 0; }
  content="$(git show "$1:$RATCHET_TEST_COUNT_FILE")" || { echo "ratchet: reading $RATCHET_TEST_COUNT_FILE at $1 failed — the merged floor cannot be computed" >&2; return 2; }
  printf '%s\n' "$content" | floor_parse
}
merge_floor() {   # $1 = the merge's other parents (merge_heads) → the merged floor, base + (ours − base) + (theirs − base), with a
  # summary line on stderr; 2 on an octopus, no merge base, an unreadable side or a sum below zero (never a guess, never the higher side)
  local n base b o t e
  local grc=0
  n="$(grep -c . <<< "$1")" || grc=$?   # three ways: 0 lines counted, 1 none (grep -c still prints 0), anything else grep itself failed
  case "$grc" in 0|1) ;; *) echo "ratchet: counting the merge's other parents failed (grep exit $grc) — the merged floor cannot be computed" >&2; return 2 ;; esac
  [ "$n" -eq 1 ] || { echo "ratchet: recount inside a merge of $n other parents — the merged floor is computed for a two-parent merge only" >&2; return 2; }
  base="$(git merge-base HEAD "$1")" || { echo "ratchet: recount inside a merge with no merge base between HEAD and $1 — the merged floor cannot be computed" >&2; return 2; }
  b="$(floor_at "$base")" || return 2; o="$(floor_at HEAD)" || return 2; t="$(floor_at "$1")" || return 2
  e=$(( o + t - b ))
  [ "$e" -ge 0 ] || { echo "ratchet: recount — merge: base $b, ours $o, theirs $t gives $e, below zero — the count files cannot be read as floors" >&2; return 2; }
  echo "ratchet: recount — merge: base $b, ours $o, theirs $t → expected $e" >&2
  printf '%s\n' "$e"
}
log_merge_awk='
function isentry(l) { return l ~ /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z/ }
function fence(l,    t, c, k) {   # markdown fences (``` or ~~~, 3+ of one char, indented 0-3 spaces): opens or closes one; sets fc/fl
  match(l, /^ */); if (RLENGTH > 3) return; t = substr(l, RLENGTH + 1)
  c = substr(t, 1, 1); if (c != "`" && c != "~") return
  for (k = 1; substr(t, k, 1) == c; k++); k--
  if (k < 3) return
  if (fc == "") { if (c == "`" && index(substr(t, k + 1), "`")) return; fc = c; fl = k; return }   # a backtick fence info string holds no backtick
  if (c == fc && k >= fl && substr(t, k + 1) ~ /^[ \t]*$/) { fc = ""; fl = 0 }                  # closes: the same char, at least as long, nothing after
}
function load(s, path,    line, r, cur, i, blanks) {   # side s → pre[s], n[s], txt[s,i] (trailing blank lines dropped), gap[s,i], ts[s,i]
  pre[s] = ""; n[s] = 0; cur = 0; blanks = 0; fc = ""; fl = 0
  while ((r = (getline line < path)) > 0) {
    if (fc == "" && isentry(line)) { if (cur) gap[s,cur] = blanks; n[s]++; cur = n[s]; txt[s,cur] = line; ts[s,cur] = substr(line, 4, 20); gap[s,cur] = 0; blanks = 0; continue }
    fence(line)   # an entry-shaped line inside a fence is an example, never a boundary
    if (!cur) { pre[s] = pre[s] line "\n"; continue }
    if (line == "") { blanks++; continue }
    for (i = 0; i < blanks; i++) txt[s,cur] = txt[s,cur] "\n"   # a blank line inside an entry stays inside it
    blanks = 0; txt[s,cur] = txt[s,cur] "\n" line
  }
  if (r < 0) exit 2
  if (fc != "") exit 4   # a fence left open at the end: no boundary is certain, so git merge-file decides
  close(path)
  if (cur) gap[s,cur] = blanks
}
function emit(s, i, last) {
  printf "%s\n", txt[s,i]
  g = gap[s,i]; if (!last && g == 0) g = sep
  if (last) g = tail
  for (k = 0; k < g; k++) printf "\n"
}
BEGIN {
  load("b", B); load("o", O); load("t", T)
  for (i = 1; i <= n["o"]; i++) cnt["o", txt["o",i]]++
  for (i = 1; i <= n["t"]; i++) cnt["t", txt["t",i]]++
  for (i = 1; i <= n["b"]; i++) { if (cnt["o", txt["b",i]] < 1 || cnt["t", txt["b",i]] < 1) exit 3 }   # append-only on both sides, or no driver
  if (pre["o"] == pre["t"] || pre["t"] == pre["b"]) p = pre["o"]; else if (pre["o"] == pre["b"]) p = pre["t"]; else exit 3
  for (j = 1; j <= n["t"]; j++) if (cnt["o", txt["t",j]] > 0) { cnt["o", txt["t",j]]--; skip[j] = 1 }   # ours already carries it: emitted once, at the place ours gives it
  sep = 1; if (n["o"] > 1) sep = gap["o",1]; else if (n["t"] > 1) sep = gap["t",1]; if (sep < 1) sep = 1
  if (n["o"]) tail = gap["o",n["o"]]; else if (n["t"]) tail = gap["t",n["t"]]; else tail = 0
  printf "%s", p
  total = 0; i = 1; j = 1
  while (i <= n["o"] || j <= n["t"]) {
    if (j <= n["t"] && skip[j]) { j++; continue }
    if (j > n["t"] || (i <= n["o"] && ("" ts["o",i]) >= ("" ts["t",j]))) { qs[++total] = "o"; qi[total] = i++ }   # newest first; a tie goes to ours
    else { qs[++total] = "t"; qi[total] = j++ }
  }
  for (m = 1; m <= total; m++) emit(qs[m], qi[m], m == total)
}'
merge_log() {   # $1 base, $2 ours (the result goes here), $3 theirs → git's merge driver for the append-only LOG (install-hooks.sh wires it):
  # the preamble, then both sides' entries newest first, each once; a heading inside a ``` or ~~~ fence is never a boundary. A file
  # that isn't append-only on both sides (a base entry changed or gone, the preamble changed on both), or a fence left open, falls back to `git merge-file`, whose status is the driver's; 2 on a tool failure,
  # with ours untouched
  local tmp rc last size
  tmp="$(mktemp "$2.log-merge.XXXXXX")" || { echo "ratchet: merge-log — mktemp failed; $2 untouched" >&2; return 2; }
  rc=0; awk -v B="$1" -v O="$2" -v T="$3" "$log_merge_awk" > "$tmp" || rc=$?
  case "$rc" in
    0) ;;
    3|4) rm -f "$tmp"
       if [ "$rc" -eq 3 ]; then echo "ratchet: merge-log — the LOG isn't append-only on both sides (an older entry changed or went, or both sides changed the preamble): falling back to git merge-file" >&2
       else echo "ratchet: merge-log — a code fence is left open at the end of one side, so no entry boundary is certain: falling back to git merge-file" >&2; fi
       rc=0; git merge-file -L ours -L base -L theirs "$2" "$1" "$3" || rc=$?
       return "$rc" ;;
    *) rm -f "$tmp"; echo "ratchet: merge-log — reading the three versions failed (awk exit $rc); $2 untouched" >&2; return 2 ;;
  esac
  last="$(tail -c 1 "$2")" || { rm -f "$tmp"; echo "ratchet: merge-log — reading $2's last byte failed; $2 untouched" >&2; return 2; }
  if [ -s "$2" ] && [ -n "$last" ]; then   # ours ended without a newline: so does the result
    size="$(wc -c < "$tmp")" || { rm -f "$tmp"; return 2; }
    head -c $(( size - 1 )) "$tmp" > "$tmp.n" && mv -f "$tmp.n" "$tmp" || { rm -f "$tmp" "$tmp.n"; return 2; }
  fi
  mv -f "$tmp" "$2" || { rm -f "$tmp"; echo "ratchet: merge-log — writing the result to $2 failed" >&2; return 2; }
}

# ---------- split-repo mode (modules/split-repo.md): the two roots, the side, the pairing, the project check ----------
clean_git() { ( unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_PREFIX GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES; git "$@" ); }   # git in ANOTHER repo: a hook's
# environment (GIT_INDEX_FILE above all — git sets it for every commit hook) names the committing repo and would bleed into it
ratchet_roots() {   # after the cd → RATCHET_SIDE (one | code | records), RATCHET_CODE_ROOT and RATCHET_RECORDS_ROOT (physical); 2 on a bad
  # RATCHET_RECORDS or a failed read, named. In split-repo mode exactly two roots are known: the kit's code repo (this script's parent,
  # physically) is the code side, and <that>/$RATCHET_RECORDS is the records side. Any other working directory is exit 2, named — never
  # read as the code side, whose rules would skip the record guards. A symlink along $RATCHET_RECORDS is refused: git runs a nested
  # repo's hooks through the relative core.hooksPath, which a link would point at another kit (modules/split-repo.md)
  local here kit lex rec r
  here="$(pwd -P)" || { echo "ratchet: reading the working directory failed" >&2; return 2; }
  if [ -z "$RATCHET_RECORDS" ]; then RATCHET_SIDE=one; RATCHET_CODE_ROOT="$here"; RATCHET_RECORDS_ROOT="$here"; return 0; fi
  r="$RATCHET_RECORDS"; while :; do case "$r" in ?*/) r="${r%/}" ;; *) break ;; esac; done
  case "$r" in ""|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*)
    echo "ratchet: RATCHET_RECORDS='$RATCHET_RECORDS' must be a relative path inside the code repo (no leading /, no . or .. parts, no empty part)" >&2; return 2 ;; esac
  RATCHET_RECORDS="$r"
  kit="$(cd "$RATCHET_DIR/.." && pwd -P)" || { echo "ratchet: reading the kit's code repo path failed" >&2; return 2; }
  lex="$kit/$r"; rec=""
  if [ -e "$lex" ] || [ -L "$lex" ]; then
    rec="$(cd "$lex" 2>/dev/null && pwd -P)" || { echo "ratchet: RATCHET_RECORDS=$r — $lex can't be entered (a broken link, or not a directory)" >&2; return 2; }
    [ "$rec" = "$lex" ] || { echo "ratchet: RATCHET_RECORDS=$r — $lex resolves to $rec: a symlink along the records path isn't supported (clone the records repo at $lex itself)" >&2; return 2; }
    # a path that EXISTS must be a repo of its own: an ordinary folder there would read as the code side and quiet the record guards.
    # A MISSING path stays the code side (code CI, a contributor without the records clone)
    local top
    top="$(clean_git -C "$rec" rev-parse --show-toplevel 2>/dev/null)" || { echo "ratchet: RATCHET_RECORDS=$r — $rec is not a git work tree: the records repo must be a repo of its own (clone it there, or remove the folder)" >&2; return 2; }
    top="$(cd "$top" 2>/dev/null && pwd -P)" || { echo "ratchet: RATCHET_RECORDS=$r — reading the work tree git names for $rec failed" >&2; return 2; }
    [ "$top" = "$rec" ] || { echo "ratchet: RATCHET_RECORDS=$r — $rec is a folder inside the work tree $top, not a repo of its own: the records repo must be its own clone at \$RATCHET_RECORDS" >&2; return 2; }
  fi
  if [ -n "$rec" ] && [ "$here" = "$rec" ]; then
    RATCHET_SIDE=records; RATCHET_CODE_ROOT="$kit"; RATCHET_RECORDS_ROOT="$rec"
  elif [ "$here" = "$kit" ]; then
    RATCHET_SIDE=code; RATCHET_CODE_ROOT="$kit"; RATCHET_RECORDS_ROOT="$lex"
  else
    echo "ratchet: split-repo mode (RATCHET_RECORDS=$r) and $here is neither this kit's code repo ($kit) nor its records repo ($lex) — refusing to guess a side (RATCHET_ROOT, or where the script ran from)" >&2; return 2
  fi
  return 0
}
records_root_check() {   # → 0 when RATCHET_RECORDS_ROOT is the top of a git work tree of its own (made physical); 2 named otherwise — a
  # missing clone must never read as the code repo, whose work tree would otherwise answer for it
  local p top
  p="$(cd "$RATCHET_RECORDS_ROOT" 2>/dev/null && pwd -P)" || { echo "ratchet: no records repo at $RATCHET_RECORDS_ROOT (RATCHET_RECORDS=$RATCHET_RECORDS) — clone it there first" >&2; return 2; }
  top="$(clean_git -C "$p" rev-parse --show-toplevel 2>/dev/null)" || { echo "ratchet: $p is not a git work tree — the records repo must be a repo of its own" >&2; return 2; }
  top="$(cd "$top" && pwd -P)" || { echo "ratchet: reading $top failed" >&2; return 2; }
  [ "$top" = "$p" ] || { echo "ratchet: $p is inside the work tree $top, not a repo of its own — the records repo must be its own clone at \$RATCHET_RECORDS" >&2; return 2; }
  RATCHET_RECORDS_ROOT="$p"
}
records_log_text() {   # → the staged LOG and every staged rotated month beside it (<LOG's dir>/log/*.md): the text the pairing reads; 2 on a failure
  local dir files f out
  case "$RATCHET_LOG" in */*) dir="${RATCHET_LOG%/*}/log" ;; *) dir="log" ;; esac
  files="$(git ls-files --cached -- "$RATCHET_LOG" "$dir")" || { echo "ratchet: listing the staged LOG failed — the pairing can't be judged"; return 2; }
  lines_of "$files"
  for f in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    case "$f" in "$RATCHET_LOG"|"$dir"/*.md) ;; *) continue ;; esac
    out="$(git show ":$f")" || { echo "ratchet: reading the staged $f failed — the pairing can't be judged"; return 2; }
    printf '%s\n' "$out"
  done
}
# pairing_ok PLAN-NN LOG_TEXT CODE_ROOT — split-repo mode's records-side close: every code-side builder commit for the plan in the code
# repo's HEAD history is named by a `Code:` line. A builder commit is one whose SUBJECT builder_claim reads as this plan's `NN.X`, `fix`
# or `patch` — the same reading the hooks give a subject, wherever in it the claim sits. A `Code:` line starts its line: `Code: ` then
# space- or comma-separated tokens, each 7-40 hex characters, a prefix of the commit's sha. There's no exemption: a plan never straddles
# the split (modules/split-repo.md), so every builder commit it has is paired. 1 = refused, each missing commit listed; 2 = a tool failed
pairing_ok() {
  local plan="$1" log="$2" code="$3" commits hits toks row sha subj t named claim miss=""
  commits="$(clean_git -C "$code" log --format="%H${TAB}%s" HEAD)" || { echo "ratchet: reading the code repo's history ($code) failed — the pairing can't be judged"; return 2; }
  hits="$(awk -F "$TAB" -v p="$plan / " 'index($2, p) > 0 && $2 !~ /^note:/' <<< "$commits")" \
    || { echo "ratchet: filtering the code repo's history failed — the pairing can't be judged"; return 2; }   # a superset: builder_claim decides
  [ -n "$hits" ] || return 0
  toks="$(awk '/^Code: / { s = substr($0, 7); gsub(/,/, " ", s); n = split(s, a, /[ \t]+/)
                for (i = 1; i <= n; i++) if (a[i] ~ /^[0-9a-fA-F]+$/ && length(a[i]) >= 7 && length(a[i]) <= 40) print tolower(a[i]) }' <<< "$log")" \
    || { echo "ratchet: reading the LOG's Code: lines failed — the pairing can't be judged"; return 2; }
  local tl=(); lines_of "$toks"; tl=(${LINES_OF[@]+"${LINES_OF[@]}"})
  lines_of "$hits"
  for row in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    sha="${row%%"$TAB"*}"; subj="${row#*"$TAB"}"
    claim="$(builder_claim "$subj" "$subj")" || { echo "ratchet: reading $sha's subject failed — the pairing can't be judged"; return 2; }
    [ "${claim%% *}" = "$plan" ] || continue
    named=0
    for t in ${tl[@]+"${tl[@]}"}; do case "$sha" in "$t"*) named=1; break ;; esac; done
    [ "$named" -eq 0 ] || continue
    miss="$miss  ${sha:0:12} $subj"$'\n'
  done
  [ -z "$miss" ] || { echo "ratchet: $plan / close — these code-side commits have no \`Code: <sha>\` line in $RATCHET_LOG (a Stage's records entry names its code commit — modules/split-repo.md):"; printf '%s' "$miss"; return 1; }
  return 0
}
project_check() {   # $1 = the change's unified diff → RATCHET_PROJECT_CHECK over it (stdin), from the working directory: 0 pass (or none
  # configured), 1 refused, 2 the check failed to run or exited anything else — never read as a pass
  local f rc=0
  [ -n "$RATCHET_PROJECT_CHECK" ] || return 0
  f="$(mktemp)" || { echo "ratchet: mktemp failed — the project check can't run"; return 2; }
  { [ -z "$1" ] || printf '%s\n' "$1"; } > "$f" || { rm -f "$f"; echo "ratchet: writing the diff for the project check failed"; return 2; }
  sh -c "$RATCHET_PROJECT_CHECK" < "$f" || rc=$?
  rm -f "$f"
  case "$rc" in
    0) return 0 ;;
    1) echo "ratchet: the project check refused this change (RATCHET_PROJECT_CHECK: $RATCHET_PROJECT_CHECK)"; return 1 ;;
    *) echo "ratchet: the project check failed to run (exit $rc) — never read as a pass (RATCHET_PROJECT_CHECK: $RATCHET_PROJECT_CHECK)"; return 2 ;;
  esac
}

# ---------- library mode: ci-replay.sh sources the decisions and stops here ----------
if [ "${RATCHET_LIB:-}" = 1 ]; then return 0 2>/dev/null || exit 0; fi
set -eu

# ---------- --merge-log: git runs it from the checkout's top with the three versions' paths, before any cd ----------
if [ "${1:-}" = "--merge-log" ]; then
  [ "$#" -eq 4 ] || { echo "usage: ratchet.sh --merge-log <base> <ours> <theirs>" >&2; exit 64; }
  rc=0; merge_log "$2" "$3" "$4" || rc=$?; exit "$rc"
fi
# the repo to check: RATCHET_ROOT (the hooks pass the committing repo's top — the records repo's, in split-repo mode), else this
# script's parent. When RATCHET_ROOT is that same repo, the path this script was run by is kept, so every relative path reads as before
if [ -n "${RATCHET_ROOT:-}" ]; then
  rr="$(cd "$RATCHET_ROOT" && pwd -P)" || { echo "ratchet: RATCHET_ROOT ($RATCHET_ROOT) can't be entered" >&2; exit 2; }
  kr="$(cd "$RATCHET_DIR/.." && pwd -P)" || { echo "ratchet: reading this script's repo path failed" >&2; exit 2; }
  if [ "$rr" = "$kr" ]; then cd "$RATCHET_DIR/.."; else cd "$RATCHET_ROOT"; fi
else
  cd "$RATCHET_DIR/.."
fi
if [ "${1:-}" != "--self-test" ]; then ratchet_roots || exit 2; fi   # the self-test proves the code at the defaults, one-repo first

# ---------- --cite-check ----------
if [ "${1:-}" = "--cite-check" ]; then tmp_cite_guard "$(cat "$2")" || exit 1; exit 0; fi

# ---------- --recount: the ritual's one suite run, and the integration merge's (execution-loop.md § Stage-close ritual, § Parallel streams) ----------
# runs the suite once (its output streamed), and its count becomes the floor — never a lower one (a merged or grown suite counts no
# fewer; when it does, the refusal names a lost test); outside a merge a conflicted .test-count reads as its higher side, inside one
# the floor is merge_floor's arithmetic. On green it records the
# run for the commit's hook (the suite-run record above) — only when the code's fingerprint is the same before and after the run, so an
# edit made while the suite ran is never recorded as tested. Every reader below is captured and checked: a floor read that fails is a
# refusal (exit 1 / 2, nothing written), never a lower floor; a fingerprint that fails leaves no record and exits 2 after saying so
if [ "${1:-}" = "--recount" ]; then
  [ "$RATCHET_SIDE" != records ] || { echo "ratchet: recount in the records repo — it has no suite (split-repo mode); run it in the code repo ($RATCHET_CODE_ROOT)"; exit 1; }
  heads="$(merge_heads)" || { echo "ratchet: reading MERGE_HEAD failed — refusing to guess whether a merge is in progress"; exit 2; }
  if [ -n "$heads" ]; then want="$(merge_floor "$heads")" || exit 2   # the integration merge: the arithmetic decides, never the conflict's higher side
  else want="$(floor_read)" || exit $?; fi
  rp="$(suite_record_path)" || { echo "ratchet: git could not name the suite-run record's path — refusing to run unrecorded"; exit 2; }
  rm -f "$rp" || { echo "ratchet: could not remove the old suite-run record ($rp)"; exit 2; }   # a stale record never outlives a new run
  fprc=0; fp1="$(code_fingerprint)" || fprc=$?
  sub1=0; submodules_clean || sub1=$?
  suite_count show || exit 1; have="$SUITE_COUNT"
  [ -z "$heads" ] || [ "$have" -ge "$want" ] || { echo "ratchet: recount refused — test count $have < the merged floor $want (base, plus each side's change): the merge lost a test — find it before anything lands"; exit 1; }
  [ "$have" -ge "$want" ] || { echo "ratchet: recount refused — test count $have < floor $want: a recount never lowers the floor (a merged suite counts more, never fewer — investigate the regression; $RATCHET_TEST_COUNT_FILE moves only in the commit that adds tests)"; exit 1; }
  printf '%s\n' "$have" > "$RATCHET_TEST_COUNT_FILE" || exit 1
  if [ "$have" -eq "$want" ]; then echo "ratchet: recount — floor unchanged at $have"; else echo "ratchet: recount — floor $want → $have"; fi
  [ "$fprc" -eq 0 ] || { echo "ratchet: recount — the run is NOT recorded: the code fingerprint failed (exit $fprc); the commit's hook will run the suite again"; exit 2; }
  fprc=0; fp2="$(code_fingerprint)" || fprc=$?
  [ "$fprc" -eq 0 ] || { echo "ratchet: recount — the run is NOT recorded: the code fingerprint failed after the run (exit $fprc); the commit's hook will run the suite again"; exit 2; }
  if [ "$fp1" != "$fp2" ]; then echo "ratchet: recount — the code changed while the suite ran; the run is not recorded (the commit's hook runs the suite)"; exit 0; fi
  sub2=0; submodules_clean || sub2=$?
  if [ "$sub1" -ne 0 ] || [ "$sub2" -ne 0 ]; then echo "ratchet: recount — the run is not recorded: a submodule is uninitialized, off its recorded commit, or holds local changes (or its state could not be read) — the suite saw content no commit holds; the commit's hook runs the suite on the staged tree"; exit 0; fi
  printf '%s %s\n' "$fp1" "$have" > "$rp" || { echo "ratchet: recount — writing the suite-run record ($rp) failed; the commit's hook will run the suite again"; exit 2; }
  echo "ratchet: recount — run recorded; the commit's hook reuses it while the code is unchanged"
  exit 0
fi

# ---------- --self-test ----------
if [ "${1:-}" = "--self-test" ]; then
  # the probes prove the CODE against fixed fixtures — a project's ratchet.conf (a Lite LOG.md, an empty plans dir) is
  # reset to the defaults here; the explicit Lite probe below writes its own conf and runs the script
  RATCHET_LOG=docs/LOG.md; RATCHET_PLANS_DIR=docs/plans; RATCHET_HASHES=docs/plans/.acceptance-hashes; RATCHET_AMENDS=docs/plans/.acceptance-amends
  RATCHET_ALLOWLIST=docs/test-allowlist.md; RATCHET_RESUME_NOTE=tmp/resume-note.md
  RATCHET_RECORDS=; RATCHET_PROJECT_CHECK=; RATCHET_SIDE=one; unset RATCHET_ROOT   # one-repo; the split-repo probes set their own
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  fx() { cat "$d/plans/$1-x.md"; }
  mkdir -p "$d/plans"
  # 0. the here-string rule (lines_of's header): outside this self-test, no here-string feeds a loop, a `grep -q` test or a pipeline —
  # bash 3.2 writes a here-string to a temp file, and a loop or test whose redirection fails is skipped with no error (a check read as a
  # pass). The failure can't be forced on macOS (bash falls back to /tmp), so the SOURCE is held to the rule, and the lint proves it
  # catches each shape
  hs_lint='/^# ---------- --self-test ----------$/ { skip = 1 }
/^# ---------- --commit-msg ----------$/ { skip = 0 }
skip { next }
{
  line = $0; sub(/^[ \t]*#.*$/, "", line)             # a comment-only line
  if (pend) { t = line; sub(/^[ \t]+/, "", t); if (t ~ /^\|[^|]/) print NR - 1 ": a here-string feeds a pipeline"; pend = 0 }
  if (index(line, "<<<") == 0) next
  rest = substr(line, index(line, "<<<"))
  if (line ~ /done[ \t]*<<</) { print NR ": a here-string feeds a loop"; next }
  pre = substr(line, 1, index(line, "<<<") - 1)
  if (pre ~ /grep[ \t]+-[A-Za-z]*q/) { print NR ": a here-string feeds a grep -q test"; next }
  r = rest; gsub(/\|\|/, "", r)
  if (r ~ /\|/) { print NR ": a here-string feeds a pipeline"; next }
  if (rest ~ /\\[ \t]*$/) pend = 1
}
'
  hl="$(awk "$hs_lint" "$RATCHET_SELF")" || fail "the here-string lint failed to run"
  [ -z "$hl" ] || fail "a here-string feeds a loop, a grep -q test or a pipeline (use lines_of or printf | …): $hl"
  for shape in '  done <<< "$rows"' '  grep -qx -- "$a" <<< "$files" || refuse' '  { [ -n "$n" ] && grep -qE "(^|x)$n" <<< "$2"; } || refuse' \
      '  nd="$(grep -E "^$p " <<< "$new" | cut -d" " -f2 || true)"' 'while read -r h; do :; done <<< "$mhs"'; do
    hl="$(printf '%s\n' "$shape" | awk "$hs_lint")" || fail "the here-string lint failed to run on a fixture"
    [ -n "$hl" ] || fail "the here-string lint missed: $shape"
  done
  hl="$(printf '%s\n' '  st="$(grep -oE "a" <<< "$row" \' '    | awk "NR==1")"' | awk "$hs_lint")" || fail "the here-string lint failed to run on a fixture"
  [ -n "$hl" ] || fail "the here-string lint missed a pipeline continued on the next line"
  hl="$(printf '%s\n' '  rows="$(grep_hits "." <<< "$norm")" || return 2' '  x="$(a <<< "$b")" || { echo no; return 2; }' | awk "$hs_lint")" || fail "the here-string lint failed to run on a fixture"
  [ -z "$hl" ] || fail "the here-string lint flagged a checked command substitution: $hl"
  # 1. a clean fixture passes; an edit inside the section trips; an edit outside (a verdict in Outcomes) does not
  printf '# PLAN-00\n\n## Validation and Acceptance\n\n- After X, the system Y.\n\n      Verify: manual — light and dark.\n\n## Outcomes\n\n(pending)\n' > "$d/plans/PLAN-00-x.md"
  ledger="PLAN-00 $(acc_hash "$d/plans/PLAN-00-x.md")"
  check_acceptance_hashes "$ledger" fx >/dev/null || fail "clean fixture tripped the hash guard"
  printf -- '- Stage 00.1: PASS — reviewer, 2026-01-01, evidence.\n' >> "$d/plans/PLAN-00-x.md"
  check_acceptance_hashes "$ledger" fx >/dev/null || fail "a verdict in Outcomes tripped the hash guard"
  sed 's/system Y/system Z/' "$d/plans/PLAN-00-x.md" > "$d/t" && mv "$d/t" "$d/plans/PLAN-00-x.md"
  check_acceptance_hashes "$ledger" fx >/dev/null 2>&1 && fail "an edit inside the section did not trip"
  # 1b. a HAND-MADE stamp reproduces: `awk -f extract plan | shasum` over a section that ends in a blank line (the reference
  #     project's 28 ledger rows) — the digest is of the raw extraction, trailing newlines included, never of a re-printed capture
  printf '# PLAN-00\n\n## Validation and Acceptance\n\n- After X, the system Y.\n\n## Outcomes\n\n(pending)\n' > "$d/plans/PLAN-00-x.md"
  hand="$(awk -f "$RATCHET_EXTRACT" "$d/plans/PLAN-00-x.md" | shasum -a 256)"; hand="${hand%% *}"
  [ "$(awk -f "$RATCHET_EXTRACT" "$d/plans/PLAN-00-x.md" | tail -c 2 | od -An -c | tr -d ' ')" = '\n\n' ] || fail "fixture section should end in a blank line"
  check_acceptance_hashes "PLAN-00 $hand" fx >/dev/null || fail "a hand-made awk|shasum stamp over a section ending in a blank line did not reproduce (the capture stripped its newlines)"
  printf '# PLAN-00\n\n## Validation and Acceptanse\n\n- x\n' > "$d/plans/PLAN-00-x.md"
  so="$(check_acceptance_hashes "$ledger" fx 2>&1)" && fail "an empty extraction passed"
  grep -qF 'EMPTY' <<< "$so" || fail "the empty extraction was not named: $so"
  # 2. the extractor boundary: a here-doc that writes a `## ` line does not end the section — the defeat pair differs
  base='## Validation and Acceptance
### Stage 1
- After setup, the fixture carries the release heading.

      Verify:
          cat > expected.md <<'"'"'FIXTURE'"'"'
## Release Notes
old expected body
FIXTURE

### Stage 2
- After submit, the system rejects unsigned releases.

      Verify:
          ./script/test.sh --require-signature
## Idempotence and Recovery
outside'
  evil="$(printf '%s\n' "$base" | sed -e 's/rejects unsigned/accepts unsigned/' -e 's|./script/test.sh --require-signature|true # neutered|')"
  hb="$(printf '%s\n' "$base" | acc_hash_stdin)"; he="$(printf '%s\n' "$evil" | acc_hash_stdin)"
  [ "$hb" != "$he" ] || fail "the here-doc defeat: Stage 2 was left outside the hash"
  printf '%s\n' "$base" | awk -f "$RATCHET_EXTRACT" | grep -qF 'require-signature' || fail "Stage 2 not extracted past the here-doc"
  printf '%s\n' "$base" | awk -f "$RATCHET_EXTRACT" | grep -qF 'outside' && fail "the real next heading did not end the section"
  fenced='## Validation and Acceptance
- x

```
## not a heading
```
- y
## Next
outside'
  printf '%s\n' "$fenced" | awk -f "$RATCHET_EXTRACT" | grep -qF -- '- y' || fail "a fenced ## ended the section"
  printf '%s\n' "$fenced" | awk -f "$RATCHET_EXTRACT" | grep -qF 'outside' && fail "the heading after a fence did not end the section"
  plain='## Validation and Acceptance
- a
## Next
- b'
  [ "$(printf '%s\n' "$plain" | awk -f "$RATCHET_EXTRACT")" = "- a" ] || fail "the plain case changed (byte-compat with the naive extractor)"
  # a longer opener is not closed by a shorter fence; chained here-docs (`<<A <<B`) both count; a fenced opener never starts the section
  printf '## Validation and Acceptance\n- a\n\n````\n```\n## Release Notes\n````\n- b\n## Next\nout\n' | awk -f "$RATCHET_EXTRACT" | grep -qF -- '- b' || fail "a triple fence closed a quadruple opener"
  printf '## Validation and Acceptance\n- a\n\n      Verify:\n          cat <<A <<B\nfirst\nA\n## Release Notes\nB\n- b\n## Next\nout\n' | awk -f "$RATCHET_EXTRACT" | grep -qF -- '- b' || fail "the second of two chained here-docs was not tracked"
  [ "$(printf '# P\n```\n## Validation and Acceptance\n```\n## Validation and Acceptance\n- real\n## Next\n' | awk -f "$RATCHET_EXTRACT")" = "- real" ] || fail "a fenced '## Validation and Acceptance' line opened the section"
  # 3. the refreeze trace over ledger CONTENTS: a changed digest needs the subject form + an amends line; a new stamp needs
  #    PLAN.md; a deleted or reformatted (tab-separated) row cannot hide; a body-only form does not count
  HA="$(printf a | shasum -a 256 | cut -c1-64)"; HB="$(printf b | shasum -a 256 | cut -c1-64)"; L0="$(printf 'PLAN-03 %s   # frozen\n' "$HA")"; L1="$(printf 'PLAN-03 %s   # frozen; re-stamped\n' "$HB")"; AD="$(printf '2026-01-01T00:00:00Z  PLAN-03  bbb  narrowed\n')"
  refreeze_trace_ok "PLAN-03 / refreeze: criterion 3.2 narrowed" "$L0" "$L1" "$AD" 0 >/dev/null || fail "a traced refreeze was refused"
  refreeze_trace_ok "note: quiet" "$L0" "$L1" "$AD" 0 >/dev/null 2>&1 && fail "a re-stamp with no refreeze form passed"
  refreeze_trace_ok "PLAN-03 / refreeze: x" "$L0" "$L1" "" 0 >/dev/null 2>&1 && fail "a re-stamp with no amends line passed"
  refreeze_trace_ok "PLAN-30 / refreeze: x" "$L0" "$L1" "$AD" 0 >/dev/null 2>&1 && fail "PLAN-30 / refreeze satisfied PLAN-03"
  refreeze_trace_ok "PLAN-03 / refreezes: x" "$L0" "$L1" "$AD" 0 >/dev/null 2>&1 && fail "a look-alike form (refreezes) passed"
  refreeze_trace_ok "note: freeze" "" "$(printf 'PLAN-04 %s   # frozen\n' "$HA")" "" 1 >/dev/null || fail "a first stamp with PLAN.md was refused"
  refreeze_trace_ok "note: freeze" "" "$(printf 'PLAN-04 %s   # frozen\n' "$HA")" "" 0 >/dev/null 2>&1 && fail "a first stamp without PLAN.md passed"
  refreeze_trace_ok "note: tidy" "$L0" "" "" 1 >/dev/null 2>&1 && fail "a DELETED stamp passed (once stamped, always stamped)"
  refreeze_trace_ok "note: reformat" "$L0" "$(printf 'PLAN-03\t%s\n' "$HB")" "" 1 >/dev/null 2>&1 && fail "a tab-separated changed row hid from the trace"
  refreeze_trace_ok "note: reformat" "$L0" "$(printf 'PLAN-03\t%s   # frozen\n' "$HA")" "" 0 >/dev/null || fail "a whitespace-only reformat of an unchanged row was refused"
  refreeze_trace_ok "$(printf 'note: same digest, comment edited')" "$L0" "$(printf 'PLAN-03 %s   # frozen 2026\n' "$HA")" "" 0 >/dev/null || fail "a comment-only ledger edit was refused"
  refreeze_trace_ok "note: x" "$L0" "$(printf 'PLAN-03 %s extra\n' "$HA")" "" 1 >/dev/null 2>&1 && fail "a malformed ledger row (a third field) was accepted"
  ledger_rows <<< "$(printf 'PLAN-03 %s extra\n' "$(printf x | shasum -a 256 | cut -c1-64)")" >/dev/null 2>&1 && fail "ledger_rows accepted a row with a stray third field"
  # 4. the docs-only classification and the count floor's skip
  is_docs_only "$(printf 'docs/LOG.md\ndocs/plans/PLAN-08-x.md\n.execplan\n')" || fail "docs-only diff not recognized"
  is_docs_only "$(printf 'docs/LOG.md\nSources/Foo.swift\n')" && fail "a source file skipped the floor"
  is_docs_only "$(printf 'AppTests/Fixtures/sample.md\n')" && fail "a test fixture .md skipped the floor"
  is_docs_only "" && fail "an empty diff counted as docs-only"
  so="$(count_floor "$(printf 'docs/LOG.md\n')" 2>&1)"; grep -qF 'skipping count floor' <<< "$so" || fail "count_floor did not skip for docs-only"
  ( cd "$d" && rm -rf cf && mkdir -p cf/script && cd cf && git init -q . && printf '#!/bin/sh\necho "A_TEST_COUNT=7"\n' > script/test.sh && chmod +x script/test.sh && printf '7\n' > .test-count && git add -A . \
    && RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" >/dev/null ) || fail "count floor at the floor failed"
  ( cd "$d/cf" && printf '8\n' > .test-count && git add -A . && RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" >/dev/null 2>&1 ) && fail "a count below the floor passed"
  ( cd "$d/cf" && printf '#!/bin/sh\necho "no marker"\n' > script/test.sh && printf '0\n' > .test-count && git add -A . && RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" >/dev/null 2>&1 ) && fail "a missing marker read as a pass"
  # 4b. --recount through the SCRIPT (a .test-count conflict at the integration merge): the marker's count becomes the floor
  #     when it is not below it — 7 → 9, 9 stays 9, a conflicted file reads as its higher side; a lower count (6 < 7), a missing
  #     marker, and a failing suite are each refused with the file untouched
  ( cd "$d" && rm -rf rc && mkdir -p rc/script && cd rc && git init -q . && cp "$RATCHET_SELF" script/ratchet.sh \
    && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/test.sh && chmod +x script/test.sh && printf '7\n' > .test-count \
    && so="$(RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount)" \
    && [ "$(cat .test-count)" = 9 ] && grep -qxF "ratchet: recount — floor 7 → 9" <<< "$so" && grep -qxF 'A_TEST_COUNT=9' <<< "$so" \
    && so="$(RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount)" \
    && [ "$(cat .test-count)" = 9 ] && grep -qxF "ratchet: recount — floor unchanged at 9" <<< "$so" \
    && printf '<<<<<<< HEAD\n7\n=======\n9\n>>>>>>> plan-31\n' > .test-count \
    && RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null && [ "$(cat .test-count)" = 9 ] \
    && printf '<<<<<<< HEAD\n7\n=======\n11\n>>>>>>> plan-31\n' > .test-count \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && grep -qx 11 .test-count \
    && printf '#!/bin/sh\necho "A_TEST_COUNT=6"\n' > script/test.sh && printf '7\n' > .test-count \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 7 ] \
    && printf '#!/bin/sh\necho "no marker"\n' > script/test.sh \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 7 ] \
    && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\nexit 1\n' > script/test.sh \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 7 ] \
    && rm -f .test-count && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/test.sh \
    && RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null && [ "$(cat .test-count)" = 9 ] ) \
    || fail "--recount: 7 → 9 and 9 → 9 must write the file and say so; a conflicted file reads as its higher side (9 resolves it, 9 < 11 leaves it); 6 < 7, no marker, and a failing suite must refuse with the file untouched; no file is floor 0"
  # 4b2. --recount INSIDE a real merge computes the floor: base + each side's change. The fork holds 1557, ours removed 9 on purpose
  #      (1548), theirs added 21 (1578): the merged floor is 1569, never the conflict's higher side (1578). 1569 passes and is written;
  #      1568 is refused with the file untouched. A side that didn't touch the file (no conflict) computes the same way; an octopus
  #      MERGE_HEAD and a missing merge base are exit 2
  ( cd "$d" && rm -rf mf && mkdir -p mf/script && cd mf && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && printf '#!/bin/sh\necho "A_TEST_COUNT=$(cat count.txt)"\n' > script/test.sh && chmod +x script/test.sh \
    && printf 'count.txt\n' > .gitignore && printf '1557\n' > .test-count && git add -A . && git commit -qm base && git branch -q -M master \
    && git checkout -qb theirs && printf '1578\n' > .test-count && git commit -qam t && git checkout -q master && printf '1548\n' > .test-count && git commit -qam o \
    && { git merge -q --no-commit theirs >/dev/null 2>&1 || true; } && [ -n "$(git ls-files -u -- .test-count)" ] \
    && echo 1568 > count.txt && ! so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" \
    && grep -qF 'merge: base 1557, ours 1548, theirs 1578 → expected 1569' <<< "$so" && grep -qF 'the merged floor 1569' <<< "$so" && grep -q '^<<<<<<< ' .test-count \
    && echo 1569 > count.txt && so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" && [ "$(cat .test-count)" = 1569 ] \
    && mh="$(git rev-parse --git-path MERGE_HEAD)" && git rev-parse HEAD >> "$mh" \
    && rc=0 && { so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" || rc=$?; } && [ "$rc" -eq 2 ] && grep -qF 'a merge of 2 other parents' <<< "$so" && [ "$(cat .test-count)" = 1569 ] \
    && git merge --abort && git checkout -qb side HEAD~1 && printf 'x\n' > x.txt && git add x.txt && git commit -qm side && git checkout -q master \
    && git merge -q --no-commit side >/dev/null 2>&1 && echo 1548 > count.txt && so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" \
    && grep -qF 'base 1557, ours 1548, theirs 1557 → expected 1548' <<< "$so" && [ "$(cat .test-count)" = 1548 ] && git merge --abort ) \
    || fail "--recount inside a merge: 1557 → 1548 / 1578 must compute 1569 (1568 refused, file untouched; 1569 written); an octopus MERGE_HEAD is exit 2; an untouched side computes the same way"
  ( cd "$d/mf" && git checkout -qf master && git checkout -q --orphan lone && git rm -rqf . >/dev/null && mkdir -p script && cp "$RATCHET_SELF" script/ratchet.sh \
    && printf '#!/bin/sh\necho "A_TEST_COUNT=$(cat count.txt)"\n' > script/test.sh && chmod +x script/test.sh && printf '3\n' > .test-count && git add -A . && git commit -qm lone \
    && { git merge -q --no-commit --allow-unrelated-histories master >/dev/null 2>&1 || true; } && echo 9999 > count.txt \
    && rc=0 && { so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" || rc=$?; } && [ "$rc" -eq 2 ] && grep -qF 'no merge base' <<< "$so" ) \
    || fail "--recount inside a merge with no merge base must be exit 2, never a guessed floor"
  # counts are decimal: zero-padded floors (base 0100, ours 0070, theirs 0101) merge to 71, never octal's 57 — so 70 (one more test
  # lost) is refused and 71 is written; and a `grep -c` that fails counting the other parents is exit 2, never a floor
  ( cd "$d" && rm -rf mo && mkdir -p mo/script && cd mo && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && printf '#!/bin/sh\necho "A_TEST_COUNT=$(cat count.txt)"\n' > script/test.sh && chmod +x script/test.sh \
    && printf 'count.txt\n' > .gitignore && printf '0100\n' > .test-count && git add -A . && git commit -qm base && git branch -q -M master \
    && git checkout -qb theirs && printf '0101\n' > .test-count && git commit -qam t && git checkout -q master && printf '0070\n' > .test-count && git commit -qam o \
    && { git merge -q --no-commit theirs >/dev/null 2>&1 || true; } \
    && echo 70 > count.txt && ! so="$(RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount 2>&1)" && grep -qF 'base 100, ours 70, theirs 101 → expected 71' <<< "$so" \
    && echo 71 > count.txt && RATCHET_TEST_CMD=./script/test.sh bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 71 ] ) \
    || fail "zero-padded floors must merge as decimal: 0100 / 0070 / 0101 → 71 (70 refused, 71 written)"
  mkdir -p "$d/fakegrepc"
  printf '#!/bin/sh\n[ "$1" = -c ] && [ "$2" = . ] && { echo 1; exit 73; }\nexec %s "$@"\n' "$(command -v grep)" > "$d/fakegrepc/grep"; chmod +x "$d/fakegrepc/grep"
  rc=0; ( cd "$d/mo" && PATH="$d/fakegrepc:$PATH" merge_floor "$(git rev-parse theirs)" >/dev/null 2>&1 ) || rc=$?
  [ "$rc" -eq 2 ] || fail "a grep that fails counting the merge's other parents must be exit 2, never a floor (rc=$rc)"
  ( cd "$d/mo" && git merge --abort ) >/dev/null 2>&1 || true
  # 4b3. the LOG merge driver (merge_log): both sides' entries newest first, each once; a timestamp tie puts ours first; the preamble
  #      changed on one side is taken; a base entry edited on one side falls back to git merge-file (markers, non-zero); a missing
  #      input is exit 2 with ours untouched; ours' missing final newline is kept
  ml="$d/ml"; mkdir -p "$ml"
  pre='# LOG\n\nintro\n\n---\n\n'; e1='## 2026-09-01T00:00:00Z — p / a\nbase one\n\n- item\n'; e2='## 2026-08-01T00:00:00Z — p / b\nbase two\n'
  printf "$pre$e1\n$e2" > "$ml/b"
  printf "$pre"'## 2026-09-03T00:00:00Z — p / ours\nours new\n\n## 2026-09-02T00:00:00Z — p / tie\nours tie\n\n## 2026-09-05T00:00:00Z — p / both\nshared\n\n'"$e1\n$e2" > "$ml/o"
  printf "$pre"'## 2026-09-05T00:00:00Z — p / both\nshared\n\n## 2026-09-04T00:00:00Z — p / theirs\ntheirs new\n\n## 2026-09-02T00:00:00Z — p / tie\ntheirs tie\n\n'"$e1\n$e2" > "$ml/t"
  merge_log "$ml/b" "$ml/o" "$ml/t" 2>/dev/null || fail "merge-log: an append-only three-way merge was refused"
  want="$(printf "$pre"'## 2026-09-04T00:00:00Z — p / theirs\ntheirs new\n\n## 2026-09-03T00:00:00Z — p / ours\nours new\n\n## 2026-09-02T00:00:00Z — p / tie\nours tie\n\n## 2026-09-05T00:00:00Z — p / both\nshared\n\n## 2026-09-02T00:00:00Z — p / tie\ntheirs tie\n\n'"$e1\n$e2"; printf x)"
  got="$(cat "$ml/o"; printf x)"
  [ "$got" = "$want" ] || fail "merge-log: the interleave is wrong (ours' own order kept, theirs merged in by time, the shared entry once, a tie ours first): $(diff <(printf '%s' "$want") <(printf '%s' "$got"))"
  printf "$pre$e1\n$e2" > "$ml/b"; printf '# LOG (renamed)\n\n---\n\n'"$e1\n$e2" > "$ml/o"; printf "$pre"'## 2026-09-04T00:00:00Z — p / t\nt\n\n'"$e1\n$e2" > "$ml/t"
  merge_log "$ml/b" "$ml/o" "$ml/t" 2>/dev/null && grep -qx '# LOG (renamed)' "$ml/o" && grep -qF 'p / t' "$ml/o" || fail "merge-log: a preamble changed on one side must be taken"
  printf "$pre$e1\n$e2" > "$ml/b"; printf "$pre"'## 2026-09-04T00:00:00Z — p / o\no\n\n'"$(printf "$e1" | sed 's/base one/base one, rewritten/')\n\n$e2" > "$ml/o"
  printf "$pre"'## 2026-09-04T00:00:00Z — p / t\nt\n\n'"$e1\n$e2" > "$ml/t"
  rc=0; merge_log "$ml/b" "$ml/o" "$ml/t" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] && grep -q '^<<<<<<< ours' "$ml/o" || fail "merge-log: a rewritten base entry must fall back to git merge-file with markers and a non-zero status (rc=$rc)"
  printf "$pre$e1" > "$ml/o"; cp "$ml/o" "$ml/o.keep"; rc=0; merge_log "$ml/nope" "$ml/o" "$ml/t" 2>/dev/null || rc=$?
  [ "$rc" -eq 2 ] && cmp -s "$ml/o" "$ml/o.keep" || fail "merge-log: an unreadable base must be exit 2 with ours untouched (rc=$rc)"
  printf "$pre"'## 2026-09-01T00:00:00Z — p / a\nno newline' > "$ml/b"; cp "$ml/b" "$ml/o"; printf "$pre"'## 2026-09-04T00:00:00Z — p / t\nt\n\n## 2026-09-01T00:00:00Z — p / a\nno newline' > "$ml/t"
  merge_log "$ml/b" "$ml/o" "$ml/t" 2>/dev/null && [ "$(tail -c 7 "$ml/o")" = newline ] && grep -qF 'p / t' "$ml/o" || fail "merge-log: ours' missing final newline must be kept"
  # a timestamp-shaped heading inside a fenced example is part of its entry, never a boundary: theirs' real entry lands after the
  # whole example (the fence stays closed around its quoted heading); a fence left open at the end falls back to git merge-file
  printf '# LOG\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > "$ml/b"
  printf '# LOG\n\n## 2026-09-04T00:00:00Z — p / ex\nExample:\n  ~~~~markdown\n\n## 2026-09-02T00:00:00Z — example / quoted\n~~~\nstill quoted\n  ~~~~\nend\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > "$ml/o"
  printf '# LOG\n\n## 2026-09-03T00:00:00Z — p / real\nreal\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > "$ml/t"
  merge_log "$ml/b" "$ml/o" "$ml/t" 2>/dev/null || fail "merge-log: a fenced example entry was refused"
  got="$(awk '/^## 20/ { print $2 }' "$ml/o" | tr '\n' ' ')"
  [ "$got" = "2026-09-04T00:00:00Z 2026-09-02T00:00:00Z 2026-09-03T00:00:00Z 2026-09-01T00:00:00Z " ] && grep -q '^end$' "$ml/o" \
    && [ "$(awk '/^end$/ { e = NR } /p \/ real/ { r = NR } END { print (e < r) }' "$ml/o")" = 1 ] \
    || fail "merge-log: a heading inside a fence must stay inside its entry, and theirs' entry must land after the whole example: $got"
  printf '# LOG\n\n## 2026-09-04T00:00:00Z — p / open\n```\nnever closed\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > "$ml/o"
  rc=0; merge_log "$ml/b" "$ml/o" "$ml/t" 2>"$ml/err" || rc=$?
  [ "$rc" -ne 0 ] && grep -qF 'a code fence is left open' "$ml/err" && grep -q '^<<<<<<< ours' "$ml/o" || fail "merge-log: a fence left open at the end must fall back to git merge-file (rc=$rc)"
  # 4c. --recount's readers are captured and checked, never piped: a `sort -n | tail -1` (floor_read) and a `sed … | tail -1`
  #     (suite_count) each dropped the left side's status under set -eu without pipefail — a sort that printed the LOWER side of a
  #     7/11 conflict before exiting 73 read as floor 7 and let a count of 9 lower the floor. The two fakes act only on the one argv
  #     they are keyed to (sort's -n, sed's TEST_COUNT= pattern); every other call reaches the real tool. Also: an unreadable floor
  #     file (mode 000, where not root) and a file with no integer line each refuse with nothing written
  mkdir -p "$d/fakesort" "$d/fakesed"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = -n ] && { echo 7; exit 73; }; done\nexec %s "$@"\n' "$(command -v sort)" > "$d/fakesort/sort"
  printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *TEST_COUNT=*) echo 9; exit 73 ;; esac; done\nexec %s "$@"\n' "$(command -v sed)" > "$d/fakesed/sed"
  chmod +x "$d/fakesort/sort" "$d/fakesed/sed"
  ( cd "$d/rc" && printf '<<<<<<< HEAD\n7\n=======\n11\n>>>>>>> plan-31\n' > .test-count \
    && [ "$(PATH="$d/fakesort:$PATH" RATCHET_TEST_COUNT_FILE=.test-count floor_read)" = 11 ] ) \
    || fail "floor_read over a 7/11 conflict, with a sort that prints 7 and exits 73 on PATH, did not read 11 (the higher side, by bash alone)"
  ( cd "$d/rc" && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/test.sh && rc=0 \
    && { PATH="$d/fakesed:$PATH" RATCHET_TEST_CMD=./script/test.sh suite_count >/dev/null 2>&1 || rc=$?; } && [ "$rc" -eq 1 ] ) \
    || fail "suite_count with a sed that prints 9 and exits 73 on PATH read a count (must fail, exit 1)"
  ( cd "$d/rc" && printf '<<<<<<< HEAD\n7\n=======\n11\n>>>>>>> plan-31\n' > .test-count \
    && ! PATH="$d/fakesort:$PATH" RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && grep -qx 11 .test-count \
    && printf '7\n' > .test-count \
    && ! PATH="$d/fakesed:$PATH" RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 7 ] \
    && printf 'abc\n\n' > .test-count \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = abc ] ) \
    || fail "--recount: a sort that fails after printing the lower side must not lower the floor (the 7/11 conflict stays); a sed that fails after printing a count must not read as one (7 stays); a floor file with no integer line refuses unchanged"
  if [ "$(id -u)" -ne 0 ]; then
    ( cd "$d/rc" && printf '7\n' > .test-count && chmod 000 .test-count && rc=0 \
      && { RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 || rc=$?; } \
      && chmod 644 .test-count && [ "$rc" -ne 0 ] && [ "$(cat .test-count)" = 7 ] ) \
      || fail "--recount over an unreadable (mode 000) floor file must refuse with nothing written"
  fi
  # 4d. a floor line `[` cannot compare is a refusal, never the LOWER side: over rows 7 and a 24-digit line the old loop's `[ n -gt max ]`
  #     tripped (exit 2), its `if` read that as "not greater", and floor 7 let a count of 9 lower the floor. floor_read caps a line at 18
  #     digits (both ways: 18 read, 19 refused) and reads the comparison three ways; --recount refuses with the file untouched
  BIG=999999999999999999999999; D18=999999999999999999; D19=9999999999999999999
  ( cd "$d/rc" && printf '7\n%s\n' "$BIG" > .test-count && rc=0 && { so="$(RATCHET_TEST_COUNT_FILE=.test-count floor_read 2>&1)" || rc=$?; } \
    && [ "$rc" -eq 1 ] && grep -qF 'malformed floor line' <<< "$so" && ! grep -qx 7 <<< "$so" \
    && printf '7\n%s\n' "$D18" > .test-count && [ "$(RATCHET_TEST_COUNT_FILE=.test-count floor_read)" = "$D18" ] \
    && printf '7\n%s\n' "$D19" > .test-count && rc=0 && { RATCHET_TEST_COUNT_FILE=.test-count floor_read >/dev/null 2>&1 || rc=$?; } && [ "$rc" -eq 1 ] ) \
    || fail "floor_read over rows 7 and a 24-digit line must refuse naming the malformed line (never read 7); an 18-digit line reads, a 19-digit one refuses"
  ( cd "$d/rc" && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/test.sh && printf '7\n%s\n' "$BIG" > .test-count \
    && ! RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && grep -qxF "$BIG" .test-count && grep -qx 7 .test-count \
    && rc=0 && { RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" >/dev/null 2>&1 || rc=$?; } && [ "$rc" -ne 0 ] ) \
    || fail "--recount and count_floor over a floor file holding 7 and a 24-digit line must refuse with the file unchanged (a count of 9 lowered it once)"
  # 4e. count_floor reads the floor through floor_read, never `cat … || echo 0`: a floor read that fails is a refusal, never floor 0 (a cat exiting
  #     73 once read as 0 and a count of 9 passed). The fakes act only on the floor's argv — cat's `.test-count`, grep's `^[0-9]+$` pattern:
  #     BOTH readers, so a regression to either unchecked form trips; an unreadable (mode 000, where not root) floor file refuses the same way.
  #     And suite_count checks its mktemp: one that prints a path and exits 73 is a refusal naming mktemp (exit 1), never a count read through
  #     the path it printed — in the function and through --recount, the floor file untouched
  mkdir -p "$d/fakecat" "$d/fakegrep" "$d/fakemktemp"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = .test-count ] && { echo "cat: injected failure" >&2; exit 73; }; done\nexec %s "$@"\n' "$(command -v cat)" > "$d/fakecat/cat"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "^[0-9]+$" ] && { echo 7; exit 73; }; done\nexec %s "$@"\n' "$(command -v grep)" > "$d/fakegrep/grep"
  printf '#!/bin/sh\necho "%s/mktemp-out"; exit 73\n' "$d" > "$d/fakemktemp/mktemp"
  chmod +x "$d/fakecat/cat" "$d/fakegrep/grep" "$d/fakemktemp/mktemp"
  ( cd "$d/rc" && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/test.sh && printf '7\n' > .test-count && rc=0 \
    && { so="$(PATH="$d/fakecat:$d/fakegrep:$PATH" RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" 2>&1)" || rc=$?; } \
    && [ "$rc" -ne 0 ] && ! grep -qF 'test count' <<< "$so" ) \
    || fail "count_floor with the floor's reader failing on PATH (cat exit 73 with no output; grep printing 7 then exit 73) read a floor (must refuse, never 0)"
  if [ "$(id -u)" -ne 0 ]; then
    ( cd "$d/rc" && printf '7\n' > .test-count && chmod 000 .test-count && rc=0 \
      && { RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count count_floor "$(printf 'Sources/a.swift\n')" >/dev/null 2>&1 || rc=$?; } \
      && chmod 644 .test-count && [ "$rc" -ne 0 ] ) \
      || fail "count_floor over an unreadable (mode 000) floor file read a floor (must refuse, never 0)"
  fi
  ( cd "$d/rc" && rc=0 && { so="$(PATH="$d/fakemktemp:$PATH" RATCHET_TEST_CMD=./script/test.sh suite_count 2>&1)" || rc=$?; } \
    && [ "$rc" -eq 1 ] && grep -qF 'mktemp failed' <<< "$so" && [ ! -e "$d/mktemp-out" ] \
    && printf '7\n' > .test-count \
    && ! PATH="$d/fakemktemp:$PATH" RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh --recount >/dev/null 2>&1 && [ "$(cat .test-count)" = 7 ] ) \
    || fail "suite_count with a mktemp that prints a path and exits 73 on PATH read a count (must refuse naming mktemp, exit 1, nothing written; --recount leaves 7)"
  # 4f. one suite run per stage commit: --recount records the run on the TESTED tree; the floor reuses it while the INDEX being committed
  #     holds exactly that code (the LOG, the plan, and the floor bump written after the run don't count), re-runs on any staged code change
  #     (a new file, an edit), never passes on a stale or malformed record, and treats a failing fingerprint — one that prints the matching
  #     value and then fails included — as an error: no reuse, no record. A run counter outside the repo proves which path ran
  realgit="$(command -v git)"; mkdir -p "$d/fakegit" && printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = hash-object ] && { [ -n "${FAKE_FP:-}" ] && echo "$FAKE_FP"; exit 73; }; done\nexec %s "$@"\n' "$realgit" > "$d/fakegit/git" && chmod +x "$d/fakegit/git"
  ( cd "$d" && rm -rf sr && mkdir -p sr/script sr/Sources sr/docs/plans && cd sr && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\necho run >> "%s/sr-runs"\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
    && printf 'let a = 1\n' > Sources/a.swift && printf '# LOG\n' > docs/LOG.md && printf '7\n' > .test-count && git add -A . && git commit -qm init && : > "$d/sr-runs" \
    && export RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count \
    && runs() { grep -c run "$d/sr-runs" || true; } && rec="$(git rev-parse --git-path ratchet-suite-run)" \
    && bash script/ratchet.sh --recount >/dev/null && [ "$(runs)" = 1 ] && [ "$(cat .test-count)" = 9 ] && [ -s "$rec" ] \
    && printf '\n## entry\nx\n' >> docs/LOG.md && printf '# PLAN-01\n' > docs/plans/PLAN-01-x.md && git add -A . \
    && so="$(count_floor "$(printf 'Sources/a.swift\ndocs/LOG.md\n')")" && [ "$(runs)" = 1 ] && grep -qF 'not re-run' <<< "$so" \
    && RATCHET_SKIP_COUNT_FLOOR= bash script/ratchet.sh >/dev/null && [ "$(runs)" = 1 ] \
    && fp="$(code_fingerprint index)" && PATH="$d/fakegit:$PATH" FAKE_FP="$fp" count_floor "Sources/a.swift" >/dev/null && [ "$(runs)" = 2 ] \
    && printf 'let b = 2\n' > Sources/b.swift && count_floor "Sources/a.swift" >/dev/null && [ "$(runs)" = 2 ] \
    && git add Sources/b.swift && count_floor "Sources/a.swift" >/dev/null && [ "$(runs)" = 3 ] && git rm -q --cached Sources/b.swift && rm Sources/b.swift \
    && printf 'let a = 2\n' > Sources/a.swift && git add Sources/a.swift && count_floor "Sources/a.swift" >/dev/null && [ "$(runs)" = 4 ] \
    && printf '#!/bin/sh\necho run >> "%s/sr-runs"\necho "A_TEST_COUNT=9"\nexit 1\n' "$d" > script/test.sh && git add script/test.sh \
    && ! count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(runs)" = 5 ] \
    && printf '%s 9\n' "$(code_fingerprint index)" > "$rec" && count_floor "Sources/a.swift" >/dev/null && [ "$(runs)" = 5 ] \
    && printf '%s 5\n' "$(code_fingerprint index)" > "$rec" && ! count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(runs)" = 5 ] \
    && printf 'zz%s 9\n' "$(code_fingerprint index)" > "$rec" && ! count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(runs)" = 6 ] \
    && printf '%s 9x\n' "$(code_fingerprint index)" > "$rec" && ! count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(runs)" = 7 ] \
    && printf '#!/bin/sh\necho run >> "%s/sr-runs"\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && git add script/test.sh \
    && rc=0 && { PATH="$d/fakegit:$PATH" bash script/ratchet.sh --recount >/dev/null 2>&1 || rc=$?; } && [ "$rc" -eq 2 ] && [ ! -e "$rec" ] && [ "$(runs)" = 8 ] \
    && printf '#!/bin/sh\necho run >> "%s/sr-runs"\necho "let a = 3" > Sources/a.swift\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh \
    && so="$(bash script/ratchet.sh --recount)" && grep -qF 'changed while the suite ran' <<< "$so" && [ ! -e "$rec" ] && [ "$(runs)" = 9 ] ) \
    || fail "the suite-run record: --recount records, the floor reuses it past LOG / plan / floor edits (function and hook) and past an unstaged file the commit leaves out, and re-runs on a failing fingerprint (even one printing the matching value), a staged new file, a staged code edit; a stale record with a failing suite, a matching record under the floor, and a malformed record never pass; --recount leaves no record when the fingerprint fails (exit 2) or the code changed during the run"
  # 4g. the record is compared against the COMMIT (codex round 1, v0.19): two dependent changes tested together, only one staged → the suite
  #     runs (the working-tree reading reused the run for an untested commit); both staged → reused. A tracked file an ignore rule now matches
  #     stays in the tested fingerprint (an EMPTY throwaway index dropped it: a change to it after the run could not be seen), and the normal flow
  #     over such a file still reuses. The floor the commit carries is read from the INDEX: a working copy edited below it never loosens the check
  ( cd "$d" && rm -rf sr2 && mkdir -p sr2/script sr2/Sources && cd sr2 && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\necho run >> "%s/sr2-runs"\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
    && printf 'let a = 1\n' > Sources/a.swift && printf '7\n' > .test-count && git add -A . && git commit -qm init && : > "$d/sr2-runs" \
    && export RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count && runs2() { grep -c run "$d/sr2-runs" || true; } \
    && printf 'let a = 2\n' > Sources/a.swift && printf 'let b = a\n' > Sources/b.swift \
    && bash script/ratchet.sh --recount >/dev/null && [ "$(runs2)" = 1 ] \
    && git add Sources/a.swift .test-count && count_floor "Sources/a.swift" >/dev/null && [ "$(runs2)" = 2 ] \
    && git add Sources/b.swift && count_floor "Sources/a.swift" >/dev/null && [ "$(runs2)" = 2 ] && git commit -qm two \
    && printf 'gen 1\n' > Sources/gen.swift && git add Sources/gen.swift && git commit -qm gen && printf 'Sources/gen.swift\n' > .gitignore && git add .gitignore && git commit -qm ignore \
    && f1="$(code_fingerprint)" && printf 'gen 2\n' > Sources/gen.swift && f2="$(code_fingerprint)" && [ -n "$f1" ] && [ "$f1" != "$f2" ] \
    && bash script/ratchet.sh --recount >/dev/null && [ "$(runs2)" = 3 ] && git add Sources/gen.swift .test-count && count_floor "Sources/gen.swift" >/dev/null && [ "$(runs2)" = 3 ] \
    && printf '12\n' > .test-count && git add .test-count && printf '7\n' > .test-count && ! count_floor "Sources/gen.swift" >/dev/null 2>&1 && [ "$(runs2)" = 3 ] ) \
    || fail "the record against the commit: a partial staging of two changes tested together must run the suite (both staged: reused); a tracked file an ignore rule matches must stay in the tested fingerprint (its change seen; the normal flow still reuses); a staged floor of 12 must refuse a count of 9 when the working copy reads 7"
  # 4h. the fingerprint leaves out ONLY the record files the ritual writes after the run (codex round 1, v0.19): a root `check.md` the suite
  #     reads, or any other markdown, changed after the recount → the suite runs; the LOG, a plan file, PLAN.md, and .test-count → reused
  is_record_path docs/LOG.md && is_record_path docs/plans/PLAN-01-x.md && is_record_path docs/plans/PLAN-01-review/MANIFEST.md \
    && is_record_path PLAN.md && is_record_path .test-count || fail "is_record_path: the LOG, a plan file, a review file, PLAN.md, .test-count must be records"
  is_record_path check.md || is_record_path README.md || is_record_path docs/ARCHITECTURE.md || is_record_path Tests/Fixtures/a.md || is_record_path LOG.md \
    && fail "is_record_path: a root .md, a docs/ file that is not the LOG or a plan, a fixture, or a Lite-shaped LOG.md under the Standard config counted as a record"
  ( RATCHET_PLANS_DIR=; RATCHET_LOG=LOG.md; is_record_path LOG.md && is_record_path PLAN.md && ! is_record_path docs/plans/PLAN-01-x.md ) \
    || fail "is_record_path under Lite (empty plans dir, LOG.md): the LOG and PLAN.md are records; a docs/plans path is not"
  ( cd "$d" && rm -rf sr4 && mkdir -p sr4/script sr4/Sources sr4/docs/plans && cd sr4 && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\necho run >> "%s/sr4-runs"\ngrep -q ok check.md || exit 1\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
    && printf 'ok\n' > check.md && printf 'let a = 1\n' > Sources/a.swift && printf '# LOG\n' > docs/LOG.md && printf '# arch\n' > docs/ARCHITECTURE.md \
    && printf '| PLAN-01 |\n' > PLAN.md && printf '7\n' > .test-count && git add -A . && git commit -qm init && : > "$d/sr4-runs" \
    && export RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count && runs4() { grep -c run "$d/sr4-runs" || true; } \
    && bash script/ratchet.sh --recount >/dev/null && [ "$(runs4)" = 1 ] \
    && printf '\n## entry\n' >> docs/LOG.md && printf '# PLAN-01\n' > docs/plans/PLAN-01-x.md && printf '| PLAN-01 | in-progress |\n' > PLAN.md && git add -A . \
    && count_floor "$(printf 'Sources/a.swift\ndocs/LOG.md\n')" >/dev/null && [ "$(runs4)" = 1 ] \
    && printf 'bad\n' > check.md && git add check.md && ! count_floor "$(printf 'Sources/a.swift\ncheck.md\n')" >/dev/null 2>&1 && [ "$(runs4)" = 2 ] \
    && printf 'ok\n' > check.md && git add check.md && bash script/ratchet.sh --recount >/dev/null && [ "$(runs4)" = 3 ] \
    && printf '# arch, edited\n' > docs/ARCHITECTURE.md && git add -A . && count_floor "Sources/a.swift" >/dev/null && [ "$(runs4)" = 4 ] ) \
    || fail "the fingerprint's exclusions: a LOG / plan / PLAN.md / .test-count change after the recount must reuse; a root check.md the suite reads (failing after the run) or another docs/ markdown file must run the suite"
  # 4i. no matching record: the suite runs on the COMMIT (codex round 1, v0.19). A change staged alone whose tests fail, beside an UNSTAGED
  #     change that makes them pass: the working-tree run passed an untested commit — now the staged tree runs in a throwaway worktree and
  #     the commit is refused, the worktree removed, and the hook's own index (GIT_INDEX_FILE) never touched; fully staged, the suite runs in
  #     place (no worktree); a worktree that cannot be made is a refusal, never a pass
  realgit2="$(command -v git)"; mkdir -p "$d/fakewt" && printf '#!/bin/sh\n[ "$1" = worktree ] && [ "$2" = add ] && exit 73\nexec %s "$@"\n' "$realgit2" > "$d/fakewt/git" && chmod +x "$d/fakewt/git"
  ( cd "$d" && rm -rf sr5 && mkdir -p sr5/script sr5/Sources && cd sr5 && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\npwd -P >> "%s/sr5-where"\n[ "$(cat Sources/a.swift)" = "$(cat Sources/b.swift)" ] || { echo "a and b disagree"; exit 1; }\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
    && printf 'v1\n' > Sources/a.swift && printf 'v1\n' > Sources/b.swift && printf '7\n' > .test-count && git add -A . && git commit -qm init \
    && export RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count && root="$(pwd -P)" && : > "$d/sr5-where" \
    && printf 'v2\n' > Sources/a.swift && printf 'v2\n' > Sources/b.swift && git add Sources/a.swift \
    && ! count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(tail -1 "$d/sr5-where")" != "$root" ] && [ -s "$d/sr5-where" ] \
    && [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] \
    && ! RATCHET_SKIP_COUNT_FLOOR= bash script/ratchet.sh >/dev/null 2>&1 \
    && alt="$d/sr5-alt-index" && cp -p "$(git rev-parse --git-path index)" "$alt" && sum1="$(cksum < "$alt")" \
    && ! GIT_INDEX_FILE="$alt" count_floor "Sources/a.swift" >/dev/null 2>&1 && [ "$(cksum < "$alt")" = "$sum1" ] \
    && rc=0 && { so="$(PATH="$d/fakewt:$PATH" count_floor "Sources/a.swift" 2>&1)" || rc=$?; } && [ "$rc" -ne 0 ] && grep -qF 'worktree add failed' <<< "$so" \
    && git add Sources/b.swift && : > "$d/sr5-where" && count_floor "Sources/a.swift" >/dev/null && [ "$(tail -1 "$d/sr5-where")" = "$root" ] \
    && [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] ) \
    || fail "the suite on the commit: a staged change whose tests fail alone beside an unstaged change that makes them pass must be refused (tested in a throwaway worktree, removed after; through the script too; a hook's GIT_INDEX_FILE left byte-identical; a worktree that cannot be made refuses); fully staged, the suite runs in place"
  # 4j. the staged run's worktree is removed on EVERY path (codex + Grok round 2, v0.19 — Grok left one registered with a Ctrl-C): a SIGINT
  #     or a TERM to the run's process group while its suite runs leaves no registered worktree and no directory
  for sig in INT TERM; do
    ( cd "$d" && rm -rf sr6 && mkdir -p sr6/script sr6/Sources && cd sr6 && git init -q . && git config user.email t@t && git config user.name t \
      && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
      && printf '#!/bin/sh\npwd -P > "%s/sr6-wt"\nsleep 30\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
      && printf 'v1\n' > Sources/a.swift && printf 'v1\n' > Sources/b.swift && printf '7\n' > .test-count && git add -A . && git commit -qm init \
      && printf 'v2\n' > Sources/a.swift && printf 'v2\n' > Sources/b.swift && git add Sources/a.swift && rm -f "$d/sr6-wt" \
      && set -m && { env -u RATCHET_TEST_CMD RATCHET_TEST_COUNT_FILE=.test-count bash script/ratchet.sh >/dev/null 2>&1 & } && pid=$! && set +m \
      && i=0 && while [ ! -s "$d/sr6-wt" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done && [ -s "$d/sr6-wt" ] \
      && kill -"$sig" -- -"$pid" && { wait "$pid" 2>/dev/null || true; } && wtp="$(cat "$d/sr6-wt")" \
      && i=0 && while { [ -e "$wtp" ] || [ "$(git worktree list | wc -l | tr -d ' ')" != 1 ]; } && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done \
      && [ ! -e "$wtp" ] && [ ! -e "$(dirname "$wtp")" ] && [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] ) \
      || fail "the staged run's worktree must be removed on SIG$sig to the run (no registered worktree, no directory left)"
  done
  # 4k. the staged run uses the STAGED checkout's test command (codex round 2, v0.19): a staged ratchet.conf naming a failing command beside a
  #     working conf naming a passing one, partially staged → refused (the working conf's command once tested the staged tree); fully staged → runs in place
  ( cd "$d" && rm -rf sr7 && mkdir -p sr7/script sr7/Sources && cd sr7 && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\necho "A_TEST_COUNT=9"\n' > script/pass.sh && printf '#!/bin/sh\necho "the staged command"; exit 1\n' > script/fail.sh && chmod +x script/pass.sh script/fail.sh \
    && printf 'RATCHET_TEST_CMD=./script/pass.sh\n' > script/ratchet.conf && printf 'v1\n' > Sources/a.swift && printf '7\n' > .test-count && git add -A . && git commit -qm init \
    && printf 'RATCHET_TEST_CMD=./script/fail.sh\n' > script/ratchet.conf && git add script/ratchet.conf && printf 'RATCHET_TEST_CMD=./script/pass.sh\n' > script/ratchet.conf \
    && ! env -u RATCHET_TEST_CMD bash script/ratchet.sh >/dev/null 2>&1 && [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] \
    && printf 'v2\n' > Sources/a.swift && git add -A . && env -u RATCHET_TEST_CMD bash script/ratchet.sh >/dev/null 2>&1 ) \
    || fail "the staged run must use the STAGED ratchet.conf's test command (staged failing, working passing, partially staged → refused; fully staged → passes)"
  # 4l. submodules (Grok round 2, v0.19, reproduced): a run over a DIRTY submodule is never recorded, and the commit's floor tests the staged
  #     gitlink in a throwaway worktree, submodules initialized — refused when that fails; a clean submodule at its recorded commit still reuses
  ( cd "$d" && rm -rf sr8 sr8sub && mkdir -p sr8sub sr8/script && cd sr8sub && git init -q . && git config user.email t@t && git config user.name t \
    && printf 'broken\n' > lib.txt && git add lib.txt && git commit -qm sub && cd "$d/sr8" && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$RATCHET_SELF" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '#!/bin/sh\necho run >> "%s/sr8-runs"\ngrep -q fixed vendor/lib.txt || exit 1\necho "A_TEST_COUNT=9"\n' "$d" > script/test.sh && chmod +x script/test.sh \
    && export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always \
    && git submodule add -q "$d/sr8sub" vendor >/dev/null 2>&1 && printf '7\n' > .test-count && git add -A . && git commit -qm init \
    && export RATCHET_TEST_CMD=./script/test.sh RATCHET_TEST_COUNT_FILE=.test-count && runs8() { grep -c run "$d/sr8-runs" 2>/dev/null || true; } \
    && rec="$(git rev-parse --git-path ratchet-suite-run)" && : > "$d/sr8-runs" \
    && printf 'fixed\n' > vendor/lib.txt && so="$(bash script/ratchet.sh --recount)" && [ ! -e "$rec" ] && grep -qF 'submodule' <<< "$so" && [ "$(runs8)" = 1 ] \
    && git add .test-count && ! count_floor ".test-count" >/dev/null 2>&1 && [ "$(runs8)" = 2 ] && [ "$(git worktree list | wc -l | tr -d ' ')" = 1 ] \
    && git -C vendor -c user.email=t@t -c user.name=t commit -qam fixed && git add vendor && bash script/ratchet.sh --recount >/dev/null && [ -s "$rec" ] && [ "$(runs8)" = 3 ] \
    && so="$(count_floor "vendor")" && grep -qF 'not re-run' <<< "$so" && [ "$(runs8)" = 3 ] ) \
    || fail "submodules: a run over a dirty submodule must not be recorded and the floor must test the staged gitlink (refused); a clean submodule at its recorded commit must reuse the run"
  # 4m. the tested fingerprint sees a same-second, same-size edit (both reviews asked for a probe that proves it, round 2): the throwaway index
  #     is seeded with `cp -p`, so git's racy-clean check behaves as on the real index — a plain copy's newer mtime makes an edit made in the same
  #     second as the last `git add` read as unchanged (reproduced 5/5 with Apple git on APFS; a git that compares nanoseconds may pass either way)
  ( cd "$d" && rm -rf sr9 && mkdir -p sr9 && cd sr9 && git init -q . && git config user.email t@t && git config user.name t \
    && printf 'aaaa\n' > f && git add f && git commit -qm init && ok=0 && tries=0 \
    && while [ "$ok" = 0 ] && [ "$tries" -lt 5 ]; do
         tries=$((tries+1)); s0="$(date +%s)"; while [ "$(date +%s)" = "$s0" ]; do sleep 0.05; done
         s1="$(date +%s)"; printf 'aaab\n' > f; git add f; printf 'aaac\n' > f; [ "$(date +%s)" = "$s1" ] && ok=1 || true
       done && [ "$ok" = 1 ] \
    && s2="$(date +%s)" && while [ "$(date +%s)" = "$s2" ]; do sleep 0.05; done \
    && fi="$(code_fingerprint index)" && ft="$(code_fingerprint)" && [ -n "$fi" ] && [ -n "$ft" ] && [ "$fi" != "$ft" ] ) \
    || fail "the tested fingerprint missed a same-second, same-size edit (the throwaway index must be seeded with cp -p)"
  # 5. skip markers: an unlisted skip trips, a listed one passes, a clean line does not (scope — test files only — is the caller's)
  D="$(printf -- 'diff --git ATests.swift ATests.swift\n--- ATests.swift\n+++ ATests.swift\n@@ -0,0 +1 @@\n+    XCTSkip("flaky")   // in testFooBar\n')"
  skip_scan "$D" "testOther" >/dev/null 2>&1 && fail "an unlisted skip passed"
  skip_scan "$D" "- testFooBar (flaky, DEC-3)" >/dev/null || fail "a listed skip was refused"
  skip_scan "$D" "- testFoo (other)" >/dev/null 2>&1 && fail "an allowlist entry for testFoo covered testFooBar (prefix match)"
  skip_scan "$(printf -- 'diff --git x x\n--- x\n+++ x\n@@ -0,0 +1 @@\n+let y = 1\n')" "" >/dev/null || fail "a clean added line tripped"
  rc=0; ( RATCHET_SKIP_REGEX='(' skip_scan "$D" "" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a grep error in the skip scan did not surface as an error (rc=$rc)"
  # 6. secrets: a key file, a private-key line, a token; the allow marker; clean lines
  secret_scan "$(printf 'Sources/a.swift\ncerts/dev.p12\n')" "" >/dev/null 2>&1 && fail "a .p12 passed"
  secret_scan "$(printf 'config/.env\n')" "" >/dev/null 2>&1 && fail "an .env passed"
  secret_scan "" "$(printf -- 'diff --git a.swift a.swift\n--- a.swift\n+++ a.swift\n@@ -0,0 +1 @@\n++AKIAABCDEFGHIJKLMNOP\n')" >/dev/null 2>&1 && fail "an added line whose content starts with + escaped the scan"   # ratchet:allow-secret
  secret_scan "" "$(printf -- 'diff --git a.swift a.swift\n--- a.swift\n+++ a.swift\n@@ -0,0 +1 @@\n+let k = "AKIAABCDEFGHIJKLMNOP" // ratchet:allow-secret was here, not at the end\n')" >/dev/null 2>&1 && fail "the allow marker counted mid-line"   # ratchet:allow-secret
  # a `-- previous` → `++ AKIA…` replacement pair looks like a --- / +++ header to a naive parser; hunk state keeps it content
  secret_scan "" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -1 +1 @@\n--- previous\n+++ AKIAABCDEFGHIJKLMNOP\n')" >/dev/null 2>&1 && fail "a removed '-- x' / added '++ y' pair (rendered ---/+++) hid a credential"   # ratchet:allow-secret
  [ "$(added_lines <<< "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -1 +1 @@\n--- previous\n+++ content\n')")" = "++ content" ] || fail "added_lines dropped a hunk line that looks like a file header"
  rc=0; ( RATCHET_SECRET_REGEX='(' secret_scan "" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -0,0 +1 @@\n+x\n')" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a grep error in the secret scan did not surface as an error (rc=$rc)"
  # (each probe's source line carries the allow marker in a trailing comment — outside the printf payload — so committing
  # THIS file through a wired hook is not refused by the scan it defines; the payload the probe feeds has no marker)
  secret_scan "Sources/a.swift" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -0,0 +1,2 @@\n+-----BEGIN RSA PRIVATE KEY-----\n')" >/dev/null 2>&1 && fail "a private key line passed"   # ratchet:allow-secret
  secret_scan "Sources/a.swift" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -0,0 +1,2 @@\n+let k = "AKIAABCDEFGHIJKLMNOP"\n')" >/dev/null 2>&1 && fail "an AWS key passed"   # ratchet:allow-secret
  secret_scan "Sources/a.swift" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -0,0 +1,2 @@\n+let k = "AKIAABCDEFGHIJKLMNOP" // fixture ratchet:allow-secret\n')" >/dev/null || fail "the allow marker was ignored"   # ratchet:allow-secret
  secret_scan "Sources/a.swift" "$(printf -- 'diff --git a a\n--- a\n+++ a\n@@ -0,0 +1,2 @@\n+let url = "https://x.y/sk-not-a-key"\n+let ghp = "ghp_short"\n')" >/dev/null || fail "clean lines tripped the secret scan"
  self="$RATCHET_SELF"
  selfdiff="$(printf 'diff --git a b\n--- /dev/null\n+++ b\n@@ -0,0 +1,%s @@\n' "$(wc -l < "$self" | tr -d ' ')"; sed 's/^/+/' "$self")"
  [ "$(added_lines <<< "$selfdiff" | wc -l | tr -d ' ')" -eq "$(wc -l < "$self" | tr -d ' ')" ] || fail "the self-source diff did not reach the scanner in full"
  secret_scan "kit/ratchet.sh" "$selfdiff" >/dev/null || fail "this file's own added lines trip the secret scan — a wired hook would refuse the commit that installs it"
  conflict_scan "$selfdiff" >/dev/null || fail "this file's own added lines trip the conflict-marker scan"
  # conflict markers: an opening and a closing marker added at column 0 in ONE file refuse; either alone, split across files,
  # indented, quoted, or removed (a resolution that deletes committed markers) passes; a lone ======= (a setext heading) passes
  rc=0; conflict_scan "$(printf -- 'diff --git a.md a.md\n--- a.md\n+++ a.md\n@@ -1 +1,5 @@\n+<<<<<<< HEAD\n+ours\n+=======\n+theirs\n+>>>>>>> plan-07\n')" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "a file with staged conflict markers passed (rc=$rc)"
  rc=0; conflict_scan "$(printf -- 'diff --git a.md a.md\n--- a.md\n+++ a.md\n@@ -1 +1,2 @@\n+<<<<<<<\n+>>>>>>>\n')" >/dev/null || rc=$?
  [ "$rc" -eq 1 ] || fail "bare seven-character markers passed (rc=$rc)"
  conflict_scan "$(printf -- 'diff --git a.md a.md\n--- a.md\n+++ a.md\n@@ -1 +1 @@\n+<<<<<<< HEAD\ndiff --git b.md b.md\n--- b.md\n+++ b.md\n@@ -1 +1 @@\n+>>>>>>> x\n')" >/dev/null || fail "markers split across two files refused"
  conflict_scan "$(printf -- 'diff --git a.md a.md\n--- a.md\n+++ a.md\n@@ -1,3 +1 @@\n-<<<<<<< HEAD\n-=======\n->>>>>>> x\n+Title\n+=======\n')" >/dev/null || fail "removed markers or a setext heading refused"
  conflict_scan "$(printf -- 'diff --git a.sh a.sh\n--- a.sh\n+++ a.sh\n@@ -1 +1,2 @@\n+  <<<<<<< indented\n+say ">>>>>>> quoted"\n+<<<<<<<<< nine\n')" >/dev/null || fail "indented, quoted or longer markers refused"
  # 7. the docs-commit decision: stage claim needs LOG + plan file; LOG growth needs a form; the boundary; the Lite shape
  docs_commit_ok "$(subject_of_msg "feat: x (PLAN-02 / 02.1)")" "feat: x (PLAN-02 / 02.1)" "$(printf 'docs/LOG.md\ndocs/plans/PLAN-02-y.md\nSources/a.swift\n')" 1 >/dev/null || fail "a conforming stage commit was refused"
  docs_commit_ok "$(subject_of_msg "feat: x (PLAN-02 / 02.1)")" "feat: x (PLAN-02 / 02.1)" "$(printf 'docs/LOG.md\ndocs/plans/PLAN-02-review/notes/e.md\n')" 1 >/dev/null 2>&1 && fail "a review-dir edit satisfied the plan-file rule"
  docs_commit_ok "$(subject_of_msg "feat: x (PLAN-02 / 02.1)")" "feat: x (PLAN-02 / 02.1)" "$(printf 'docs/plans/PLAN-02-y.md\n')" 0 >/dev/null 2>&1 && fail "a stage claim with no LOG passed"
  docs_commit_ok "$(subject_of_msg "chore: grow")" "chore: grow" "docs/LOG.md" 1 >/dev/null 2>&1 && fail "LOG growth with no form passed"
  for m in 'docs: PLAN-03 / review — r1' 'PLAN-03 / close: flip' 'PLAN-03 / patch (spacing)' 'PLAN-03 / refreeze: narrowed' 'PLAN-03 / fix — x' 'note: housekeeping'; do docs_commit_ok "$(subject_of_msg "$m")" "$m" "docs/LOG.md" 1 >/dev/null || fail "form '$m' refused"; done
  for m in 'PLAN-03 / patchwork' 'PLAN-03 / closeup' 'PLAN-03 / review2' 'PLAN-03 / refreezes' 'PLAN-03 / fixup' 'a note: inside'; do docs_commit_ok "$(subject_of_msg "$m")" "$m" "docs/LOG.md" 1 >/dev/null 2>&1 && fail "look-alike '$m' accepted"; done
  docs_commit_ok "$(subject_of_msg "$(printf 'chore: tidy\n\nnote: buried in the body\n')")" "$(printf 'chore: tidy\n\nnote: buried in the body\n')" "docs/LOG.md" 1 >/dev/null 2>&1 && fail "a note: in the body satisfied LOG growth"
  docs_commit_ok "$(subject_of_msg "$(printf 'chore: tidy\n\nPLAN-03 / review in the body\n')")" "$(printf 'chore: tidy\n\nPLAN-03 / review in the body\n')" "docs/LOG.md" 1 >/dev/null 2>&1 && fail "a form in the body satisfied LOG growth"
  docs_commit_ok "$(subject_of_msg "$(printf 'chore: work\n\ndone as PLAN-02 / 02.1\n')")" "$(printf 'chore: work\n\ndone as PLAN-02 / 02.1\n')" "$(printf 'docs/LOG.md\ndocs/plans/PLAN-02-y.md\n')" 1 >/dev/null 2>&1 && fail "a stage claim in the body only satisfied LOG growth"
  docs_commit_ok "$(subject_of_msg "$(printf 'chore: work\n\ndone as PLAN-02 / 02.1\n')")" "$(printf 'chore: work\n\ndone as PLAN-02 / 02.1\n')" "$(printf 'docs/plans/PLAN-02-y.md\n')" 0 >/dev/null 2>&1 && fail "a body claim without the LOG passed (a claim anywhere demands its artifacts)"
  [ -z "$(close_plan_in "PLAN-05 / closeup")" ] || fail "closeup read as a close"
  [ "$(stage_ref "$(printf 'x\n\ndone as PLAN-02 / 02.1 and PLAN-03 / 03.1\n')")" = PLAN-02 ] || fail "stage_ref did not return the first claim"
  rc=0; ( PATH=/nonexistent close_plan_in "PLAN-05 / close" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a grep failure in close_plan_in did not surface as an error (rc=$rc)"
  ( cd "$d" && rm -rf sub && mkdir sub && cd sub && git init -q . && git config user.email t@t && git config user.name t \
    && [ "$(subject_of_msg "$(printf '#123 fix\n\nnote: buried\n')")" = "#123 fix" ] \
    && subject_readings "$(printf '#123 fix\n\nnote: buried\n')" && [ "$SUBJ_N" -eq 2 ] && [ "$SUBJ_2" = "note: buried" ] \
    && subject_readings "$(printf '# only a comment\n')" && [ "$SUBJ_N" -eq 2 ] && [ -z "$SUBJ_2" ] \
    && [ "$(subject_of_msg "$(printf 'note: real\nPLAN-07 / close: done\n\nbody\n')")" = "note: real PLAN-07 / close: done" ] \
    && git config commit.cleanup verbatim && subject_readings "$(printf '#123 fix\n\nnote: buried\n')" && [ "$SUBJ_N" -eq 1 ] \
    && git config commit.cleanup scissors && subject_readings "$(printf 'note: real\n# ------------------------ >8 ------------------------\nPLAN-07 / refreeze: x\n')" \
    && [ "$SUBJ_N" -eq 2 ] && [ "$SUBJ_2" = "note: real" ] && [ "$SUBJ_1" = "note: real # ------------------------ >8 ------------------------ PLAN-07 / refreeze: x" ] \
    && git config commit.cleanup default && [ "$(subject_of_msg "$(printf '#123 fix\n\nnote: buried\n')")" = "#123 fix" ] \
    && git config commit.cleanup strip && [ "$(subject_of_msg "$(printf '#123 fix\n\nnote: buried\n')")" = "note: buried" ] \
    && git config core.commentChar ';' && [ "$(subject_of_msg "$(printf '; note\n#123 fix\n')")" = "#123 fix" ] \
    && git config --unset commit.cleanup && git config --unset core.commentChar \
    && printf 'x\n' > a && git add a && git commit -q -m "$(printf '#123 fix\n\nnote: buried\n')" \
    && [ "$(git show -s --format=%s HEAD)" = "#123 fix" ] ) \
    || fail "subject_of_msg does not follow the repo's commit.cleanup / core.commentChar (default -m keeps a #-led subject; strip drops it)"
  ( RATCHET_LOG=LOG.md RATCHET_PLANS_DIR="" docs_commit_ok "$(subject_of_msg "feat: x (PLAN-02 / 02.1)")" "feat: x (PLAN-02 / 02.1)" "$(printf 'LOG.md\nPLAN.md\n')" 1 >/dev/null ) || fail "the Lite shape (root LOG, inline plan) was refused"
  ( RATCHET_LOG=LOG.md RATCHET_PLANS_DIR="" docs_commit_ok "$(subject_of_msg "feat: x (PLAN-02 / 02.1)")" "feat: x (PLAN-02 / 02.1)" "$(printf 'LOG.md\n')" 1 >/dev/null 2>&1 ) && fail "a Lite stage claim without PLAN.md passed"
  # 7b. the Lite shape through the script: ratchet.conf with an EMPTY plans dir survives the defaults; a stage commit with
  #     LOG.md + PLAN.md passes the message leg; a close needs only a clean tmp/ (no review dir, no archive)
  ( cd "$d" && rm -rf lite && mkdir -p lite/script lite/tmp && cd lite && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf 'RATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=\n' > script/ratchet.conf \
    && printf '# P\n| **PLAN-01** x | inline | in-progress | none | 1d |\n' > PLAN.md && printf '# LOG\n' > LOG.md && git add -A . && git commit -qm init \
    && printf '\n## t — PLAN-01 / 01.1\nstage\n' >> LOG.md && printf '\n## PLAN-01\n- progress\n' >> PLAN.md && git add LOG.md PLAN.md \
    && printf 'feat: lite stage (PLAN-01 / 01.1)\n' > m && bash script/ratchet.sh --commit-msg m >/dev/null \
    && git reset -q -- PLAN.md && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 \
    && git add PLAN.md && printf 'PLAN-01 / close: done\n' > m && bash script/ratchet.sh --commit-msg m >/dev/null \
    && printf '# PLAN-01 / review: a form only in a comment line\n\nchore: no form\n' > m && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 \
    && printf '# PLAN-01 / review: a comment is the whole message\n' > m && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 \
    && printf 'note: real\n\n# chore: comment\n' > m && bash script/ratchet.sh --commit-msg m >/dev/null \
    && printf 'x\n' > tmp/stale.log && touch -t 202001010000 tmp/stale.log \
    && printf 'note: real\nPLAN-01 / close: done\n\nbody\n' > m && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 && rm -f tmp/stale.log ) \
    || fail "the Lite shape through the script (empty RATCHET_PLANS_DIR in ratchet.conf) did not behave: stage with PLAN.md passes, without fails, close needs only --check; a form only in a comment-led first line (or a comment-only message) must fail under the default cleanup (both readings judged); a close on the title's second line is a close"
  # 7c. the refreeze trace through the SCRIPT in a Standard-shaped repo: deleting the ledger is refused; a changed digest with
  #     PLAN.md staged and no form is refused (it is not a first stamp); the traced re-stamp passes
  ( cd "$d" && rm -rf std && mkdir -p std/script std/docs/plans && cd std && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After X, Y.\n\n## Outcomes\n' > docs/plans/PLAN-01-x.md && printf '# P\n' > PLAN.md && printf '# LOG\n' > docs/LOG.md \
    && printf 'PLAN-01 %s   # frozen\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && git add -A . && git commit -qm init \
    && git rm -q --cached docs/plans/.acceptance-hashes && printf 'note: tidy\n' > m && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 \
    && git reset -q && sed 's/After X, Y./After X, Z./' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s   # frozen; re-stamped\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && printf '\n' >> PLAN.md && git add -A . && printf 'note: quiet\n' > m && ! bash script/ratchet.sh --commit-msg m >/dev/null 2>&1 \
    && printf '2026  PLAN-01  x  narrowed\n' > docs/plans/.acceptance-amends && git add -A . && printf 'PLAN-01 / refreeze: narrowed\n' > m && bash script/ratchet.sh --commit-msg m >/dev/null ) \
    || fail "the refreeze trace through the script: a deleted ledger or an untraced changed digest (with PLAN.md staged) must be refused; the traced re-stamp must pass"
  # 8. tmp/ cites over a unified diff
  planmd="$(printf '| **PLAN-01** done | [x](docs/plans/PLAN-01-x.md) | complete | none | 1d |\n| **PLAN-02** live | [y](docs/plans/PLAN-02-y.md) | in-progress | PLAN-01 | 2d |\n| **PLAN-03** parked | [z](docs/plans/PLAN-03-z.md) | drafted (parked) | none | ? |\n')"
  [ "$(plan_status "$planmd" PLAN-01)" = complete ] || fail "plan_status PLAN-01"
  [ "$(plan_status "$planmd" PLAN-03)" = drafted ] || fail "plan_status parked"
  [ "$(plan_status "$planmd" PLAN-99)" = no-row ] || fail "plan_status no-row"
  # the freeze marks the row `in-progress (frozen)` (execution-loop.md § Lifecycle): the parenthetical strips, so the plan stays open and its tmp/ cites stay legal
  frozenmd="$(printf '| **PLAN-04** live | [w](docs/plans/PLAN-04-w.md) | in-progress (frozen) | none | 2d |\n')"
  [ "$(plan_status "$frozenmd" PLAN-04)" = in-progress ] || fail "plan_status: in-progress (frozen) should read in-progress"
  cite_ok tmp/PLAN-04/04.1-run.log "$frozenmd" || fail "a frozen, open plan's tmp/ cite was refused"
  cite_ok tmp/PLAN-04/04.1-run.log "$(printf '| **PLAN-04** done | [w](docs/plans/PLAN-04-w.md) | complete | none | 2d |\n')" && fail "a complete plan's tmp/ cite passed"
  good="$(printf '%s\n' 'diff --git docs/LOG.md docs/LOG.md' '--- docs/LOG.md' '+++ docs/LOG.md' '@@ -1,2 +1,5 @@' '+see `tmp/PLAN-02/02.1-run.log` and (`tmp/PLAN-03/prefreeze-r1.log`).' \
    "+resume via \`$RATCHET_RESUME_NOTE\`; the form is \`tmp/PLAN-NN/<stage>-<kind>[-rN].<ext>\`" \
    '+not cites: /tmp/x.out, `script/tmp-tidy.sh --check`, everything under `tmp/` is ignored' \
    '-old entry (`tmp/legacy-edit.log`) with a tyop' '+old entry (`tmp/legacy-edit.log`) with a typo fixed' \
    'diff --git docs/log/2026-08.md docs/log/2026-08.md' '--- /dev/null' '+++ docs/log/2026-08.md' '@@ -0,0 +1 @@' '+rotated history keeps `tmp/legacy-thing.log`' \
    'diff --git docs/plans/PLAN-01-review/MANIFEST.md docs/plans/PLAN-01-review/MANIFEST.md' '--- /dev/null' '+++ docs/plans/PLAN-01-review/MANIFEST.md' '@@ -0,0 +1 @@' '+| `tmp/plan01-L2.log` | archive |' \
    'diff --git docs/archive/old.md docs/archive/old.md' '--- /dev/null' '+++ docs/archive/old.md' '@@ -0,0 +1 @@' '+`tmp/old-note.md`' \
    'diff --git Sources/Foo.swift Sources/Foo.swift' '--- Sources/Foo.swift' '+++ Sources/Foo.swift' '@@ -0,0 +1 @@' '+// tmp/whatever.txt is not a doc')"
  printf '%s\n' "$good" | tmp_cite_guard "$planmd" >/dev/null || fail "allowed cites tripped the cite guard"
  bad="$(printf '%s\n' 'diff --git docs/LOG.md docs/LOG.md' '--- docs/LOG.md' '+++ docs/LOG.md' '@@ -0,0 +1 @@' '+evidence: `tmp/PLAN-01/01.2-verdict.md` (`tmp/plan29-L2.log`) and tmp/PLAN-99/x.md.' \
    'diff --git PLAN.md PLAN.md' '--- PLAN.md' '+++ PLAN.md' '@@ -1 +1,2 @@' '+record: `tmp/PLAN-07-discussion.md`' '-removed `tmp/removed.log` does not count' \
    'diff --git docs/x.md docs/x.md' '--- docs/x.md' '+++ docs/x.md' '@@ -1 +1 @@' '--- old' '+++see `tmp/PLAN-88/x.log` (a content line starting with +)' '+sprint proof: `tmp/bounded/uc-paths-run.log`')"
  so="$(printf '%s\n' "$bad" | tmp_cite_guard "$planmd" 2>&1)" && fail "offending cites passed"
  for want in 'tmp/PLAN-01/01.2-verdict.md (PLAN-01 is complete' 'tmp/plan29-L2.log (legacy' 'tmp/PLAN-99/x.md (PLAN-99 is no-row' 'tmp/PLAN-07-discussion.md (PLAN-07 is no-row' 'tmp/PLAN-88/x.log (PLAN-88 is no-row' "tmp/bounded/uc-paths-run.log (a small change's scratch is disposable"; do grep -qF "$want" <<< "$so" || fail "cite guard did not report: $want"; done
  [ "$(grep -c '^  tmp/' <<< "$so")" -eq 6 ] || fail "expected exactly 6 offenders: $so"
  grep -qF 'tmp/removed.log' <<< "$so" && fail "a removed line's cite was reported"
  # 8b. a merge: a cite is new only when it is new against EVERY parent — a closed plan's own LOG line, written on its branch
  #     while the plan was open, is inherited through the merge; a stale cite first written while resolving is still new
  inh="$(printf '%s\n' 'diff --git docs/LOG.md docs/LOG.md' '--- docs/LOG.md' '+++ docs/LOG.md' '@@ -0,0 +1,2 @@' '+evidence `tmp/PLAN-01/01.2-verdict.md`' '+resolved: `tmp/PLAN-01/01.9-late.md`')"
  vs2="$(printf '%s\n' 'diff --git docs/LOG.md docs/LOG.md' '--- docs/LOG.md' '+++ docs/LOG.md' '@@ -0,0 +1 @@' '+resolved: `tmp/PLAN-01/01.9-late.md`')"
  o="$(fresh_cites <<< "$vs2")" || fail "fresh_cites errored on a plain diff"
  so="$(tmp_cite_guard "$planmd" "$o" <<< "$inh" 2>&1)" && fail "a stale cite written while resolving a merge passed"
  grep -qF '01.9-late.md' <<< "$so" || fail "the merge's own stale cite was not named: $so"
  grep -qF '01.2-verdict.md' <<< "$so" && fail "a cite the other parent already carries was reported as new on the merge"
  tmp_cite_guard "$planmd" <<< "$inh" >/dev/null 2>&1 && fail "with no other parent both cites are new — the guard passed them"
  rc=0; ( PATH=/nonexistent fresh_cites <<< "$vs2" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a tool failure in fresh_cites read as no cites (rc=$rc)"
  # (8c's producer probes: the close branch's listing and its manifest read, each failing AFTER printing the true output — exit 2, never a pass)
  mkdir -p "$d/lsfail" "$d/showfail"
  printf '#!/bin/sh\nif [ "$1" = ls-files ] && [ "$2" = --cached ] && [ "$#" -eq 2 ]; then "%s" "$@"; exit 73; fi\nexec "%s" "$@"\n' "$(command -v git)" "$(command -v git)" > "$d/lsfail/git"
  printf '#!/bin/sh\ncase "$1:$2" in show:*MANIFEST.md) "%s" "$@"; exit 73 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" "$(command -v git)" > "$d/showfail/git"
  chmod +x "$d/lsfail/git" "$d/showfail/git"
  # 8c. a real merge through the SCRIPT (a plan branch that cited its scratch while open, then closed; the default branch moved):
  #     the pre-commit leg passes the inherited cites and refuses a stale one added while resolving; the message leg judges only
  #     the close's tracked half when the merged branch carries that plan's own close (no archive/ here), and the full ritual when it does not
  ( cd "$d" && rm -rf mg && mkdir -p mg/script mg/docs/plans && cd mg && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '| **PLAN-01** x | [x](docs/plans/PLAN-01-x.md) | in-progress | none | 1d |\n' > PLAN.md && printf '# LOG\n' > docs/LOG.md \
    && git add -A . && git commit -qm init && base="$(git rev-parse --abbrev-ref HEAD)" && git checkout -q -b plan \
    && printf '\n## PLAN-01 / 01.1\nevidence `tmp/PLAN-01/01.1-run.log`\n' >> docs/LOG.md && git commit -qam stage && git branch -q noclose \
    && mkdir -p docs/plans/PLAN-01-review && printf '# m\n\n## Tracked files\n' > docs/plans/PLAN-01-review/MANIFEST.md \
    && sed 's/in-progress/complete/' PLAN.md > t && mv t PLAN.md && git add -A . && git commit -qm "PLAN-01 / close — done" \
    && git checkout -q "$base" && printf 'other\n' > docs/OTHER.md && git add -A . && git commit -qm "note: other" \
    && git merge -q --no-ff --no-commit plan >/dev/null 2>&1 && [ -f "$(git rev-parse --git-path MERGE_HEAD)" ] \
    && RATCHET_SKIP_COUNT_FLOOR=1 bash script/ratchet.sh >/dev/null \
    && printf 'merge: PLAN-01 / close — integrate\n' > ../mg-msg && bash script/ratchet.sh --commit-msg ../mg-msg >/dev/null \
    && rc=0 && { PATH="$d/lsfail:$PATH" bash script/ratchet.sh --commit-msg ../mg-msg >/dev/null 2>&1 || rc=$?; } && [ "$rc" -eq 2 ] \
    && rc=0 && { PATH="$d/showfail:$PATH" bash script/ratchet.sh --commit-msg ../mg-msg >/dev/null 2>&1 || rc=$?; } && [ "$rc" -eq 2 ] \
    && printf 'late `tmp/PLAN-01/01.9-late.md`\n' >> docs/LOG.md && git add docs/LOG.md && ! RATCHET_SKIP_COUNT_FLOOR=1 bash script/ratchet.sh >/dev/null 2>&1 \
    && git merge --abort && git merge -q --no-ff --no-commit noclose >/dev/null 2>&1 \
    && mkdir -p docs/plans/PLAN-01-review && printf '# m\n\n## Tracked files\n' > docs/plans/PLAN-01-review/MANIFEST.md \
    && sed 's/in-progress/complete/' PLAN.md > t && mv t PLAN.md && git add -A . && ! bash script/ratchet.sh --commit-msg ../mg-msg >/dev/null 2>&1 ) \
    || fail "a merge through the script: inherited cites must pass and a stale cite added while resolving must not; a merged branch's own close is judged on its tracked half (a listing or a manifest read that fails after printing is exit 2), a close first claimed by the merge on the full ritual"
  # 9. the close ritual, both halves, each condition named — needs tmp-tidy beside this script
  [ -x "$RATCHET_TMP_TIDY" ] || fail "tmp-tidy.sh not found beside ratchet.sh ($RATCHET_TMP_TIDY) — the kit installs together"
  c="$d/c"; mkdir -p "$c/docs/plans" "$c/tmp/PLAN-00"
  printf '# PLAN-00\n\nSee `tmp/PLAN-00/00.1-run.log` and `tmp/PLAN-00/00.1-prompt.md`.\n' > "$c/docs/plans/PLAN-00-x.md"
  printf '## log\n' > "$c/docs/LOG.md"; printf 'run\n' > "$c/tmp/PLAN-00/00.1-run.log"; printf 'go\n' > "$c/tmp/PLAN-00/00.1-prompt.md"
  "$RATCHET_TMP_TIDY" --plan PLAN-00 --apply --root "$c" >/dev/null 2>&1 || fail "fixture tidy failed"
  man="$(cat "$c/docs/plans/PLAN-00-review/MANIFEST.md")"
  tree="$(printf 'PLAN.md\ndocs/LOG.md\ndocs/plans/PLAN-00-review/MANIFEST.md\ndocs/plans/PLAN-00-review/prompts/00.1-prompt.md\n')"
  check_close_ritual PLAN-00 "$tree" "$c" "$man" >/dev/null || fail "a tidied close tripped: $(check_close_ritual PLAN-00 "$tree" "$c" "$man" 2>&1)"
  check_close_ritual PLAN-00 "$(printf 'PLAN.md\ndocs/LOG.md\n')" "$c" "$man" >/dev/null 2>&1 && fail "a close with no MANIFEST in the tree passed"
  so="$(check_close_ritual PLAN-00 "$tree" "$c" "$(printf '# m\n| x | y |\n')" 2>&1)" && fail "a manifest with no inventory passed"
  grep -qF "no '## Tracked files'" <<< "$so" || fail "missing inventory not named: $so"
  so="$(check_close_ritual PLAN-00 "$(printf 'PLAN.md\ndocs/LOG.md\ndocs/plans/PLAN-00-review/MANIFEST.md\n')" "$c" "$man" 2>&1)" && fail "an unstaged tracked path passed"
  grep -qF 'prompts/00.1-prompt.md' <<< "$so" || fail "the unstaged path was not named: $so"
  mkdir -p "$c/tmp/PLAN-00" && printf 'again\n' > "$c/tmp/PLAN-00/00.2-prompt.md"
  "$RATCHET_TMP_TIDY" --plan PLAN-00 --apply --root "$c" >/dev/null 2>&1 || fail "fixture re-tidy failed"
  tree2="$(printf '%s\ndocs/plans/PLAN-00-review/prompts/00.2-prompt.md\n' "$tree")"
  so="$(check_close_ritual PLAN-00 "$tree2" "$c" "$man" 2>&1)" && fail "a stale staged manifest passed"
  grep -qF 'prompts/00.2-prompt.md' <<< "$so" || fail "the stale manifest's missing path was not named: $so"
  man="$(cat "$c/docs/plans/PLAN-00-review/MANIFEST.md")"; tree="$tree2"
  check_close_ritual PLAN-00 "$tree" "$c" "$man" >/dev/null || fail "the re-staged manifest tripped"
  : > "$c/archive/plans/PLAN-00.list"
  check_close_ritual PLAN-00 "$tree" "$c" "$man" >/dev/null 2>&1 && fail "an empty .list passed"
  printf 'PLAN-00/00.1-run.log\n' > "$c/archive/plans/PLAN-00.list"
  arc="$(ls "$c/archive/plans/"PLAN-00.tar.* | awk 'NR==1')"; mv "$arc" "$c/archive/plans/hidden"
  so="$(check_close_ritual PLAN-00 "$tree" "$c" "$man" 2>&1)" && fail "a .list with no archive passed"
  grep -qF 'no archive beside it' <<< "$so" || fail "the missing archive was not named: $so"
  mv "$c/archive/plans/hidden" "$arc"
  mkdir -p "$c/tmp/PLAN-00"; check_close_ritual PLAN-00 "$tree" "$c" "$man" >/dev/null 2>&1 && fail "tmp/PLAN-00 still present passed"; rmdir "$c/tmp/PLAN-00"
  printf 'Also `tmp/PLAN-00/00.9-missing.md`.\n' >> "$c/docs/plans/PLAN-00-x.md"
  so="$(check_close_ritual PLAN-00 "$tree" "$c" "$man" 2>&1)" && fail "an UNRESOLVED cite passed"
  grep -qF '00.9-missing.md' <<< "$so" || fail "the unresolved cite was not named"
  grep -v '00.9-missing' "$c/docs/plans/PLAN-00-x.md" > "$c/t" && mv "$c/t" "$c/docs/plans/PLAN-00-x.md"
  printf 'x\n' > "$c/tmp/stray.log"; touch -t 202001010000 "$c/tmp/stray.log"
  so="$(check_close_ritual PLAN-00 "$tree" "$c" "$man" 2>&1)" && fail "a stale stray in tmp/ passed"
  grep -qF 'tmp/stray.log' <<< "$so" || fail "the stray was not named"
  rc=0; ( PATH=/nonexistent manifest_inventory <<< "$man" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a grep failure in the inventory parser did not surface as an error (rc=$rc)"
  rc=0; ( PATH=/nonexistent close_ritual_tracked_ok PLAN-00 "$tree" "$man" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -ne 0 ] || fail "an inventory tool failure read as a clean close"
  [ "$(close_plan_in "$(subject_of_msg "$(printf 'docs: PLAN-05 / close — flip\n\nbody PLAN-06 / close\n')")")" = PLAN-05 ] || fail "close_plan_in reads the subject only"
  [ -z "$(close_plan_in "$(subject_of_msg "$(printf 'note: x\n\nPLAN-06 / close in the body\n')")")" ] || fail "a close form in the body counted"
  # 10. the index copy is what gets hashed: a weakened section staged with the original restored on disk must trip
  ( cd "$d" && rm -rf r && mkdir r && cd r && git init -q . && git config user.email t@t && git config user.name t \
    && mkdir -p docs/plans script && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After X, Y.\n\n## Outcomes\n' > docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s\n' "$(acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && git add -A . && git commit -qm init \
    && sed 's/After X, Y./After X, nothing./' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md && git add docs/plans/PLAN-01-x.md \
    && git checkout -- . 2>/dev/null; git show HEAD:docs/plans/PLAN-01-x.md > docs/plans/PLAN-01-x.md \
    && ! ( RATCHET_PLANS_DIR=docs/plans RATCHET_EXTRACT=script/acceptance-extract.awk check_acceptance_hashes "$(git show :docs/plans/.acceptance-hashes)" plan_content_index >/dev/null 2>&1 ) \
    && git checkout -q -- . && git rm -q --cached docs/plans/PLAN-01-x.md \
    && ! ( RATCHET_PLANS_DIR=docs/plans RATCHET_EXTRACT=script/acceptance-extract.awk check_acceptance_hashes "$(git show HEAD:docs/plans/.acceptance-hashes)" plan_content_index >/dev/null 2>&1 ) ) \
    || fail "a weakened section staged with the original restored on disk passed, or a plan removed from the index but present on disk was read from disk"
  # 11. the draft's criteria: a builder commit leaves an unstamped plan's Validation and Acceptance alone
  #     11a. who builds: a stage claim (subject, or the body alone), `fix`, `patch` — bounded; never note:, review, close, refreeze
  for pair in 'PLAN-02 / 02.1: build|PLAN-02 / 02.1' 'feat: x (PLAN-02 / 02.1)|PLAN-02 / 02.1' 'PLAN-02 / fix — batch|PLAN-02 / fix' 'PLAN-02 / patch: y|PLAN-02 / patch' 'PLAN-02 / fix|PLAN-02 / fix' \
              'note: blocks after PLAN-02 / 02.1|' 'PLAN-02 / review: r1|' 'PLAN-02 / close — done|' 'PLAN-02 / refreeze: narrowed|' 'PLAN-02 / fixup|' 'PLAN-02 / patchwork|' 'chore: tidy|'; do
    s="${pair%|*}"; want="${pair#*|}"
    got="$(builder_claim "$s" "$s")" || fail "builder_claim errored on '$s'"
    [ "$got" = "$want" ] || fail "builder_claim '$s' read '$got', want '$want'"
  done
  [ -z "$(builder_claim 'PLAN-02 / review: r1' "$(printf 'PLAN-02 / review: r1\n\nfixes PLAN-02 / 02.1\n')")" ] || fail "a record form in the subject must outrank a stage named in the body"
  [ "$(builder_claim 'chore: work' "$(printf 'chore: work\n\ndone as PLAN-02 / 02.3\n')")" = 'PLAN-02 / 02.3' ] || fail "a stage claim in the body alone must claim"
  [ -z "$(builder_claim 'note: x' "$(printf 'note: x\n\nPLAN-02 / 02.1\n')")" ] || fail "a note: subject must stay a note whatever its body names"
  rc=0; ( PATH=/nonexistent builder_claim 'PLAN-02 / 02.1' x >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a grep failure in builder_claim must be exit 2 (rc=$rc)"
  #     11b. which plans: those the commit changes with no stamp in the PARENT's ledger — a review dir is not a plan file; a malformed ledger is 1
  got="$(unstamped_changed_plans "$(printf 'PLAN-01 %064d\n' 0)" "$(printf 'docs/plans/PLAN-01-x.md\ndocs/plans/PLAN-10-z.md\ndocs/plans/PLAN-02-y.md\ndocs/plans/PLAN-02-review/MANIFEST.md\nSources/a.swift\n')")" || fail "unstamped_changed_plans errored"
  [ "$got" = "$(printf 'PLAN-02\nPLAN-10')" ] || fail "unstamped_changed_plans should list PLAN-02 and PLAN-10 (PLAN-01 is stamped): '$got'"
  rc=0; unstamped_changed_plans 'not a row' docs/plans/PLAN-02-y.md >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 1 ] || fail "a malformed parent ledger must be 1 (rc=$rc)"
  [ -z "$( RATCHET_PLANS_DIR= unstamped_changed_plans '' docs/plans/PLAN-02-y.md )" ] || fail "an empty plans dir (Lite, inline plans) must leave the leg off"
  #     11c. the comparison, through the ONE extractor: a change past a fenced `## ` line is a change (a naive extractor stops at the fence);
  #          a change outside the section is none; a section that appears or disappears is a change; no section before and after is none;
  #          a failed read or a failed extraction is exit 2; two files claiming the plan is a named refusal
  mkdir -p "$d/crit/old/docs/plans" "$d/crit/new/docs/plans"
  cshow() { cat "$d/crit/$1/$2"; }
  p2='# PLAN-02\n\n## Validation and Acceptance\n\n- After X, Y.\n\n```sh\n## not a heading (fenced)\n```\n\n- After P, Q.\n\n## Progress\n\n- [ ] 02.1\n'
  printf "$p2" > "$d/crit/old/docs/plans/PLAN-02-y.md"; printf "$p2" > "$d/crit/new/docs/plans/PLAN-02-y.md"
  L=docs/plans/PLAN-02-y.md
  criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$L" cshow >/dev/null || fail "an unchanged section was refused"
  printf -- '- [x] 02.1\n' >> "$d/crit/new/$L"
  criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$L" cshow >/dev/null || fail "an edit outside the section (Progress) was refused"
  sed 's/After P, Q./After P, anything./' "$d/crit/new/$L" > "$d/t" && mv "$d/t" "$d/crit/new/$L"
  rc=0; out="$(criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$L" cshow)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF "PLAN-02 / 02.1 changes the Validation and Acceptance section of $L — PLAN-02 has no stamp yet" <<< "$out" && grep -qF "as 'note:'" <<< "$out" \
    || fail "a criterion edited past a fenced '## ' line was not refused with the plan file and the remedy named (rc=$rc): $out"
  rc=0; ( RATCHET_EXTRACT=/nonexistent/extract.awk criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$L" cshow >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a failed extraction must be exit 2, never unchanged (rc=$rc)"
  cfail() { [ "$1" = old ] && return 73; cshow "$@"; }
  rc=0; criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$L" cfail >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a failed read of the parent's plan must be exit 2 (rc=$rc)"
  rc=0; out="$(criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "$(printf '%s\ndocs/plans/PLAN-02-other.md' "$L")" cshow 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'two plan files claim PLAN-02' <<< "$out" || fail "two plan files for one plan must be a named refusal (rc=$rc): $out"
  printf '# PLAN-03 (a draft still being written)\n\n## Progress\n' > "$d/crit/old/docs/plans/PLAN-03-z.md"; cp "$d/crit/old/docs/plans/PLAN-03-z.md" "$d/crit/new/docs/plans/PLAN-03-z.md"
  printf -- '- [x] 03.1\n' >> "$d/crit/new/docs/plans/PLAN-03-z.md"; L3=docs/plans/PLAN-03-z.md
  criteria_unchanged_ok 'PLAN-03 / 03.1' PLAN-03 "$L3" "$L3" cshow >/dev/null || fail "a section-less draft with no section added was refused"
  printf '\n## Validation and Acceptance\n\n- written after the code\n' >> "$d/crit/new/$L3"
  criteria_unchanged_ok 'PLAN-03 / 03.1' PLAN-03 "$L3" "$L3" cshow >/dev/null 2>&1 && fail "a section that appears in a builder commit passed"
  criteria_unchanged_ok 'PLAN-03 / 03.1' PLAN-03 "" "$L3" cshow >/dev/null 2>&1 && fail "a new plan file carrying a section passed in a builder commit"
  criteria_unchanged_ok 'PLAN-02 / 02.1' PLAN-02 "$L" "" cshow >/dev/null 2>&1 && fail "a builder commit deleting an unstamped plan (its section gone) passed"
  #     11d. through the SCRIPT (the commit-msg hook): a stage commit editing an unstamped section is refused; as note: it passes; `fix` is
  #          refused; a stage commit editing only Progress passes; a stamped plan's edit is the hash leg's ONE refusal (this leg is silent);
  #          a section-less draft passes until a builder commit adds the section; a stage commit that stamps and edits at once is judged
  #          here; a merge in progress is no builder commit; a failed read (git) and a failed extraction (awk) are exit 2
  mkdir -p "$d/evfk/git" "$d/evfk/awk"
  printf '#!/bin/sh\n[ "$1" = show ] && [ "$2" = HEAD:docs/plans/PLAN-02-y.md ] && exit 73\nexec "%s" "$@"\n' "$(command -v git)" > "$d/evfk/git/git"
  printf '#!/bin/sh\n[ "$1" = -f ] && exit 2\nexec "%s" "$@"\n' "$(command -v awk)" > "$d/evfk/awk/awk"
  chmod +x "$d/evfk/git/git" "$d/evfk/awk/awk"
  ( cd "$d" && rm -rf ev && mkdir -p ev/script ev/docs/plans && cd ev && git init -q . && git config user.email t@t && git config user.name t
    cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk
    printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After A, B.\n\n## Progress\n' > docs/plans/PLAN-01-x.md
    printf '# PLAN-02\n\n## Validation and Acceptance\n\n- After X, Y.\n\n## Progress\n' > docs/plans/PLAN-02-y.md
    printf '# PLAN-03 (a draft still being written)\n\n## Progress\n' > docs/plans/PLAN-03-z.md
    printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes
    printf '# P\n' > PLAN.md && printf '# LOG\n' > docs/LOG.md && git add -A . && git commit -qm 'note: drafts' || fail "fixture: the drafts commit failed"
    cm() { rc=0; printf '%s\n' "$1" > "$d/ev-msg"; out="$(bash script/ratchet.sh --commit-msg "$d/ev-msg" 2>&1)" || rc=$?; }   # the message file outside the repo
    printf '\n## t — PLAN-02 / 02.1\nstage\n' >> docs/LOG.md; sed 's/After X, Y./After X, anything./' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md; printf -- '- [x] 02.1\n' >> docs/plans/PLAN-02-y.md; git add -A .
    cm 'PLAN-02 / 02.1: build'; [ "$rc" -eq 1 ] && grep -qF 'changes the Validation and Acceptance section of docs/plans/PLAN-02-y.md' <<< "$out" || fail "a stage commit editing an unstamped section passed the hook (rc=$rc): $out"
    cm 'note: Verify blocks for PLAN-02 / 02.1'; [ "$rc" -eq 0 ] || fail "the same edit as note: was refused (rc=$rc): $out"
    cm 'PLAN-02 / fix — the review batch'; [ "$rc" -eq 1 ] || fail "a fix commit editing an unstamped section passed (rc=$rc): $out"
    cm 'PLAN-02 / review: round 1 fixes'; [ "$rc" -eq 0 ] || fail "a review-form commit was judged as a builder's (rc=$rc): $out"
    rc=0; ( printf 'PLAN-02 / 02.1: build\n' > "$d/ev-msg"; PATH="$d/evfk/git:$PATH" bash script/ratchet.sh --commit-msg "$d/ev-msg" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a failed read of HEAD's plan must be exit 2 through the hook (rc=$rc)"
    rc=0; ( printf 'PLAN-02 / 02.1: build\n' > "$d/ev-msg"; PATH="$d/evfk/awk:$PATH" bash script/ratchet.sh --commit-msg "$d/ev-msg" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a failed extraction must be exit 2 through the hook (rc=$rc)"
    printf 'BEGIN { exit }\n' > script/acceptance-extract.awk && git add -A . && cm 'PLAN-02 / 02.1: build'
    [ "$rc" -eq 1 ] && grep -qF 'PLAN-02 has no stamp yet' <<< "$out" || fail "a builder commit that also blanks the extractor passed — the check reads with HEAD's extractor (rc=$rc): $out"
    git reset -q && git checkout -q -- . && printf '\n## t — PLAN-02 / 02.1\nstage\n' >> docs/LOG.md && printf -- '- [x] 02.1\n' >> docs/plans/PLAN-02-y.md && git add -A .
    cm 'PLAN-02 / 02.1: build'; [ "$rc" -eq 0 ] || fail "a stage commit editing only Progress was refused (rc=$rc): $out"
    git reset -q && git checkout -q -- . && printf '\n## t — PLAN-01 / 01.2\nstage\n' >> docs/LOG.md && sed 's/After A, B./After A, anything./' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md && git add -A .
    cm 'PLAN-01 / 01.2: build'; [ "$rc" -eq 0 ] && ! grep -qF 'no stamp yet' <<< "$out" || fail "a stamped plan must be left to the hash leg by the message leg (rc=$rc): $out"
    rc=0; out="$(RATCHET_SKIP_COUNT_FLOOR=1 bash script/ratchet.sh 2>&1)" || rc=$?
    [ "$rc" -eq 1 ] && grep -qF 'acceptance hash mismatch for PLAN-01' <<< "$out" && ! grep -qF 'no stamp yet' <<< "$out" || fail "a stamped plan's edit must be the hash leg's one refusal (rc=$rc): $out"
    git reset -q && git checkout -q -- . && printf '\n## t — PLAN-03 / 03.1\nstage\n' >> docs/LOG.md && printf -- '- [x] 03.1\n' >> docs/plans/PLAN-03-z.md && git add -A .
    cm 'PLAN-03 / 03.1: build'; [ "$rc" -eq 0 ] || fail "a section-less draft's stage commit was refused (rc=$rc): $out"
    printf '\n## Validation and Acceptance\n\n- written after the code\n' >> docs/plans/PLAN-03-z.md && git add -A .
    cm 'PLAN-03 / 03.1: build'; [ "$rc" -eq 1 ] && grep -qF 'section of docs/plans/PLAN-03-z.md' <<< "$out" || fail "a section added by a stage commit passed (rc=$rc): $out"
    git reset -q && git checkout -q -- . && printf '\n## t — PLAN-02 / 02.1\nstage\n' >> docs/LOG.md && sed 's/After X, Y./After X, anything./' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md
    printf 'PLAN-02 %s\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-02-y.md)" >> docs/plans/.acceptance-hashes && printf '\n' >> PLAN.md && git add -A .
    cm 'PLAN-02 / 02.1: build'; [ "$rc" -eq 1 ] && grep -qF 'PLAN-02 has no stamp yet' <<< "$out" || fail "a stage commit that stamps and edits at once passed on the stamp it wrote itself (rc=$rc): $out"
    git reset -q && git checkout -q -- . && base="$(git rev-parse --abbrev-ref HEAD)" && git checkout -q -b plan \
      && printf '\n## t — note\nthe plan read asked\n' >> docs/LOG.md && sed 's/After X, Y./After X, Y, as the plan read asked./' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md \
      && git add -A . && git commit -qm 'note: the plan read asked for a sharper criterion' && git checkout -q "$base" && printf 'other\n' > docs/OTHER.md && git add -A . && git commit -qm 'note: other' \
      && git merge -q --no-ff --no-commit plan >/dev/null 2>&1 || fail "fixture: the merge failed"
    cm 'PLAN-02 / 02.2: integrate the branch'; [ "$rc" -eq 0 ] || fail "a merge in progress was judged as a builder commit (rc=$rc): $out"
    git merge --abort ) || fail "the draft's criteria through the script (a fixture step failed, or a check above named its failure)"
  # split-repo mode (modules/split-repo.md). The roots and the side; the code side's stage claim and close; the records side's hash leg
  # (the extractor read from the code repo), its no-suite legs and its close with the pairing; the project check; RATCHET_ROOT on the
  # kit's own repo keeping every relative path (a one-repo commit judged exactly as before)
  sp="$d/sp"; rm -rf "$sp"; mkdir -p "$sp/code/script"
  ( cd "$sp/code" && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf 'RATCHET_RECORDS=private\nRATCHET_TEST_CMD=./script/test.sh\n' > script/ratchet.conf \
    && printf '#!/bin/sh\necho "SP_TEST_COUNT=$(cat count.txt)"\n' > script/test.sh && chmod +x script/test.sh && echo 1 > count.txt && echo 1 > .test-count \
    && printf '/private\n/tmp/\n' > .gitignore && printf 'a\n' > src.txt && git add -A . && git commit -qm init \
    && git init -q private && cd private && git config user.email t@t && git config user.name t && mkdir -p docs/plans \
    && printf '# P\n\n| **PLAN-01** x | [x](docs/plans/PLAN-01-x.md) | in-progress | none | 1d |\n' > PLAN.md && printf '# LOG\n' > docs/LOG.md \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After A, B.\n\n## Progress\n' > docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=../script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && git add -A . && git commit -qm 'note: init' ) >/dev/null || fail "fixture: the split-repo pair"
  spc="$(cd "$sp/code" && pwd -P)"; spr="$spc/private"
  # the roots: one-repo, the code side, the records side (its code root the records top less the suffix), and bad settings refused (2)
  ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=; cd "$sp/code" && ratchet_roots && [ "$RATCHET_SIDE" = one ] ) || fail "no RATCHET_RECORDS must be the one-repo side"
  ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=private/; cd "$sp/code" && ratchet_roots && [ "$RATCHET_SIDE" = code ] && [ "$RATCHET_RECORDS_ROOT" = "$spr" ] ) || fail "the code repo must be the code side, its records root beside"
  ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=private; cd "$sp/code/private" && ratchet_roots && [ "$RATCHET_SIDE" = records ] && [ "$RATCHET_CODE_ROOT" = "$spc" ] ) || fail "the records repo must be the records side, the code root above it"
  for bad in /abs ../x a/../b . ./private 'a//b'; do
    rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS="$bad"; cd "$sp/code" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "RATCHET_RECORDS='$bad' must be refused as a setting (2), got $rc"
  done
  # only the kit's code repo and its records repo have a side: any other root is 2, never the code side (whose rules skip the record
  # guards) — another folder, a records path named differently in the environment, a subfolder of the records repo
  mkdir -p "$sp/code/other" "$spr/sub"
  for wd in "$sp/code/other" "$spr/sub" "$d"; do
    rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=private; cd "$wd" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a root that is neither the code repo nor its records repo ($wd) must be 2, got $rc"
  done
  rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=other; cd "$spr" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "the records repo judged under another RATCHET_RECORDS must be 2, never the code side (rc=$rc)"
  rmdir "$sp/code/other" "$spr/sub"
  # a symlink along the records path is refused on both sides: git would run a linked repo's hooks from another kit
  mkdir -p "$d/sp-linked" && ln -s "$d/sp-linked" "$sp/code/lnk"
  rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=lnk; cd "$sp/code" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a symlinked records path must be 2 on the code side (rc=$rc)"
  rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=lnk; cd "$d/sp-linked" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a symlinked records repo must be 2 on its own side (rc=$rc)"
  rm -f "$sp/code/lnk"; ln -s "$d/nowhere" "$sp/code/lnk"
  rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=lnk; cd "$sp/code" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a broken link at the records path must be 2 (rc=$rc)"
  rm -f "$sp/code/lnk"; rmdir "$d/sp-linked"
  ( RATCHET_RECORDS=private; RATCHET_RECORDS_ROOT="$spr"; records_root_check && [ "$RATCHET_RECORDS_ROOT" = "$spr" ] ) || fail "a records clone must pass records_root_check"
  mkdir -p "$sp/code/plain"; rc=0; ( RATCHET_RECORDS=plain; RATCHET_RECORDS_ROOT="$sp/code/plain"; records_root_check ) >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || fail "a plain directory inside the code repo must not pass as the records repo (rc=$rc)"; rmdir "$sp/code/plain"
  rc=0; ( RATCHET_RECORDS=nope; RATCHET_RECORDS_ROOT="$sp/code/nope"; records_root_check ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a missing records repo must be 2 (rc=$rc)"
  # ratchet_roots itself: a records path that EXISTS must be a repo of its own (an ordinary folder there would read as the code side and
  # quiet the record guards) — 2, through the script's commit-msg and pre-commit too; a MISSING path stays the code side (code CI, a
  # contributor without the records clone)
  mkdir -p "$sp/code/plain" && printf 'x\n' > "$sp/code/plain/f"
  rc=0; ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=plain; cd "$sp/code" && ratchet_roots ) >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "an ordinary folder at the records path must be 2 on the code side, never the code side (rc=$rc)"
  ( RATCHET_DIR="$sp/code/script"; RATCHET_RECORDS=absent; cd "$sp/code" && ratchet_roots && [ "$RATCHET_SIDE" = code ] && [ "$RATCHET_RECORDS_ROOT" = "$spc/absent" ] ) || fail "a missing records path must leave the code side working"
  printf '%s\n' 'PLAN-01 / 01.1 — build' > "$d/sp-msg"
  rc=0; out="$(cd "$sp/code" && RATCHET_RECORDS=plain RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" --commit-msg "$d/sp-msg" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] && grep -qE 'not a git work tree|not a repo of its own' <<< "$out" || fail "an ordinary folder at the records path must be 2 through --commit-msg (rc=$rc): $out"
  rc=0; out="$(cd "$sp/code" && RATCHET_RECORDS=plain RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" 2>&1)" || rc=$?
  [ "$rc" -eq 2 ] && grep -qE 'not a git work tree|not a repo of its own' <<< "$out" || fail "an ordinary folder at the records path must be 2 through the pre-commit legs (rc=$rc): $out"
  rc=0; out="$(cd "$sp/code" && RATCHET_RECORDS=absent RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" --commit-msg "$d/sp-msg" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "a missing records path must leave the code side's stage claim passing (rc=$rc): $out"
  rm -rf "$sp/code/plain"
  # the code side, through the script as the hooks call it: a stage claim with no LOG passes, and so does a harvest close with no MANIFEST;
  # a tmp/PLAN-NN cite in a code-side doc is refused (no PLAN.md here); the same claim one-repo is refused
  cm2() { rc=0; printf '%s\n' "$2" > "$d/sp-msg"; out="$(cd "$1" && RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" --commit-msg "$d/sp-msg" 2>&1)" || rc=$?; }
  pc2() { rc=0; out="$(cd "$1" && RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" 2>&1)" || rc=$?; }
  ( cd "$sp/code" && printf 'b\n' >> src.txt && git add src.txt ) || fail "fixture: a code change"
  cm2 "$sp/code" 'PLAN-01 / 01.1 — build'; [ "$rc" -eq 0 ] || fail "a code-side stage claim with no LOG was refused (rc=$rc): $out"
  pc2 "$sp/code"; [ "$rc" -eq 0 ] || fail "a code-side code change failed the pre-commit legs (rc=$rc): $out"
  cm2 "$sp/code" 'PLAN-01 / close — harvest'; [ "$rc" -eq 0 ] || fail "a code-side harvest close was asked for a MANIFEST (rc=$rc): $out"
  sed 's/^RATCHET_RECORDS=private$/RATCHET_RECORDS=/' "$sp/code/script/ratchet.conf" > "$d/sp-conf" && cp "$sp/code/script/ratchet.conf" "$d/sp-conf0" && cp "$d/sp-conf" "$sp/code/script/ratchet.conf"
  cm2 "$sp/code" 'PLAN-01 / 01.1 — build'; o1="$out"; r1="$rc"
  export RATCHET_RECORDS=private; cm2 "$sp/code" 'PLAN-01 / 01.1 — build'; unset RATCHET_RECORDS; cp "$d/sp-conf0" "$sp/code/script/ratchet.conf"
  [ "$r1" -eq 1 ] && grep -qF 'no docs/LOG.md staged' <<< "$o1" || fail "the same claim one-repo must still need its LOG (rc=$r1): $o1"
  [ "$rc" -eq 0 ] || fail "a non-empty RATCHET_RECORDS in the environment must outrank the conf's empty one (rc=$rc): $out"
  ( cd "$sp/code" && printf 'see tmp/PLAN-01/01.1-L1.log\n' > NOTES.md && git add NOTES.md ) || fail "fixture: a cite"
  pc2 "$sp/code"; [ "$rc" -eq 1 ] && grep -qF 'tmp/PLAN-01/01.1-L1.log' <<< "$out" || fail "a code-side doc citing the records' scratch passed (rc=$rc): $out"
  ( cd "$sp/code" && git rm -q --cached NOTES.md && rm -f NOTES.md ) || fail "fixture: drop the cite"
  # the project check: fed the staged diff, it refuses (1) and passes (0), and any other exit is a tool failure (2); the records side never runs it
  export RATCHET_PROJECT_CHECK='! grep -q "^+.*FORBIDDEN"'
  pc2 "$sp/code"; [ "$rc" -eq 0 ] || fail "a clean change failed the project check (rc=$rc): $out"
  ( cd "$sp/code" && printf 'FORBIDDEN\n' >> src.txt && git add src.txt ) || fail "fixture: a refused line"
  pc2 "$sp/code"; [ "$rc" -eq 1 ] && grep -qF 'the project check refused' <<< "$out" || fail "the project check's refusal did not refuse the commit (rc=$rc): $out"
  RATCHET_PROJECT_CHECK='exit 3'; pc2 "$sp/code"; [ "$rc" -eq 2 ] && grep -qF 'failed to run (exit 3)' <<< "$out" || fail "a project check exiting 3 must be a tool failure (rc=$rc): $out"
  ( cd "$sp/code" && git reset -q && git checkout -q -- src.txt ) || fail "fixture: reset the code side"
  ( cd "$sp/code" && mkdir -p docs/plans && printf '# PLAN-09\n\n## Validation and Acceptance\n\n- a\n' > docs/plans/PLAN-09-x.md && git add docs/plans \
    && git -c core.hooksPath=/dev/null commit -qm 'note: a code-side docs/plans' && sed 's/^- a$/- b/' docs/plans/PLAN-09-x.md > t && mv t docs/plans/PLAN-09-x.md && git add docs/plans ) >/dev/null \
    || fail "fixture: a code-side plan-shaped file"
  cm2 "$sp/code" 'PLAN-09 / 09.1 — build'; [ "$rc" -eq 0 ] || fail "the code side judged a plan-shaped file of its own as a plan (the plans are the records repo's) (rc=$rc): $out"
  ( cd "$sp/code" && git reset -q --hard HEAD~1 ) || fail "fixture: drop the plan-shaped file"
  # the records side: the stage claim needs its LOG and plan file; no count floor (a script change commits with no suite here), no skip
  # scan, no project check; the hash leg reads the extractor from the code repo — an unchanged stamped plan passes, a changed one is refused
  ( cd "$spr" && mkdir -p Tests && printf 'XCTSkip("x")\nFORBIDDEN\n' > Tests/a.swift && printf 'echo x\n' > tool.sh \
    && printf '\n## t — PLAN-01 / 01.1\nCode: abcdef1\n' >> docs/LOG.md && printf -- '- [x] 01.1\n' >> docs/plans/PLAN-01-x.md && git add -A . ) || fail "fixture: a records stage"
  RATCHET_PROJECT_CHECK='exit 1'
  pc2 "$spr"; [ "$rc" -eq 0 ] || fail "the records side ran a suite, a skip scan or the project check, or misread the code repo's extractor (rc=$rc): $out"
  cm2 "$spr" 'PLAN-01 / 01.1 — records'; [ "$rc" -eq 0 ] || fail "a records-side stage claim with its LOG and plan file was refused (rc=$rc): $out"
  ( cd "$spr" && git reset -q -- docs/LOG.md ) || fail "fixture: unstage the LOG"
  cm2 "$spr" 'PLAN-01 / 01.1 — records'; [ "$rc" -eq 1 ] && grep -qF 'no docs/LOG.md staged' <<< "$out" || fail "a records-side stage claim with no LOG passed (rc=$rc): $out"
  ( cd "$spr" && sed 's/After A, B./After A, anything./' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md && git add -A . ) || fail "fixture: a criteria edit"
  pc2 "$spr"; [ "$rc" -eq 1 ] && grep -qF 'acceptance hash mismatch for PLAN-01' <<< "$out" || fail "a records-side edit to a stamped plan passed (rc=$rc): $out"
  rc=0; out="$(cd "$spr" && RATCHET_ROOT="$(pwd -P)" bash "$sp/code/script/ratchet.sh" --recount 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'no suite' <<< "$out" || fail "a recount in the records repo must be refused (rc=$rc): $out"
  unset RATCHET_PROJECT_CHECK
  ( cd "$spr" && git reset -q && git checkout -q -- . && rm -rf Tests tool.sh t ) || fail "fixture: reset the records side"
  # the pairing, unit: the code repo's history holds PLAN-01's stage, fix and patch commits, a claim inside a `feat:` subject (the hook
  # reads it as a stage claim, so the pairing must too), a note: naming the Stage, another plan's, a bounded look-alike and a stage
  # commit that also changed a code-side LOG (never an exemption)
  ( cd "$sp/code" && for m in 'PLAN-01 / 01.1 — build' 'PLAN-01 / fix — r1' 'PLAN-012 / 012.1 — other' 'PLAN-01 / fixup — not a form' 'PLAN-01 / patch (spacing)'; do
      printf '%s\n' "$m" >> src.txt && git add src.txt && git -c core.hooksPath=/dev/null commit -qm "$m" || exit 1; done
    for m in 'feat: CSV export (PLAN-01 / 01.3)' 'note: proof blocks for PLAN-01 / 01.1'; do
      printf '%s\n' "$m" >> src.txt && git add src.txt && git -c core.hooksPath=/dev/null commit -qm "$m" || exit 1; done
    mkdir -p docs && printf '# LOG\n' > docs/LOG.md && git add docs/LOG.md && git -c core.hooksPath=/dev/null commit -qm 'PLAN-01 / 01.0 — before the split' ) || fail "fixture: the code history"
  sha_of() { ( cd "$sp/code" && git log --format=%H --grep="^$1" -n 1 ) ; }
  s1="$(sha_of 'PLAN-01 / 01\.1 ')"; s2="$(sha_of 'PLAN-01 / fix —')"; s3="$(sha_of 'PLAN-01 / patch')"; s4="$(sha_of 'PLAN-012 /')"; s5="$(sha_of 'PLAN-01 / fixup')"
  s6="$(sha_of 'feat: CSV')"; s7="$(sha_of 'note: proof')"; s0="$(sha_of 'PLAN-01 / 01\.0 ')"
  [ -n "$s1" ] && [ -n "$s2" ] && [ -n "$s3" ] && [ -n "$s4" ] && [ -n "$s5" ] && [ -n "$s6" ] && [ -n "$s7" ] && [ -n "$s0" ] || fail "fixture: the code history's shas"
  pr() { rc=0; out="$(pairing_ok PLAN-01 "$1" "$spc" 2>&1)" || rc=$?; }
  pr "$(printf 'Code: %s\nx\nCode: %s, %s\nCode: %s %s\n' "${s1:0:7}" "$s2" "$(printf '%s' "${s3:0:9}" | tr a-f A-F)" "$s6" "$s0")"; [ "$rc" -eq 0 ] || fail "a fully paired plan was refused (rc=$rc): $out"
  pr "$(printf 'Code: %s %s %s %s\n' "${s1:0:7}" "${s3:0:7}" "$s6" "$s0")"; [ "$rc" -eq 1 ] && grep -qF "${s2:0:12} PLAN-01 / fix — r1" <<< "$out" && ! grep -qF "${s1:0:12}" <<< "$out" || fail "an unpaired fix commit passed or was not named alone (rc=$rc): $out"
  grep -qF "${s7:0:12}" <<< "$out" && fail "a note: naming the Stage was counted as a builder commit: $out"
  grep -qF "${s4:0:12}" <<< "$out" && fail "another plan's commit was counted: $out"
  grep -qF "${s5:0:12}" <<< "$out" && fail "a 'fixup' subject was counted as a fix: $out"
  pr "$(printf 'Code: %s %s %s %s %s\n' "${s1:0:6}" "$s2" "$s3" "$s6" "$s0")"; [ "$rc" -eq 1 ] && grep -qF "${s1:0:12}" <<< "$out" || fail "a 6-character token named a commit (rc=$rc): $out"
  pr "$(printf -- '- Code: %s\nCode: %s %s %s %s\n' "$s1" "$s2" "$s3" "$s6" "$s0")"; [ "$rc" -eq 1 ] && grep -qF "${s1:0:12}" <<< "$out" || fail "a Code: line not at the line's start named a commit (rc=$rc): $out"
  pr "$(printf 'Code: %s %s %s %s\n' "$s1" "$s2" "$s3" "$s0")"; [ "$rc" -eq 1 ] && grep -qF "${s6:0:12} feat: CSV export (PLAN-01 / 01.3)" <<< "$out" || fail "a stage claim inside a feat: subject escaped the pairing (rc=$rc): $out"
  pr "$(printf 'Code: %s %s %s %s\n' "$s1" "$s2" "$s3" "$s6")"; [ "$rc" -eq 1 ] && grep -qF "${s0:0:12}" <<< "$out" || fail "a stage commit that also changed a code-side LOG was exempted from the pairing (rc=$rc): $out"
  rc=0; out="$(export GIT_INDEX_FILE="$spr/.git/index" GIT_DIR="$spr/.git"; pairing_ok PLAN-01 "Code: $s1 $s3 $s6 $s0" "$spc" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF "${s2:0:12}" <<< "$out" || fail "the pairing read the committing repo through a hook's GIT_DIR/GIT_INDEX_FILE instead of the code repo (rc=$rc): $out"
  rc=0; pairing_ok PLAN-01 "Code: $s1" "$d/nowhere" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "an unreadable code repo must be 2, never a pass (rc=$rc)"
  # the records-side close through the script (a stub tidy logs its arguments): tmp/PLAN-01 is looked for in the code repo and archive/ in
  # the records repo, tmp-tidy gets --root <code> --records <records>, and the pairing runs — a rotated month's Code: line counts
  mkdir -p "$d/sp-tidy"; printf '#!/bin/sh\necho "$*" >> "%s"\ncase "$*" in *--dry-run*) printf -- "- tracked: docs/plans/PLAN-01-review/notes/n.md\\n" ;; esac\nexit 0\n' "$d/sp-tidy.log" > "$d/sp-tidy/tidy"; chmod +x "$d/sp-tidy/tidy"
  ( cd "$spr" && mkdir -p docs/plans/PLAN-01-review/notes docs/log archive/plans && printf 'n\n' > docs/plans/PLAN-01-review/notes/n.md \
    && printf '# m\n\n## Tracked files\n\n- tracked: docs/plans/PLAN-01-review/notes/n.md\n' > docs/plans/PLAN-01-review/MANIFEST.md \
    && printf 'x\n' > archive/plans/PLAN-01.list && printf 'x' > archive/plans/PLAN-01.tar.gz && printf '/archive/\n' > .gitignore \
    && printf '# 2026-09\n\n## t — PLAN-01 / 01.1\nCode: %s\n' "$s1" > docs/log/2026-09.md \
    && printf '\n## t — PLAN-01 / close\nCode: %s %s %s %s\n' "$s2" "$s3" "$s6" "$s0" >> docs/LOG.md && git add -A . ) || fail "fixture: a records close"
  export RATCHET_TMP_TIDY="$d/sp-tidy/tidy"
  cm2 "$spr" 'PLAN-01 / close — done'; [ "$rc" -eq 0 ] || fail "a paired, tidied records-side close was refused (rc=$rc): $out"
  grep -qF -- "--root $spc --records $spr" "$d/sp-tidy.log" || fail "tmp-tidy was not given the code root and the records root: $(cat "$d/sp-tidy.log")"
  mkdir -p "$spc/tmp/PLAN-01"; cm2 "$spr" 'PLAN-01 / close — done'
  [ "$rc" -eq 1 ] && grep -qF "$spc/tmp/PLAN-01 still exists" <<< "$out" || fail "the close did not look for tmp/PLAN-01 in the code repo (rc=$rc): $out"
  rmdir "$spc/tmp/PLAN-01"; mkdir -p "$spr/tmp/PLAN-01"; cm2 "$spr" 'PLAN-01 / close — done'; rmdir "$spr/tmp/PLAN-01"
  [ "$rc" -eq 0 ] || fail "a tmp/PLAN-01 in the records repo (not the code repo's scratch) failed the close (rc=$rc): $out"
  mv "$spr/archive" "$spc/archive"; cm2 "$spr" 'PLAN-01 / close — done'; mv "$spc/archive" "$spr/archive"
  [ "$rc" -eq 1 ] && grep -qF 'archive/plans/PLAN-01.list is missing' <<< "$out" || fail "the close found the archive in the code repo instead of the records repo (rc=$rc): $out"
  ( cd "$spr" && git rm -q --cached docs/log/2026-09.md ) || fail "fixture: unstage the month"
  cm2 "$spr" 'PLAN-01 / close — done'; [ "$rc" -eq 1 ] && grep -qF "${s1:0:12} PLAN-01 / 01.1 — build" <<< "$out" || fail "a close with a stage commit unpaired passed (rc=$rc): $out"
  unset RATCHET_TMP_TIDY; RATCHET_TMP_TIDY="$RATCHET_DIR/tmp-tidy.sh"
  # the pre-commit hash leg's ledger: a failed listing or a failed read of the staged ledger is exit 2, never an empty ledger that checks
  # nothing (a stamped plan's edited criteria would pass)
  mkdir -p "$d/lrfk"; realgit="$(command -v git)"
  ( cd "$d" && rm -rf lr && mkdir -p lr/script lr/docs/plans && cd lr && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- a\n' > docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && git add -A . && git commit -qm init && sed 's/^- a$/- anything/' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md && git add docs/plans ) >/dev/null \
    || fail "fixture: the ledger-read repo"
  lrun() { rc=0; ( cd "$d/lr" && PATH="$d/lrfk:$PATH" RATCHET_SKIP_COUNT_FLOOR=1 bash script/ratchet.sh ) >/dev/null 2>&1 || rc=$?; }
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$realgit" > "$d/lrfk/git"; chmod +x "$d/lrfk/git"; lrun
  [ "$rc" -eq 1 ] || fail "fixture: the edited stamped plan must be refused with a working git (rc=$rc)"
  printf '#!/bin/sh\n[ "$1" = show ] && [ "$2" = ":docs/plans/.acceptance-hashes" ] && exit 73\nexec "%s" "$@"\n' "$realgit" > "$d/lrfk/git"; lrun
  [ "$rc" -eq 2 ] || fail "a failed read of the staged ledger must be exit 2, never an empty ledger (rc=$rc)"
  printf '#!/bin/sh\n[ "$1" = ls-files ] && [ "$4" = "docs/plans/.acceptance-hashes" ] && exit 73\nexec "%s" "$@"\n' "$realgit" > "$d/lrfk/git"; lrun
  [ "$rc" -eq 2 ] || fail "a failed listing of the staged ledger must be exit 2, never 'no ledger' (rc=$rc)"
  # RATCHET_ROOT naming the kit's own repo (the hooks always pass it) keeps the path the script was run by: a one-repo commit hashes with
  # the INDEX's extractor, never a working copy the physical path would make look foreign
  ( cd "$d" && rm -rf rr && mkdir -p rr/script rr/docs/plans && cd rr && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$self" script/ratchet.sh && cp "$RATCHET_TMP_TIDY" script/tmp-tidy.sh && cp "$RATCHET_EXTRACT" script/acceptance-extract.awk \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- a\n' > docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && git add -A . && git commit -qm init && printf 'BEGIN { exit }\n' > script/acceptance-extract.awk && printf 'x\n' > docs/NOTE.md && git add docs/NOTE.md \
    && RATCHET_ROOT="$(pwd -P)" RATCHET_SKIP_COUNT_FLOOR=1 bash "$(pwd)/script/ratchet.sh" >/dev/null ) \
    || fail "RATCHET_ROOT on the kit's own repo read the working copy of the extractor (the index's is the one the commit holds)"
  echo "SELF-TEST OK"; exit 0
fi

# ---------- --commit-msg ----------
if [ "${1:-}" = "--commit-msg" ]; then
  msg="$(cat "$2")"
  files="$(git diff --cached --name-only)" || exit 1
  added="$(git diff --cached -U0 --no-prefix -- "$RATCHET_LOG")" || exit 1
  la="$(added_lines <<< "$added")" || exit 2
  grew=0; [ -n "$la" ] && grew=1
  subject_readings "$msg" || exit 2
  i=1
  while [ "$i" -le "$SUBJ_N" ]; do   # under an ambiguous cleanup both readings must pass — git commits one of them
    eval "subject=\"\$SUBJ_$i\""
    docs_commit_ok "$subject" "$msg" "$files" "$grew" || exit $?   # 1 = refused, 2 = a tool error
    close="$(close_plan_in "$subject")" || exit 2
    if [ -n "$close" ]; then
      tree="$(git ls-files --cached)" || { echo "ratchet: git ls-files failed (exit $?) — the $close / close cannot be judged"; exit 2; }   # captured, then checked: a listing that failed after printing once passed the tracked half
      mpath="${RATCHET_PLANS_DIR:-docs/plans}/$close-review/MANIFEST.md"; man=""
      case $'\n'"$tree"$'\n' in *$'\n'"$mpath"$'\n'*)   # present by the checked listing: a failed read of a present blob is an error, never an empty manifest
        man="$(git show ":$mpath")" || { echo "ratchet: reading the staged $mpath failed (exit $?) — the $close / close cannot be judged"; exit 2; } ;; esac
      carried=1; mhs="$(merge_heads)" || exit 2
      if [ -n "$mhs" ] && [ -n "$RATCHET_PLANS_DIR" ]; then carried=0; merge_carries_close "$close" "$mhs" || carried=$?; fi
      [ "$carried" -le 1 ] || exit 2
      if [ "$RATCHET_SIDE" = code ]; then   # split-repo mode's code side: `PLAN-NN / close` carries the harvest; the close is the records repo's
        :
      elif [ "$carried" -eq 0 ]; then   # a merge integrating a branch that closed the plan itself: that close's hook proved the on-disk half where archive/ and tmp/ live — judge the tracked half here
        close_ritual_tracked_ok "$close" "$tree" "$man" || exit $?
      else
        check_close_ritual "$close" "$tree" . "$man" || exit $?
        if [ "$RATCHET_SIDE" = records ]; then   # the pairing: every code-side builder commit named by a Code: line
          lt="$(records_log_text)" || exit $?
          pairing_ok "$close" "$lt" "$RATCHET_CODE_ROOT" || exit $?
        fi
      fi
    fi
    i=$((i+1))
  done
  # the refreeze trace over the two ledgers: HEAD's and the index's (a deleted or reformatted row cannot hide); the code side holds no ledger
  if [ -n "$RATCHET_PLANS_DIR" ] && [ "$RATCHET_SIDE" != code ]; then
    old_ledger=""; new_ledger=""   # presence by a checked listing; a failed read is an error, never an empty ledger
    rc=0; git rev-parse -q --verify HEAD >/dev/null 2>&1 || rc=$?
    [ "$rc" -le 1 ] || { echo "ratchet: git could not resolve HEAD (exit $rc) — refusing to read that as an unborn repository" >&2; exit 2; }   # 1 = unborn, established; anything else is an error
    if [ "$rc" -eq 0 ]; then
      has="$(git ls-tree --name-only HEAD -- "$RATCHET_HASHES")" || exit 2
      [ -z "$has" ] || old_ledger="$(git show "HEAD:$RATCHET_HASHES")" || exit 2
    fi
    has="$(git ls-files --cached -- "$RATCHET_HASHES")" || exit 2
    [ -z "$has" ] || new_ledger="$(git show ":$RATCHET_HASHES")" || exit 2
    lp="$(git diff --cached -U0 --no-prefix -- "$RATCHET_AMENDS")" || exit 1; ad="$(added_lines <<< "$lp")" || exit 2
    ps=0; printf '%s\n' "$files" | grep -qx 'PLAN.md' && ps=1
    i=1
    while [ "$i" -le "$SUBJ_N" ]; do eval "subject=\"\$SUBJ_$i\""; refreeze_trace_ok "$subject" "$old_ledger" "$new_ledger" "$ad" "$ps" || exit 1; i=$((i+1)); done
    # the draft's criteria: a builder commit leaves an unstamped plan's Validation and Acceptance alone — HEAD's ledger names
    # the stamps; a merge in progress is no builder commit (its branch's commits were judged one by one). Any reading that is a
    # builder's subjects the commit to the check (git commits one of them); the extractor is HEAD's copy where HEAD holds one
    hashead="$rc"; mhs="$(merge_heads)" || exit 2
    cplans=""; [ -n "$mhs" ] || { cplans="$(unstamped_changed_plans "$old_ledger" "$files")" || exit $?; }
    claim=""
    if [ -n "$cplans" ]; then
      i=1; while [ "$i" -le "$SUBJ_N" ]; do eval "subject=\"\$SUBJ_$i\""; bc="$(builder_claim "$subject" "$msg")" || exit 2; [ -n "$claim" ] || claim="$bc"; i=$((i+1)); done
    fi
    if [ -n "$claim" ]; then
      olds=""; [ "$hashead" -ne 0 ] || { olds="$(git ls-tree -r --name-only HEAD -- "$RATCHET_PLANS_DIR")" || exit 2; }
      news="$(git ls-files --cached -- "$RATCHET_PLANS_DIR")" || exit 2
      exrel="${RATCHET_EXTRACT#$PWD/}"; hx=""; ix=""; cex="$RATCHET_EXTRACT"
      case "$exrel" in /*) ;; *)   # an extractor configured outside the repo is read where it is
        [ "$hashead" -ne 0 ] || { hx="$(git ls-tree --name-only HEAD -- "$exrel")" || exit 2; }
        ix="$(git ls-files --cached -- "$exrel")" || exit 2 ;; esac
      if [ -n "$hx$ix" ]; then
        cex="$(mktemp)" || exit 2; trap 'rm -f "$cex"' EXIT
        if [ -n "$hx" ]; then git show "HEAD:$exrel" > "$cex" || exit 2; else git show ":$exrel" > "$cex" || exit 2; fi
      fi
      crit_show() { if [ "$1" = old ]; then git show "HEAD:$2"; else git show ":$2"; fi; }
      RATCHET_EXTRACT="$cex" criteria_unchanged_ok "$claim" "$cplans" "$olds" "$news" crit_show || exit $?
    fi
  fi
  exit 0
fi

# ---------- pre-commit legs, cheapest first ----------
staged_files="$(git diff --cached --name-only)" || exit 1                                     # a git failure is an error, never "clean"
present_files="$(git diff --cached --name-only --diff-filter=d)" || exit 1                   # everything but deletions (a rename INTO a key name counts): a deleted key file is the fix, not a finding
# (a) skip markers — test files only: a docs line or an app-code `.disabled(` view modifier never trips it; the allowlist is read from the INDEX
test_files=""; [ "$RATCHET_SIDE" = records ] || { test_files="$(grep_hits "$RATCHET_TEST_PATH_REGEX" <<< "$staged_files")" || exit 2; }   # the records repo has no tests
if [ -n "$test_files" ]; then
  added_test=""
  lines_of "$test_files"
  for f in ${LINES_OF[@]+"${LINES_OF[@]}"}; do
    fdiff="$(git diff --cached -U0 --no-prefix -- "$f")" || exit 1
    added_test="$added_test"$'\n'"$fdiff"
  done
  skip_scan "$added_test" "$(git show ":$RATCHET_ALLOWLIST" 2>/dev/null || true)" || exit 1
fi
# (b) secrets — the Never list, wired: added/modified file names, then every added line of the staged diff
whole="$(git diff --cached -U0 --no-prefix)" || exit 1
secret_scan "$present_files" "$whole" || exit 1
conflict_scan "$whole" || exit $?                                                            # a resolution staged with its markers still in
# (c) tmp/ cites — PLAN.md read from the INDEX (a close flips its row in the same commit)
planmd=""; has="$(git ls-files --cached -- PLAN.md)" || exit 2
[ -z "$has" ] || planmd="$(git show :PLAN.md)" || exit 2                                     # the INDEX copy; absent = no rows = any plan cite refused
others=(); mhs="$(merge_heads)" || exit 2                                                    # a merge concluded by `git commit`: each cite judged against every parent
lines_of "$mhs"; for h in ${LINES_OF[@]+"${LINES_OF[@]}"}; do d="$(git diff --cached -U0 --no-prefix "$h")" || exit 1; f="$(fresh_cites <<< "$d")" || exit 2; others+=("$f"); done
tmp_cite_guard "$planmd" ${others[@]+"${others[@]}"} <<< "$whole" || exit 1
# (d) acceptance hashes — the INDEX copies of the ledger, each plan file, and the extractor itself; nothing falls back to disk
# (the code side holds no ledger of the plans, which are the records repo's: the leg is the records side's and one-repo's). Presence is a
# checked listing and the ledger a checked read: a failed git call is exit 2, never "no ledger" or an empty one that checks nothing
hl=""; if [ -n "$RATCHET_PLANS_DIR" ] && [ "$RATCHET_SIDE" != code ]; then
  hl="$(git ls-files --cached -- "$RATCHET_HASHES")" || { echo "ratchet: listing the staged $RATCHET_HASHES failed — the hashes can't be checked"; exit 2; }
fi
if [ -n "$hl" ]; then
  ledger="$(git show ":$RATCHET_HASHES")" || { echo "ratchet: reading the staged $RATCHET_HASHES failed — the hashes can't be checked"; exit 2; }
  ex="$(mktemp)"; trap 'rm -f "$ex"' EXIT
  exrel="${RATCHET_EXTRACT#$PWD/}"
  case "$exrel" in
    /*) cp "$RATCHET_EXTRACT" "$ex" || { echo "ratchet: reading the extractor $RATCHET_EXTRACT failed — the hashes can't be checked"; exit 2; } ;;   # outside this repo (split-repo mode's records side: the code repo's kit): read where it is
    *) git show ":$exrel" > "$ex" 2>/dev/null || { echo "ratchet: the extractor $exrel is not in the index — commit/stage it (the guard hashes with the extractor the commit will hold, never a working copy)"; exit 1; } ;;
  esac
  RATCHET_EXTRACT="$ex" check_acceptance_hashes "$ledger" plan_content_index || exit 1
fi
# (e) the project's own check (RATCHET_PROJECT_CHECK) over the staged diff; the records side has none
if [ "$RATCHET_SIDE" != records ]; then project_check "$whole" || exit $?; fi
# (f) count floor — last, because it builds and tests; docs-only skips; CI sets RATCHET_SKIP_COUNT_FLOOR=1 and runs the suite itself;
# the records repo has no suite
if [ "${RATCHET_SKIP_COUNT_FLOOR:-}" != "1" ] && [ "$RATCHET_SIDE" != records ]; then
  count_floor "$(git diff --cached --name-only --no-renames)" || exit 1
fi
