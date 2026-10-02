#!/usr/bin/env bash
# ci-replay.sh: CI's replay of the local hooks over every commit in a push range. It sources ratchet.sh
# (`RATCHET_LIB=1 . script/ratchet.sh`) and calls the same decision functions, so a commit that skipped its hooks
# (--no-verify, a clone without them) still turns CI red. Rules: protocol/verification.md § The test ratchet,
# § Enforce the freeze, § The docs-commit guard.
#
# Kit copy: install as script/ci-replay.sh beside ratchet.sh. It reads the same RATCHET_* variables / ratchet.conf.
#
# Usage
#   ci-replay.sh <base>..<head>     replay every commit in the range; run it in CI before the suite
#   ci-replay.sh --self-test
#
# Per commit it checks: the docs-commit rules (stage claim, LOG forms), skip markers, secrets, tmp/ cites (against that
# commit's own PLAN.md; on a merge, only a cite new against every parent), the acceptance hashes (from the commit's own
# ledger, plans and extractor), the refreeze trace (against the parent's ledger), that a builder commit leaves an
# unstamped plan's Validation and Acceptance unchanged (a merge is judged through its branch's commits), and the close's
# tracked half (the committed MANIFEST's inventory). Then it runs the ratchet's index checks on the head tree in a
# detached worktree, with the count floor skipped: CI runs the suite once in its own Test step. The on-disk halves of
# the close (archive/, tmp/) exist only on the committing machine and aren't checked here.
#
# The project's own check (RATCHET_PROJECT_CHECK, ratchet.sh's header) runs per commit over its first-parent diff.
#
# Split-repo mode (RATCHET_RECORDS set; modules/split-repo.md; ratchet.sh's header has the rule table): each repo replays
# itself. In the code repo, run it as above: the code side's rules. For the records repo, check it out at the code repo's
# $RATCHET_RECORDS (the nested layout — the side is found from where the records repo sits) and run the code repo's kit with
# RATCHET_ROOT=<that records checkout>: the records side's rules. The pairing isn't replayed — a stream's code branch is gone
# once it merges; the records-side close's hook is its gate.
#
# RATCHET_CI_SKIP_DEFAULT_MERGE_HEAD=true exempts only the message rule on a head commit that is a default-branch merge
# (a PR merge commit has no LOG entry of its own); its content and ledger checks still run over its first-parent diff.
#
# Exit codes: 0 every commit passes · 1 a commit is refused (the message names it and the rule) · 2 a tool failed,
# including a worktree that can't be made (never a skipped check)
set -eu   # NOT pipefail — the kit's rule (ratchet.sh's header): the sourced decisions and everything below capture each producer, then check it
HERE="$(cd "$(dirname "$0")" && pwd)"
RATCHET_LIB=1 . "$HERE/ratchet.sh"
if [ -n "${RATCHET_ROOT:-}" ]; then   # the repo to replay (the records repo's checkout, in split-repo mode); the kit's own repo keeps its path
  rr="$(cd "$RATCHET_ROOT" && pwd -P)" || { echo "ci-replay: RATCHET_ROOT ($RATCHET_ROOT) can't be entered" >&2; exit 2; }
  kr="$(cd "$HERE/.." && pwd -P)" || { echo "ci-replay: reading this script's repo path failed" >&2; exit 2; }
  if [ "$rr" = "$kr" ]; then cd "$HERE/.."; else cd "$RATCHET_ROOT"; fi
else
  cd "$HERE/.."
fi
if [ "${1:-}" != "--self-test" ]; then ratchet_roots || exit 2; fi

usage() { echo "usage: $0 <base>..<head> | --self-test" >&2; }
empty_tree="$(git hash-object -t tree /dev/null)"

first_parent_or_empty_tree() {   # → the first parent, or the empty tree ONLY after a successful lookup shows no parent; a failed lookup is exit 2
  local p; p="$(git rev-list --parents -n 1 "$1")" || return 2
  set -- $p; [ "$#" -ge 1 ] && [ "$1" = "$(git rev-parse --verify "${1}^{commit}" 2>/dev/null)" ] || return 2   # the first token is the commit itself
  shift; if [ "$#" -gt 0 ]; then printf '%s\n' "$1"; else printf '%s\n' "$empty_tree"; fi
}
files_of()    { local p; p="$(first_parent_or_empty_tree "$1")" || return 2; git diff-tree --no-commit-id --name-only -r "$p" "$1"; }
present_of()  { local p; p="$(first_parent_or_empty_tree "$1")" || return 2; git diff-tree --no-commit-id --name-only -r --diff-filter=d "$p" "$1"; }   # everything but deletions (a rename INTO a key name counts): a deleted key file is the fix
patch_of()    { local p; p="$(first_parent_or_empty_tree "$1")" || return 2; git diff-tree --unified=0 --no-prefix -p "$p" "$1" -- "${@:2}" || { echo "ci-replay: git diff-tree failed for $1" >&2; return 2; }; }   # a git failure is an error, never an empty (clean) patch — every caller captures it FIRST and checks
subject_of()  { git show -s --format=%s "$1"; }
message_of()  { git show -s --format=%B "$1"; }
blob_of() {   # $1 = commit, $2 = path → its content; empty ONLY when a checked listing shows the commit holds no such path; 2 on a failed
  # listing or a failed read of a present blob (a `git show … || true` read every failure as "absent" — a PLAN.md that failed to read became
  # "no rows", an allowlist that failed became "none") — every caller captures and checks it
  local has; has="$(git ls-tree --name-only "$1" -- "$2")" || { echo "ci-replay: listing $2 in $1 failed" >&2; return 2; }
  [ -n "$has" ] || return 0
  git show "$1:$2" || { echo "ci-replay: reading $2 in $1 failed" >&2; return 2; }
}
is_default_merge() { local c="$1" p; p="$(git rev-list --parents -n 1 "$c")" || return 2; set -- $p; shift; [ "$#" -gt 1 ] && grep -qE '^Merge ' <<< "$(subject_of "$c")"; }   # $c saved first: after `set --`, $1 is a parent; a failed lookup is 2

REPLAY_COMMIT=""; CRIT_OLD=""; CRIT_NEW=""
crit_show_commit() { if [ "$1" = old ]; then git show "$CRIT_OLD:$2"; else git show "$CRIT_NEW:$2"; fi; }   # the criteria leg's SHOW: the parent's blob, the commit's blob
plan_content_commit() {   # $1 = PLAN-NN → that plan's blob in $REPLAY_COMMIT (resolved from the commit's tree, never the checkout)
  local f ls n=0 l
  ls="$(git ls-tree -r --name-only "$REPLAY_COMMIT" -- "$RATCHET_PLANS_DIR")" || return 2   # captured, then filtered: a `ls-tree | grep` lost ls-tree's status
  f="$(grep_hits "^$RATCHET_PLANS_DIR/$1-[^/]*\.md\$" <<< "$ls")" || return 2
  while IFS= read -r l; do [ -n "$l" ] && n=$((n+1)); done <<< "$f"
  [ "$n" -eq 1 ] || return 1
  git show "$REPLAY_COMMIT:$f"
}
replay_commit() {   # $1 = commit, $2 = 1 to exempt the MESSAGE rule only (a PR-merge head) → 0 iff every per-commit guard
  # passes; each refusal is named with the commit. Called in an `||` context, so no `set -e` inside: every producer is
  # captured and checked explicitly before its output is judged.
  local c="$1" nomsg="${2:-0}" msg subject files present grew added lp planmd close tree man old new ad ps test_files f added_test allow ex parent whole has hasp
  msg="$(message_of "$c")" || return 2; files="$(files_of "$c")" || return 2; present="$(present_of "$c")" || return 2
  parent="$(first_parent_or_empty_tree "$c")" || return 2; whole="$(patch_of "$c")" || return 2
  # docs-commit decision (exempt on a merge head whose message is git's own)
  lp="$(patch_of "$c" "$RATCHET_LOG")" || return 2; added="$(added_lines <<< "$lp")" || return 2; grew=0; [ -n "$added" ] && grew=1
  subject="$(subject_of "$c")" || return 2   # the COMMITTED subject — never re-derived from the body
  if [ "$nomsg" = 1 ]; then echo "ci-replay: $c is a merge head — its message rule is exempt; content and ledger checks run on its first-parent diff"
  else docs_commit_ok "$subject" "$msg" "$files" "$grew" || { echo "ci-replay: $c: see the ratchet line above" >&2; return 1; }; fi
  # skip markers over the commit's test files, allowlist as of that commit
  test_files=""; [ "$RATCHET_SIDE" = records ] || { test_files="$(grep_hits "$RATCHET_TEST_PATH_REGEX" <<< "$present")" || return 2; }   # the records repo has no tests
  if [ -n "$test_files" ]; then
    added_test=""
    while IFS= read -r f; do [ -n "$f" ] || continue; lp="$(patch_of "$c" "$f")" || return 2; added_test="$added_test"$'\n'"$lp"; done <<< "$test_files"
    allow="$(blob_of "$c" "$RATCHET_ALLOWLIST")" || return 2
    skip_scan "$added_test" "$allow" || { echo "ci-replay: $c adds an unlisted skip marker" >&2; return 1; }
  fi
  # secrets (added/modified files only)
  secret_scan "$present" "$whole" || { echo "ci-replay: $c: a secret-shaped file or line" >&2; return 1; }
  # the project's own check over the commit's first-parent diff (none on the records side)
  if [ "$RATCHET_SIDE" != records ]; then
    local pr=0; project_check "$whole" || pr=$?
    [ "$pr" -eq 0 ] || { [ "$pr" -eq 1 ] && echo "ci-replay: $c: see the ratchet line above" >&2; return "$pr"; }
  fi
  # tmp/ cites against the commit's own PLAN.md (the row statuses as of that commit)
  planmd="$(blob_of "$c" PLAN.md)" || return 2
  # a merge: a cite is new only if it is new against every parent (the lines a closed plan's branch wrote while open are inherited)
  local others=() op ops d f ps_; ps_="$(git rev-list --parents -n 1 "$c")" || return 2; ops="$(cut -s -d' ' -f3- <<< "$ps_")" || return 2
  for op in $ops; do d="$(git diff-tree --unified=0 --no-prefix -p "$op" "$c")" || return 2; f="$(fresh_cites <<< "$d")" || return 2; others+=("$f"); done
  tmp_cite_guard "$planmd" ${others[@]+"${others[@]}"} <<< "$whole" || { echo "ci-replay: $c adds a docs line citing tmp/ scratch outside an open plan's tmp/PLAN-NN/" >&2; return 1; }
  # acceptance hashes from the COMMIT's ledger, plans, and extractor; then the refreeze trace against the parent's ledger
  # (split-repo mode's code side skips this leg and the criteria leg below, as its hook does: the plans and their ledger are the records
  # repo's, so a ledger in the code repo — or its deletion, when a one-repo project moves its records out — is no freeze record)
  has=""; hasp=""
  if [ -n "$RATCHET_PLANS_DIR" ] && [ "$RATCHET_SIDE" != code ]; then   # presence by a CHECKED tree listing (a failed probe is an error, never "absent")
    has="$(git ls-tree --name-only "$c" -- "$RATCHET_HASHES")" || return 2
    [ "$parent" = "$empty_tree" ] || { hasp="$(git ls-tree --name-only "$parent" -- "$RATCHET_HASHES")" || return 2; }
  fi
  if [ -n "$has" ]; then
    ex="$(mktemp)" || return 2
    case "${RATCHET_EXTRACT#$PWD/}" in
      /*) cp "$RATCHET_EXTRACT" "$ex" || { rm -f "$ex"; echo "ci-replay: reading the extractor $RATCHET_EXTRACT failed" >&2; return 2; } ;;   # outside this repo (split-repo mode's records side): read where it is
      *) git show "$c:${RATCHET_EXTRACT#$PWD/}" > "$ex" 2>/dev/null || { rm -f "$ex"; echo "ci-replay: $c stamps plans but does not hold the extractor ${RATCHET_EXTRACT#$PWD/}" >&2; return 1; } ;;
    esac
    new="$(git show "$c:$RATCHET_HASHES")" || { rm -f "$ex"; return 2; }
    REPLAY_COMMIT="$c" RATCHET_EXTRACT="$ex" check_acceptance_hashes "$new" plan_content_commit \
      || { rm -f "$ex"; echo "ci-replay: $c: see the ratchet line above (a frozen section changed without a re-stamp)" >&2; return 1; }
    rm -f "$ex"
    old=""; [ -z "$hasp" ] || { old="$(git show "$parent:$RATCHET_HASHES")" || return 2; }
    lp="$(patch_of "$c" "$RATCHET_AMENDS")" || return 2; ad="$(added_lines <<< "$lp")" || return 2
    ps=0; grep -qx 'PLAN.md' <<< "$files" && ps=1
    refreeze_trace_ok "$subject" "$old" "$new" "$ad" "$ps" || { echo "ci-replay: $c: see the ratchet line above" >&2; return 1; }
  elif [ -n "$hasp" ]; then
    echo "ci-replay: $c deletes $RATCHET_HASHES — once stamped, always stamped" >&2; return 1
  fi
  # the draft's criteria: a builder commit leaves an unstamped plan's Validation and Acceptance alone — the PARENT's ledger
  # names the stamps and the parent's extractor (where it holds one) does the reading; a merge is no builder commit (each commit of
  # its branch replays on its own) — so a stage commit made with --no-verify is caught here
  if [ -n "$RATCHET_PLANS_DIR" ] && [ -z "$ops" ] && [ "$RATCHET_SIDE" != code ]; then
    local oldl="" cplans claim="" olds="" news exrel px="" cx="" cex rc=0
    [ -z "$hasp" ] || { oldl="$(git show "$parent:$RATCHET_HASHES")" || return 2; }
    cplans="$(unstamped_changed_plans "$oldl" "$files")" || { rc=$?; [ "$rc" -eq 1 ] && echo "ci-replay: $c: see the ratchet line above" >&2; return "$rc"; }
    [ -z "$cplans" ] || { claim="$(builder_claim "$subject" "$msg")" || return 2; }
    if [ -n "$claim" ]; then
      [ "$parent" = "$empty_tree" ] || { olds="$(git ls-tree -r --name-only "$parent" -- "$RATCHET_PLANS_DIR")" || return 2; }
      news="$(git ls-tree -r --name-only "$c" -- "$RATCHET_PLANS_DIR")" || return 2
      exrel="${RATCHET_EXTRACT#$PWD/}"; cex="$RATCHET_EXTRACT"
      case "$exrel" in /*) ;; *)
        [ "$parent" = "$empty_tree" ] || { px="$(git ls-tree --name-only "$parent" -- "$exrel")" || return 2; }
        cx="$(git ls-tree --name-only "$c" -- "$exrel")" || return 2 ;; esac
      if [ -n "$px$cx" ]; then
        cex="$(mktemp)" || return 2
        if [ -n "$px" ]; then git show "$parent:$exrel" > "$cex" || { rm -f "$cex"; return 2; }; else git show "$c:$exrel" > "$cex" || { rm -f "$cex"; return 2; }; fi
      fi
      CRIT_OLD="$parent" CRIT_NEW="$c" RATCHET_EXTRACT="$cex" criteria_unchanged_ok "$claim" "$cplans" "$olds" "$news" crit_show_commit || rc=$?
      [ "$cex" = "$RATCHET_EXTRACT" ] || rm -f "$cex"
      [ "$rc" -eq 0 ] || { [ "$rc" -eq 1 ] && echo "ci-replay: $c: see the ratchet line above (a builder commit edited an unstamped plan's criteria)" >&2; return "$rc"; }
    fi
  fi
  # the close ritual's tracked half
  close="$(close_plan_in "$subject")" || return 2
  if [ -n "$close" ] && [ -n "$RATCHET_PLANS_DIR" ] && [ "$RATCHET_SIDE" != code ]; then   # Lite with inline plans has no review dir — nothing tracked to replay; split-repo mode's code-side close is the harvest
    tree="$(git ls-tree -r --name-only "$c")" || return 2; man="$(blob_of "$c" "$RATCHET_PLANS_DIR/$close-review/MANIFEST.md")" || return 2
    close_ritual_tracked_ok "$close" "$tree" "$man" || { echo "ci-replay: $c is a $close / close without its tidied evidence in the commit" >&2; return 1; }
  fi
  return 0
}

run_ratchet_on_head_tree() {   # the index legs over the head tree in a detached worktree; the count floor is CI's own Test step
  local head="$1" wt rc; wt="$(mktemp -d)" || { echo "ci-replay: mktemp failed" >&2; return 2; }
  if [ "$RATCHET_SIDE" = records ]; then run_records_on_head_tree "$head" "$wt"; return $?; fi
  CI_WT="$wt"   # global: the trap runs after this function has returned, when a local is gone (unbound under set -u, which turned a 2 into a 1)
  trap 'git worktree remove --force "$CI_WT" >/dev/null 2>&1 || rm -rf "$CI_WT"' EXIT INT TERM
  git worktree add --detach "$wt" "$head" >/dev/null 2>&1 || { echo "ci-replay: could not check out the head tree in a detached worktree (git worktree add exit $?) — no verdict on the head" >&2; return 2; }
  ( cd "$wt" && unset RATCHET_ROOT && { git add -A . >/dev/null 2>&1 || { echo "ci-replay: git add -A failed in the head's worktree" >&2; exit 2; }; } && RATCHET_SKIP_COUNT_FLOOR=1 "$wt/script/ratchet.sh" ) \
    || { rc=$?; [ "$rc" -eq 2 ] && { echo "ci-replay: the head tree's check could not run (exit 2)" >&2; return 2; }; echo "ci-replay: the head tree fails the ratchet's index legs" >&2; return 1; }
  git worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"; trap - EXIT INT TERM
}
run_records_on_head_tree() {   # split-repo mode's records side: the records repo holds no kit, so the head is checked out at <tmp>/$RATCHET_RECORDS
  # beside a copy of this kit at <tmp>/script — the nested layout the side is found from — and that kit's ratchet runs its index legs
  local head="$1" base="$2" wt kit rc
  wt="$base/$RATCHET_RECORDS"; kit="$base/script"
  CI_WT="$wt"; CI_BASE="$base"
  trap 'git worktree remove --force "$CI_WT" >/dev/null 2>&1; rm -rf "$CI_BASE"' EXIT INT TERM
  mkdir -p "$kit" "$(dirname "$wt")" && cp "$RATCHET_SELF" "$kit/ratchet.sh" && cp "$RATCHET_EXTRACT" "$kit/acceptance-extract.awk" && cp "$RATCHET_TMP_TIDY" "$kit/tmp-tidy.sh" \
    && { [ ! -f "$RATCHET_DIR/ratchet.conf" ] || cp "$RATCHET_DIR/ratchet.conf" "$kit/ratchet.conf"; } \
    || { echo "ci-replay: could not lay out the kit beside the records head — no verdict on the head" >&2; return 2; }
  git worktree add --detach "$wt" "$head" >/dev/null 2>&1 || { echo "ci-replay: could not check out the records head in a detached worktree (git worktree add exit $?) — no verdict on the head" >&2; return 2; }
  ( cd "$wt" && { git add -A . >/dev/null 2>&1 || { echo "ci-replay: git add -A failed in the head's worktree" >&2; exit 2; }; } \
    && RATCHET_ROOT="$wt" RATCHET_RECORDS="$RATCHET_RECORDS" RATCHET_EXTRACT="$kit/acceptance-extract.awk" RATCHET_TMP_TIDY="$kit/tmp-tidy.sh" RATCHET_SKIP_COUNT_FLOOR=1 "$kit/ratchet.sh" ) \
    || { rc=$?; [ "$rc" -eq 2 ] && { echo "ci-replay: the records head's check could not run (exit 2)" >&2; return 2; }; echo "ci-replay: the records head fails the ratchet's index legs" >&2; return 1; }
  git worktree remove --force "$wt" >/dev/null 2>&1; rm -rf "$base"; trap - EXIT INT TERM
}

if [ "${1:-}" = "--self-test" ]; then
  # the probes prove the CODE against fixed fixtures — a project's ratchet.conf is reset to the defaults here; the Lite probe sets its own
  RATCHET_LOG=docs/LOG.md; RATCHET_PLANS_DIR=docs/plans; RATCHET_HASHES=docs/plans/.acceptance-hashes; RATCHET_AMENDS=docs/plans/.acceptance-amends
  RATCHET_ALLOWLIST=docs/test-allowlist.md; RATCHET_RESUME_NOTE=tmp/resume-note.md
  RATCHET_RECORDS=; RATCHET_PROJECT_CHECK=; RATCHET_SIDE=one; unset RATCHET_ROOT   # one-repo; the split-repo probes set their own
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  cd "$d" && git init -q . && git config user.email t@t && git config user.name t
  mkdir -p docs/plans script && cp "$HERE/ratchet.sh" "$HERE/acceptance-extract.awk" "$HERE/tmp-tidy.sh" script/
  RATCHET_EXTRACT="$d/script/acceptance-extract.awk"; RATCHET_TMP_TIDY="$d/script/tmp-tidy.sh"
  mk() { local idx t; idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
         if [ -n "$1" ]; then git commit-tree "$t" -p "$1" -m "$2"; else git commit-tree "$t" -m "$2"; fi; }
  printf '# PLAN\n\n| Plan | File | Status | Depends | Est |\n|---|---|---|---|---|\n| **PLAN-01** done | [x](docs/plans/PLAN-01-x.md) | complete | none | 1d |\n| **PLAN-02** live | [y](docs/plans/PLAN-02-y.md) | in-progress | PLAN-01 | 2d |\n' > PLAN.md
  printf '# LOG\n' > docs/LOG.md
  printf '# PLAN-02\n\n## Validation and Acceptance\n\n- x\n' > docs/plans/PLAN-02-y.md
  c0="$(mk "" init)"
  # 1. a tidied close passes; without the inventory or with an uncommitted inventoried path it is refused and named
  mkdir -p docs/plans/PLAN-01-review/prompts && printf 'go\n' > docs/plans/PLAN-01-review/prompts/01.1-prompt.md
  printf '# m\n| `tmp/plan01-L2.log` | archive |\n\n## Tracked files\n\n- tracked: docs/plans/PLAN-01-review/prompts/01.1-prompt.md\n' > docs/plans/PLAN-01-review/MANIFEST.md
  printf '\n## t — PLAN-01 / close\nevidence: docs/plans/PLAN-01-review/MANIFEST.md\n' >> docs/LOG.md
  c1="$(mk "$c0" "PLAN-01 / close: done")"; replay_commit "$c1" || fail "a tidied close was refused: $(replay_commit "$c1" 2>&1 || true)"
  printf '# m\n| `tmp/plan01-L2.log` | archive |\n' > docs/plans/PLAN-01-review/MANIFEST.md
  out="$(replay_commit "$(mk "$c0" "PLAN-01 / close: done")" 2>&1 || true)"; grep -qF "no '## Tracked files'" <<< "$out" || fail "a manifest without an inventory passed: $out"
  printf '# m\n\n## Tracked files\n\n- tracked: docs/plans/PLAN-01-review/prompts/01.1-prompt.md\n- tracked: docs/plans/PLAN-01-review/shots/missing.png\n' > docs/plans/PLAN-01-review/MANIFEST.md
  out="$(replay_commit "$(mk "$c0" "PLAN-01 / close: done")" 2>&1 || true)"; grep -qF 'shots/missing.png' <<< "$out" || fail "an inventoried path absent from the tree was not named: $out"
  rm -rf docs/plans/PLAN-01-review; git checkout -q "$c0" -- docs/LOG.md
  # 2. forms and their boundary; a stage claim needs the LOG + the plan file (a review-dir edit is not the plan file)
  printf '\n## t — note\nx\n' >> docs/LOG.md; replay_commit "$(mk "$c0" "note: x")" || fail "a note: commit was refused"
  replay_commit "$(mk "$c0" "PLAN-01 / patch: spacing")" || fail "a patch form was refused"
  replay_commit "$(mk "$c0" "PLAN-01 / fix — a fix batch across Stages")" || fail "a fix form was refused"
  for m in "PLAN-01 / patchwork" "PLAN-01 / review2" "PLAN-01 / fixup" "chore: grow LOG with no form"; do replay_commit "$(mk "$c0" "$m")" >/dev/null 2>&1 && fail "'$m' passed"; done
  git checkout -q "$c0" -- docs/LOG.md
  mkdir -p docs/plans/PLAN-02-review/notes && printf 'e\n' > docs/plans/PLAN-02-review/notes/e.md; printf '\n## t — PLAN-02 / 02.1\nstage\n' >> docs/LOG.md
  replay_commit "$(mk "$c0" "feat: work (PLAN-02 / 02.1)")" >/dev/null 2>&1 && fail "a review-dir edit satisfied the plan-file rule"
  rm -rf docs/plans/PLAN-02-review; sed '1s/$/ (02.1 in progress)/' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md   # outside Validation and Acceptance
  replay_commit "$(mk "$c0" "feat: work (PLAN-02 / 02.1)")" || fail "a conforming stage commit was refused"
  git checkout -q "$c0" -- docs/LOG.md docs/plans/PLAN-02-y.md
  replay_commit "$(git commit-tree "$c0^{tree}" -p "$c0" -m "feat: fake (PLAN-02 / 02.1)")" >/dev/null 2>&1 && fail "a stage claim with no diff passed"
  # 3. tmp/ cites judged against the row status AS OF THAT COMMIT; rotated history out of scope
  printf '\n## t — note\n`tmp/PLAN-02/02.1-run.log`, `tmp/PLAN-NN/<stage>-<kind>[-rN].<ext>`, /tmp/x\n' >> docs/LOG.md
  replay_commit "$(mk "$c0" "note: live cites")" || fail "allowed cites tripped"
  printf '`tmp/PLAN-01/01.2-verdict.md`\n' >> docs/LOG.md
  replay_commit "$(mk "$c0" "note: stale")" >/dev/null 2>&1 && fail "a closed plan's cite passed"
  git checkout -q "$c0" -- docs/LOG.md
  printf '\n## t — note\n`tmp/PLAN-02/02.1-run.log`\n' >> docs/LOG.md; sed 's/| in-progress |/| complete |/' PLAN.md > t && mv t PLAN.md
  replay_commit "$(mk "$c0" "note: close-time cite")" >/dev/null 2>&1 && fail "a cite of the plan being closed passed"
  git checkout -q "$c0" -- PLAN.md docs/LOG.md
  mkdir -p docs/log && printf '## old\n`tmp/legacy.log`\n' > docs/log/2026-08.md
  replay_commit "$(mk "$c0" "note: rotate")" || fail "rotated history tripped"; rm -rf docs/log
  # 4. secrets and skip markers per commit
  printf 'k\n' > docs/dev.p12; replay_commit "$(mk "$c0" "note: oops")" >/dev/null 2>&1 && fail "a .p12 passed"; rm -f docs/dev.p12
  mkdir -p AppTests && printf 'func testA() { XCTSkip("x") }\n' > AppTests/ATests.swift
  replay_commit "$(mk "$c0" "note: skip")" >/dev/null 2>&1 && fail "an unlisted skip passed"
  printf -- '- testA\n' > docs/test-allowlist.md; replay_commit "$(mk "$c0" "note: skip")" || fail "a listed skip was refused"
  rm -rf AppTests docs/test-allowlist.md
  # 5. acceptance hashes and the refreeze trace per commit: a freeze needs PLAN.md; a real stamp reproduces; a weakened section
  #    in a LATER commit trips even when a still-later commit restores it (per-commit, not head-only); a quiet re-stamp is
  #    refused, a traced one passes; a deleted ledger is refused
  cp "$HERE/acceptance-extract.awk" script/acceptance-extract.awk
  h="$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-02-y.md)"
  printf 'PLAN-02 %s   # frozen\n' "$h" > docs/plans/.acceptance-hashes; ca="$(mk "$c0" "note: freeze")"
  replay_commit "$ca" >/dev/null 2>&1 && fail "a first stamp without PLAN.md in the commit passed"
  printf '\n' >> PLAN.md; ca="$(mk "$c0" "note: freeze")"; replay_commit "$ca" || fail "a freeze with PLAN.md and a true stamp was refused: $(replay_commit "$ca" 2>&1 || true)"
  printf 'PLAN-02 0000 # bogus\n' > docs/plans/.acceptance-hashes; cbog="$(mk "$c0" "note: freeze")"
  replay_commit "$cbog" >/dev/null 2>&1 && fail "a stamp that does not match the plan passed"
  printf 'PLAN-02 %s   # frozen\n' "$h" > docs/plans/.acceptance-hashes
  printf 'weakened\n' >> docs/plans/PLAN-02-y.md; cw="$(mk "$ca" "note: weaken")"
  git checkout -q "$ca" -- docs/plans/PLAN-02-y.md; cr="$(mk "$cw" "note: restore")"
  replay_commit "$cw" >/dev/null 2>&1 && fail "a commit that weakened a frozen section passed the per-commit hash replay"
  replay_commit "$cr" || fail "the restoring commit was refused"
  printf 'weakened\n' >> docs/plans/PLAN-02-y.md; h2="$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-02-y.md)"
  printf 'PLAN-02 %s   # frozen; re-stamped\n' "$h2" > docs/plans/.acceptance-hashes
  out="$(replay_commit "$(mk "$ca" "note: quiet re-stamp")" 2>&1 || true)"; grep -qF 'no '"'"'PLAN-02 / refreeze'"'"'' <<< "$out" || fail "an untraced re-stamp (with a TRUE digest) was not refused for its missing trace: $out"
  printf 'PLAN-02 %s   # frozen; re-stamped\n' "$h2" > docs/plans/.acceptance-hashes; printf '2026  PLAN-02  %s  narrowed\n' "$h2" > docs/plans/.acceptance-amends
  replay_commit "$(mk "$ca" "PLAN-02 / refreeze: narrowed")" || fail "a traced re-stamp was refused: $(replay_commit "$(mk "$ca" "PLAN-02 / refreeze: narrowed")" 2>&1 || true)"
  rm -f docs/plans/.acceptance-hashes docs/plans/.acceptance-amends; git checkout -q "$ca" -- docs/plans/PLAN-02-y.md
  replay_commit "$(mk "$ca" "note: drop the ledger")" >/dev/null 2>&1 && fail "deleting the ledger passed"
  # 6. a PR-merge head: a two-parent `Merge …` commit that grows the LOG with no form is refused by the per-commit guards, and
  #    exempted from the message rule only with RATCHET_CI_SKIP_DEFAULT_MERGE_HEAD=true (content and ledger checks still run) — the flag reads the MERGE's subject, not a parent's
  printf '\n## t — from the branch\nx\n' >> docs/LOG.md; cb="$(mk "$c0" "note: branch work")"; git checkout -q "$c0" -- docs/LOG.md
  printf '\n## t — merged in\nx\n' >> docs/LOG.md
  idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
  cm="$(git commit-tree "$t" -p "$c0" -p "$cb" -m "Merge pull request #7 from feature")"; git checkout -q "$c0" -- docs/LOG.md
  is_default_merge "$cm" || fail "a two-parent Merge commit was not recognized as a merge (the subject read was a parent's)"
  is_default_merge "$cb" && fail "a single-parent commit read as a merge"
  replay_commit "$cm" >/dev/null 2>&1 && fail "a merge that grows the LOG with no form passed the per-commit guards"
  replay_commit "$cm" 1 >/dev/null 2>&1 || fail "the merge with the message rule exempted was refused"
  printf 'k\n' > docs/dev.p12; idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
  cms="$(git commit-tree "$t" -p "$c0" -p "$cb" -m "Merge pull request #8")"; rm -f docs/dev.p12
  replay_commit "$cms" 1 >/dev/null 2>&1 && fail "a merge head with a key file passed under the message exemption (content checks must still run)"
  # a rename INTO a key name is caught (renames are not deletions)
  git checkout -q "$c0" -- docs/LOG.md; printf 'k\n' > docs/sample.txt; cs="$(mk "$c0" "note: sample")"
  git mv -q docs/sample.txt docs/dev.p12 2>/dev/null || mv docs/sample.txt docs/dev.p12
  replay_commit "$(mk "$cs" "note: rename")" >/dev/null 2>&1 && fail "a rename into a .p12 passed the secret scan"; rm -f docs/dev.p12
  # a merge's tmp/ cites: new only if new against EVERY parent — the lines a closed plan's branch wrote while it was open are
  # inherited (the branch flipped the row); a stale cite first written in the merge itself is refused
  git checkout -q "$c0" -- docs/LOG.md PLAN.md; rm -f docs/OTHER.md
  printf '\n## t — note\n`tmp/PLAN-02/02.1-run.log`\n' >> docs/LOG.md; cb1="$(mk "$c0" "note: open-plan cite")"
  sed 's/| in-progress |/| complete |/' PLAN.md > t && mv t PLAN.md; cb2="$(mk "$cb1" "note: close the row")"
  git checkout -q "$c0" -- docs/LOG.md PLAN.md; printf 'other\n' > docs/OTHER.md; cm0="$(mk "$c0" "note: the default branch moves")"
  git checkout -q "$cb2" -- docs/LOG.md PLAN.md
  idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
  cmg="$(git commit-tree "$t" -p "$cm0" -p "$cb2" -m "note: integrate")"
  replay_commit "$cmg" || fail "a merge's inherited cite (the closed plan's own branch line) was refused: $(replay_commit "$cmg" 2>&1 || true)"
  printf '`tmp/PLAN-02/02.9-late.md`\n' >> docs/LOG.md
  idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"
  replay_commit "$(git commit-tree "$t" -p "$cm0" -p "$cb2" -m "note: integrate")" >/dev/null 2>&1 && fail "a stale cite written in the merge itself passed"
  git checkout -q "$c0" -- docs/LOG.md PLAN.md; rm -f docs/OTHER.md
  # the Lite close through CI: no review dir is demanded when the plans dir is empty
  ( RATCHET_PLANS_DIR= RATCHET_LOG=docs/LOG.md; printf '\n## t — PLAN-01 / close\nx\n' >> docs/LOG.md; c="$(mk "$c0" "PLAN-01 / close: inline")"; git checkout -q "$c0" -- docs/LOG.md; replay_commit "$c" >/dev/null ) || fail "a Lite close (empty plans dir) was refused by CI for lacking a MANIFEST"
  # the head tree's check: a range run ends in the ratchet's index legs over the head in a detached worktree — `git worktree add` failing
  # (the harsher fault: git does the work, then exits 73) is exit 2 with no "clean", never a skipped check; unfaulted, the range is clean
  cp "$HERE/ci-replay.sh" script/ci-replay.sh; ch="$(git commit-tree "$c0^{tree}" -p "$c0" -m "note: nothing")"
  realgit="$(command -v git)"; mkdir -p "$d/fk"
  printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase " $* " in *" worktree add "*) echo "git: injected failure" >&2; exit 73 ;; esac\nexit $rc\n' "$realgit" > "$d/fk/git"; chmod +x "$d/fk/git"
  out="$(bash script/ci-replay.sh "$c0..$ch" 2>&1)" && grep -Fq 'clean' <<< "$out" || fail "an unfaulted range run should be clean: $out"
  set +e; out="$(PATH="$d/fk:$PATH" bash script/ci-replay.sh "$c0..$ch" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && ! grep -Fq "$c0..$ch clean" <<< "$out" || fail "a failing git worktree add should exit 2 with no clean verdict (rc=$rc): $out"
  # blob_of: presence by a CHECKED listing, a present blob read checked — absent is empty (exit 0), a failed listing or a failed read of a
  # present blob is exit 2 and the replay's verdict is exit 2, never a pass (a `git show … || true` once read a failed PLAN.md as "no rows")
  realgit="$(command -v git)"; mkdir -p "$d/fakeshow" "$d/fakels"
  printf '#!/bin/sh\nif [ "$1" = show ]; then for a in "$@"; do case "$a" in *:*) echo "| partial"; exit 73 ;; esac; done; fi\nexec %s "$@"\n' "$realgit" > "$d/fakeshow/git"
  printf '#!/bin/sh\n[ "$1" = ls-tree ] && exit 73\nexec %s "$@"\n' "$realgit" > "$d/fakels/git"; chmod +x "$d/fakeshow/git" "$d/fakels/git"
  [ "$(blob_of "$c0" PLAN.md | head -1)" = "# PLAN" ] || fail "blob_of did not read a present PLAN.md"
  rc=0; out="$(blob_of "$c0" docs/nope.md)" || rc=$?; [ "$rc" -eq 0 ] && [ -z "$out" ] || fail "blob_of on an absent path must be empty with exit 0 (rc=$rc)"
  rc=0; ( PATH="$d/fakeshow:$PATH" blob_of "$c0" PLAN.md >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "blob_of with a git show that prints then fails on a present blob did not exit 2 (rc=$rc)"
  rc=0; ( PATH="$d/fakels:$PATH" blob_of "$c0" PLAN.md >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "blob_of with a failing listing did not exit 2 (rc=$rc)"
  git checkout -q "$c0" -- . && cn="$(mk "$c0" "note: a plain commit")" && replay_commit "$cn" >/dev/null 2>&1 || fail "a plain note: commit off c0 does not replay clean (the next probe needs one whose only blob read is PLAN.md)"
  rc=0; ( PATH="$d/fakeshow:$PATH" replay_commit "$cn" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "replay_commit with PLAN.md's read failing passed or read it as absent (rc=$rc; must be 2)"
  # 7. the draft's criteria per commit — the stage commit a --no-verify skipped the hook for is caught here: a builder commit
  #    editing an unstamped plan's Validation and Acceptance is refused (the plan file named); the same edit as note: passes; a merge
  #    whose first-parent diff carries its branch's note: edit is no builder commit; a stamped plan's edit is the hash leg's one refusal;
  #    a failed read of the parent's plan is exit 2, never a pass
  git checkout -q "$c0" -- .
  printf '\n## t — PLAN-02 / 02.1\nstage\n' >> docs/LOG.md; sed 's/^- x$/- x, whatever was built/' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md
  ce="$(mk "$c0" "PLAN-02 / 02.1: build")"
  rc=0; out="$(replay_commit "$ce" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'changes the Validation and Acceptance section of docs/plans/PLAN-02-y.md' <<< "$out" || fail "a stage commit editing an unstamped plan's criteria passed CI (rc=$rc): $out"
  cnb="$(mk "$c0" "note: the criterion the plan read asked for")"; replay_commit "$cnb" >/dev/null || fail "the same edit as note: was refused by CI"
  rc=0; out="$(replay_commit "$(mk "$c0" "PLAN-02 / fix — the review batch")" 2>&1)" || rc=$?; [ "$rc" -eq 1 ] || fail "a fix commit editing an unstamped plan's criteria passed CI (rc=$rc): $out"
  git checkout -q "$c0" -- docs/LOG.md docs/plans/PLAN-02-y.md; printf 'other\n' > docs/OTHER2.md; cmv="$(mk "$c0" "note: the default branch moves")"; rm -f docs/OTHER2.md
  git checkout -q "$cnb" -- docs/LOG.md docs/plans/PLAN-02-y.md; printf 'other\n' > docs/OTHER2.md
  idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git add -A . >/dev/null; t="$(GIT_INDEX_FILE="$idx" git write-tree)"; rm -f "$idx"; rm -f docs/OTHER2.md
  replay_commit "$(git commit-tree "$t" -p "$cmv" -p "$cnb" -m "PLAN-02 / 02.2: integrate")" >/dev/null || fail "a merge carrying its branch's note: criteria edit was judged as a builder commit"
  mkdir -p "$d/fkplan"; printf '#!/bin/sh\n[ "$1" = show ] && [ "$2" = "%s:docs/plans/PLAN-02-y.md" ] && exit 73\nexec "%s" "$@"\n' "$c0" "$realgit" > "$d/fkplan/git"; chmod +x "$d/fkplan/git"
  rc=0; ( PATH="$d/fkplan:$PATH" replay_commit "$ce" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 2 ] || fail "a failed read of the parent's plan must be exit 2 in CI (rc=$rc)"
  git checkout -q "$ca" -- .; printf '\n## t — PLAN-02 / 02.3\nstage\n' >> docs/LOG.md; sed 's/^- x$/- x, whatever was built/' docs/plans/PLAN-02-y.md > t && mv t docs/plans/PLAN-02-y.md
  rc=0; out="$(replay_commit "$(mk "$ca" "PLAN-02 / 02.3: build")" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'acceptance hash mismatch for PLAN-02' <<< "$out" && ! grep -qF 'no stamp yet' <<< "$out" || fail "a stamped plan's stage edit must be the hash leg's one refusal in CI (rc=$rc): $out"
  # 8. the project check per commit, over its first-parent diff: a refusal is 1, any other exit 2, a clean diff passes; the records side never runs it
  mk1() {   # $1 parent, $2 path, $3 content, $4 message → a commit of the parent's tree plus that one file (the working tree untouched)
    local idx b t; idx="$(mktemp)"; rm -f "$idx"; GIT_INDEX_FILE="$idx" git read-tree "$1" && b="$(printf '%s\n' "$3" | git hash-object -w --stdin)" \
      && GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$b,$2" && t="$(GIT_INDEX_FILE="$idx" git write-tree)" && rm -f "$idx" && git commit-tree "$t" -p "$1" -m "$4"; }
  cfb="$(mk1 "$c0" src.txt FORBIDDEN "feat: a refused line")" && cok="$(mk1 "$c0" src.txt fine "feat: a clean line")" || fail "fixture: the project-check commits"
  RATCHET_PROJECT_CHECK='! grep -q "^+FORBIDDEN"'
  rc=0; out="$(replay_commit "$cfb" 2>&1)" || rc=$?; [ "$rc" -eq 1 ] && grep -qF 'the project check refused' <<< "$out" || fail "CI passed a commit the project check refuses (rc=$rc): $out"
  out="$(replay_commit "$cok" 2>&1)" || fail "CI refused a commit the project check passes: $out"
  rc=0; ( RATCHET_SIDE=records; replay_commit "$cfb" >/dev/null 2>&1 ) || rc=$?; [ "$rc" -eq 0 ] || fail "the records side ran the project check (rc=$rc)"
  RATCHET_PROJECT_CHECK='exit 3'; rc=0; replay_commit "$cfb" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 2 ] || fail "a project check exiting 3 must be exit 2 in CI (rc=$rc)"
  RATCHET_PROJECT_CHECK=
  # 9. split-repo mode's code side (modules/split-repo.md): a stage claim with no LOG and a harvest close with no MANIFEST replay clean
  ccl="$(mk1 "$c0" src.txt x "PLAN-02 / 02.1: build")" && cch="$(mk1 "$c0" CHANGELOG.md x "PLAN-01 / close: harvest")" || fail "fixture: the code-side commits"
  ( RATCHET_SIDE=code; replay_commit "$ccl" >/dev/null && replay_commit "$cch" >/dev/null ) || fail "the code side asked a stage claim for its LOG or a harvest close for a MANIFEST"
  rc=0; replay_commit "$ccl" >/dev/null 2>&1 || rc=$?; [ "$rc" -eq 1 ] || fail "one-repo, a stage claim with no LOG must still be refused in CI (rc=$rc)"
  # 10. split-repo mode's records side, end to end through the script: the records checkout nested at the code repo's private/, the
  # kit's extractor read where it lives (a stamped plan replays; an edit to its criteria is refused), no skip scan (a records file
  # that looks like a skipped test replays), and the head tree checked with the kit laid beside it — a secret in the records head is refused
  sp="$d/sp"; mkdir -p "$sp/code/script"
  ( cd "$sp/code" && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$HERE/ratchet.sh" "$HERE/acceptance-extract.awk" "$HERE/tmp-tidy.sh" "$HERE/ci-replay.sh" script/ && printf 'RATCHET_RECORDS=private\n' > script/ratchet.conf \
    && printf '/private\n' > .gitignore && git add -A . && git commit -qm init \
    && git init -q private && cd private && git config user.email t@t && git config user.name t && mkdir -p docs/plans \
    && printf '# P\n' > PLAN.md && printf '# LOG\n' > docs/LOG.md && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- a\n\n## Progress\n' > docs/plans/PLAN-01-x.md \
    && git add -A . && git commit -qm 'note: init' && git rev-parse HEAD > "$d/sp-base" \
    && printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=../script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && printf '# P\n| **PLAN-01** x | [x](docs/plans/PLAN-01-x.md) | in-progress (frozen) | none | 1d |\n' > PLAN.md \
    && git add -A . && git commit -qm 'PLAN-01 / review: freeze' && printf '\n## t — PLAN-01 / 01.1\nCode: abcdef1\n' >> docs/LOG.md \
    && printf -- '- [x] 01.1\n' >> docs/plans/PLAN-01-x.md && mkdir -p Tests && printf 'XCTSkip("records hold no tests")\n' > Tests/a.swift \
    && git add -A . && git commit -qm 'PLAN-01 / 01.1 — records' ) >/dev/null || fail "fixture: the split-repo pair"
  spb="$(cat "$d/sp-base")"
  rc=0; out="$(RATCHET_ROOT="$sp/code/private" bash "$sp/code/script/ci-replay.sh" "$spb..HEAD" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && grep -qF 'clean' <<< "$out" || fail "a clean records range did not replay clean on the records side — a skip scan there, per commit or on the head tree, reads as the code side (rc=$rc): $out"
  ( cd "$sp/code/private" && sed 's/^- a$/- anything/' docs/plans/PLAN-01-x.md > t && mv t docs/plans/PLAN-01-x.md && git add -A . && git commit -qm 'note: edit' ) >/dev/null || fail "fixture: a criteria edit"
  rc=0; out="$(RATCHET_ROOT="$sp/code/private" bash "$sp/code/script/ci-replay.sh" "$spb..HEAD" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'acceptance hash mismatch for PLAN-01' <<< "$out" || fail "a records-side criteria edit replayed clean (rc=$rc): $out"
  ( cd "$sp/code/private" && git reset -q --hard HEAD~1 && printf 'k\n' > dev.p12 && git add dev.p12 && git -c core.hooksPath=/dev/null commit -qm 'note: key' ) >/dev/null || fail "fixture: a key"
  rc=0; out="$(RATCHET_ROOT="$sp/code/private" bash "$sp/code/script/ci-replay.sh" "HEAD~1..HEAD" 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'secret' <<< "$out" || fail "a key in the records head replayed clean (rc=$rc): $out"
  # 11. moving a one-repo project over (modules/split-repo.md): a populated one-repo history — a frozen plan, its stamp, the LOG and
  # PLAN.md — then the commit that deletes every record path (the stamped ledger included) and sets RATCHET_RECORDS. The code side
  # replays it clean, as its hook passed it: the ledger is the records repo's now, so its deletion is no broken freeze. One-repo, the
  # same deletion is still refused
  mg="$d/mg"; mkdir -p "$mg/script" "$mg/docs/plans"
  ( cd "$mg" && git init -q . && git config user.email t@t && git config user.name t \
    && cp "$HERE/ratchet.sh" "$HERE/acceptance-extract.awk" "$HERE/tmp-tidy.sh" "$HERE/ci-replay.sh" script/ \
    && printf '# LOG\n\n## t — PLAN-01 / 01.1\nbuilt\n' > docs/LOG.md && printf 'a\n' > src.txt \
    && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- a\n\n## Progress\n' > docs/plans/PLAN-01-x.md \
    && printf 'PLAN-01 %s\n' "$(RATCHET_EXTRACT=script/acceptance-extract.awk acc_hash docs/plans/PLAN-01-x.md)" > docs/plans/.acceptance-hashes \
    && printf '# P\n| **PLAN-01** x | [x](docs/plans/PLAN-01-x.md) | complete | none | 1d |\n' > PLAN.md \
    && git add -A . && git -c core.hooksPath=/dev/null commit -qm 'note: the one-repo history' && git rev-parse HEAD > "$d/mg-base" \
    && git rm -rq docs PLAN.md && printf 'RATCHET_RECORDS=private\n' > script/ratchet.conf && printf '/private\n' > .gitignore \
    && git add -A . && git -c core.hooksPath=/dev/null commit -qm 'note: the records move to their own repo at private/' ) >/dev/null || fail "fixture: the migration history"
  mgb="$(cat "$d/mg-base")"
  rc=0; out="$(bash "$mg/script/ci-replay.sh" "$mgb..HEAD" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "the code side refused the migration commit that deletes the records (the hook passed it) (rc=$rc): $out"
  ( cd "$mg" && git checkout -q -b one "$mgb" && git rm -rq docs PLAN.md && git -c core.hooksPath=/dev/null commit -qm 'note: drop the records' ) >/dev/null || fail "fixture: the one-repo deletion"
  rc=0; out="$(env -u RATCHET_RECORDS bash "$mg/script/ci-replay.sh" HEAD~1..HEAD 2>&1)" || rc=$?
  [ "$rc" -eq 1 ] && grep -qF 'once stamped, always stamped' <<< "$out" || fail "one-repo, deleting a stamped ledger must still be refused (rc=$rc): $out"
  echo "SELF-TEST OK"; exit 0
fi

range="${1:-}"
[ -n "$range" ] && [ "$range" != "${range#*..}" ] || { usage; exit 64; }
base="$(git rev-parse --verify "${range%%..*}^{commit}")"; head="$(git rev-parse --verify "${range#*..}^{commit}")"
commits="$(git rev-list --reverse "$base..$head")"
if [ -z "$commits" ]; then echo "ci-replay: no commits in $range; skipping per-commit replay"
else
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    nomsg=0; [ "${RATCHET_CI_SKIP_DEFAULT_MERGE_HEAD:-}" = true ] && [ "$c" = "$head" ] && is_default_merge "$c" && nomsg=1
    replay_commit "$c" "$nomsg" || exit $?   # 1 = refused, 2 = a tool error — both red, distinguishable
  done <<< "$commits"
fi
rc=0; run_ratchet_on_head_tree "$head" || rc=$?
[ "$rc" -eq 0 ] || exit "$rc"   # 1 = refused, 2 = a tool error
echo "ci-replay: $range clean"
