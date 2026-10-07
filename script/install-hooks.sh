#!/usr/bin/env bash
# install-hooks.sh: points git at the tracked hooks in script/hooks/, so every clone runs the ratchet from the same files.
# Run it once per clone (bootstrap.md Step 5).
#
# Kit copy: install as script/install-hooks.sh, with kit/hooks/* under script/hooks/.
#
# Usage
#   install-hooks.sh               set core.hooksPath to script/hooks, and wire the LOG merge driver: git config
#                                  merge.execplan-log.driver runs `script/ratchet.sh --merge-log %O %A %B`, and the common git
#                                  dir's info/attributes (shared by every worktree; nothing tracked) maps RATCHET_LOG to it.
#                                  RATCHET_LOG is read the way the ratchet reads it: the environment, then script/ratchet.conf.
#                                  Split-repo mode (RATCHET_RECORDS set — a non-empty environment value, else the conf's;
#                                  modules/split-repo.md): the records repo at
#                                  $RATCHET_RECORDS is wired too — its core.hooksPath is the relative path back to these hooks
#                                  (../script/hooks for `private`; each of its worktrees, nested in a code worktree, then runs
#                                  that worktree's kit), its merge driver is `<same>/ratchet.sh --merge-log %O %A %B` (git runs a
#                                  driver from the records repo's top), and its common dir's info/attributes maps RATCHET_LOG.
#                                  The code repo is wired first; a records repo that is missing, not a repo of its own, or
#                                  reached through a symlink (its relative hooksPath would name another kit) is then exit 2,
#                                  named. Running it again changes nothing.
#   install-hooks.sh --self-test   install into a throwaway repo under mktemp and prove the three hooks fire; touches
#                                  nothing here
#
# Exit codes: 0 installed · 2 a tool failed (chmod, git config, the conf, the attributes file), the step named · 64 usage
set -eu   # NOT pipefail (the kit's rule); nothing here reads a pipe
HERE="$(cd "$(dirname "$0")" && pwd)"

install_into() {   # $1 = repo root (with script/hooks/ and script/ratchet.sh in place)
  local hp
  ( cd "$1" && chmod +x script/hooks/pre-commit script/hooks/commit-msg script/hooks/pre-push script/ratchet.sh \
    && git config core.hooksPath script/hooks ) || { echo "install-hooks: chmod or git config failed — the hooks are not wired" >&2; return 2; }
  hp="$(cd "$1" && git config core.hooksPath)" || { echo "install-hooks: reading core.hooksPath back failed — the hooks may not be wired" >&2; return 2; }   # captured, then checked: an echo once masked a failed read
  [ "$hp" = script/hooks ] || { echo "install-hooks: core.hooksPath reads '$hp' after it was set — the hooks are not wired" >&2; return 2; }
  echo "installed: core.hooksPath=$hp (pre-commit, commit-msg, pre-push)"
  install_log_driver "$1" || return $?
  install_records "$1"
}

install_records() {   # $1 = the code repo's root → split-repo mode's records repo wired (hooks, the LOG merge driver); nothing when
  # RATCHET_RECORDS is empty; 2 on any failure, named — never a half-wired "installed"
  local rec r pp top hp up n cp_
  rec="${RATCHET_RECORDS:-}"   # a non-empty environment value outranks the conf, as the ratchet reads it
  [ -n "$rec" ] || rec="$( cd "$1" && if [ -f script/ratchet.conf ]; then . script/ratchet.conf || exit 1; fi; printf '%s\n' "${RATCHET_RECORDS:-}" )" \
    || { echo "install-hooks: script/ratchet.conf failed to source — the records repo is not wired" >&2; return 2; }
  [ -n "$rec" ] || return 0
  r="$rec"; while :; do case "$r" in ?*/) r="${r%/}" ;; *) break ;; esac; done
  case "$r" in ""|/*|.|..|./*|../*|*/.|*/..|*/./*|*/../*|*//*)
    echo "install-hooks: RATCHET_RECORDS='$rec' must be a relative path inside the code repo (no leading /, no . or .. parts)" >&2; return 2 ;; esac
  pp="$(cd "$1/$r" 2>/dev/null && pwd -P)" \
    || { echo "install-hooks: RATCHET_RECORDS=$r but there is no records repo at $1/$r — clone it there, then run install-hooks.sh again (the code repo is wired)" >&2; return 2; }
  cp_="$(cd "$1" && pwd -P)" || { echo "install-hooks: reading the code repo's path failed — the records repo is not wired" >&2; return 2; }
  [ "$pp" = "$cp_/$r" ] || { echo "install-hooks: $1/$r resolves to $pp — a symlink along RATCHET_RECORDS isn't supported: git would run the linked repo's hooks through ${r}'s relative core.hooksPath from another kit, or none (clone the records repo at $1/$r itself; the code repo is wired)" >&2; return 2; }
  top="$(cd "$pp" && git rev-parse --show-toplevel 2>/dev/null)" && top="$(cd "$top" && pwd -P)" \
    || { echo "install-hooks: $pp is not a git work tree — the records repo must be a repo of its own (the code repo is wired)" >&2; return 2; }
  [ "$top" = "$pp" ] || { echo "install-hooks: $pp is inside the work tree $top, not a repo of its own — clone the records repo there (the code repo is wired)" >&2; return 2; }
  up=""; n="$r"; while :; do up="../$up"; case "$n" in */*) n="${n#*/}" ;; *) break ;; esac; done   # one ../ per path part
  ( cd "$pp" && git config core.hooksPath "${up}script/hooks" ) || { echo "install-hooks: git config failed in the records repo — its hooks are not wired" >&2; return 2; }
  hp="$(cd "$pp" && git config core.hooksPath)" || { echo "install-hooks: reading the records repo's core.hooksPath back failed — its hooks may not be wired" >&2; return 2; }
  [ "$hp" = "${up}script/hooks" ] || { echo "install-hooks: the records repo's core.hooksPath reads '$hp' after it was set — its hooks are not wired" >&2; return 2; }
  echo "installed: the records repo $r — core.hooksPath=$hp"
  install_log_driver "$pp" "${up}script" "$1"
}

install_log_driver() {   # $1 = repo root, [$2 = the kit dir as the driver names it, relative to $1's top — default script], [$3 = the
  # root whose script/ratchet.conf names the LOG — default $1] → the LOG merge driver wired; 2 on any failure (named), never a half-wired "installed"
  local log common attrs line has rc kit="${2:-script}" conf="${3:-$1}"
  log="$( cd "$conf" && if [ -f script/ratchet.conf ]; then . script/ratchet.conf || exit 1; fi; printf '%s\n' "${RATCHET_LOG:-docs/LOG.md}" )" \
    || { echo "install-hooks: script/ratchet.conf failed to source — the LOG merge driver is not wired" >&2; return 2; }
  common="$(cd "$1" && git rev-parse --path-format=absolute --git-common-dir)" || { echo "install-hooks: git cannot name the common git dir" >&2; return 2; }
  attrs="$common/info/attributes"; line="$log merge=execplan-log"
  ( cd "$1" && git config merge.execplan-log.name "ExecPlan LOG: both sides' entries, newest first" \
    && git config merge.execplan-log.driver "$kit/ratchet.sh --merge-log %O %A %B" ) || { echo "install-hooks: git config failed — the LOG merge driver is not wired" >&2; return 2; }
  mkdir -p "$common/info" || { echo "install-hooks: cannot create $common/info" >&2; return 2; }
  has=0
  if [ -f "$attrs" ]; then
    rc=0; grep -qxF -e "$line" "$attrs" || rc=$?
    case "$rc" in 0) has=1 ;; 1) ;; *) echo "install-hooks: reading $attrs failed" >&2; return 2 ;; esac
  fi
  [ "$has" -eq 1 ] || printf '%s\n' "$line" >> "$attrs" || { echo "install-hooks: writing $attrs failed" >&2; return 2; }
  echo "installed: the LOG merge driver for $log (merge.execplan-log, $attrs)"
}

case "${1:-}" in
  "") rc=0; install_into "$HERE/.." || rc=$?; exit "$rc" ;;
  --self-test)
    d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
    fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
    mkdir -p "$d/r/script/hooks" "$d/r/docs/plans" && cd "$d/r" && git init -q . && git config user.email t@t && git config user.name t
    for f in ratchet.sh tmp-tidy.sh acceptance-extract.awk; do cp "$HERE/$f" script/; done
    for h in pre-commit commit-msg pre-push; do cp "$HERE/hooks/$h" script/hooks/; done
    printf '# LOG\n' > docs/LOG.md; printf '# P\n' > PLAN.md; git add -A . && git commit -qm init >/dev/null
    git branch -q -M master   # the home branch is master whatever init.defaultBranch says (the hook finds it on its own)
    install_into "$d/r" >/dev/null || fail "install failed"
    # a failed readback of core.hooksPath is a tool failure (2), never "installed" with an empty path
    realgit="$(command -v git)" || fail "no git on PATH"; mkdir -p "$d/shim-git"
    printf '#!/bin/sh\n[ "$#" -eq 2 ] && [ "$1" = config ] && [ "$2" = core.hooksPath ] && exit 3\nexec "%s" "$@"\n' "$realgit" > "$d/shim-git/git"; chmod +x "$d/shim-git/git"
    rc=0; so="$(PATH="$d/shim-git:$PATH" install_into "$d/r" 2>&1)" || rc=$?
    [ "$rc" -eq 2 ] && grep -Fq 'reading core.hooksPath back failed' <<< "$so" && ! grep -Fq 'installed: core.hooksPath' <<< "$so" || fail "a failed core.hooksPath readback must be exit 2, not 'installed' (rc=$rc): $so"
    [ "$(git config core.hooksPath)" = script/hooks ] || fail "core.hooksPath not set"
    # pre-commit fires: a .p12 is refused; commit-msg fires: LOG growth with no form is refused; a clean note: commit lands
    printf 'k\n' > docs/dev.p12; git add docs/dev.p12
    git commit -qm "note: oops" >/dev/null 2>&1 && fail "the pre-commit hook did not fire (a .p12 was committed)"
    git rm -q --cached docs/dev.p12; rm -f docs/dev.p12
    printf '\n## t\nentry\n' >> docs/LOG.md; git add docs/LOG.md
    git commit -qm "chore: no form" >/dev/null 2>&1 && fail "the commit-msg hook did not fire (LOG growth with no form was committed)"
    git commit -qm "note: entry" >/dev/null 2>&1 || fail "a clean note: commit was refused by the hooks"
    # pre-push fires: a push to master without the variable is refused (against a local bare remote)
    git init -q --bare "$d/remote.git"; git remote add origin "$d/remote.git"
    git push -q origin HEAD:master >/dev/null 2>&1 && fail "the pre-push hook did not fire (master pushed without RATCHET_ALLOW_PUSH)"
    RATCHET_ALLOW_PUSH=1 git push -q origin HEAD:master >/dev/null 2>&1 || fail "a push with RATCHET_ALLOW_PUSH=1 was refused"
    git push -q origin HEAD:feature >/dev/null 2>&1 || fail "a push to a non-default branch was refused"
    # a deletion is no force push: a feature branch deletes; deleting the default branch still needs the key
    git push -q origin --delete feature >/dev/null 2>&1 || fail "deleting a pushed feature branch was refused"
    out="$(git push -q origin --delete master 2>&1)" && fail "deleting master passed without RATCHET_ALLOW_PUSH"
    grep -qF 'needs RATCHET_ALLOW_PUSH=1' <<< "$out" || fail "deleting master was refused, but not by the key gate: $out"
    RATCHET_ALLOW_PUSH=1 git push -q origin --delete master >/dev/null 2>&1 || fail "deleting master with RATCHET_ALLOW_PUSH=1 was refused"
    RATCHET_ALLOW_PUSH=1 git push -q origin HEAD:master >/dev/null 2>&1 || fail "fixture: re-push master"
    # the default branch is found without the environment (EVO-80): script/ratchet.conf names it; else the one of master/main
    printf 'RATCHET_DEFAULT_BRANCH="trunk"\n' > script/ratchet.conf
    env -u RATCHET_DEFAULT_BRANCH git push -q origin HEAD:trunk >/dev/null 2>&1 && fail "a push to trunk (named only in script/ratchet.conf) passed without RATCHET_ALLOW_PUSH"
    RATCHET_DEFAULT_BRANCH=release git push -q origin HEAD:trunk >/dev/null 2>&1 || fail "the environment's RATCHET_DEFAULT_BRANCH should win over script/ratchet.conf"
    rm -f script/ratchet.conf
    git branch -q -M main   # the current branch, whatever init named it, becomes the only home branch
    env -u RATCHET_DEFAULT_BRANCH git push -q origin HEAD:main >/dev/null 2>&1 && fail "a push to main (the repo's only home branch, no conf) passed without RATCHET_ALLOW_PUSH"
    # the conf is read the way the ratchet reads it (sourced in a subshell): a comment or trailing spaces don't hide the name;
    # a conf that fails to source, or names no valid branch, refuses every push. Each case pushes a new commit (an up-to-date
    # push never runs the hook)
    bump() { git -c core.hooksPath=/dev/null commit -q --allow-empty -m "note: bump" >/dev/null || fail "fixture: bump"; }
    nopush() { bump; env -u RATCHET_DEFAULT_BRANCH git push -q origin "HEAD:$1" >/dev/null 2>&1 && fail "$2"; return 0; }
    printf 'RATCHET_DEFAULT_BRANCH=trunk # the home branch\n' > script/ratchet.conf
    nopush trunk "a conf value with a trailing comment must still gate trunk"
    printf 'RATCHET_DEFAULT_BRANCH="trunk"   \n' > script/ratchet.conf
    nopush trunk "a quoted conf value with trailing spaces must still gate trunk"
    printf 'RATCHET_DEFAULT_BRANCH=trunk\nfalse\n' > script/ratchet.conf
    nopush feature "a ratchet.conf that fails to source must refuse every push"
    printf 'RATCHET_DEFAULT_BRANCH=bad..name\n' > script/ratchet.conf
    nopush feature "a conf naming an invalid branch must refuse every push"
    rm -f script/ratchet.conf
    # no env, conf or origin/HEAD, and BOTH master and main exist: a push to either needs the key
    git branch -q master
    nopush master "with master and main both present, a push to master must need the key"
    nopush main "with master and main both present, a push to main must need the key"
    bump; git push -q origin HEAD:feature >/dev/null 2>&1 || fail "with master and main both present, a push to another branch must pass"
    # the hook never needs a temp file (bash 3.2 backs a here-string or heredoc with one; a failed redirect once skipped the gate):
    # no `<<` in it, and it still gates master with an unwritable TMPDIR under /bin/bash
    ! grep -q '<<' script/hooks/pre-push || fail "pre-push must not use a here-string or heredoc (a temp file whose failure skips the gate)"
    mkdir -p "$d/ro" && chmod 555 "$d/ro"
    printf 'refs/heads/master %s refs/heads/master 0000000000000000000000000000000000000000\n' "$(git rev-parse HEAD)" \
      | env -u RATCHET_DEFAULT_BRANCH -u RATCHET_ALLOW_PUSH TMPDIR="$d/ro" /bin/bash script/hooks/pre-push origin "$d/remote.git" >/dev/null 2>&1 \
      && fail "with an unwritable TMPDIR the hook must still refuse a push to master without the key"
    chmod 755 "$d/ro"
    # a name git only accepts by expanding it (@{-1} → the previous branch) is not a branch name: refused, never gated as the literal
    git checkout -q -b prev && git checkout -q main || fail "fixture: a previous branch for @{-1}"
    printf 'RATCHET_DEFAULT_BRANCH=@{-1}\n' > script/ratchet.conf
    nopush feature "a conf naming @{-1} must refuse every push (check-ref-format expands it; the hook would gate the literal)"
    rm -f script/ratchet.conf
    # the project check at push time (EVO-100): a commit that never met pre-commit (a cherry-pick, `git am`) and that the check refuses
    # stops the push before anything is sent; once it's gone, the push goes through
    printf 'RATCHET_PROJECT_CHECK='"'"'! grep -q "^+.*FORBIDDEN"'"'"'\n' > script/ratchet.conf
    printf 'FORBIDDEN\n' > bad.txt && git add bad.txt && git -c core.hooksPath=/dev/null commit -qm "note: picked" >/dev/null || fail "fixture: a commit that skipped pre-commit"
    rc=0; out="$(git push origin HEAD:feature 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] && grep -qF 'project check refused' <<< "$out" || fail "a pushed commit the project check refuses was sent (rc=$rc): $out"
    [ "$(git rev-parse HEAD)" != "$(git --git-dir="$d/remote.git" rev-parse feature)" ] || fail "the refused commit reached the remote"
    git -c core.hooksPath=/dev/null reset -q --hard HEAD~1 && bump && git push -q origin HEAD:feature >/dev/null 2>&1 || fail "a clean push with a project check configured was refused"
    rm -f script/ratchet.conf
    # the LOG merge driver, end to end: two branches each add an entry at the LOG's top (a conflict to a plain merge) and a real
    # `git merge` interleaves them newest first with the hooks on; the same from a second worktree (config and info/attributes are
    # shared); installing twice leaves one attributes line; the conf's RATCHET_LOG is the path wired
    common="$(git rev-parse --path-format=absolute --git-common-dir)"
    [ "$(grep -c 'merge=execplan-log' "$common/info/attributes")" -eq 1 ] || fail "the first install should write one attributes line"
    install_into "$d/r" >/dev/null && install_into "$d/r" >/dev/null || fail "a second install failed"
    [ "$(grep -c 'merge=execplan-log' "$common/info/attributes")" -eq 1 ] || fail "installing again must not duplicate the attributes line"
    [ "$(git config merge.execplan-log.driver)" = 'script/ratchet.sh --merge-log %O %A %B' ] || fail "the driver is not configured"
    logmerge() {   # $1 = the checkout, $2 = the branch to merge in; each side adds its own entry on top of a shared one
      ( cd "$1" && git merge -q --no-edit -m "note: merge $2" "$2" >/dev/null 2>&1 ) || fail "a LOG conflict the driver resolves failed to merge in $1"
      grep -q '^<<<<<<<' "$1/docs/LOG.md" && fail "the merged LOG in $1 holds conflict markers"
      awk '/^## 20/ { print $2 }' "$1/docs/LOG.md" | tr '\n' ' '
    }
    git checkout -q main && printf '# LOG\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > docs/LOG.md && git add docs/LOG.md && git commit -qm "note: base" >/dev/null 2>&1 || fail "fixture: the base entry"
    git checkout -q -b lb && printf '# LOG\n\n## 2026-09-03T00:00:00Z — p / lb\nlb\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > docs/LOG.md && git commit -qam "note: lb" >/dev/null 2>&1 || fail "fixture: branch entry"
    git checkout -q main && printf '# LOG\n\n## 2026-09-02T00:00:00Z — p / main\nmain\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > docs/LOG.md && git commit -qam "note: main" >/dev/null 2>&1 || fail "fixture: main entry"
    got="$(logmerge "$d/r" lb)"; [ "$got" = "2026-09-03T00:00:00Z 2026-09-02T00:00:00Z 2026-09-01T00:00:00Z " ] || fail "the driver's merge is not newest first: $got"
    git worktree add -q -b wt "$d/wt" HEAD~2 >/dev/null 2>&1 || fail "fixture: a second worktree"
    ( cd "$d/wt" && printf '# LOG\n\n## 2026-09-05T00:00:00Z — p / wt\nwt\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > docs/LOG.md && git commit -qam "note: wt" >/dev/null 2>&1 ) || fail "fixture: the worktree's entry"
    got="$(logmerge "$d/wt" main)"; [ "$got" = "2026-09-05T00:00:00Z 2026-09-03T00:00:00Z 2026-09-02T00:00:00Z 2026-09-01T00:00:00Z " ] || fail "the driver did not run in a second worktree: $got"
    git config --remove-section merge.execplan-log   # an attribute naming an undefined driver falls back to git's own text merge
    ( cd "$d/wt" && git reset -q --hard HEAD~1 && printf '# LOG\n\n## 2026-09-06T00:00:00Z — p / w2\nw2\n\n## 2026-09-01T00:00:00Z — p / base\nbase\n' > docs/LOG.md && git commit -qam "note: w2" >/dev/null 2>&1 \
      && ! git merge -q --no-edit -m "note: merge" main >/dev/null 2>&1 && [ -n "$(git ls-files -u -- docs/LOG.md)" ] ) || fail "with the driver unwired, the same merge must conflict (the fixture proves the driver did the work)"
    ( cd "$d/wt" && git merge --abort ) || fail "fixture: abort"
    printf 'RATCHET_LOG=LOG.md\n' > script/ratchet.conf && install_into "$d/r" >/dev/null || fail "an install with a Lite conf failed"
    grep -qxF 'LOG.md merge=execplan-log' "$common/info/attributes" || fail "the conf's RATCHET_LOG was not the path wired"
    printf 'false\n' > script/ratchet.conf; rc=0; install_into "$d/r" >/dev/null 2>&1 || rc=$?
    [ "$rc" -eq 2 ] || fail "a conf that fails to source must fail the install with exit 2 (a tool failure), got $rc"
    rm -f script/ratchet.conf
    # an attributes file that can't be written is a tool failure (2), never "installed" — through the script's own dispatch
    grep -v 'merge=execplan-log' "$common/info/attributes" > "$d/attrs.tmp" || true; cp "$d/attrs.tmp" "$common/info/attributes"
    chmod 444 "$common/info/attributes"
    cp "$HERE/install-hooks.sh" script/install-hooks.sh || fail "fixture: copy the installer into the fixture"
    rc=0; bash script/install-hooks.sh >/dev/null 2>&1 || rc=$?   # the fixture's own copy: its dispatch installs into $d/r only
    chmod 644 "$common/info/attributes"; rm -f script/install-hooks.sh
    [ "$rc" -eq 2 ] || fail "an unwritable info/attributes must exit 2 through the dispatch, got $rc"
    rm -f script/ratchet.conf
    # split-repo mode end to end, real hooks (modules/split-repo.md; the going-public brief's acceptance 1-4 — its 6, a one-repo project
    # unchanged, is every probe above and every other self-test): a code repo with /private ignored, a records repo nested at private/,
    # both wired by one install; a stream pair (a code worktree and a records worktree nested in it, one branch name) whose records
    # commits run that stream's own hooks; a Stage as two commits, its records half naming the code commit in the plan's evidence
    # file; the close, which stamps from the code worktree into the records worktree (after the tidy moved the plan read's verdict
    # into the review dir), refused while a code commit is unpaired or the stamp lacks PLAN.md's flip, then passing; the integration
    # merge of the records branch through the relative merge driver
    ( e="$d/split"; mkdir -p "$e/code/script/hooks" && cd "$e/code" && git init -q . && git config user.email t@t && git config user.name t || exit 1
      for f in ratchet.sh tmp-tidy.sh acceptance-extract.awk refreeze.sh; do cp "$HERE/$f" script/ || exit 1; done
      for h in pre-commit commit-msg pre-push; do cp "$HERE/hooks/$h" script/hooks/ || exit 1; done
      printf 'RATCHET_RECORDS=private\n' > script/ratchet.conf && printf '#!/bin/sh\necho "E_TEST_COUNT=$(cat count.txt)"\n' > script/test.sh \
        && chmod +x script/test.sh && echo 1 > count.txt && echo 1 > .test-count && printf '/private\n/tmp/\n' > .gitignore && printf 'a\n' > src.txt \
        && git add -A . && git -c core.hooksPath=/dev/null commit -qm init && git branch -q -M master || fail "fixture: the code repo"
      git init -q private && ( cd private && git config user.email t@t && git config user.name t && mkdir -p docs/plans \
        && printf '# PLAN\n\n| Plan | File | Status | Depends | Est |\n|---|---|---|---|---|\n| **PLAN-01** x | [x](docs/plans/PLAN-01-x.md) | drafted | none | 1d |\n' > PLAN.md \
        && printf '# LOG\n\n## 2026-09-28T09:00:00Z — note: drafted\nPLAN-01 drafted.\n' > docs/LOG.md && printf '/archive/\n' > .gitignore \
        && printf '# PLAN-01\n\n## Validation and Acceptance\n\n- After A, B.\n\n## Progress\n' > docs/plans/PLAN-01-x.md \
        && git add -A . && git -c core.hooksPath=/dev/null commit -qm 'note: PLAN-01 drafted' && git branch -q -M master ) || fail "fixture: the records repo"
      so="$(install_into "$e/code" 2>&1)" || fail "the split-repo install failed: $so"
      [ "$(git -C private config core.hooksPath)" = ../script/hooks ] || fail "the records repo's hooks are not wired back to the kit"
      [ "$(git -C private config merge.execplan-log.driver)" = '../script/ratchet.sh --merge-log %O %A %B' ] || fail "the records repo's merge driver doesn't name the kit relative to its top"
      grep -qxF 'docs/LOG.md merge=execplan-log' "$(git -C private rev-parse --path-format=absolute --git-common-dir)/info/attributes" || fail "the records repo's LOG isn't mapped to the driver"
      # the stream pair: one branch name in both repos, the records worktree nested in the code worktree
      git worktree add -q "$e/wt" -b plan-01 >/dev/null 2>&1 && git -C private worktree add -q "$e/wt/private" -b plan-01 >/dev/null 2>&1 || fail "fixture: the stream pair"
      [ -z "$(git -C "$e/wt" status --porcelain)" ] || fail "the nested records worktree shows in the code worktree's status: $(git -C "$e/wt" status --porcelain)"
      cd "$e/wt" && mkdir -p tmp/PLAN-01 && printf 'PASS\n' > tmp/PLAN-01/01.1-verdict.md && printf 'PLAN READY\n' > tmp/PLAN-01/prefreeze-read-verdict.md
      # acceptance 1: the code half passes the code hooks with no LOG staged; the records half (the Progress line and the evidence
      # entry naming the code commit, no LOG entry) passes the records hooks, and without the plan file it is refused — they fire
      printf 'b\n' >> src.txt && git add src.txt && git commit -qm 'PLAN-01 / 01.1 — build' >/dev/null 2>&1 || fail "the code half of a Stage was refused by the code hooks"
      s1="$(git rev-parse HEAD)"
      ( cd private && mkdir -p docs/plans/PLAN-01-review && printf '# PLAN-01 evidence\n\n### 01.1\nCode: %s\nevidence: tmp/PLAN-01/01.1-verdict.md\n' "${s1:0:9}" > docs/plans/PLAN-01-review/EVIDENCE.md \
        && git add docs/plans/PLAN-01-review/EVIDENCE.md && git commit -qm 'PLAN-01 / 01.1 — build' >/dev/null 2>&1 ) \
        && fail "the stream's records hooks passed a stage claim with no plan file"
      ( cd private && printf -- '- [x] 01.1\n' >> docs/plans/PLAN-01-x.md \
        && git add docs/plans/PLAN-01-x.md docs/plans/PLAN-01-review/EVIDENCE.md && git commit -qm 'PLAN-01 / 01.1 — build' >/dev/null ) || fail "the records half of a Stage was refused"
      # acceptance 2: a code-side fix with no records half is caught at the close; the harvest close on the code side needs nothing
      printf 'c\n' >> src.txt && git add src.txt && git commit -qm 'PLAN-01 / fix — r1' >/dev/null 2>&1 || fail "the code-side fix was refused"
      s2="$(git rev-parse HEAD)"
      git commit -q --allow-empty -m 'PLAN-01 / close — harvest' >/dev/null 2>&1 || fail "the code-side harvest close was refused"
      # acceptance 4: tmp-tidy tidies the code worktree's tmp/PLAN-01 into the records worktree's review dir and archive/, reading the
      # evidence file's cite and leaving the file in place; the close stamps from the code worktree into the records worktree, the
      # plan read's verdict now in the review dir; the close is refused while the fix is unpaired, then while the stamp lacks
      # PLAN.md's flip, and passes with both
      cp private/docs/plans/PLAN-01-review/EVIDENCE.md "$e/ev0"
      so="$(bash script/tmp-tidy.sh --plan PLAN-01 --apply 2>&1)" || fail "tmp-tidy --apply into the records repo failed: $so"
      [ -f private/docs/plans/PLAN-01-review/MANIFEST.md ] && [ -s private/archive/plans/PLAN-01.list ] && [ ! -e tmp/PLAN-01 ] \
        && cmp -s "$e/ev0" private/docs/plans/PLAN-01-review/EVIDENCE.md \
        || fail "the tidy did not land in the records repo (review dir, archive), clear the code repo's tmp/PLAN-01 and leave the evidence file as it was"
      so="$(bash script/refreeze.sh PLAN-01 --initial 2>&1)" || fail "the close's stamp from the code worktree failed (the verdict is in the records review dir): $so"
      grep -q '^PLAN-01 [0-9a-f]\{64\}' private/docs/plans/.acceptance-hashes || fail "the close's stamp did not land in the records worktree"
      ( cd private && sed 's/| drafted |/| complete |/' PLAN.md > t && mv t PLAN.md && printf '\n## 2026-09-28T11:00:00Z — PLAN-01 / close\nDone.\n' >> docs/LOG.md \
        && git add -A . && so="$(git commit -qm 'PLAN-01 / close — done' 2>&1)"; rc=$?; [ "$rc" -ne 0 ] && grep -qF "${s2:0:12} PLAN-01 / fix — r1" <<< "$so" ) \
        || fail "the records close passed with the code-side fix unpaired (or didn't name it)"
      ( cd private && printf 'Code: %s\n' "$s2" >> docs/LOG.md && git add docs/LOG.md && git reset -q PLAN.md && so="$(git commit -qm 'PLAN-01 / close — done' 2>&1)"; rc=$?
        [ "$rc" -ne 0 ] && grep -qF 'PLAN.md is not in the commit' <<< "$so" ) || fail "the records hooks passed the close's first stamp with no PLAN.md flip"
      ( cd private && git add PLAN.md && git commit -qm 'PLAN-01 / close — done' >/dev/null ) || fail "the paired, tidied, stamped records close was refused"
      # the integration: the records branch merges into the records master, whose LOG grew at the same place meanwhile (a conflict to
      # git's own merge), through the relative driver
      cd "$e/code/private" && printf '\n## 2026-09-28T10:30:00Z — note: another stream\nx\n' >> docs/LOG.md \
        && git commit -qam 'note: another stream' >/dev/null || fail "fixture: the records master moves"
      git merge -q --no-ff --no-commit plan-01 >/dev/null 2>&1 && ! grep -q '^<<<<<<<' docs/LOG.md && git commit -qm 'merge: PLAN-01 / close' >/dev/null \
        || fail "the records branch did not merge through the driver and the hooks"
      [ "$(awk '/^## 20/ { print $2 }' docs/LOG.md | sort | tr '\n' ' ')" = "2026-09-28T09:00:00Z 2026-09-28T10:30:00Z 2026-09-28T11:00:00Z " ] \
        || fail "the merged records LOG does not hold both sides' entries once each: $(awk '/^## 20/ { print $2 }' docs/LOG.md | tr '\n' ' ')"
    ) || fail "split-repo mode end to end (a step above named its failure)"
    # a records repo reached through a symlink is refused, and left unwired: its relative core.hooksPath would resolve from the link's
    # target, naming another kit's hooks or none — a commit there would run unguarded while the install said "installed"
    ( k="$d/lk"; mkdir -p "$k/code/script/hooks" "$k/elsewhere" && cd "$k/code" && git init -q . || exit 1
      for f in ratchet.sh tmp-tidy.sh acceptance-extract.awk; do cp "$HERE/$f" script/ || exit 1; done
      for h in pre-commit commit-msg pre-push; do cp "$HERE/hooks/$h" script/hooks/ || exit 1; done
      printf 'RATCHET_RECORDS=private\n' > script/ratchet.conf && git -C "$k/elsewhere" init -q . && ln -s "$k/elsewhere" private || exit 1
      rc=0; so="$(install_into "$k/code" 2>&1)" || rc=$?
      [ "$rc" -eq 2 ] && grep -qF 'a symlink along RATCHET_RECORDS' <<< "$so" || fail "a symlinked records repo must be exit 2, named (rc=$rc): $so"
      [ -z "$(git -C "$k/elsewhere" config core.hooksPath || true)" ] || fail "the symlinked records repo was wired anyway"
    ) || fail "the symlinked records path (a step above named its failure)"
    echo "SELF-TEST OK" ;;
  *) echo "usage: install-hooks.sh [--self-test]" >&2; exit 64 ;;
esac
