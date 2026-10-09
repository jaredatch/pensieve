#!/usr/bin/env bash
# drive-stage.sh: the one way to launch Codex for a Stage, a small change, a fix batch, a review or a read.
# It owns the invocation (pinned models, sandbox, timeout, closed stdin, prompt and log paths), keeps one Codex session
# per Stage, and records enough to reattach to a run whose launcher died. Rule: protocol/execution-loop.md § Driving an Executor.
#
# Kit copy: copy to script/drive-stage.sh and fill the INVOCATION BLOCK below from the project's decisions (recorded in
# DECISIONS.md; in PLAN.md or the LOG at Lite). A mode refuses a real launch while a value it uses still reads EDIT-ME.
# For another executor CLI, replace the `codex exec` lines and the self-test's argv assertions and keep the rest.
#
# Usage
#   drive-stage.sh PLAN-NN NN.X [--heavy] [--sandbox <mode>] [--again] [--dry-run]   build a Stage in a fresh session (in Herdr: its own tab)
#   drive-stage.sh PLAN-NN NN.X --continue <prompt-file> [--heavy] [--dry-run]        the next message in the Stage's own session
#   drive-stage.sh PLAN-NN NN.X --resume [<prompt-file>] [flags]                      a fresh session, only when the record is gone
#   drive-stage.sh PLAN-NN NN.X --wait [--heavy] | --peek | --abandon                 reattach (sends nothing) · look · settle
#   drive-stage.sh --bounded <slug> [same flags]                                      a small change with no plan (in Herdr: its own tab)
#   drive-stage.sh --fix PLAN-NN <prompt-file> [--again] [--dry-run]                  a fresh build session for a fix batch
#   drive-stage.sh PLAN-NN fix --wait | --peek | --abandon                            recover the last fix batch
#   drive-stage.sh --review PLAN-NN NN.X [--base <sha>] [--head <sha>] [--again] [--dry-run]   review a committed range
#   drive-stage.sh --read PLAN-NN <prompt-file> [--again] [--dry-run]                 a read-only read: premise read, plan read
#   drive-stage.sh --preflight | --self-test
#
# Flags
#   --heavy           timeout 7200 s instead of 3600 s, for a build-heavy Stage
#   --sandbox <mode>  override the invocation block's sandbox for one Stage (e.g. workspace-write for a docs-only Stage).
#                     Under workspace-write the launcher adds --add-dir for the worktree's git dir and common dir
#                     (git rev-parse --git-dir / --git-common-dir; a linked worktree needs both) so the Executor can
#                     commit. Nothing else is granted. Reviews and reads are always read-only.
#   --headless        inside Herdr, launch a build Stage or a --bounded small change without its own tab
#   --pane            ask for the tab outright; refused outside Herdr. Neither flag goes with the other.
#   --again           run again beside an existing log, under the next free -rN suffix (N >= 2)
#   --base, --head    the ends of a --review range. The base defaults to the Stage run log's `before=`; name it when
#                     there is no run log (a Stage the Planner built: the commit before its first). The head defaults to
#                     HEAD; name the Stage's own last commit once later Stages have landed.
#   --dry-run         print the exact command and exit 0: every argument single-quoted so it pastes back, prefixed with
#                     `env -u RATCHET_ALLOW_PUSH` (a build's also with `TMPDIR=<its agent temp>`, which the dry-run
#                     doesn't make). The refusals still apply; the preflight doesn't run.
#   --preflight       run only the preflight. --no-preflight skips it for one launch.
#   --root DIR        act on another repo (the self-test uses it)
#
# Files (under tmp/PLAN-NN/ unless noted)
#   NN.X-prompt.md          the Stage prompt (--resume: NN.X-resume-prompt.md, or the file named)
#   NN.X-run.log            line 1 `# drive-stage: before=<short sha> sandbox=<mode> started=<UTC ISO>`, then Codex's output
#                           (--resume: NN.X-resume-run.log; --again: -rN)
#   NN.X-binding            the Stage's session, its record, its pane, and its last message: the record's length and HEAD
#                           before the send, and sent | settled | uncertain. A --fix batch uses fix-binding.
#   NN.X-rollout.jsonl      a copy of Codex's session record (mode 600; the close archives it, never tracks it)
#   NN.X-L1.log             a --review transcript, and NN.X-L1-verdict.md its final message (-L1 kept so old cites resolve)
#   <name>-read.log         a --read transcript, and <name>-read-verdict.md; <name> is the prompt file's basename less
#                           `.md` and `-prompt` (premise-prompt.md -> premise-read.log). Line 1 of the log:
#                           `# drive-stage: read head=<full sha> model=<review pin> started=<UTC ISO>`
#   fix-run.log             a --fix transcript; the builder commits `PLAN-NN / fix — <summary>`
#   tmp/bounded/<slug>-prompt.md, <slug>-run.log   a --bounded run
#   tmp/.run-lock           the checkout's one build lock, held by every build (any plan, --bounded included)
#   .run-lock-<log name>    a review's or a read's lock
#   Reads REVIEW_MANDATE (.codex/agents/<project>-reviewer.toml, from templates/codex-reviewer.toml) for --review.
#
# How it works
#   Sessions. Every message the launcher sends opens with the tag `[planner NN.X-cN]` (`[planner fix-cN]` for a fix
#     batch). A message is done only when the turn of the first user message after the recorded length that carries its
#     tag completes in Codex's session record. An earlier turn, a turn a human typed, or the Stage's first commit never
#     counts. A fresh session (--again, --resume, a pane launch, a new --fix) is refused while the last message is unsettled,
#     and --resume is refused while the session record exists (use --continue). A fix batch is never continued.
#   Panes. Inside Herdr (HERDR_ENV=1), a build Stage and a --bounded small change run in their own tab by default, labelled
#     `executor (NN.X)` or `executor (<slug>)`. The agent is <project>-codex-NN-X, or <project>-codex-<slug> with the slug
#     lowercased and anything outside a-z, 0-9 and - turned into -. Herdr caps a name at 32 characters, so a longer one is
#     refused before anything is made. --headless opts out. --resume, --fix, --review and --read always run headless, and
#     --continue, --wait, --peek and --abandon follow the Stage's binding. A failed Herdr check (no herdr, its server not running, no workspace; any Herdr version runs)
#     refuses and names --headless. It never falls back to headless on its own. Outside Herdr every launch is headless.
#     A pane launch closes the tabs of the plan's settled Stages (a small change's: the other settled small changes), but
#     only while Herdr reads that Codex idle or done, or the pane no longer holds Codex. A working one (a human may have
#     typed a follow-up), a reply that names no agent kind, or a failed read leaves the tab open with one line; the launch
#     goes on. A small change is one-off: when its run, --continue or --wait settles, it closes its own tab at once under
#     the same guard, waiting up to DRIVE_STAGE_SETTLE_TAB_WAIT (15) s for Herdr to read its Codex idle. A Stage keeps its
#     tab until the Stage ends (the next launch's sweep, or end-stream), so every --continue queues into the live pane.
#   Locks. A lock is a mkdir plus an owner file (pid, start time, plan, stage; kit/herdr/lib.sh's convention). A lock
#     whose launcher died is stale and still blocks the next build, because its Codex may still be working. A build
#     keeps its lock past its own exit while its message is unsettled. Only --wait or --abandon of the same plan and
#     Stage takes a stale lock over, through a mkdir claim (<lock>.claim). A stale lock with no message recorded (no
#     binding, a settled one, or no owner file) is recovered by that Stage's --wait or --abandon (an ownerless one by any
#     Stage's), which reports that nothing was sent. A stale review or read lock is swept at the next launch. A lock that
#     can't be made (a failed mkdir with no lock there, three tries running: an unwritable tmp/) is exit 2, naming it.
#   Pins. Builds, --bounded and --fix use CODEX_MODEL + CODEX_REASONING; --review and --read use CODEX_REVIEW_MODEL +
#     CODEX_REVIEW_REASONING. They may be the same model. Every mode passes its pin explicitly (-m, -c
#     model_reasoning_effort=), because without -m Codex runs the interactive default in ~/.codex/config.toml.
#   Preflight. Before every real launch, `codex --version` must equal DRIVE_STAGE_CODEX_VERSION (empty is refused: probe
#     the invocation by hand once, then pin it), and a 60 s read-only smoke under the pin the mode will use must answer
#     OK. On a mismatch it refuses and prints the recovery: re-probe by hand, re-pin, write a playbook-feedback LOG note. A
#     failed smoke names the usual cause of a refused model first: a model newer than the pinned CLI, which needs the CLI
#     upgraded and the pin raised.
#   Safety. stdin is closed (an open stdin wedges `codex exec`) and `timeout` bounds the run. RATCHET_ALLOW_PUSH is unset
#     before the launch, so an Executor never inherits the human's push key. Every producer is captured and checked: a
#     git failure before the launch refuses (exit 1, nothing launched), and a git, sort or grep failure after it is exit 2
#     with Codex's status and the transcript path, never a result line with a wrong head or count.
#   Agent temp. A build session (a Stage, --continue, --resume, --fix, --bounded) runs with TMPDIR set to its plan's folder
#     under the project's scratch root, outside the repo: <the main checkout's parent>/<its folder>-scratch/tmp/PLAN-NN/ (a
#     small change's: …/tmp/bounded/), so its tests' and tools' temp leaves the shared temp folder and goes when the plan
#     closes (tmp-tidy) or goes stale (the watchman's sweep). XP_SCRATCH_PARENT, absolute, replaces <parent>.
#     A pane gets it through `tab create --env` (with XP_SCRATCH_PARENT when set, and the inherited TMPDIR when no agent temp
#     could be chosen: a tab's shell starts from Herdr's environment), a headless run through the environment, and a dry-run
#     prints it. A path over
#     80 bytes, an unusable XP_SCRATCH_PARENT or a folder that can't be made keeps the inherited TMPDIR with one line:
#     temp never stops a run. Reviews and reads are read-only and keep the inherited TMPDIR. The `>>> xp_scratch` block is
#     kept byte for byte the same as kit/herdr/lib.sh's (new-stream.sh's self-test compares them); the rule's home is
#     protocol/context-discipline.md § Workspace.
#   Reviews. --review refuses an EDIT-ME review pin or mandate, a missing run-log header without --base, a --base or
#     --head that isn't a commit, an empty range (base equals head: commit the Stage first), a base that isn't an
#     ancestor of the head, and an existing review log or verdict without --again.
#   Split-repo mode (modules/split-repo.md). RATCHET_RECORDS in script/ratchet.conf (a non-empty environment value wins; an
#     empty one leaves the conf in force) names the records repo, a path from the code repo's top such as `private`; empty or
#     unset is one repo, and every line this launcher prints or passes is then as before. With it set: -C, tmp/ and every run
#     file stay in the code repo; trailing slashes are stripped, and the records root must be relative, with no '.', '..' or
#     empty component and no symlink along it, and its own git work tree (else exit 2); a build's message (a fresh session, a --fix batch, a --bounded change) and a read's
#     carry one `[split-repo]` line naming the records repo and, for a build, the two-commit rule (code first, then its
#     records under the same subject, with a `Code: <short sha>` line naming the code commit: in the plan's evidence entry for a Stage or a --fix batch, in its LOG entry for a --bounded change); a review's prompt
#     names the records repo and, when the run log's header recorded it, the Stage's records range; workspace-write also
#     grants the records repo's git dir and common dir; the run log's header ends ` records=<short sha>`; the binding keeps
#     the records HEAD (rhead=); and the result line adds records-head= and records-commit= (changed= counts both repos).
#
# Codex CLI facts this relies on (probed 0.144-0.154; check `codex exec --help` / `codex exec review --help` when one breaks)
#   - `codex exec review` is read-only by design and takes -m, -c and -o as its own options; -C goes before `review`.
#   - Its diff selectors (--base, --commit, --uncommitted) can't be combined with a custom prompt. So --review validates
#     both ends as full shas and names the range in the prompt: "run git diff <base>..<head> and review exactly that".
#   - There is no --agent flag. A .codex/agents/*.toml file is mandate text the prompt points at, never a spawned reviewer,
#     and a file whose developer_instructions is blank is ignored.
#   - -o writes only the final message (the verdict file), so the transcript comes from the stdout redirect. --json
#     emits JSONL events and isn't used.
#
# Result: ONE line, then the launcher exits with Codex's status.
#   build   PLAN-NN NN.X exit=<rc> log=<path> head=<short sha> changed=<n> commit=<short sha|none|moved> session=<id|none>
#           rollout=<copy|none>   (a pane run, --wait and a queued --continue add pane=<id|none> settled=yes|no).
#           In split-repo mode records-head=<short sha> records-commit=<short sha|none|moved|unknown> follow rollout=
#           (commit= stays the code repo's; unknown: a binding written before the records HEAD was kept).
#           changed counts paths that differ from the pre-run HEAD: committed, uncommitted and untracked.
#   fix     PLAN-NN fix …   and   bounded <slug> …   the same fields as a build
#   review  PLAN-NN NN.X review exit=<rc> log=<path> verdict=<path> scope=<range>
#   read    PLAN-NN read exit=<rc> log=<path> verdict=<path> head=<short sha>
# Exit codes, besides Codex's own:
#   1    refused; nothing launched
#   2    a tool failed (git, jq, grep, sort …). Never read as absent or clean.
#   64   usage error
#   75   the message never reached the session record. It is never re-sent.
#   124  the timeout fired. After a build, --continue into the Stage's session ("time's up, commit what's done"),
#        never a restart. After --wait with settled=no, the run is still going: --wait again or --peek.
#   130  the turn was aborted
set -eu   # NOT pipefail (the kit's rule): every producer below is captured, then checked

# ---- the ONE place the Executor invocation lives. The briefing (AGENTS.md § operating mode) only points here. ----
# Fill from your project's decisions: the model + reasoning effort, and the sandbox (sandbox to the risk — a build that
# spawns its own sandbox, e.g. xcodebuild → SwiftPM's sandbox-exec, cannot run inside Codex's Seatbelt and needs
# danger-full-access on an isolated machine; a docs-only stage can run workspace-write). Env overrides exist for the
# self-test and for a one-off; the file is the record.
CODEX_MODEL="${DRIVE_STAGE_MODEL:-gpt-6.1-sol}"                     # the BUILDER's pin: stages, --bounded, --fix
CODEX_REASONING="${DRIVE_STAGE_REASONING:-xhigh}"             # e.g. high
CODEX_REVIEW_MODEL="${DRIVE_STAGE_REVIEW_MODEL:-gpt-6-astra}"       # the REVIEWER's pin: --review, --read (may be the builder's model; decided once, in DECISIONS.md)
CODEX_REVIEW_REASONING="${DRIVE_STAGE_REVIEW_REASONING:-xhigh}"   # e.g. xhigh
CODEX_SANDBOX="${DRIVE_STAGE_SANDBOX:-danger-full-access}"                 # the builder's sandbox (a review and a read are always read-only)
TIMEOUT_NORMAL="${DRIVE_STAGE_TIMEOUT:-3600}"
TIMEOUT_HEAVY="${DRIVE_STAGE_TIMEOUT_HEAVY:-7200}"
CODEX_VERSION="${DRIVE_STAGE_CODEX_VERSION-0.160.0}"   # the pin, e.g. 0.144.3 — what the invocation below was last probed against; empty = unpinned (a launch is refused until it is set). `-` not `:-`: an explicitly EMPTY env value means unpinned even on a filled copy (the self-test relies on it)
REVIEW_MANDATE="${DRIVE_STAGE_REVIEW_MANDATE:-private/.codex/agents/pensieve-reviewer.toml}"   # the stage reviewer's mandate file, repo-relative: templates/codex-reviewer.toml copied to .codex/agents/<project>-reviewer.toml; --review is refused while it reads EDIT-ME
# --------------------------------------------------------------------------------------------------
PROJECT="${DRIVE_STAGE_PROJECT:-}"   # a pane launch names its agent <project>-codex-NN-X or <project>-codex-<slug> (Herdr names are global across workspaces); empty = the main checkout's folder name
PANE_DELIVERY="${DRIVE_STAGE_PANE_DELIVERY:-180}"   # a pane launch / a queued --continue: seconds for the tagged message to show in Codex's session record before its delivery reads as unconfirmed
POLL="${DRIVE_STAGE_POLL:-5}"   # seconds between reads of the session record while a pane run is live
CODEX_SESSIONS="${CODEX_HOME:-$HOME/.codex}/sessions"   # Codex's session records: rollout-<time>-<session id>.jsonl, one per session, appended by every turn

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SCRIPT_ROOT"
REC_REL=""; REC=""   # split-repo mode: the records repo's path from the code repo's top, and its physical path; both empty = one repo (records_resolve sets them)
plan=""; stage=""; heavy=0; resume=0; resume_prompt=""; again=0; dry=0; selftest=0; bounded=""; preflight_only=0; no_preflight=0; review=0; base=""; rhead=""; rhead_set=0; sandbox_set=0; readmode=0; fixmode=0
cont_prompt=""; waitmode=0; peekmode=0; panemode=0; headless=0; abandonmode=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --continue)  [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "drive-stage: --continue needs a <prompt-file>" >&2; exit 64; }
                 cont_prompt="$2"; shift 2 ;;
    --wait)      waitmode=1; shift ;;
    --peek)      peekmode=1; shift ;;
    --pane)      panemode=1; shift ;;
    --headless)  headless=1; shift ;;
    --abandon)   abandonmode=1; shift ;;
    --heavy)     heavy=1; shift ;;
    --bounded)   bounded="${2:-}"; shift 2 ;;
    --sandbox)   CODEX_SANDBOX="$2"; sandbox_set=1; shift 2 ;;
    --resume)    resume=1; shift
                 case "${1:-}" in ""|--*) ;; *) resume_prompt="$1"; shift ;; esac ;;
    --review)    review=1; shift ;;
    --read)      readmode=1; shift ;;
    --fix)       fixmode=1; shift ;;
    --base)      base="${2:-}"; shift 2 ;;
    --head)      [ "$#" -ge 2 ] || { echo "drive-stage: --head needs a <sha>" >&2; exit 64; }   # a bare trailing --head must not die silently in `shift 2`
                 rhead="$2"; rhead_set=1; shift 2 ;;
    --again)     again=1; shift ;;
    --dry-run)   dry=1; shift ;;
    --preflight) preflight_only=1; shift ;;
    --no-preflight) no_preflight=1; shift ;;
    --self-test) selftest=1; shift ;;
    --root)      ROOT="${2:-}"; shift 2 ;;
    --*)         echo "drive-stage: unknown arg: $1" >&2; exit 64 ;;
    *) if [ -z "$plan" ]; then plan="$1"; elif [ -z "$stage" ]; then stage="$1"; else echo "drive-stage: extra arg: $1" >&2; exit 64; fi; shift ;;
  esac
done

timeout_bin() {   # GNU coreutils `timeout` (homebrew); macOS ships none. gtimeout is the un-prefixed install's name.
  if command -v timeout >/dev/null 2>&1; then echo timeout
  elif command -v gtimeout >/dev/null 2>&1; then echo gtimeout
  else return 1; fi
}

prompt_path() {   # $1 root, $2 a prompt file (repo-relative or absolute) → its path on disk
  case "$2" in /*) printf '%s\n' "$2" ;; *) printf '%s/%s\n' "$1" "$2" ;; esac
}

# resolve prompt + log for one invocation; prints "<prompt>\t<log>" (the prompt as given — repo-relative or absolute; the log
# repo-relative) or fails with the refusal
resolve_paths() {   # $1 root, $2 plan, $3 stage, $4 resume(0/1), $5 resume_prompt (or --fix's prompt file), $6 again(0/1), $7 fix(0/1)
  local root="$1" plan="$2" stage="$3" resume="$4" rp="$5" again="$6" fix="${7:-0}" dir prompt log n
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"   # a bounded task's scratch: no plan cites it (§ Workspace)
  if [ "$fix" -eq 1 ]; then   # a fix batch across Stages: the prompt file named on the command line, one plan-level log
    prompt="$rp"; log="$dir/fix-run.log"
  elif [ "$resume" -eq 1 ]; then
    prompt="${rp:-$dir/$stage-resume-prompt.md}"; log="$dir/$stage-resume-run.log"
  else
    prompt="$dir/$stage-prompt.md"; log="$dir/$stage-run.log"
  fi
  [ -f "$(prompt_path "$root" "$prompt")" ] || { echo "drive-stage: prompt file missing: $prompt" >&2; return 1; }
  if [ -e "$root/$log" ]; then
    if [ "$again" -eq 1 ]; then
      n=2; while [ -e "$root/${log%.log}-r$n.log" ]; do n=$((n+1)); done
      log="${log%.log}-r$n.log"
    else
      echo "drive-stage: log already exists: $log (pass --again for a -rN log)" >&2; return 1
    fi
  fi
  printf '%s\t%s\n' "$prompt" "$log"
}

last_line() {   # $1 text → its last non-blank line, trimmed — bash expansions only: no grep/tail/sed whose status could go unread, no here-string temp file
  local t="$1"
  t="${t%"${t##*[![:space:]]}"}"                # drop trailing whitespace, newlines included
  t="${t##*$'\n'}"                              # the last line
  printf '%s\n' "${t#"${t%%[![:space:]]*}"}"   # drop leading whitespace
}

unfilled() {   # $1 what, then NAME=value pairs → 0 iff none still reads EDIT-ME; else a refusal naming every one (nothing launched)
  local what="$1" kv bad=""; shift
  for kv in "$@"; do case "${kv#*=}" in *EDIT-ME*) bad="$bad ${kv%%=*}" ;; esac; done
  [ -z "$bad" ] && return 0
  echo "drive-stage: edit the invocation block first — $what needs:$bad (still EDIT-ME)" >&2; return 1
}

preflight() {   # $1 root, $2 model, $3 reasoning → 0 iff the CLI is the pinned version and a smoke UNDER THAT PIN exits 0 with OK as its last line
  local root="$1" model="$2" reasoning="$3" tb have out ver rc=0 tl l
  tb="$(timeout_bin)" || { echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 1; }
  command -v codex >/dev/null 2>&1 || { echo "drive-stage: preflight — no codex on PATH" >&2; return 1; }
  ver="$(codex --version 2>&1)" || rc=$?   # the status is checked on its own: a version string from a failing CLI is not a version
  [ "$rc" -eq 0 ] || { echo "drive-stage: preflight — 'codex --version' failed (exit $rc): ${ver:-<no output>}" >&2; return 1; }
  rc=0; have="$(printf '%s\n' "$ver" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?')" || rc=$?   # three-way: 0 a version, 1 none printed, else grep itself failed — not a verdict on the version
  case "$rc" in
    0) have="${have%%$'\n'*}" ;;
    1) echo "drive-stage: preflight — 'codex --version' printed no version: $ver" >&2; return 1 ;;
    *) echo "drive-stage: preflight — grep failed (exit $rc) parsing the output of 'codex --version'; not a verdict on the version" >&2; return 1 ;;
  esac
  if [ -z "$CODEX_VERSION" ]; then
    echo "drive-stage: preflight — codex is $have and the invocation block carries no pin. Probe this version by hand once (a read-only smoke, then a real stage under --no-preflight), then set DRIVE_STAGE_CODEX_VERSION=$have in the block; an unpinned launch is refused so the pin is never skipped." >&2
    return 1
  elif [ "$have" != "$CODEX_VERSION" ]; then
    echo "drive-stage: preflight — codex is $have, the invocation was probed against $CODEX_VERSION. The CLI moved under the pin: re-probe the invocation by hand (a read-only smoke, then a real stage), re-pin DRIVE_STAGE_CODEX_VERSION, and write a playbook-feedback LOG note naming what changed. --no-preflight skips this once." >&2
    return 1
  fi
  local last
  rc=0; out="$("$tb" 60 codex exec -m "$model" -c "model_reasoning_effort=$reasoning" -s read-only -C "$root" "Reply with exactly the word OK and nothing else." < /dev/null 2>&1)" || rc=$?
  last="$(last_line "$out")"
  if [ "$rc" -ne 0 ] || [ "$last" != "OK" ]; then   # the exit status AND the final line, exactly — an echoed prompt or a timeout that mentions OK is not an answer
    echo "drive-stage: preflight — the smoke under the pin $model ($reasoning) did not complete with the answer OK (exit $rc, last line: '${last:-<none>}'; the pin was refused, or the invocation shape or the auth moved). Re-probe by hand, re-pin, playbook-feedback note. --no-preflight skips this once." >&2
    echo "  If the output below says $model is unknown, unsupported or needs a newer version, the usual cause is a model newer than codex $have: upgrade the CLI, re-probe, and raise DRIVE_STAGE_CODEX_VERSION to the new version." >&2
    tl="$(tail -n 5 <<< "$out")" || tl="$out"
    while IFS= read -r l; do echo "  $l" >&2; done <<< "$tl"
    return 1
  fi
  return 0
}

shq() {   # single-quote one argument for the dry-run's printed command, so a path with a space pastes back as one argv element
  local s="$1" q="'"
  s="${s//$q/$q\\$q$q}"
  printf "'%s'" "$s"
}

# >>> xp_scratch: agent temp's home (protocol/context-discipline.md § Workspace). Kept byte for byte the same in kit/herdr/lib.sh and
# kit/drive-stage.sh.example, which is copied into projects and can't source this file; new-stream.sh's self-test compares the copies.
xp_scratch_root() {   # $1 a checkout (the main one or a stream's worktree) → prints the project's scratch root, no trailing slash:
  # <parent>/<the main checkout's folder>-scratch, the parent being XP_SCRATCH_PARENT when set (absolute), else the main checkout's own.
  # The main checkout is the parent of git's common dir, so a stream's worktree (../<project>-PLAN-NN) maps to its project's root, and
  # two projects under one XP_SCRATCH_PARENT keep apart. 1 when the override isn't usable, 2 when git fails (the reason printed either way)
  local c m p
  c="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || { echo "scratch: git rev-parse --git-common-dir failed in $1" >&2; return 2; }
  case "$c" in
    */.git) m="${c%/.git}" ;;
    *) m="$(git -C "$1" rev-parse --show-toplevel 2>/dev/null)" || { echo "scratch: git rev-parse --show-toplevel failed in $1" >&2; return 2; } ;;   # a git dir kept elsewhere: the checkout itself
  esac
  case "$m" in /?*) ;; *) echo "scratch: the main checkout '$m' has no parent folder" >&2; return 1 ;; esac
  p="${m%/*}"
  if [ -n "${XP_SCRATCH_PARENT:-}" ]; then
    p="${XP_SCRATCH_PARENT%/}"
    case "$p" in /?*) ;; *) echo "scratch: XP_SCRATCH_PARENT '$XP_SCRATCH_PARENT' is not an absolute folder below /" >&2; return 1 ;; esac
  fi
  printf '%s/%s-scratch\n' "$p" "${m##*/}"
}

xp_scratch_tmpdir() {   # $1 a checkout, $2 PLAN-NN | bounded → prints <scratch root>/tmp/<$2>/, the TMPDIR of that plan's sessions (of small
  # changes and sprints: bounded), without making it; 1 when it can't, the reason printed: a bad name, no scratch root, or a path over 80
  # bytes (a socket made under it could pass macOS's 104-byte limit; counted under LC_ALL=C, so a multibyte name counts every byte). The
  # caller then keeps the inherited TMPDIR: temp never stops a run
  local r n
  case "$2" in bounded|PLAN-[0-9]*) ;; *) echo "scratch: '$2' is not PLAN-NN or bounded" >&2; return 1 ;; esac
  case "$2" in PLAN-*[!0-9]*) echo "scratch: '$2' is not PLAN-NN or bounded" >&2; return 1 ;; esac
  r="$(xp_scratch_root "$1")" || return 1
  r="$r/tmp/$2/"
  n="$(LC_ALL=C; printf '%s' "${#r}")" || { echo "scratch: cannot measure $r" >&2; return 1; }
  [ "$n" -le 80 ] || { echo "scratch: $r is $n bytes, over 80: a socket made under it could pass macOS's 104-byte limit — set XP_SCRATCH_PARENT to a shorter folder" >&2; return 1; }
  printf '%s\n' "$r"
}
# <<< xp_scratch

SCRATCH_TMP=""   # the TMPDIR this launch's build session gets (scratch_env); empty = the inherited one
scratch_env() {   # $1 root, $2 PLAN-NN | bounded, $3 dry (0/1) → a build session's agent temp outside the repo (protocol/context-discipline.md
  # § Workspace): SCRATCH_TMP set and, on a real launch, the folder made and TMPDIR exported. Anything that fails keeps the inherited
  # TMPDIR with one line on stderr: temp never stops a run. A dry-run makes nothing and only prints it
  local t
  t="$(xp_scratch_tmpdir "$1" "$2")" || { echo "drive-stage: the session keeps TMPDIR=${TMPDIR:-/tmp} (the line above)" >&2; return 0; }
  if [ "$3" -eq 0 ]; then
    mkdir -p "$t" 2>/dev/null && [ -w "$t" ] || { echo "drive-stage: cannot create or write $t — the session keeps TMPDIR=${TMPDIR:-/tmp}" >&2; return 0; }
    TMPDIR="$t"; export TMPDIR
  fi
  SCRATCH_TMP="$t"
}

records_resolve() {   # $1 root → REC_REL / REC for split-repo mode (modules/split-repo.md): RATCHET_RECORDS as every kit script reads it — a
  # NON-EMPTY environment value wins, else <root>/script/ratchet.conf's, sourced in a subshell (the pre-push hook's pattern); empty or unset = one
  # repo. The records path rule: trailing slashes stripped; refused (2, named, nothing launched) when absolute, with a '.', '..' or empty
  # component, with a symlink anywhere along it (its physical path must be its lexical one under the root: a linked records path gets
  # hooks git never runs), or not the top of its own git work tree — never a fall back to one repo
  local root="$1" conf rr="" rc=0 rootp phys top
  REC_REL=""; REC=""
  if [ -n "${RATCHET_RECORDS:-}" ]; then rr="$RATCHET_RECORDS"
  else
    conf="$root/script/ratchet.conf"
    if [ -f "$conf" ]; then
      rr="$( . "$conf" >/dev/null || exit $?; printf '%s' "${RATCHET_RECORDS:-}" )" || rc=$?
      [ "$rc" -eq 0 ] || { echo "drive-stage: sourcing $conf failed (exit $rc) — the records repo can't be read; nothing launched" >&2; return 2; }
    fi
  fi
  [ -n "$rr" ] || return 0
  while :; do case "$rr" in */) rr="${rr%/}" ;; *) break ;; esac; done
  case "$rr" in ""|/*) echo "drive-stage: RATCHET_RECORDS='$rr' must be a path from the code repo's top, not an absolute one — nothing launched" >&2; return 2 ;; esac
  case "/$rr/" in */./*|*/../*|*//*) echo "drive-stage: RATCHET_RECORDS='$rr' names a '.', '..' or empty component — nothing launched" >&2; return 2 ;; esac
  rootp="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "drive-stage: cannot enter the root $root — nothing launched" >&2; return 2; }
  phys="$(cd "$root/$rr" 2>/dev/null && pwd -P)" || { echo "drive-stage: RATCHET_RECORDS=$rr names no directory in $root (split-repo mode: clone the records repo there) — nothing launched" >&2; return 2; }
  [ "$phys" = "$rootp/$rr" ] || { echo "drive-stage: RATCHET_RECORDS=$rr — a symlink along the path leads to $phys; the records repo must sit at $rootp/$rr itself — nothing launched" >&2; return 2; }
  top="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null)" || { echo "drive-stage: RATCHET_RECORDS=$rr — $phys is not a git work tree — nothing launched" >&2; return 2; }
  top="$(cd "$top" 2>/dev/null && pwd -P)" || { echo "drive-stage: RATCHET_RECORDS=$rr — cannot enter the work tree git names for $phys — nothing launched" >&2; return 2; }
  [ "$top" = "$phys" ] || { echo "drive-stage: RATCHET_RECORDS=$rr — $phys is inside the work tree $top, not the top of its own repo — nothing launched" >&2; return 2; }
  REC_REL="$rr"; REC="$phys"
}

split_note() {   # $1 build|read, $2 the plan (`bounded` for a small change) → the one `[split-repo]` line a message carries in
  # split-repo mode; nothing in one repo. A Stage or --fix build names the plan's evidence entry as the Code: line's home; a small
  # change has no plan file (and a patch never edits a closed plan's), so its Code: line rides in its LOG entry (modules/split-repo.md)
  [ -n "$REC_REL" ] || return 0
  if [ "$1" = build ] && [ "${2:-}" = bounded ]; then
    printf '%s\n' "[split-repo] The records (PLAN.md, the LOG, the plan files) are the separate git repo at $REC_REL/ (modules/split-repo.md). Every builder commit is two commits: the code in this repo first, then its records in $REC_REL/ under the same subject, the small change's LOG entry carrying a \`Code: <short sha>\` line that names the code commit. A closed plan's files are never edited."
  elif [ "$1" = build ]; then
    printf '%s\n' "[split-repo] The records (PLAN.md, the LOG, the plan files) are the separate git repo at $REC_REL/ (modules/split-repo.md). Every builder commit is two commits: the code in this repo first, then its records in $REC_REL/ under the same subject, the plan's evidence entry (docs/plans/PLAN-NN-review/EVIDENCE.md there) carrying a \`Code: <short sha>\` line that names the code commit."
  else
    printf '%s\n' "[split-repo] The records (PLAN.md, the LOG, the plan files) are the separate git repo at $REC_REL/ (modules/split-repo.md): read the plan and the LOG there."
  fi
}

git_write_dirs() {   # $1 root → the directories a commit from this worktree writes, absolute, one per line, deduped. The root is made
  # absolute FIRST (`cd … && pwd -P`, captured and checked; a root that cannot be entered is a refusal) — a relative --root (`.`) once
  # printed `./.git` as the grant, because a relative answer was prefixed with the root as given. Then `git rev-parse --git-dir` and
  # `--git-common-dir`, each captured and checked (a relative answer — `.git` at a main worktree's top — is made absolute against the
  # resolved root). A main worktree: the one <root>/.git. A LINKED worktree (`git worktree add`): <root>/.git is a pointer FILE;
  # the index and HEAD live under <main>/.git/worktrees/<name>, the objects and refs under <main>/.git — granting <root>/.git alone
  # left the promised stage commit unable to write
  local root gd cdir rc=0
  root="$(cd "$1" 2>/dev/null && pwd -P)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$root" ] || { echo "drive-stage: root '$1' is not a directory that can be entered (exit $rc) — nothing launched" >&2; return 1; }
  rc=0; gd="$(git -C "$root" rev-parse --git-dir)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$gd" ] || { echo "drive-stage: git rev-parse --git-dir failed in $root (exit $rc) — nothing launched" >&2; return 1; }
  rc=0; cdir="$(git -C "$root" rev-parse --git-common-dir)" || rc=$?
  [ "$rc" -eq 0 ] && [ -n "$cdir" ] || { echo "drive-stage: git rev-parse --git-common-dir failed in $root (exit $rc) — nothing launched" >&2; return 1; }
  case "$gd" in /*) ;; *) gd="$root/$gd" ;; esac
  case "$cdir" in /*) ;; *) cdir="$root/$cdir" ;; esac
  printf '%s\n' "$gd"; [ "$cdir" = "$gd" ] || printf '%s\n' "$cdir"
}

all_write_dirs() {   # $1 root → git_write_dirs for the root, then (split-repo mode) for the records repo: a records commit writes its own git
  # dirs, which in a stream's worktree live under the main checkout's records repo; 1 (named) when either can't be resolved
  local a b
  a="$(git_write_dirs "$1")" || return 1
  printf '%s\n' "$a"
  [ -n "$REC" ] || return 0
  b="$(git_write_dirs "$REC")" || return 1
  printf '%s\n' "$b"
}

# ---- one Executor session per Stage (v0.20): the run lock, the binding, Codex's session record ---------------------------------
# The run lock (kit/herdr/lib.sh's convention — the watchman and the manager read it): a `mkdir` directory holding `owner`
# (pid= start= what= plan= stage= at=). A BUILD run (a stage, --resume, --continue, --wait, --abandon, --fix, --bounded, in a pane or not) holds
# the checkout's ONE build lock tmp/.run-lock — one writer per checkout, whatever the plan; a review or a read holds
# tmp/PLAN-NN/.run-lock-<its log's name> (tmp/bounded/.run-lock-<name>). LIVE: the owner pid runs with its recorded start time. STALE
# (the pid is gone or reused — `ps` positively says so; a `ps` that cannot read even this launcher is a failure, never "gone") is not
# free: a dead launcher may have left Codex working in its tab, so a stale build lock refuses every build run until --wait of the SAME
# plan and stage takes it over (or --abandon settles the message) — another Stage's stale lock is refused, never taken. A takeover
# claims <lock>.claim (mkdir) first and re-reads the lock under it: two takers never both win; a leftover claim is removed by hand.
# A stale lock left by a launcher that died BEFORE recording a message (owner-less, or its plan and stage with no binding or a settled
# one) is recovered by that Stage's --wait or --abandon (an owner-less one by any Stage's): taken over, released — nothing was sent.
# A lock that cannot be read (ps, the owner file) or a claim that cannot be removed is exit 2, never "free", "stale" or silence.
# A stale review lock guards nothing (a review writes no code) and the next invocation for the plan removes it. A build run keeps its
# lock past its own exit while the message it sent is unsettled — the watchman then reads "launcher gone" and the manager will not
# rotate over it.
RUN_LOCK=""; LOCK_RELEASE=1   # the lock this run holds, and whether its exit drops it (0 from the send until the message settles)

proc_start() {   # $1 pid → its start time (`ps -o lstart=`, runs of spaces squeezed — BSD pads a one-digit day); 1 when no such process;
  # 2 otherwise: "no such process" is ONLY ps's own answer for it — exit 1, nothing printed — while ps still reads this shell's start;
  # any other status, an empty exit 0, or a ps that cannot read even this shell is a broken lookup, never "the owner is gone"
  local s rc=0 me mrc=0
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  s="$(ps -o lstart= -p "$1" 2>/dev/null)" || rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$s" ]; then set -f; set -- $s; set +f; printf '%s\n' "$*"; return 0; fi
  if [ "$rc" -eq 1 ] && [ -z "$s" ]; then
    me="$(ps -o lstart= -p "$$" 2>/dev/null)" || mrc=$?
    [ "$mrc" -eq 0 ] && [ -n "$me" ] && return 1
  fi
  echo "drive-stage: ps could not read pid $1's start time (exit $rc) — not a verdict on it" >&2; return 2
}

kv_get() {   # $1 a file of KEY=value lines, $2 key → prints the value ("" when the key or the file is absent); 2 when it cannot be read
  local f="$1" k v
  [ -e "$f" ] || return 0
  [ -r "$f" ] || { echo "drive-stage: cannot read $f" >&2; return 2; }
  while IFS='=' read -r k v; do [ "$k" = "$2" ] && { printf '%s\n' "$v"; return 0; }; done < "$f"
  return 0
}

lock_state() {   # $1 lock dir → free | live | starting | stale; 2 when it cannot be read (never read as free)
  local d="$1" pid start now mt clk rc
  [ -d "$d" ] || { echo free; return 0; }
  if [ ! -f "$d/owner" ]; then   # between another launcher's mkdir and its owner write — for 10 s; after that its writer is gone
    mt="$(stat -f %m "$d" 2>/dev/null || stat -c %Y "$d" 2>/dev/null)" || { echo "drive-stage: cannot stat $d" >&2; return 2; }
    clk="$(date +%s)" || { echo "drive-stage: the clock could not be read — the lock's age is unknown" >&2; return 2; }   # checked: a failed date once read as `starting`
    case "$clk" in ''|*[!0-9]*) echo "drive-stage: the clock read '$clk', not a number — the lock's age is unknown" >&2; return 2 ;; esac
    case "$mt" in ''|*[!0-9]*) echo "drive-stage: $d's mtime read '$mt', not a number — the lock's age is unknown" >&2; return 2 ;; esac
    if [ $(( clk - mt )) -lt 10 ]; then echo starting; else echo stale; fi
    return 0
  fi
  pid="$(kv_get "$d/owner" pid)" || return 2
  start="$(kv_get "$d/owner" start)" || return 2
  rc=0; now="$(proc_start "$pid")" || rc=$?
  case "$rc" in 0) ;; 1) echo stale; return 0 ;; *) return 2 ;; esac
  if [ "$now" = "$start" ]; then echo live; else echo stale; fi
}

lock_own() {   # $1 lock dir (it exists), $2 what, $3 plan, $4 stage → this launcher's owner file, written atomically; then read back (two takers: the last writer wins)
  local start p
  start="$(proc_start "$$")" || { echo "drive-stage: cannot read this launcher's own start time (ps)" >&2; return 2; }
  printf 'pid=%s\nstart=%s\nwhat=%s\nplan=%s\nstage=%s\nat=%s\n' "$$" "$start" "$2" "${3:-}" "${4:-}" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$1/owner.tmp.$$" && mv -f "$1/owner.tmp.$$" "$1/owner" \
    || { rm -f "$1/owner.tmp.$$"; echo "drive-stage: cannot write $1/owner" >&2; return 2; }
  p="$(kv_get "$1/owner" pid)" || return 2
  [ "$p" = "$$" ] || { echo "drive-stage: another launcher took $1 at the same moment — nothing launched" >&2; return 1; }
}

lock_takeover() {   # $1 lock dir (judged STALE), $2 what, $3 plan, $4 stage → 0 ours; 1 refused (the reason printed); 2 a tool failed (a read,
  # the owner write, or the claim's removal — the claim is then left in place and named, so the next taker refuses). Atomic: <lock>.claim (mkdir)
  # is the mutex two takers race for, and under it the lock must still read stale under the SAME owner (pid + start) the judgment saw.
  # A claim left by a taker killed inside this window is never aged out: the refusal names it, and a human removes it
  local d="$1" c="$1.claim" p0 s0 p1 s1 st rc=0
  p0="$(kv_get "$d/owner" pid)" || return 2
  s0="$(kv_get "$d/owner" start)" || return 2
  mkdir "$c" 2>/dev/null || { echo "drive-stage: another launcher is taking over $d at this moment — or a takeover was interrupted: once no launcher runs, remove $c by hand (rmdir) — nothing taken over" >&2; return 1; }
  st="$(lock_state "$d")" || rc=$?
  p1="$(kv_get "$d/owner" pid)" || rc=2
  s1="$(kv_get "$d/owner" start)" || rc=2
  if [ "$rc" -ne 0 ] || [ "$st" != stale ] || [ "$p1" != "$p0" ] || [ "$s1" != "$s0" ]; then
    claim_drop "$c" || return 2
    [ "$rc" -eq 0 ] || { echo "drive-stage: reading the run lock $d under the claim failed — nothing taken over" >&2; return 2; }
    echo "drive-stage: the run lock $d changed while it was being taken over (now: $st) — nothing taken over; look again (--peek)" >&2; return 1
  fi
  rc=0; lock_own "$d" "$2" "$3" "$4" || rc=$?
  claim_drop "$c" || return 2   # the lock (ours now, or the other taker's) stays; the named claim refuses the next taker until a human removes it
  return "$rc"
}
claim_drop() {   # $1 a takeover's claim dir → 0 removed; 2 (named, for a human to remove) when rmdir fails
  rmdir "$1" 2>/dev/null || { echo "drive-stage: cannot remove the takeover claim $1 — once no launcher runs, remove it by hand (rmdir); every takeover refuses while it stands" >&2; return 2; }
}

lock_take() {   # $1 lock dir, $2 what, $3 1 = may take over a STALE lock (--wait, --abandon), $4 plan, $5 stage → 0 held by this launcher (RUN_LOCK set);
  # 1 refused, the reason printed (live, another Stage's stale lock, a claim in the way); 2 a tool failed (ps, the owner's read or write,
  # or a lock that can't be made: a failed mkdir with no lock there, three times over — an unwritable tmp/ once looped here forever)
  local d="$1" what="$2" take="${3:-0}" lp="${4:-}" ls="${5:-}" st="" w op os rc=0 try=0
  mkdir -p "$(dirname "$d")" || { echo "drive-stage: cannot create $(dirname "$d") — nothing launched" >&2; return 2; }
  while [ "$try" -lt 3 ]; do   # bounded: a lock released between a failed mkdir and the read is retried, never recursed into
    try=$((try + 1))
    if mkdir "$d" 2>/dev/null; then
      lock_own "$d" "$what" "$lp" "$ls" || { rc=$?; rmdir "$d" 2>/dev/null || echo "drive-stage: cannot remove the owner-less $d this launcher just made — remove it by hand once no launcher runs" >&2; return "$rc"; }
      RUN_LOCK="$d"; return 0
    fi
    [ -d "$d" ] || { st=""; continue; }   # mkdir failed and no lock is there: a folder that can't be written, or a lock just released
    st="$(lock_state "$d")" || { echo "drive-stage: cannot tell whether the run lock $d is held — nothing done" >&2; return 2; }
    [ "$st" = free ] || break   # released between the mkdir and the read: try again
  done
  [ -n "$st" ] && [ "$st" != free ] || { echo "drive-stage: cannot make the run lock $d — mkdir failed 3 times with no lock there (is $(dirname "$d") writable?) — nothing launched" >&2; return 2; }
  w="$(kv_get "$d/owner" what)" || return 2
  op="$(kv_get "$d/owner" plan)" || return 2
  os="$(kv_get "$d/owner" stage)" || return 2
  case "$st" in
    stale)
      if [ "$take" -eq 1 ]; then
        if [ -f "$d/owner" ] && { [ "$op" != "$lp" ] || [ "$os" != "$ls" ]; }; then   # an owner-less lock died before any send: any --wait/--abandon may take it
          echo "drive-stage: the stale run lock $d belongs to ${op:-?} ${os:-?} ('${w:-?}'), not $lp $ls — run --wait (or --peek) for ${op:-that plan} ${os:-that stage}; nothing taken over" >&2; return 1
        fi
        lock_takeover "$d" "$what" "$lp" "$ls" || return $?
        RUN_LOCK="$d"; echo "drive-stage: took over the stale run lock of '${w:-?}' (its launcher is gone)" >&2; return 0
      fi
      echo "drive-stage: the run lock $d is STALE — the launcher of '${w:-?}' (${op:-?} ${os:-?}) is gone, and its Codex may still be working. Run --wait for ${op:-its plan} ${os:-its stage} (it reattaches without sending anything and takes the lock over) or --peek; nothing clears a stale lock on its own — nothing launched" >&2; return 1 ;;
    *) echo "drive-stage: another run holds $d (live: '${w:-?}') — one writer per checkout; nothing launched" >&2; return 1 ;;
  esac
}

on_exit() {   # the EXIT trap: drop RUN_LOCK when this launcher owns it and the run is settled (a review's or a read's always)
  local p
  [ "$LOCK_RELEASE" -eq 1 ] && [ -n "$RUN_LOCK" ] && [ -d "$RUN_LOCK" ] || return 0
  p="$(kv_get "$RUN_LOCK/owner" pid 2>/dev/null)" || return 0
  [ "$p" = "$$" ] || return 0
  rm -f "$RUN_LOCK/owner"; rmdir "$RUN_LOCK" 2>/dev/null || true
}

sweep_read_locks() {   # $1 root, $2 dir → removes STALE review/read locks (.run-lock-<name>): they guard nothing once their launcher is gone
  local l st
  for l in "$1/$2"/.run-lock-*; do
    [ -d "$l" ] || continue
    st="$(lock_state "$l")" || continue
    [ "$st" = stale ] || continue
    rm -f "$l/owner"; rmdir "$l" 2>/dev/null && echo "drive-stage: removed a stale review lock ${l##*/} (its launcher is gone; a review writes no code)" >&2 || true
  done
}

# The binding — tmp/PLAN-NN/NN.X-binding (tmp/bounded/<slug>-binding): which Codex session is this Stage's, and which message was
# sent last. Written before every send (the rollout's length and HEAD at that moment), rewritten when the message settles:
#   mode=headless|pane  session=<id>  rollout=<Codex's record, absolute>  copy=<its copy beside the run log>  pane= tab= agent=
#   launched=<UTC>  attempt=<N>  tag=[planner NN.X-cN]  lines=<the record's line count before the send>  head=<full sha before>
#   sent=<UTC>  sent_s=<epoch>  state=sent|settled|uncertain  log=<the send's log>
# A message is DONE only when a task_complete with the turn id of the first UserMessage after `lines` whose whole text (its blocks
# joined) OPENS with its `tag` — a tag quoted in a later block of a human's message never matches —
# follows it in the record (turn_state) — an earlier turn's mark, a turn the human typed, or the Stage's first commit never count.
B_KEYS="mode session rollout copy pane tab agent launched attempt tag lines head sent sent_s state log rhead"   # rhead: the records HEAD before the send (split-repo mode)
bind_read() {   # $1 binding (absolute) → sets B_<key> for every key ("" when absent); 2 when it cannot be read. A <binding>.new (a pane
  # launch between its agent start and its binding write — live, or killed there) is READ in its place, never renamed: it names the newer
  # session, and only bind_promote moves it, under the run lock (--wait, --abandon) — a read (--peek, a dry-run) changes no file
  local k v f="$1"
  for k in $B_KEYS; do eval "B_$k=''"; done
  [ ! -e "$1.new" ] || f="$1.new"
  [ -e "$f" ] || return 0
  [ -r "$f" ] || { echo "drive-stage: cannot read the binding $f" >&2; return 2; }
  while IFS='=' read -r k v; do case " $B_KEYS " in *" $k "*) eval "B_$k=\$v" ;; esac; done < "$f"
}
bind_promote() {   # $1 binding → a leftover <binding>.new becomes the binding; called only while this launcher holds the run lock it took
  # (so the pane launcher that wrote it is gone); 2 on a failure
  [ -e "$1.new" ] || return 0
  mv -f "$1.new" "$1" || { echo "drive-stage: cannot promote $1.new" >&2; return 2; }
  echo "drive-stage: promoted $1.new — a pane launch ended before recording its binding" >&2
}
bind_write() {   # $1 path → B_* written atomically (tmp + mv); 2 on a failure
  local k v
  { for k in $B_KEYS; do eval "v=\${B_$k}"; printf '%s=%s\n' "$k" "$v"; done; } > "$1.tmp.$$" && mv -f "$1.tmp.$$" "$1" \
    || { rm -f "$1.tmp.$$"; echo "drive-stage: cannot write the binding $1" >&2; return 2; }
}

log_session() {   # $1 log (absolute) → the first `session id: <id>` line's id (codex's header, or the pane launcher's own line); "" when none; 2 when unreadable
  local out rc=0
  [ -r "$1" ] || { echo "drive-stage: cannot read $1" >&2; return 2; }
  out="$(sed -n '/^session id: /{s///p;q;}' "$1")" || rc=$?
  [ "$rc" -eq 0 ] || { echo "drive-stage: sed failed reading $1 (exit $rc)" >&2; return 2; }
  printf '%s\n' "$out"
}

find_rollout() {   # $1 session id → prints its record's path; 1 when there is none; 3 when there is more than one (never guessed); 2 when find fails
  local id="$1" out rc=0
  case "$id" in ''|*[!A-Za-z0-9-]*) return 1 ;; esac
  [ -d "$CODEX_SESSIONS" ] || return 1
  out="$(find "$CODEX_SESSIONS" -type f -name "rollout-*-$id.jsonl")" || rc=$?
  [ "$rc" -eq 0 ] || { echo "drive-stage: find failed under $CODEX_SESSIONS (exit $rc)" >&2; return 2; }
  [ -n "$out" ] || return 1
  case "$out" in *$'\n'*) return 3 ;; esac
  printf '%s\n' "$out"
}

line_count() {   # $1 file → its complete lines (a half-written last line is not counted — it is read on a later poll); 2 when wc fails
  local n rc=0
  n="$(wc -l < "$1")" || rc=$?
  [ "$rc" -eq 0 ] || { echo "drive-stage: wc -l failed on $1 (exit $rc)" >&2; return 2; }
  printf '%s\n' "$(( n + 0 ))"
}

copy_name() {   # $1 a build run's log → its session record's copy beside it: NN.X-run.log → NN.X-rollout.jsonl, NN.X-run-r2.log → NN.X-rollout-r2.jsonl
  local log="$1" pre post
  pre="${log%run*}"; post="${log##*run}"
  printf '%srollout%s.jsonl\n' "$pre" "${post%.log}"
}

copy_rollout() {   # $1 root, $2 record (absolute), $3 copy (repo-relative) → copied with mode 600 (a full transcript: on disk only, never tracked — the tidy archives it); 2 on a failure
  local t="$1/$3.tmp.$$"
  ( umask 077 && cp "$2" "$t" ) && chmod 600 "$t" && mv -f "$t" "$1/$3" || { rm -f "$t"; echo "drive-stage: copying the session record $2 to $3 failed" >&2; return 2; }
}

turn_state() {   # $1 record (absolute), $2 lines before the send, $3 tag → complete <turn> | aborted <turn> | running <turn> | pending; 2 when unreadable
  local f="$1" from="$2" tag="$3" out rc=0 t="" k id
  [ -r "$f" ] || { echo "drive-stage: cannot read the session record $f" >&2; return 2; }
  out="$(jq -nrR --argjson from "${from:-0}" --arg tag "$tag" '
    inputs | select(input_line_number > $from) | (fromjson? // empty) | select(.type == "event_msg") | .payload
    | if .type == "item_completed" and (.item.type // "") == "UserMessage" and ([.item.content[]? | (.text? // "")] | join("") | startswith($tag)) then "U \(.turn_id // "")"
      elif .type == "task_complete" then "C \(.turn_id // "")"
      elif .type == "turn_aborted" then "A \(.turn_id // "")"
      else empty end' "$f" 2>&1)" || rc=$?   # fromjson? skips a half-written last line: it is re-read, whole, on the next poll
  [ "$rc" -eq 0 ] || { echo "drive-stage: jq failed reading $f (exit $rc): $out" >&2; return 2; }
  while IFS=' ' read -r k id; do
    [ -n "$k" ] || continue
    if [ -z "$t" ]; then [ "$k" = U ] && [ -n "$id" ] && t="$id"; continue; fi
    [ "$id" = "$t" ] || continue
    case "$k" in C) echo "complete $t"; return 0 ;; A) echo "aborted $t"; return 0 ;; esac
  done <<< "$out"
  if [ -n "$t" ]; then echo "running $t"; else echo pending; fi
}

commit_since() {   # $1 root, $2 the full sha recorded before the send → the short HEAD when a commit landed since; none when HEAD has not moved;
  # moved when HEAD no longer descends from it (a reset or a rebase — the Planner looks); 2 when git fails
  local h arc=0 s
  h="$(git -C "$1" rev-parse HEAD)" || { echo "drive-stage: git rev-parse HEAD failed (exit $?)" >&2; return 2; }
  [ "$h" != "$2" ] || { echo none; return 0; }
  git -C "$1" merge-base --is-ancestor "$2" "$h" || arc=$?
  case "$arc" in
    0) s="$(git -C "$1" rev-parse --short "$h")" || { echo "drive-stage: git rev-parse --short failed (exit $?)" >&2; return 2; }; echo "$s" ;;
    1) echo moved ;;
    *) echo "drive-stage: git merge-base --is-ancestor $2 HEAD failed (exit $arc)" >&2; return 2 ;;
  esac
}

footprint() {   # $1 root, $2 the short pre-run HEAD, $3 log, $4 codex's status → prints "<short HEAD> <changed paths>"; 2 (the transcript named) when a producer fails
  local root="$1" before="$2" log="$3" rc="$4" head diffed untracked sorted changed trc
  head="$(git -C "$root" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse HEAD failed after the run (exit $?) — codex exit=$rc, transcript at $log" >&2; return 2; }
  diffed="$(git -C "$root" diff --name-only "$before")" || { echo "drive-stage: git diff --name-only $before failed after the run (exit $?) — codex exit=$rc, transcript at $log" >&2; return 2; }
  untracked="$(git -C "$root" ls-files --others --exclude-standard)" || { echo "drive-stage: git ls-files --others failed after the run (exit $?) — codex exit=$rc, transcript at $log" >&2; return 2; }
  trc=0; sorted="$(printf '%s\n%s\n' "$diffed" "$untracked" | sort -u)" || trc=$?   # sort on its own first: in one pipeline its failure would hide behind grep -c's status-1 "no lines"
  [ "$trc" -eq 0 ] || { echo "drive-stage: sort -u failed (exit $trc) counting the changed paths after the run — codex exit=$rc, transcript at $log" >&2; return 2; }
  trc=0; changed="$(printf '%s\n' "$sorted" | grep -c .)" || trc=$?   # three-way: 0 lines counted, 1 no lines (grep printed 0), anything else is grep failing
  case "$trc" in 0|1) ;; *) echo "drive-stage: grep -c failed (exit $trc) counting the changed paths after the run — codex exit=$rc, transcript at $log" >&2; return 2 ;; esac
  printf '%s %s\n' "$head" "$changed"
}

settle_record() {   # $1 root, $2 log (repo-relative) → after a run: B_session from the binding or the log, B_rollout found, the copy refreshed.
  # Prints nothing; sets R_SESSION / R_COPY for the result line (`none` when Codex never reached its header, or its record is not found).
  # 2 when a producer fails (the transcript named); an ambiguous record (two files for one id) is reported, never guessed
  local root="$1" log="$2" sid ro frc=0
  R_SESSION=none; R_COPY=none
  sid="$B_session"; [ -n "$sid" ] || { sid="$(log_session "$root/$log")" || return 2; }
  [ -n "$sid" ] || return 0
  B_session="$sid"; R_SESSION="$sid"
  ro="$(find_rollout "$sid")" || frc=$?
  case "$frc" in
    0) B_rollout="$ro" ;;
    1) echo "drive-stage: no session record for $sid under $CODEX_SESSIONS — the copy is skipped" >&2; return 0 ;;
    3) echo "drive-stage: more than one session record names $sid under $CODEX_SESSIONS — none copied (never guessed)" >&2; return 0 ;;
    *) return 2 ;;
  esac
  [ -n "$B_copy" ] || B_copy="$(copy_name "$log")"
  copy_rollout "$root" "$B_rollout" "$B_copy" || return 2
  R_COPY="$B_copy"
}

name_part() {   # $1 text → lowercased, anything outside [a-z0-9-] turned into -; 2 when a step fails or leaves nothing. Each tr is captured and
  # checked on its own: in a pipe (no pipefail) the lowercase step's failure was lost and its unlowered output named the agent
  local a b
  a="$(tr 'A-Z' 'a-z' <<< "$1")" || { echo "drive-stage: tr failed lowercasing '$1' for the pane agent's name — nothing created" >&2; return 2; }
  b="$(tr -c 'a-z0-9\n-' '-' <<< "$a")" || { echo "drive-stage: tr failed cleaning '$1' for the pane agent's name — nothing created" >&2; return 2; }
  [ -n "$b" ] || { echo "drive-stage: '$1' leaves nothing for the pane agent's name — nothing created" >&2; return 2; }
  printf '%s\n' "$b"
}

project_name() {   # the pane agent's name prefix: $PROJECT, else the MAIN checkout's folder through name_part (a stream's worktree is <project>-PLAN-NN)
  local root="$1" m
  [ -z "$PROJECT" ] || { printf '%s\n' "$PROJECT"; return 0; }
  m="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)" || { echo "drive-stage: git rev-parse --git-common-dir failed in $root" >&2; return 2; }
  m="${m%/.git}"; m="${m##*/}"
  name_part "$m"
}

bind_clear() { local k; for k in $B_KEYS; do eval "B_$k=''"; done; }

fresh_ok() {   # $1 root, $2 plan, $3 stage, $4 resume (0/1) → 0 when a FRESH session may start for the Stage (B_* holds its binding):
  # never beside a message still in flight, and never a --resume while the Stage's own session is on record (one session per Stage);
  # 1 refused (the reason printed); 2 when the record's lookup fails
  local ro frc=0
  if [ -n "$B_tag" ] && [ "$B_state" != settled ]; then
    echo "drive-stage: $2 $3 — the last message $B_tag is '$B_state', not settled: a fresh session would run beside the one that may still be working. Run --wait (it reattaches and sends nothing) or --peek; --abandon only once you know it is done or dead — nothing launched" >&2; return 1
  fi
  [ "$4" -eq 1 ] && [ -n "$B_session$B_rollout" ] || return 0
  ro="$B_rollout"
  if [ -z "$ro" ] || [ ! -f "$ro" ]; then ro="$(find_rollout "$B_session")" || frc=$?; fi
  case "$frc" in
    0|3) echo "drive-stage: $2 $3 — the Stage's session ${B_session:-?} is on record (${ro:-more than one file}): send the next message into it with --continue <prompt-file>; --resume is only for a Stage whose session record is gone — nothing launched" >&2; return 1 ;;
    1) return 0 ;;
    *) return 2 ;;
  esac
}

records_before() {   # split-repo mode, before a send: sets the CALLER's rbfull (the records HEAD, full) and rhdr (the run-log header's
  # ` records=<short>`) — bash's dynamic scope; 1 (nothing launched) when git fails in the records repo
  local rs
  rbfull="$(git -C "$REC" rev-parse HEAD)" || { echo "drive-stage: git rev-parse HEAD failed in the records repo $REC_REL (exit $?) — nothing launched" >&2; return 1; }
  rs="$(git -C "$REC" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse --short HEAD failed in the records repo $REC_REL (exit $?) — nothing launched" >&2; return 1; }
  rhdr=" records=$rs"
}

drive() {   # $1 root, $2 plan, $3 stage (`fix` for --fix), $4 heavy, $5 resume, $6 resume_prompt (--fix: its prompt file), $7 again, $8 dry, $9 fix(0/1)
  local root="$1" plan="$2" stage="$3" heavy="$4" resume="$5" rp="$6" again="$7" dry="$8" fix="${9:-0}"
  local tb secs paths prompt log before bfull rc started prompt_text grants g dir bindf="" attempt=1 tag catpart sq="'" note rbfull="" rhdr=""
  tb="$(timeout_bin)" || { echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 1; }
  secs="$TIMEOUT_NORMAL"; [ "$heavy" -eq 1 ] && secs="$TIMEOUT_HEAVY"
  paths="$(resolve_paths "$root" "$plan" "$stage" "$resume" "$rp" "$again" "$fix")" || return 1
  prompt="${paths%	*}"; log="${paths#*	}"
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"
  bind_clear
  bindf="$root/$dir/$stage-binding"; bind_read "$bindf" || return 2   # the Stage's binding (a fix batch's: fix-binding — never continued, but recoverable by --wait/--abandon)
  attempt=$(( ${B_attempt:-0} + 1 ))
  tag="[planner $stage-c$attempt]"
  fresh_ok "$root" "$plan" "$stage" "$resume" || return $?
  local extra=""   # the dry-run's printed form of the same grants: what it prints is exactly what the real launch passes
  set --
  if [ "$CODEX_SANDBOX" = workspace-write ]; then   # git needs the write; the module's contract — as real argv, never a re-split string. The ONLY grants are the worktree's git dirs (git_write_dirs): the review is never run from inside the stage, so a reviewer's needs (a state dir, the network) are never added here
    grants="$(all_write_dirs "$root")" || return 1   # resolved for the dry-run too: it must print the real grant, and a git failure here is a refusal before anything is written
    while IFS= read -r g; do [ -n "$g" ] || continue; set -- "$@" --add-dir "$g"; extra="$extra --add-dir $(shq "$g")"; done <<< "$grants"
  fi
  note="$(split_note build "$plan")"   # split-repo mode: one line after the tag; empty in one repo, and the message is then exactly as before
  if [ "$dry" -eq 1 ]; then   # ONE line, the command — every argument single-quoted: it pastes back to the same argv (the tag line, then the prompt file); the trailing comment says what the launcher does before it
    if [ -n "$note" ]; then catpart="\"\$(printf ${sq}%s\\n${sq} $(shq "$tag") $(shq "$note"); cat $(shq "$prompt"))\""
    else catpart="\"\$(printf ${sq}%s\\n${sq} $(shq "$tag"); cat $(shq "$prompt"))\""; fi
    printf 'env -u RATCHET_ALLOW_PUSH%s %s %s codex exec -m %s -c %s -s %s%s -C %s %s < /dev/null >> %s 2>&1   # the launcher takes the run lock, writes the binding and the run-log header (line 1 of the log) first, then runs this\n' \
      "${SCRATCH_TMP:+ TMPDIR=$(shq "$SCRATCH_TMP")}" "$tb" "$secs" "$(shq "$CODEX_MODEL")" "$(shq "model_reasoning_effort=$CODEX_REASONING")" "$(shq "$CODEX_SANDBOX")" "$extra" "$(shq "$root")" "$catpart" "$(shq "$log")"
    return 0
  fi
  unfilled "a build launch" "CODEX_MODEL=$CODEX_MODEL" "CODEX_REASONING=$CODEX_REASONING" "CODEX_SANDBOX=$CODEX_SANDBOX" || return 1
  [ "$no_preflight" -eq 1 ] || preflight "$root" "$CODEX_MODEL" "$CODEX_REASONING" || return 1
  prompt_text="$(cat "$(prompt_path "$root" "$prompt")")" || { echo "drive-stage: cannot read the prompt $prompt (cat exit $?) — nothing launched" >&2; return 1; }   # read and checked BEFORE the header or the launch: an unreadable prompt once launched an Executor with an empty one
  [ -n "$prompt_text" ] || { echo "drive-stage: the prompt $prompt is empty — nothing launched" >&2; return 1; }
  mkdir -p "$root/$(dirname "$log")"   # only a --resume <file> from elsewhere can leave the log dir missing
  lock_take "$root/tmp/.run-lock" "$plan $stage build" 0 "$plan" "$stage" || return $?   # one writer per checkout; released on every exit before the send
  bind_clear; bind_read "$bindf" || return 2; fresh_ok "$root" "$plan" "$stage" "$resume" || return $?   # re-read under the lock: nothing moved since the check above
  sweep_read_locks "$root" "$dir"
  before="$(git -C "$root" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse HEAD failed in $root (exit $?) — nothing launched" >&2; return 1; }
  bfull="$(git -C "$root" rev-parse HEAD)" || { echo "drive-stage: git rev-parse HEAD failed in $root (exit $?) — nothing launched" >&2; return 1; }
  if [ -n "$REC" ]; then records_before || return 1; fi
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# drive-stage: before=%s sandbox=%s started=%s%s\n' "$before" "$CODEX_SANDBOX" "$started" "$rhdr" > "$root/$log"   # line 1: what --review reads its base from
  if [ -n "$bindf" ]; then   # recorded BEFORE the send: a new session (the record's length 0), the HEAD the message starts from
    bind_clear; B_mode=headless; B_session=""; B_rollout=""; B_copy=""; B_pane=""; B_tab=""; B_agent=""; B_launched="$started"; B_attempt="$attempt"; B_tag="$tag"
    B_lines=0; B_head="$bfull"; B_rhead="$rbfull"; B_sent="$started"; B_sent_s="$(date +%s)"; B_state=sent; B_log="$log"
    bind_write "$bindf" || return 1
  fi
  LOCK_RELEASE=0   # from the send until the message settles, an exit keeps the lock: a launcher that dies here leaves it stale, never free
  unset RATCHET_ALLOW_PUSH   # the Never list's push key never reaches an Executor, exported or not (the pre-push hook reads it; the human sets it on the push)
  set +e
  "$tb" "$secs" codex exec -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING" -s "$CODEX_SANDBOX" "$@" \
    -C "$root" "$tag"$'\n'"${note:+$note$'\n'}$prompt_text" < /dev/null >> "$root/$log" 2>&1
  rc=$?
  set -e
  B_state=settled   # headless: the process is gone, so no turn of this message is live
  if [ -n "$bindf" ]; then bind_write "$bindf" || { echo "drive-stage: codex exit=$rc, transcript at $log — the binding could not be settled; the run lock stays (--abandon settles it)" >&2; return 2; }; fi
  LOCK_RELEASE=1
  # the footprint and the session: each producer captured and checked on its own — a failure after the run is exit 2 with the transcript named, never a result line with a wrong count
  settle_record "$root" "$log" || { echo "drive-stage: reading the session after the run failed — codex exit=$rc, transcript at $log" >&2; return 2; }
  if [ -n "$bindf" ]; then bind_write "$bindf" || { echo "drive-stage: codex exit=$rc, transcript at $log — the binding could not record the session" >&2; return 2; }; fi
  result_line "$root" "$plan" "$stage" "$rc" "$log" "$before" "" || return 2
  return "$rc"
}

review_base() {   # $1 root, $2 run log (repo-relative), $3 --base value or "" → prints the base's full sha, or refuses naming both remedies
  local root="$1" runlog="$2" base="$3" hdr full grc=0
  if [ -z "$base" ]; then
    [ -f "$root/$runlog" ] || { echo "drive-stage: review — no run log at $runlog: run the stage first, or pass --base <sha>" >&2; return 1; }
    hdr="$(head -n 1 "$root/$runlog")" || { echo "drive-stage: review — cannot read $runlog" >&2; return 1; }
    case "$hdr" in '# drive-stage: before='*) ;; *) echo "drive-stage: review — $runlog has no drive-stage header on line 1 (a launcher older than this one wrote it?): run the stage first, or pass --base <sha>" >&2; return 1 ;; esac
    base="${hdr#\# drive-stage: before=}"; base="${base%% *}"   # the FIRST token after the prefix, whatever follows it: this launcher's header (`sandbox= started=`) and an older one's (`sandbox= layer1=<nested|external> started=`) read the same way
    [ -n "$base" ] || { echo "drive-stage: review — the header in $runlog names no before= sha: run the stage first, or pass --base <sha>" >&2; return 1; }
  fi
  full="$(git -C "$root" rev-parse --verify --quiet "$base^{commit}" 2>&1)" || grc=$?   # --verify --quiet: 1 = not a commit here, anything else = git itself failed (128 outside a repo, …)
  case "$grc" in
    0) printf '%s\n' "$full" ;;
    1) echo "drive-stage: review — base '$base' is not a commit in this repo (git rev-parse --verify exit 1)" >&2; return 1 ;;
    *) echo "drive-stage: review — git rev-parse --verify $base failed (exit $grc): ${full:-<no output>}" >&2; return 1 ;;
  esac
}

review_head() {   # $1 root, $2 --head value or "" → prints the full sha of the range's END — the current HEAD unless --head names a commit — or refuses; validated the way the base is
  local root="$1" h="$2" full grc=0
  if [ -z "$h" ]; then
    full="$(git -C "$root" rev-parse --verify --quiet 'HEAD^{commit}' 2>&1)" || grc=$?
    case "$grc" in
      0) printf '%s\n' "$full" ;;
      1) echo "drive-stage: review — no HEAD commit in $root (unborn branch? git rev-parse --verify exit 1)" >&2; return 1 ;;
      *) echo "drive-stage: review — git rev-parse --verify HEAD failed (exit $grc): ${full:-<no output>}" >&2; return 1 ;;
    esac
    return 0
  fi
  full="$(git -C "$root" rev-parse --verify --quiet "$h^{commit}" 2>&1)" || grc=$?   # --verify --quiet: 1 = not a commit here, anything else = git itself failed
  case "$grc" in
    0) printf '%s\n' "$full" ;;
    1) echo "drive-stage: review — head '$h' is not a commit in this repo (git rev-parse --verify exit 1)" >&2; return 1 ;;
    *) echo "drive-stage: review — git rev-parse --verify $h failed (exit $grc): ${full:-<no output>}" >&2; return 1 ;;
  esac
}

review_records_note() {   # $1 root, $2 run log (repo-relative) → the sentence a review's prompt ends with in split-repo mode: the records repo, and
  # the records range since the Stage began (to the records HEAD, so later Stages' records may be in it — the sentence says so and names
  # the Stage's own commits by their subject) when the run log's header carries ` records=<sha>` and the records HEAD has moved past it. 1 (nothing launched,
  # named) when that sha isn't a commit in the records repo or git fails — the range is never guessed
  local root="$1" runlog="$2" hdr rb rbf rhf grc=0 range=""
  if [ -f "$root/$runlog" ]; then
    hdr="$(head -n 1 "$root/$runlog")" || { echo "drive-stage: review — cannot read $runlog" >&2; return 1; }
    case "$hdr" in
      '# drive-stage: before='*' records='*)
        rb="${hdr##* records=}"; rb="${rb%% *}"
        rbf="$(git -C "$REC" rev-parse --verify --quiet "$rb^{commit}" 2>&1)" || grc=$?
        case "$grc" in
          0) ;;
          1) echo "drive-stage: review — the run log's records=$rb is not a commit in the records repo $REC_REL — nothing launched" >&2; return 1 ;;
          *) echo "drive-stage: review — git rev-parse --verify $rb failed in the records repo $REC_REL (exit $grc) — nothing launched" >&2; return 1 ;;
        esac
        rhf="$(git -C "$REC" rev-parse HEAD)" || { echo "drive-stage: review — git rev-parse HEAD failed in the records repo $REC_REL (exit $?) — nothing launched" >&2; return 1; }
        [ "$rbf" = "$rhf" ] || range=" The records written since this Stage began are the range $rbf..$rhf there: run 'git -C $REC_REL diff $rbf..$rhf'. It runs to the records HEAD, so it may include later Stages' records: this Stage's are the commits under its own subject ('git -C $REC_REL log --oneline $rbf..$rhf')." ;;
    esac
  fi
  printf ' Split-repo mode (modules/split-repo.md): the records (PLAN.md, the LOG, the plan file and its Verify: blocks, and the evidence file holding its proof table) are the separate git repo at %s/, and each code commit'"'"'s records commit there carries the same subject.%s\n' "$REC_REL" "$range"
}

review() {   # $1 root, $2 plan, $3 stage, $4 base (or ""), $5 again, $6 dry, $7 head (or "" = the current HEAD) — the review of a COMMITTED range as its own invocation, by the model that did not write the code (nothing committed since the base is a refusal — a review never reads an uncommitted tree): `codex exec -C <root> review "<prompt>"`, read-only by the subcommand's design
  local root="$1" plan="$2" stage="$3" base="$4" again="$5" dry="$6" rhead="${7:-}"
  local tb secs dir runlog l1 v n head sbase shead scope scopetext what prompt rc arc=0 aroot recnote=""
  tb="$(timeout_bin)" || { echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 1; }
  secs="$TIMEOUT_NORMAL"
  case "$REVIEW_MANDATE" in *EDIT-ME*) echo "drive-stage: edit the invocation block first (REVIEW_MANDATE is still EDIT-ME: copy templates/codex-reviewer.toml to .codex/agents/<project>-reviewer.toml and name it there)" >&2; return 1 ;; esac
  [ -f "$root/$REVIEW_MANDATE" ] || { echo "drive-stage: review mandate missing: $REVIEW_MANDATE (REVIEW_MANDATE is repo-relative; the file is not there)" >&2; return 1; }
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"
  runlog="$dir/$stage-run.log"; l1="$dir/$stage-L1.log"   # l1 = the review's log; the -L1 file name is kept from earlier kits so a project's cites still resolve
  base="$(review_base "$root" "$runlog" "$base")" || return 1
  head="$(review_head "$root" "$rhead")" || return 1   # the END of the range: the current HEAD, or --head — a Stage read after later Stages have landed ends at the Stage's own last commit
  # the reviewer gets the range as the two validated FULL shas; the short forms are display only, each captured and checked on its own (a failed shortening is a refusal, never an empty end of a range)
  sbase="$(git -C "$root" rev-parse --short "$base")" || { echo "drive-stage: review — git rev-parse --short $base failed (exit $?) — nothing launched" >&2; return 1; }
  if [ "$head" = "$base" ]; then   # an empty range: refused before the dry-run, the preflight, or a log — since 0.18 every review reads a COMMITTED range (0.17's uncommitted-spike read is retired)
    echo "drive-stage: review — base equals head ($sbase): the range is empty and a review reads a committed range — commit the Stage first, or pass --base <sha> for an earlier base (a --head must be a later commit than the base)" >&2; return 1
  fi
  shead="$(git -C "$root" rev-parse --short "$head")" || { echo "drive-stage: review — git rev-parse --short $head failed (exit $?) — nothing launched" >&2; return 1; }
  git -C "$root" merge-base --is-ancestor "$base" "$head" || arc=$?   # three-way: 0 an ancestor (equal was refused above, so a STRICT one), 1 not an ancestor, anything else git itself failed — not a verdict on the range
  case "$arc" in
    0) ;;
    1) echo "drive-stage: review — base $sbase is not an ancestor of head $shead: 'git diff $sbase..$shead' would not be the Stage's own change (a rebase moved the branch, or the two are on different lines) — pass --base <sha> and --head <sha> from this branch's history" >&2; return 1 ;;
    *) echo "drive-stage: review — git merge-base --is-ancestor $sbase $shead failed (exit $arc) — nothing launched" >&2; return 1 ;;
  esac
  # the prompt must TELL the reviewer to read the diff: `codex exec review` takes a custom [PROMPT] or a diff selector (--base/--commit/--uncommitted), never both (the module's probed contract), so naming the range alone left it unread
  scope="$sbase..$shead"; scopetext="the committed range $base..$head — run 'git diff $base..$head' (and 'git log --oneline $base..$head') and review exactly that"
  v="${l1%.log}-verdict.md"   # the final message, written by -o beside the transcript: what the close tracks
  if [ -e "$root/$l1" ] || [ -e "$root/$v" ]; then
    if [ "$again" -eq 1 ]; then n=2; while [ -e "$root/${l1%.log}-r$n.log" ] || [ -e "$root/${l1%.log}-r$n-verdict.md" ]; do n=$((n+1)); done; l1="${l1%.log}-r$n.log"; v="${l1%.log}-verdict.md"
    else echo "drive-stage: review log or verdict already exists: $l1 (pass --again for a -rN log)" >&2; return 1; fi
  fi
  aroot="$(cd "$root" && pwd -P)" || { echo "drive-stage: review — root '$root' cannot be entered — nothing launched" >&2; return 1; }   # -o gets an absolute path: never resolved against a directory codex chose
  what="$plan Stage $stage"; [ "$plan" = bounded ] && what="bounded task $stage"
  if [ -n "$REC" ]; then recnote="$(review_records_note "$root" "$runlog")" || return 1; fi   # split-repo mode: where the plan lives, and the Stage's records range when the run log recorded it
  prompt="Review under the mandate in $REVIEW_MANDATE — read that file first; its developer_instructions govern; you are read-only and change nothing. Scope: ONLY $scopetext — $what. Re-prove the Stage's Verify: blocks where the plan has them, as the mandate says (the playbook's prompts/review-stage.md — read-only: audit the named mutation). Return the verdict as that prompt specifies: PASS or ISSUES (n findings), blocking / Observations, file, line, why.$recnote"
  if [ "$dry" -eq 1 ]; then   # every argument single-quoted: the line pastes back to the same argv
    printf '%s %s codex exec -C %s review -m %s -c %s -o %s %s < /dev/null > %s 2>&1\n' "$tb" "$secs" "$(shq "$root")" "$(shq "$CODEX_REVIEW_MODEL")" "$(shq "model_reasoning_effort=$CODEX_REVIEW_REASONING")" "$(shq "$aroot/$v")" "$(shq "$prompt")" "$(shq "$l1")"
    return 0
  fi
  unfilled "a review" "CODEX_REVIEW_MODEL=$CODEX_REVIEW_MODEL" "CODEX_REVIEW_REASONING=$CODEX_REVIEW_REASONING" || return 1
  [ "$no_preflight" -eq 1 ] || preflight "$root" "$CODEX_REVIEW_MODEL" "$CODEX_REVIEW_REASONING" || return 1
  mkdir -p "$root/$dir" || { echo "drive-stage: review — mkdir $dir failed — nothing launched" >&2; return 1; }
  sweep_read_locks "$root" "$dir"
  lock_take "$root/$dir/.run-lock-$(basename "$l1" .log)" "$what review" || return $?   # the watchman reads a live one as "waiting on Codex"; a review writes no code, so its exit always drops it
  set +e
  "$tb" "$secs" codex exec -C "$root" review -m "$CODEX_REVIEW_MODEL" -c "model_reasoning_effort=$CODEX_REVIEW_REASONING" -o "$aroot/$v" "$prompt" < /dev/null > "$root/$l1" 2>&1   # -C is `exec`'s and goes before the subcommand (review rejects it); the pin and -o are the subcommand's own options; never -s or --add-dir here
  rc=$?
  set -e
  printf '%s %s review exit=%s log=%s verdict=%s scope=%s\n' "$plan" "$stage" "$rc" "$l1" "$v" "$scope"
  return "$rc"
}

read_plan() {   # $1 root, $2 plan, $3 prompt file (repo-relative or absolute), $4 again, $5 dry — one read-only read under the REVIEW pin:
  # the premise read on the draft, the round's plan read. The prompt file's text is the prompt (it names its own mandate); the log and
  # the verdict are named from the prompt's basename less `.md` and a trailing `-prompt`, so the tidy files the verdict under reviews/
  local root="$1" plan="$2" pf="$3" again="$4" dry="$5" tb secs dir name log v n aroot head hfull started ptext rc note sq="'" rfull="" rshort="" rhdr="" rres=""
  tb="$(timeout_bin)" || { echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 1; }
  secs="$TIMEOUT_NORMAL"; dir="tmp/$plan"
  case "$pf" in /*) ;; *) pf="$root/$pf" ;; esac
  [ -f "$pf" ] || { echo "drive-stage: read — prompt file missing: $pf" >&2; return 1; }
  name="${pf##*/}"; name="${name%.md}"; name="${name%-prompt}"
  case "$name" in ""|*[!A-Za-z0-9._-]*) echo "drive-stage: read — the prompt's name '$name' must be [A-Za-z0-9._-]+ (it names the log and the verdict)" >&2; return 1 ;; esac
  log="$dir/$name-read.log"; v="$dir/$name-read-verdict.md"
  if [ -e "$root/$log" ] || [ -e "$root/$v" ]; then
    if [ "$again" -eq 1 ]; then n=2; while [ -e "$root/$dir/$name-read-r$n.log" ] || [ -e "$root/$dir/$name-read-r$n-verdict.md" ]; do n=$((n+1)); done; log="$dir/$name-read-r$n.log"; v="$dir/$name-read-r$n-verdict.md"
    else echo "drive-stage: read log or verdict already exists: $log (pass --again for a -rN log)" >&2; return 1; fi
  fi
  aroot="$(cd "$root" && pwd -P)" || { echo "drive-stage: read — root '$root' cannot be entered — nothing launched" >&2; return 1; }
  note="$(split_note read)"   # split-repo mode: one line before the prompt's text; one repo: the prompt exactly as before
  if [ "$dry" -eq 1 ]; then
    if [ -n "$note" ]; then
      printf '%s %s codex exec -m %s -c %s -s read-only -C %s -o %s "$(printf %s %s; cat %s)" < /dev/null >> %s 2>&1   # the launcher writes the read-log header (line 1 of the log) first, then runs this\n' "$tb" "$secs" "$(shq "$CODEX_REVIEW_MODEL")" "$(shq "model_reasoning_effort=$CODEX_REVIEW_REASONING")" "$(shq "$root")" "$(shq "$aroot/$v")" "${sq}%s\\n${sq}" "$(shq "$note")" "$(shq "$pf")" "$(shq "$log")"
    else
      printf '%s %s codex exec -m %s -c %s -s read-only -C %s -o %s "$(cat %s)" < /dev/null >> %s 2>&1   # the launcher writes the read-log header (line 1 of the log) first, then runs this\n' "$tb" "$secs" "$(shq "$CODEX_REVIEW_MODEL")" "$(shq "model_reasoning_effort=$CODEX_REVIEW_REASONING")" "$(shq "$root")" "$(shq "$aroot/$v")" "$(shq "$pf")" "$(shq "$log")"
    fi
    return 0
  fi
  unfilled "a read" "CODEX_REVIEW_MODEL=$CODEX_REVIEW_MODEL" "CODEX_REVIEW_REASONING=$CODEX_REVIEW_REASONING" || return 1
  [ "$no_preflight" -eq 1 ] || preflight "$root" "$CODEX_REVIEW_MODEL" "$CODEX_REVIEW_REASONING" || return 1
  ptext="$(cat "$pf")" || { echo "drive-stage: read — cannot read the prompt $pf (cat exit $?) — nothing launched" >&2; return 1; }
  [ -n "$ptext" ] || { echo "drive-stage: read — the prompt $pf is empty — nothing launched" >&2; return 1; }
  head="$(git -C "$root" rev-parse --short HEAD)" || { echo "drive-stage: read — git rev-parse HEAD failed (exit $?) — nothing launched" >&2; return 1; }
  hfull="$(git -C "$root" rev-parse HEAD)" || { echo "drive-stage: read — git rev-parse HEAD failed (exit $?) — nothing launched" >&2; return 1; }
  if [ -n "$REC" ]; then   # the records commit the read saw: the plan lives there
    rfull="$(git -C "$REC" rev-parse HEAD)" || { echo "drive-stage: read — git rev-parse HEAD failed in the records repo $REC_REL (exit $?) — nothing launched" >&2; return 1; }
    rshort="$(git -C "$REC" rev-parse --short HEAD)" || { echo "drive-stage: read — git rev-parse --short HEAD failed in the records repo $REC_REL (exit $?) — nothing launched" >&2; return 1; }
    rhdr=" records=$rfull"; rres=" records-head=$rshort"
  fi
  mkdir -p "$root/$dir" || { echo "drive-stage: read — mkdir $dir failed — nothing launched" >&2; return 1; }
  sweep_read_locks "$root" "$dir"
  lock_take "$root/$dir/.run-lock-$(basename "$log" .log)" "$plan read $name" || return $?
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || { echo "drive-stage: read — date failed (exit $?) — nothing launched" >&2; return 1; }
  printf '# drive-stage: read head=%s model=%s started=%s%s\n' "$hfull" "$CODEX_REVIEW_MODEL" "$started" "$rhdr" > "$root/$log" \
    || { echo "drive-stage: read — writing the header to $log failed — nothing launched" >&2; return 1; }   # line 1: the commit the read saw, and the pin it ran under
  set +e
  "$tb" "$secs" codex exec -m "$CODEX_REVIEW_MODEL" -c "model_reasoning_effort=$CODEX_REVIEW_REASONING" -s read-only -C "$root" -o "$aroot/$v" "${note:+$note$'\n'}$ptext" < /dev/null >> "$root/$log" 2>&1
  rc=$?
  set -e
  printf '%s read exit=%s log=%s verdict=%s head=%s%s\n' "$plan" "$rc" "$log" "$v" "$head" "$rres"
  return "$rc"
}

# ---- the session modes: --continue, --wait, --peek, --abandon, and the pane --------------------------------------------------------
ESC_WAIT="${DRIVE_STAGE_ESC_WAIT:-30}"   # seconds an Esc gets to show as the turn's end in the record
SETTLE_TAB_WAIT="${DRIVE_STAGE_SETTLE_TAB_WAIT:-15}"   # seconds a settled run's Codex gets to read idle in Herdr before its tab is left open for the next launch
H_OUT=""; H_CODE=""
hcall() {   # herdr <args…> under a timeout (HCALL_TIMEOUT, default 20 s): H_OUT = stdout, H_CODE = Herdr's JSON error code off stderr ("" on success, timeout on 124); returns herdr's status
  local tb ef rc=0
  tb="$(timeout_bin)" || { H_CODE=no_timeout; echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 2; }
  ef="$(mktemp "${TMPDIR:-/tmp}/drive-stage-herdr.XXXXXX")" || { H_CODE=mktemp; echo "drive-stage: mktemp failed" >&2; return 2; }
  H_OUT="$("$tb" "${HCALL_TIMEOUT:-20}" herdr "$@" 2> "$ef")" || rc=$?
  H_CODE=""
  if [ "$rc" -eq 124 ]; then H_CODE=timeout
  elif [ "$rc" -ne 0 ]; then H_CODE="$(jq -r '.error.code // empty' < "$ef" 2>/dev/null)" || H_CODE=""; [ -n "$H_CODE" ] || H_CODE="exit_$rc"; fi
  rm -f "$ef"
  return "$rc"
}

need_jq() { command -v jq >/dev/null 2>&1 || { echo "drive-stage: $1 reads Codex's session record with jq (macOS 15+ ships /usr/bin/jq) — not on PATH; nothing done" >&2; return 1; }; }

herdr_gate() {   # the gate of every Herdr action (a tab, an agent start, an Esc, a queued message into a pane): inside Herdr, its server running; any version
  local v
  [ "${HERDR_ENV:-}" = 1 ] || { echo "drive-stage: a pane runs inside Herdr only (HERDR_ENV=1) — nothing created" >&2; return 1; }
  command -v herdr >/dev/null 2>&1 || { echo "drive-stage: herdr is not on PATH — nothing created" >&2; return 1; }
  need_jq "a pane" || return 1
  hcall status --json || { echo "drive-stage: herdr status failed ($H_CODE) — nothing created" >&2; return 1; }
  v="$(printf '%s' "$H_OUT" | jq -r '.server.running // false')" || { echo "drive-stage: jq failed reading herdr status — nothing created" >&2; return 1; }
  [ "$v" = true ] && return 0
  echo "drive-stage: the Herdr server is not running (status: running=$v) — nothing created" >&2
  return 1
}

log_note() {   # $1 log (absolute), $2 text — the launcher's own lines in a pane run's log; 2 when the append fails (never silently lost)
  printf '# drive-stage: %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$1" || { echo "drive-stage: cannot append to $1" >&2; return 2; }
}

agent_bound() {   # the Stage's pane agent, looked up by its PANE id (stable, never reused; a name Herdr may drop — a start that timed out leaves the
  # agent unnamed, probed live) and checked against the binding: prints live | gone; 2 when Herdr cannot tell or the pane holds another session (never acted on)
  local k s
  if hcall agent get "$B_pane"; then
    k="$(printf '%s' "$H_OUT" | jq -r '.result.agent.agent // ""')" || return 2
    s="$(printf '%s' "$H_OUT" | jq -r '.result.agent.agent_session.value // ""')" || return 2
    [ "$k" = codex ] || { echo gone; return 0; }   # the pane is back at a shell, or holds something else: the Stage's Codex exited
    if [ -z "$s" ] || [ -z "$B_session" ] || [ "$s" = "$B_session" ]; then echo live; return 0; fi
    echo "drive-stage: pane $B_pane holds Codex session $s, not the bound $B_session — nothing sent" >&2; return 2
  fi
  case "$H_CODE" in agent_not_found|pane_not_found) echo gone; return 0 ;; esac
  echo "drive-stage: cannot tell whether pane $B_pane still holds the Stage's Codex (herdr: $H_CODE) — nothing sent" >&2; return 2
}

send_esc() {   # Esc to the bound agent, only when it is still the bound one; 0 sent, 1 not sent (gone or not ours)
  local st
  st="$(agent_bound)" || return 1
  [ "$st" = live ] || return 1
  hcall agent send-keys "$B_pane" esc || { echo "drive-stage: herdr agent send-keys esc failed ($H_CODE)" >&2; return 1; }
}

queue_msg() {   # $1 root, $2 log, $3 text (the tag line first) → `codex queue` into the Stage's live session; 0 queued, else the message is UNCERTAIN
  local out rc=0
  out="$(codex queue --thread "$B_session" --message "$3" < /dev/null 2>&1)" || rc=$?
  printf '%s\n' "$out" >> "$1/$2" || { echo "drive-stage: codex queue exit=$rc, and its reply could not be appended to $2: $out" >&2; return 1; }   # uncertain, never re-sent
  [ "$rc" -eq 0 ] || { echo "drive-stage: codex queue failed (exit $rc): $out" >&2; return 1; }
}

new_message() {   # $1 root, $2 tag → the binding's message fields for a send that starts now (the record's length and HEAD at this moment; in
  # split-repo mode the records HEAD too)
  B_tag="$2"; B_lines="$(line_count "$B_rollout")" || return 2
  B_head="$(git -C "$1" rev-parse HEAD)" || { echo "drive-stage: git rev-parse HEAD failed (exit $?)" >&2; return 2; }
  B_rhead=""; [ -z "$REC" ] || { B_rhead="$(git -C "$REC" rev-parse HEAD)" || { echo "drive-stage: git rev-parse HEAD failed in the records repo $REC_REL (exit $?)" >&2; return 2; }; }
  B_sent="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; B_sent_s="$(date +%s)"; B_state=sent
}

pane_wait() {   # $1 root, $2 log (repo-relative), $3 deadline (epoch), $4 1 = the time budget acts at the deadline, 0 = --wait (sends nothing)
  # → W_RC: 0 the message's turn completed; 130 it was aborted (an Esc — a human's); 124 the bound; 75 the message never reached the record within
  # PANE_DELIVERY. B_state: settled on a complete or an aborted turn, or once the budget has quit the Stage's Codex; else kept (sent / uncertain).
  # The bound (pane mode): Esc the running turn, then quit that Codex (Ctrl-C) — a message queued to an interrupted Codex is never delivered (probed
  # on 0.154.0: it waits in Codex's queue until the session's next turn starts), so the Planner's next word — "time's up: reach the stage-close
  # ritual and commit what is done" — goes through --continue, which resumes the session headless once its tab no longer holds Codex.
  local root="$1" log="$2" deadline="$3" budget="$4" ts now i
  while :; do
    ts="$(turn_state "$B_rollout" "$B_lines" "$B_tag")" || return 2
    case "$ts" in
      complete\ *) B_state=settled; W_RC=0; log_note "$root/$log" "complete: $B_tag (turn ${ts#* })" || return 2; return 0 ;;
      aborted\ *)  B_state=settled; W_RC=130; log_note "$root/$log" "aborted: $B_tag (turn ${ts#* })" || return 2; return 0 ;;
    esac
    now="$(date +%s)"
    if [ "$ts" = pending ] && [ $(( now - ${B_sent_s:-now} )) -ge "$PANE_DELIVERY" ]; then
      B_state=uncertain; W_RC=75; log_note "$root/$log" "unconfirmed: $B_tag never reached the session record in ${PANE_DELIVERY}s" || return 2; return 0
    fi
    if [ "$now" -ge "$deadline" ]; then
      W_RC=124
      [ "$budget" -eq 1 ] || return 0   # --wait sends nothing: the state stays as it was
      log_note "$root/$log" "the time budget: Esc, then quit the Stage's Codex" || return 2
      send_esc || true
      i=0; while [ "$i" -lt "$ESC_WAIT" ]; do ts="$(turn_state "$B_rollout" "$B_lines" "$B_tag")" || return 2; case "$ts" in complete\ *|aborted\ *) break ;; esac; sleep 1; i=$((i+1)); done
      if quit_codex; then B_state=settled; log_note "$root/$log" "quit: the tab holds a shell now; --continue resumes the session headless" || return 2
      else B_state=uncertain; log_note "$root/$log" "the Stage's Codex did not quit — unsettled" || return 2; fi
      return 0
    fi
    sleep "$POLL"
  done
}

quit_codex() {   # Ctrl-C to the Stage's pane until it no longer holds Codex (at an idle composer one Ctrl-C quits it — probed); 0 gone, 1 still there or unknown
  local i=0 st
  while [ "$i" -lt 3 ]; do
    st="$(agent_bound)" || return 1
    [ "$st" = live ] || return 0
    hcall agent send-keys "$B_pane" ctrl+c || true
    sleep 2; i=$((i+1))
  done
  st="$(agent_bound)" || return 1
  [ "$st" = gone ]
}

last_turn() {   # $1 record → how its LAST turn ended: complete | aborted | running | none; 2 when unreadable
  local out rc=0
  out="$(jq -nrR 'reduce (inputs | (fromjson? // empty) | select(.type == "event_msg") | .payload | select(.type == "task_started" or .type == "task_complete" or .type == "turn_aborted")) as $e
    ("none"; if $e.type == "task_started" then "running" elif $e.type == "task_complete" then "complete" else "aborted" end)' "$1" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { echo "drive-stage: jq failed reading $1 (exit $rc): $out" >&2; return 2; }
  printf '%s\n' "$out"
}

discover_session() {   # $1 root → prints the pane Codex's session id: Herdr's agent_session, else the ONE recent record whose
  # first tagged UserMessage is this message and whose cwd is this worktree; "" while none shows; 3 when two candidates exist (never guessed); 2 on a failure
  local root="$1" sid cands f c n=0 pr mins k nm
  if hcall agent get "$B_pane"; then
    k="$(printf '%s' "$H_OUT" | jq -r '.result.agent.agent // ""')" || return 2
    nm="$(printf '%s' "$H_OUT" | jq -r '.result.agent.name // ""')" || return 2
    sid="$(printf '%s' "$H_OUT" | jq -r '.result.agent.agent_session.value // ""')" || return 2
    if [ "$k" = codex ] && [ -z "$nm" ]; then hcall agent rename "$B_pane" "$B_agent" >/dev/null 2>&1 || true; fi   # a start that timed out leaves Codex unnamed: the name the watchman reads, re-applied
    if [ "$k" = codex ] && [ -n "$sid" ]; then printf '%s\n' "$sid"; return 0; fi
  fi
  [ -d "$CODEX_SESSIONS" ] || return 0
  pr="$(cd "$root" && pwd -P)" || return 2
  mins=$(( ( $(date +%s) - ${B_sent_s:-0} ) / 60 + 2 ))   # a prefilter only (find's -newer compares whole seconds on macOS): the tag and the cwd decide
  cands="$(find "$CODEX_SESSIONS" -type f -name 'rollout-*.jsonl' -mmin "-$mins")" || { echo "drive-stage: find failed under $CODEX_SESSIONS" >&2; return 2; }
  sid=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    c="$(jq -nrR --arg tag "$B_tag" --arg cwd "$pr" '[inputs | (fromjson? // empty)] as $e
      | ($e | map(select(.type == "session_meta")) | .[0].payload) as $m
      | if ($m.cwd // "") == $cwd and ($e | any(.type == "event_msg" and .payload.type == "item_completed" and (.payload.item.type // "") == "UserMessage" and ([.payload.item.content[]? | (.text? // "")] | join("") | startswith($tag))))
        then ($m.id // $m.session_id // "") else empty end' "$f")" || return 2
    [ -n "$c" ] || continue
    n=$((n+1)); sid="$c"
  done <<< "$cands"
  [ "$n" -le 1 ] || return 3
  printf '%s\n' "$sid"
}

close_settled_tabs() {   # $1 root, $2 dir → closes the tab of every SETTLED pane binding of this plan (the previous Stage's, this Stage's earlier run):
  # a full-access agent holding a finished Stage's instructions has no reason to stay alive. An unsettled one is left alone. Tab ids are never
  # reused. The launch goes on whatever happens here (close_settled_tab names every tab it leaves open)
  local b
  for b in "$1/$2"/*-binding; do
    [ -f "$b" ] || continue
    close_settled_tab "$b" 0 || true
  done
}

close_settled_tab() {   # $1 a binding, $2 1 = quiet while its Codex still reads busy → 0 closed, or nothing to close (not a pane, no tab, not
  # settled); 1 left open because its Codex reads working, blocked, unknown or no status; 2 left open for another reason (named). Leaves B_* read
  # from the binding. Settled is the launcher's view only: a human may have typed a follow-up since. So a tab closes only while Herdr reads its
  # pane's Codex idle or done, or the pane no longer holds Codex (gone: agent_not_found / pane_not_found; or a kind that isn't codex, a shell).
  # The reply must be an agent object with a string kind: `{}`, no .result.agent, or no kind is never "gone". A malformed reply or a read that
  # fails is never idle
  local b="$1" quiet="$2" k st v
  [ ! -e "$b.new" ] || return 0   # a pane launch between its start and its binding write: not settled
  bind_read "$b" || { echo "drive-stage: warning — ${b##*/} could not be read: its Stage's tab, if any, is left open" >&2; return 2; }
  [ -n "$B_tab" ] && [ "$B_state" = settled ] || return 0   # a pane Stage later continued headless keeps its tab id until this closes it
  if [ -n "$B_pane" ]; then
    if hcall agent get "$B_pane"; then
      v="$(printf '%s' "$H_OUT" | jq -r '.result.agent as $a | if ($a | type) == "object" and ($a.agent | type) == "string" and $a.agent != ""
          then [$a.agent, (if ($a.agent_status | type) == "string" then $a.agent_status else "" end)] | @tsv else "-" end')" \
        || { echo "drive-stage: jq failed reading pane $B_pane's reply — the settled Stage's tab $B_tab is left open" >&2; return 2; }
      [ "$v" != - ] || { echo "drive-stage: Herdr's reply for pane $B_pane names no agent kind — the settled Stage's tab $B_tab is left open" >&2; return 2; }
      k="${v%%	*}"; st="${v#*	}"
      if [ "$k" = codex ]; then case "$st" in idle|done) ;; *) [ "$quiet" = 1 ] || echo "drive-stage: the settled Stage's tab $B_tab is left open — its Codex reads ${st:-no status} (a human's follow-up?); a later launch closes it once it's idle, or close it by hand" >&2; return 1 ;; esac; fi
    else
      case "$H_CODE" in agent_not_found|pane_not_found) ;; *) echo "drive-stage: cannot read pane $B_pane ($H_CODE) — the settled Stage's tab $B_tab is left open" >&2; return 2 ;; esac
    fi
  fi
  if ! hcall tab close "$B_tab" && [ "$H_CODE" != tab_not_found ]; then echo "drive-stage: could not close the settled Stage's tab $B_tab ($H_CODE) — left open" >&2; return 2; fi
  echo "drive-stage: closed the settled Stage's tab $B_tab (${b##*/})" >&2
  B_tab=""; bind_write "$b" || echo "drive-stage: warning — ${b##*/} still names the closed tab (its rewrite failed)" >&2
  return 0
}

close_on_settle() {   # $1 the binding of a run that just settled → its tab closed now, not at the next launch (a one-off run has none): Herdr's status
  # can trail the record by a moment, so a Codex still reading busy is re-read every POLL for up to SETTLE_TAB_WAIT s, then left open, named, for
  # the next launch's sweep (close_settled_tabs) or end-stream.sh. Outside Herdr, or past a failed gate, the tab is left open, named. Never fails
  # the run: its result line is already printed
  local b="$1" rc end now
  bind_read "$b" 2>/dev/null || return 0   # a binding this run just wrote; one that can't be read now has nothing this can close
  [ -n "$B_tab" ] && [ "$B_state" = settled ] || return 0
  herdr_gate >/dev/null 2>&1 || { echo "drive-stage: the settled run's tab $B_tab is left open — no tested Herdr to close it from here; the next launch or end-stream.sh closes it" >&2; return 0; }
  now="$(date +%s)" || now=0; end=$(( now + SETTLE_TAB_WAIT ))
  while :; do
    rc=0; close_settled_tab "$b" 1 || rc=$?
    [ "$rc" -eq 1 ] || return 0
    now="$(date +%s)" || break   # a clock that can't be read ends the wait: the last read below names the tab left open
    [ "$now" -lt "$end" ] || break
    sleep "$POLL"
  done
  close_settled_tab "$b" 0 || true
}

result_line() {   # $1 root, $2 plan, $3 stage, $4 rc, $5 log, $6 the short pre-send HEAD, $7 extra fields → the one result line; 2 when a producer fails.
  # Split-repo mode: changed= counts both repos' paths, and records-head= / records-commit= (against the binding's rhead) follow rollout=
  local fp commit changed rfp rcommit rh rext=""
  fp="$(footprint "$1" "$6" "$5" "$4")" || return 2
  commit="$(commit_since "$1" "$B_head")" || { echo "drive-stage: codex exit=$4, transcript at $5" >&2; return 2; }
  changed="${fp#* }"
  if [ -n "$REC" ]; then
    if [ -n "$B_rhead" ]; then
      rfp="$(footprint "$REC" "$B_rhead" "$5" "$4")" || { echo "drive-stage: (the records repo $REC_REL)" >&2; return 2; }
      rcommit="$(commit_since "$REC" "$B_rhead")" || { echo "drive-stage: codex exit=$4, transcript at $5 (the records repo $REC_REL)" >&2; return 2; }
      changed=$(( changed + ${rfp#* } )); rext=" records-head=${rfp% *} records-commit=$rcommit"
    else   # a binding written before the records HEAD was kept: the head is read, the commit is not guessed
      rh="$(git -C "$REC" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse HEAD failed in the records repo $REC_REL (exit $?) — codex exit=$4, transcript at $5" >&2; return 2; }
      rext=" records-head=$rh records-commit=unknown"
    fi
  fi
  printf '%s %s exit=%s log=%s head=%s changed=%s commit=%s session=%s rollout=%s%s%s\n' "$2" "$3" "$4" "$5" "${fp% *}" "$changed" "$commit" "$R_SESSION" "$R_COPY" "$rext" "$7"
}

drive_pane() {   # $1 root, $2 plan, $3 stage, $4 heavy, $5 again, $6 dry — a build Stage or a --bounded small change (plan=bounded, stage=<slug>) in its own Herdr tab: `codex NN.X` or `codex <slug>` in the caller's workspace
  local root="$1" plan="$2" stage="$3" heavy="$4" again="$5" dry="$6"
  local secs paths prompt log dir name sn attempt tag pointer grants g before started tab pane i sid drc=0 frc ws settled sq="'" note rbfull="" rhdr="" ptmp
  secs="$TIMEOUT_NORMAL"; [ "$heavy" -eq 1 ] && secs="$TIMEOUT_HEAVY"
  # the agent name first: a slug too long for Herdr is the refusal to read, before anything about its prompt file
  name="$(project_name "$root")" || return $?   # 2: git or tr failed (never a refusal's 1)
  sn="$(name_part "$stage")" || return 2
  name="$name-codex-$sn"   # NN.X → NN-X; a --bounded slug lowercased, anything outside [a-z0-9-] → -
  case "$name" in [a-z]*) ;; *) echo "drive-stage: the agent name '$name' must start with a letter (set DRIVE_STAGE_PROJECT) — nothing created" >&2; return 1 ;; esac
  [ "${#name}" -le 32 ] || { echo "drive-stage: the agent name '$name' is over Herdr's 32 characters — use a shorter --bounded slug or DRIVE_STAGE_PROJECT, or pass --headless; nothing created" >&2; return 1; }
  paths="$(resolve_paths "$root" "$plan" "$stage" 0 "" "$again" 0)" || return 1
  prompt="${paths%	*}"; log="${paths#*	}"; dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"; ROOT_BIND="$root/$dir/$stage-binding"
  bind_clear; bind_read "$ROOT_BIND" || return 2   # reads only: a dry-run changes no file
  attempt=$(( ${B_attempt:-0} + 1 )); tag="[planner $stage-c$attempt]"
  fresh_ok "$root" "$plan" "$stage" 0 || return $?
  pointer="$tag Your prompt is the file $prompt: read it in full and carry it out."   # Herdr refuses a newline in a launch argument (invalid_agent_argument, 0.9.1): the Stage prompt stays a file Codex reads
  note="$(split_note build "$plan")"; pointer="$pointer${note:+ $note}"   # split-repo mode: the one-line note rides on the pointer (no newline); one repo: unchanged
  set -- -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING" -s "$CODEX_SANDBOX"
  if [ "$CODEX_SANDBOX" = workspace-write ]; then grants="$(all_write_dirs "$root")" || return 1; while IFS= read -r g; do [ -n "$g" ] || continue; set -- "$@" --add-dir "$g"; done <<< "$grants"; fi
  set -- "$@" -a never -c check_for_update_on_startup=false -C "$root" "$pointer"
  ws="${HERDR_WORKSPACE_ID:-}"
  ptmp="${SCRATCH_TMP:-${TMPDIR:-}}"   # the tab's shell starts from Herdr's environment, not ours: the agent temp, or else the inherited TMPDIR, goes with it, and so does XP_SCRATCH_PARENT (the session's own launcher and tidy compute the same root)
  if [ "$dry" -eq 1 ]; then
    printf 'herdr tab create --workspace %s --cwd %s --label %s --env DISABLE_AUTO_UPDATE=true --env RATCHET_ALLOW_PUSH=%s --no-focus\n' "$(shq "${ws:-<HERDR_WORKSPACE_ID>}")" "$(shq "$root")" "$(shq "executor ($stage)")" "${ptmp:+ --env $(shq "TMPDIR=$ptmp")}${XP_SCRATCH_PARENT:+ --env $(shq "XP_SCRATCH_PARENT=$XP_SCRATCH_PARENT")}"
    printf 'herdr agent start %s --kind codex --pane <the new tab'"'"'s pane> --timeout 60000 --' "$(shq "$name")"; for g in "$@"; do printf ' %s' "$(shq "$g")"; done
    printf '   # the launcher takes the run lock and writes the binding first; then it waits on the session record\n'
    return 0
  fi
  unfilled "a build launch" "CODEX_MODEL=$CODEX_MODEL" "CODEX_REASONING=$CODEX_REASONING" "CODEX_SANDBOX=$CODEX_SANDBOX" || return 1
  [ "$no_preflight" -eq 1 ] || preflight "$root" "$CODEX_MODEL" "$CODEX_REASONING" || return 1
  herdr_gate || { echo "drive-stage: to launch without a pane, pass --headless" >&2; return 1; }
  [ -n "$ws" ] || { echo "drive-stage: HERDR_WORKSPACE_ID is empty — a pane opens its tab in the caller's workspace; pass --headless to launch without one. Nothing created" >&2; return 1; }
  [ -s "$(prompt_path "$root" "$prompt")" ] && [ -r "$(prompt_path "$root" "$prompt")" ] || { echo "drive-stage: the prompt $prompt is empty or unreadable — nothing launched" >&2; return 1; }
  lock_take "$root/tmp/.run-lock" "$plan $stage build (pane)" 0 "$plan" "$stage" || return $?
  sweep_read_locks "$root" "$dir"
  close_settled_tabs "$root" "$dir"
  bind_clear; bind_read "$ROOT_BIND" || return 2   # close_settled_tabs read other bindings into B_*
  fresh_ok "$root" "$plan" "$stage" 0 || return $?   # re-read under the lock
  before="$(git -C "$root" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse HEAD failed — nothing launched" >&2; return 1; }
  if [ -n "$REC" ]; then records_before || return 1; fi
  hcall tab create --workspace "$ws" --cwd "$root" --label "executor ($stage)" --env DISABLE_AUTO_UPDATE=true --env RATCHET_ALLOW_PUSH= \
    ${ptmp:+--env} ${ptmp:+"TMPDIR=$ptmp"} ${XP_SCRATCH_PARENT:+--env} ${XP_SCRATCH_PARENT:+"XP_SCRATCH_PARENT=$XP_SCRATCH_PARENT"} --no-focus \
    || { echo "drive-stage: herdr tab create failed ($H_CODE) — nothing launched" >&2; return 1; }
  tab="$(printf '%s' "$H_OUT" | jq -r '.result.tab.tab_id // ""')" && pane="$(printf '%s' "$H_OUT" | jq -r '.result.root_pane.pane_id // ""')" && [ -n "$tab" ] && [ -n "$pane" ] \
    || { echo "drive-stage: herdr tab create returned no tab/pane id — nothing launched" >&2; return 1; }
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '# drive-stage: before=%s sandbox=%s started=%s pane=%s tab=%s agent=%s%s\n' "$before" "$CODEX_SANDBOX" "$started" "$pane" "$tab" "$name" "$rhdr" > "$root/$log"
  B_mode=pane; B_session=""; B_rollout=""; B_copy=""; B_pane="$pane"; B_tab="$tab"; B_agent="$name"; B_launched="$started"; B_attempt="$attempt"; B_tag="$tag"
  B_lines=0; B_head="$(git -C "$root" rev-parse HEAD)" || return 1; B_rhead="$rbfull"; B_sent="$started"; B_sent_s="$(date +%s)"; B_state=sent; B_log="$log"
  bind_write "$ROOT_BIND.new" || return 1   # promoted once the start returns; a launcher killed during the start leaves it for --wait to promote
  LOCK_RELEASE=0
  i=0
  while :; do   # a new tab refuses with agent_pane_busy until its shell owns the foreground
    drc=0; HCALL_TIMEOUT=60 hcall agent start "$name" --kind codex --pane "$pane" --timeout 30000 -- "$@" || drc=$?
    [ "$drc" -ne 0 ] && [ "$H_CODE" = agent_pane_busy ] && [ "$i" -lt 30 ] && { sleep 1; i=$((i+1)); continue; }
    break
  done
  if [ "$drc" -ne 0 ]; then
    case "$H_CODE" in
      agent_pane_busy|invalid_agent_argument|pane_not_found|no_timeout|mktemp)   # the PROVEN pre-launch refusals (a busy pane past 30 s, a bad
        # argument, a missing pane — or hcall failing before herdr ran): nothing was sent
        rm -f "$ROOT_BIND.new"; LOCK_RELEASE=1; hcall tab close "$tab" || true
        echo "drive-stage: herdr agent start refused ($H_CODE) — nothing sent; the tab is closed" >&2; return 1 ;;
      *)   # anything else is UNCERTAIN: agent_not_ready / timeout (Herdr reads "ready" only when Codex is idle: a Codex busy with its launch
        # prompt — any Stage past the start's bound, probed live — or one behind a dialog, is never ready in time; the launch line ran), or an
        # error nobody classified (a lost reply after the launch). The session record decides, below; the binding and the lock are kept
        log_note "$root/$log" "agent start: $H_CODE — the launch line may have run; the session record decides" || return 2 ;;
    esac
  fi
  mv -f "$ROOT_BIND.new" "$ROOT_BIND" || { echo "drive-stage: cannot promote the binding — Codex runs in tab $tab; --wait reattaches" >&2; return 2; }
  log_note "$root/$log" "agent started: $name in pane $pane (tab $tab)" || return 2
  sid=""
  while :; do   # the session id: Herdr's report of it, cross-checked against the record; ambiguity stops
    drc=0; sid="$(discover_session "$root")" || drc=$?
    case "$drc" in 0) ;; 3) B_state=uncertain; bind_write "$ROOT_BIND" || { echo "drive-stage: the binding could not record the message as uncertain — the run lock stays; --peek, then --wait or --abandon" >&2; return 2; }; echo "drive-stage: two candidate session records carry $tag — never guessed; look at the tab, then --wait or --abandon" >&2
         R_SESSION=none; R_COPY=none; result_line "$root" "$plan" "$stage" 75 "$log" "$before" " pane=$pane settled=no" || return 2; return 75 ;;
       *) return 2 ;; esac
    if [ -n "$sid" ]; then
      frc=0; B_rollout="$(find_rollout "$sid")" || frc=$?
      case "$frc" in 0) break ;; 1) B_rollout="" ;;   # not written yet
        3) B_rollout=""; B_state=uncertain; bind_write "$ROOT_BIND" || { echo "drive-stage: the binding could not record the message as uncertain — the run lock stays; --peek, then --wait or --abandon" >&2; return 2; }; echo "drive-stage: more than one session record names $sid — never guessed; look at the tab, then --wait or --abandon" >&2
           R_SESSION=none; R_COPY=none; result_line "$root" "$plan" "$stage" 75 "$log" "$before" " pane=$pane settled=no" || return 2; return 75 ;;
        *) return 2 ;; esac   # a failing find is a tool failure, never "not there yet"; the binding and the lock stay
    fi
    if [ $(( $(date +%s) - B_sent_s )) -ge "$PANE_DELIVERY" ]; then
      B_state=uncertain; bind_write "$ROOT_BIND" || { echo "drive-stage: the binding could not record the message as uncertain — the run lock stays; --peek, then --wait or --abandon" >&2; return 2; }; log_note "$root/$log" "no session record within ${PANE_DELIVERY}s" || return 2
      echo "drive-stage: no session record for $name within ${PANE_DELIVERY}s — look at the tab (a dialog?); never re-sent: --wait reattaches once Codex starts" >&2
      R_SESSION=none; R_COPY=none; result_line "$root" "$plan" "$stage" 75 "$log" "$before" " pane=$pane settled=no" || return 2; return 75
    fi
    sleep "$POLL"
  done
  B_session="$sid"; printf 'session id: %s\n' "$sid" >> "$root/$log"; bind_write "$ROOT_BIND" || return 2
  pane_wait "$root" "$log" $(( B_sent_s + secs )) 1 || return 2
  bind_write "$ROOT_BIND" || return 2
  settle_record "$root" "$log" || return 2; bind_write "$ROOT_BIND" || return 2
  settled=no; [ "$B_state" != settled ] || { settled=yes; LOCK_RELEASE=1; }
  result_line "$root" "$plan" "$stage" "$W_RC" "$log" "$before" " pane=$pane settled=$settled" || return 2
  [ "$settled" = no ] || [ "$plan" != bounded ] || close_on_settle "$ROOT_BIND"   # a small change is one-off: no next launch closes its tab
  return "$W_RC"
}

cont() {   # $1 root, $2 plan, $3 stage, $4 prompt file, $5 heavy, $6 dry — --continue: the next message in the Stage's own session
  local root="$1" plan="$2" stage="$3" pf="$4" heavy="$5" dry="$6"
  local tb secs dir log n text tag mode=headless st before rc=0 grants g extra="" sq="'" catpart settled rhdr
  tb="$(timeout_bin)" || { echo "drive-stage: no timeout/gtimeout on PATH (brew install coreutils)" >&2; return 1; }
  secs="$TIMEOUT_NORMAL"; [ "$heavy" -eq 1 ] && secs="$TIMEOUT_HEAVY"
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"; ROOT_BIND="$root/$dir/$stage-binding"
  bind_clear; bind_read "$ROOT_BIND" || return 2
  [ -n "$B_session" ] || { echo "drive-stage: --continue — $dir/$stage-binding records no session (not launched by this launcher, or Codex never started): use --resume, a fresh session with a resume prompt — nothing sent" >&2; return 1; }
  [ -n "$B_rollout" ] && [ -f "$B_rollout" ] || { echo "drive-stage: --continue — the session's record is gone (${B_rollout:-none}): use --resume — nothing sent" >&2; return 1; }
  [ "$B_state" = settled ] || { echo "drive-stage: --continue — the last message $B_tag is '$B_state', not settled: run --wait (it reattaches) or --peek first; --abandon only once you know it is done or dead. A message whose delivery is uncertain is never re-sent — nothing sent" >&2; return 1; }
  case "$pf" in /*) ;; *) pf="$root/$pf" ;; esac
  [ -f "$pf" ] || { echo "drive-stage: --continue — prompt file missing: $pf" >&2; return 1; }
  tag="[planner $stage-c$(( ${B_attempt:-0} + 1 ))]"
  log="$dir/$stage-continue-run.log"; if [ -e "$root/$log" ]; then n=2; while [ -e "$root/$dir/$stage-continue-run-r$n.log" ]; do n=$((n+1)); done; log="$dir/$stage-continue-run-r$n.log"; fi
  [ "$B_mode" != pane ] || mode=pane
  set --
  if [ "$CODEX_SANDBOX" = workspace-write ]; then grants="$(all_write_dirs "$root")" || return 1; while IFS= read -r g; do [ -n "$g" ] || continue; set -- "$@" --add-dir "$g"; extra="$extra --add-dir $(shq "$g")"; done <<< "$grants"; fi
  if [ "$dry" -eq 1 ]; then
    catpart="\"\$(printf ${sq}%s\\n${sq} $(shq "$tag"); cat $(shq "$pf"))\""
    if [ "$mode" = pane ]; then printf 'codex queue --thread %s --message %s < /dev/null   # into the live pane session (headless resume if its tab is gone); the launcher takes the run lock and writes the binding first, then waits on the record\n' "$(shq "$B_session")" "$catpart"
    else printf 'env -u RATCHET_ALLOW_PUSH%s %s %s codex exec -m %s -c %s -s %s%s -C %s resume %s %s < /dev/null >> %s 2>&1   # the launcher takes the run lock, writes the binding and the log header first\n' \
      "${SCRATCH_TMP:+ TMPDIR=$(shq "$SCRATCH_TMP")}" "$tb" "$secs" "$(shq "$CODEX_MODEL")" "$(shq "model_reasoning_effort=$CODEX_REASONING")" "$(shq "$CODEX_SANDBOX")" "$extra" "$(shq "$root")" "$(shq "$B_session")" "$catpart" "$(shq "$log")"; fi
    return 0
  fi
  need_jq "--continue" || return 1
  unfilled "a build launch" "CODEX_MODEL=$CODEX_MODEL" "CODEX_REASONING=$CODEX_REASONING" "CODEX_SANDBOX=$CODEX_SANDBOX" || return 1
  [ "$no_preflight" -eq 1 ] || preflight "$root" "$CODEX_MODEL" "$CODEX_REASONING" || return 1
  text="$(cat "$pf")" || { echo "drive-stage: cannot read the prompt $pf — nothing sent" >&2; return 1; }
  [ -n "$text" ] || { echo "drive-stage: the prompt $pf is empty — nothing sent" >&2; return 1; }
  if [ "$mode" = pane ]; then   # the Stage ran in a tab: queue into it while its Codex is live; when the tab is gone, the session continues headless
    herdr_gate || return 1
    st="$(agent_bound)" || return 1
    [ "$st" = live ] || { mode=headless; echo "drive-stage: the Stage's Codex ($B_agent) is gone — continuing its session headless" >&2; }
    if [ "$mode" = pane ]; then
      st="$(last_turn "$B_rollout")" || return 2   # an unreadable record is a tool failure, not a refusal's verdict
      [ "$st" != aborted ] || { echo "drive-stage: --continue — the Stage's Codex in tab 'executor ($stage)' was interrupted (its last turn ended with an Esc), and Codex does not deliver a queued message to an interrupted session (probed on 0.154.0); a human may be steering it. Look at the tab; to continue from here, quit that Codex (Ctrl-C, or close the tab) and run --continue again — it resumes the session headless. Nothing sent" >&2; return 1; }
    fi
  fi
  lock_take "$root/tmp/.run-lock" "$plan $stage continue" 0 "$plan" "$stage" || return $?
  sweep_read_locks "$root" "$dir"
  bind_clear; bind_read "$ROOT_BIND" || return 2   # re-read under the lock: still settled, still this session
  [ "$B_state" = settled ] && [ -n "$B_session" ] || { echo "drive-stage: --continue — the binding moved while the lock was taken ('$B_state') — nothing sent; --peek" >&2; return 1; }
  before="$(git -C "$root" rev-parse --short HEAD)" || { echo "drive-stage: git rev-parse HEAD failed — nothing sent" >&2; return 1; }
  B_attempt=$(( ${B_attempt:-0} + 1 ))
  new_message "$root" "$tag" || return 1
  rhdr=""; [ -z "$B_rhead" ] || { rhdr="$(git -C "$REC" rev-parse --short "$B_rhead")" || { echo "drive-stage: git rev-parse --short failed in the records repo $REC_REL (exit $?)" >&2; return 2; }; rhdr=" records=$rhdr"; }
  printf '# drive-stage: before=%s sandbox=%s started=%s continue=%s mode=%s%s\n' "$before" "$CODEX_SANDBOX" "$B_sent" "$B_session" "$mode" "$rhdr" > "$root/$log"
  B_log="$log"; [ "$mode" = pane ] || { B_mode=headless; B_pane=""; B_agent=""; }
  bind_write "$ROOT_BIND" || return 1
  LOCK_RELEASE=0
  unset RATCHET_ALLOW_PUSH
  if [ "$mode" = headless ]; then
    set +e
    "$tb" "$secs" codex exec -m "$CODEX_MODEL" -c "model_reasoning_effort=$CODEX_REASONING" -s "$CODEX_SANDBOX" "$@" -C "$root" resume "$B_session" "$tag"$'\n'"$text" < /dev/null >> "$root/$log" 2>&1
    rc=$?
    set -e
    B_state=settled; bind_write "$ROOT_BIND" || { echo "drive-stage: codex exit=$rc, transcript at $log — the binding could not be settled; the run lock stays (--abandon settles it)" >&2; return 2; }
    LOCK_RELEASE=1
    settle_record "$root" "$log" || return 2; bind_write "$ROOT_BIND" || return 2
    result_line "$root" "$plan" "$stage" "$rc" "$log" "$before" "" || return 2
    return "$rc"
  fi
  queue_msg "$root" "$log" "$tag"$'\n'"$text" || { B_state=uncertain; bind_write "$ROOT_BIND" || { echo "drive-stage: the binding could not record the message as uncertain — the run lock stays; --peek, then --wait or --abandon" >&2; return 2; }; echo "drive-stage: the queued message's delivery is uncertain — never re-sent: --peek, then --wait or --abandon" >&2; return 75; }
  pane_wait "$root" "$log" $(( B_sent_s + secs )) 1 || return 2
  bind_write "$ROOT_BIND" || return 2
  settle_record "$root" "$log" || return 2; bind_write "$ROOT_BIND" || return 2
  settled=no; [ "$B_state" != settled ] || { settled=yes; LOCK_RELEASE=1; }
  result_line "$root" "$plan" "$stage" "$W_RC" "$log" "$before" " pane=$B_pane settled=$settled" || return 2
  [ "$settled" = no ] || [ "$plan" != bounded ] || close_on_settle "$ROOT_BIND"
  return "$W_RC"
}

recover_unbound() {   # $1 root, $2 plan, $3 stage, $4 wait|abandon — this Stage has NO unsettled message (no binding, or its last message settled):
  # a STALE build lock that is owner-less, or owned by this plan and stage, belongs to a launcher that died before it recorded a message
  # (every mode writes the binding before its send) — taken over through the claim and released; nothing was sent. Another Stage's stale
  # lock is refused naming it (lock_take). 0 recovered; 3 nothing to recover (no stale lock); 1 refused; 2 a tool failed
  local d="$1/tmp/.run-lock" st rc=0
  st="$(lock_state "$d")" || return 2
  [ "$st" = stale ] || return 3
  lock_take "$d" "$2 $3 $4 (no message)" 1 "$2" "$3" || return $?
  LOCK_RELEASE=1
  echo "$2 $3 $4: took over the stale build lock tmp/.run-lock (its launcher died before recording a message) and released it — nothing was sent"
}

wait_run() {   # $1 root, $2 plan, $3 stage, $4 heavy — --wait: reattach to the last message, send nothing; takes over a STALE run lock
  # of the SAME plan and stage (never another Stage's), then reads the binding under it
  local root="$1" plan="$2" stage="$3" heavy="$4" dir secs before sid drc=0 frc=0 settled rc
  need_jq "--wait" || return 1
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"; ROOT_BIND="$root/$dir/$stage-binding"
  if [ ! -e "$ROOT_BIND" ] && [ ! -e "$ROOT_BIND.new" ]; then
    rc=0; recover_unbound "$root" "$plan" "$stage" wait || rc=$?
    case "$rc" in 3) echo "drive-stage: --wait — no binding at $dir/$stage-binding: nothing this launcher sent to wait for" >&2; return 1 ;; *) return "$rc" ;; esac
  fi
  lock_take "$root/tmp/.run-lock" "$plan $stage wait" 1 "$plan" "$stage" || return $?
  LOCK_RELEASE=0   # kept through every exit below until the binding, read under the lock, shows the message settled
  bind_promote "$ROOT_BIND" || return 2   # the pane launcher that wrote a .new is gone: this launcher holds the lock it held
  bind_clear; bind_read "$ROOT_BIND" || return 2
  [ -n "$B_tag" ] || { LOCK_RELEASE=1; echo "drive-stage: --wait — $dir/$stage-binding records no message: nothing to wait for" >&2; return 1; }
  [ "$B_state" != settled ] || LOCK_RELEASE=1
  sweep_read_locks "$root" "$dir"
  before="$(git -C "$root" rev-parse --short "$B_head")" || { echo "drive-stage: the binding's HEAD $B_head is not a commit here" >&2; return 1; }
  if [ -z "$B_session" ]; then   # a launcher that died before recording it: the run log names it (codex's header), or Herdr does (a pane)
    sid="$(log_session "$root/$B_log")" || return 2
    if [ -z "$sid" ] && [ "$B_mode" = pane ] && command -v herdr >/dev/null 2>&1; then
      sid="$(discover_session "$root")" || drc=$?
      case "$drc" in 0) ;; 3) echo "drive-stage: --wait — two candidate session records carry $B_tag — never guessed; look at the tab, then --abandon once you know" >&2; return 75 ;; *) return 2 ;; esac
    fi
    B_session="$sid"
  fi
  if [ -n "$B_session" ] && [ -z "$B_rollout" ]; then
    B_rollout="$(find_rollout "$B_session")" || frc=$?
    case "$frc" in 0) ;; 1) B_rollout="" ;;
      3) B_rollout=""; echo "drive-stage: --wait — more than one session record names $B_session — never guessed; --peek the tab or the log" >&2; return 75 ;;
      *) return 2 ;; esac   # a failing find is a tool failure (exit 2), never "no record yet"
  fi
  if [ -z "$B_rollout" ]; then
    echo "drive-stage: --wait — no session record yet for $B_tag (session ${B_session:-unknown}) — --peek the tab or the log; --abandon once you know it is dead" >&2
    bind_write "$ROOT_BIND" || return 2; return 75
  fi
  bind_write "$ROOT_BIND" || return 2
  R_SESSION="$B_session"; R_COPY="${B_copy:-none}"
  if [ "$B_state" = settled ]; then
    echo "drive-stage: the last message $B_tag is settled — nothing to wait for" >&2
    result_line "$root" "$plan" "$stage" 0 "$B_log" "$before" " pane=${B_pane:-none} settled=yes" || return 2
    [ "$plan" != bounded ] || close_on_settle "$ROOT_BIND"; return 0
  fi
  secs="$TIMEOUT_NORMAL"; [ "$heavy" -eq 1 ] && secs="$TIMEOUT_HEAVY"
  pane_wait "$root" "$B_log" $(( $(date +%s) + secs )) 0 || return 2   # 124 here is --wait's own bound: the message is still running (settled=no) — --wait again or --peek, never --continue
  bind_write "$ROOT_BIND" || return 2
  settle_record "$root" "$B_log" || return 2; bind_write "$ROOT_BIND" || return 2
  settled=no; [ "$B_state" != settled ] || { settled=yes; LOCK_RELEASE=1; }
  result_line "$root" "$plan" "$stage" "$W_RC" "$B_log" "$before" " pane=${B_pane:-none} settled=$settled" || return 2
  # a small change is one-off: its tab goes now, not at a next launch that may never come. A Stage keeps its tab until the Stage ends
  # (the next launch's sweep, or end-stream), so its next --continue queues into the live pane
  [ "$settled" = no ] || [ "$plan" != bounded ] || close_on_settle "$ROOT_BIND"
  return "$W_RC"
}

abandon() {   # $1 root, $2 plan, $3 stage — --abandon: mark the last message settled without waiting (once --peek shows it done or dead); sends nothing
  local root="$1" plan="$2" stage="$3" dir was rc
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"; ROOT_BIND="$root/$dir/$stage-binding"
  bind_clear; bind_read "$ROOT_BIND" || return 2
  if [ -z "$B_tag" ] || [ "$B_state" = settled ]; then   # no message in flight: only a stale lock this Stage's dead launcher left, if any
    rc=0; recover_unbound "$root" "$plan" "$stage" abandon || rc=$?
    [ "$rc" -eq 3 ] || return "$rc"
    if [ -z "$B_tag" ]; then echo "drive-stage: --abandon — no binding at $dir/$stage-binding" >&2; return 1; fi
    echo "drive-stage: --abandon — $B_tag is already settled; nothing to do" >&2; return 0
  fi
  lock_take "$root/tmp/.run-lock" "$plan $stage abandon" 1 "$plan" "$stage" || return $?
  LOCK_RELEASE=0   # the lock goes only once the settled binding is written: a failed write keeps it
  bind_promote "$ROOT_BIND" || return 2
  bind_clear; bind_read "$ROOT_BIND" || return 2   # re-read under the lock
  if [ "$B_state" = settled ]; then LOCK_RELEASE=1; echo "drive-stage: --abandon — $B_tag settled meanwhile; nothing to do" >&2; return 0; fi
  was="$B_state"; B_state=settled; bind_write "$ROOT_BIND" || { echo "drive-stage: --abandon — the binding could not be settled; the run lock stays" >&2; return 2; }
  LOCK_RELEASE=1
  echo "$plan $stage abandoned $B_tag (was $was) — nothing sent; the run lock is released"
  [ "$B_mode" != pane ] || echo "drive-stage: note — a message queued to a Codex that is gone waits in Codex's queue and is delivered at the session's next resume (verified on 0.154.0): word the next --continue so that a repeat does no harm" >&2
}

peek() {   # $1 root, $2 plan, $3 stage, $4 n — the Stage's session state and its last n items; reads only (no lock, nothing sent)
  local root="$1" plan="$2" stage="$3" n="$4" dir sid ro frc=0 ts="none" last tl items shown pr
  need_jq "--peek" || return 1
  dir="tmp/$plan"; [ "$plan" = bounded ] && dir="tmp/bounded"
  bind_clear; bind_read "$root/$dir/$stage-binding" || return 2   # reads only: a .new is read, never promoted
  sid="$B_session"; [ -n "$sid" ] || [ -z "$B_log" ] || { sid="$(log_session "$root/$B_log")" || return 2; }
  if [ -z "$sid" ] && [ -f "$root/$dir/$stage-run.log" ]; then sid="$(log_session "$root/$dir/$stage-run.log")" || return 2; fi
  ro="$B_rollout"; if [ -z "$ro" ] && [ -n "$sid" ]; then ro="$(find_rollout "$sid")" || frc=$?; case "$frc" in 0) ;; 1|3) ro="" ;; *) return 2 ;; esac; fi
  [ -n "$ro" ] && [ -f "$ro" ] || { echo "drive-stage: --peek — no session record for $plan $stage (session ${sid:-unknown})" >&2; return 1; }
  [ -z "$B_tag" ] || { ts="$(turn_state "$ro" "${B_lines:-0}" "$B_tag")" || return 2; }
  tl="$(tail -n 1 "$ro")" || { echo "drive-stage: tail failed on $ro" >&2; return 2; }
  last="$(printf '%s' "$tl" | jq -rR '(fromjson? // {}) | .timestamp // "?"')" || last="?"
  pr="$(cd "$root" && pwd -P)/" || pr=""
  items="$(jq -nrR --arg root "$pr" 'inputs | (fromjson? // empty) | select(.type == "event_msg" and .payload.type == "item_completed") | .payload.item
    | def one: gsub("[\r\n\t]+"; " ") | .[0:200];
      if .type == "AgentMessage" then "  agent: " + ([.content[]? | .text? // empty] | join(" ") | one)
      elif .type == "CommandExecution" then "  exec:  " + ((.command // "") | if type == "array" then (.[-1] // "") else tostring end | one)
      elif .type == "FileChange" then "  edit:  " + ((.changes // {}) | to_entries | map("\(.value.type // "?") \(.key | ltrimstr($root))") | join(", ") | one)
      elif .type == "UserMessage" then ([.content[]? | .text? // empty] | join(" ")) as $t
        | if ($t | startswith("[planner") or startswith("[manager")) then "  sent:  " + ($t | one) else "  human: " + ($t | one) + "   (untagged)" end
      else empty end' "$ro")" || { echo "drive-stage: jq failed reading $ro" >&2; return 2; }
  echo "$plan $stage peek session=${sid:-?} state=${B_state:-none} message=${B_tag:-none} turn=$ts last-event=$last record=$ro"
  [ -n "$items" ] || return 0
  shown="$(tail -n "$n" <<< "$items")" || { echo "drive-stage: tail failed" >&2; return 2; }
  printf '%s\n' "$shown"
}

if [ "$selftest" -eq 1 ]; then
  d="$(mktemp -d)"; sr="$(mktemp -d /tmp/xps.XXXXXX)"; trap 'rm -rf "$d" "$sr"' EXIT
  sr="$(cd "$sr" && pwd -P)"; export XP_SCRATCH_PARENT="$sr"   # every launch's agent temp: a SHORT parent (mktemp -d's own path is over scratch_env's 80-byte cap)
  d="$(cd "$d" && pwd -P)"   # the PHYSICAL path: the grants are resolved through `pwd -P` (and git's own linked-worktree answers are physical), so a fixture under a symlinked tmp (/var → /private/var on macOS) is compared as the launcher prints it
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  export CODEX_HOME="$d/codexhome"; CODEX_SESSIONS="$CODEX_HOME/sessions"; mkdir -p "$CODEX_SESSIONS/2026/09/23"   # never the real session store
  unset HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID HERDR_SOCKET_PATH DRIVE_STAGE_PROJECT   # a pane test sets its own; never the caller's live Herdr
  unset RATCHET_RECORDS   # split-repo mode comes only from a fixture's own script/ratchet.conf (or a probe's own value), never the caller's
  count_logs() { local n=0 f; for f in "$1"/*"$2"*.log; do [ -e "$f" ] && n=$((n+1)); done; echo "$n"; }   # $1 dir, $2 an infix: how many <…$2…>.log files exist
  mkdir -p "$d/repo/tmp/PLAN-07" "$d/bin"
  ( cd "$d/repo" && git init -q && git config user.email t@t && git config user.name t && printf 'x\n' > a.txt && printf 'tmp/\n' > .gitignore && git add a.txt .gitignore && git commit -qm init )
  printf 'do stage 07.1\n' > "$d/repo/tmp/PLAN-07/07.1-prompt.md"
  printf 'resume 07.1\n' > "$d/repo/tmp/PLAN-07/07.1-resume-prompt.md"
  # a fake codex that records argv, echoes stdin state, touches the tree, and exits 3; `exec … review …` and a `-s read-only` read record argv,
  # print a verdict, write it to the -o file, touch nothing, exit 0; the smoke records its argv (FAKE_SMOKE_ARGV); FAKE_REFUSE_MODEL makes every
  # call under that `-m` fail as a refused pin would
  cat > "$d/bin/codex" <<'FAKE'
#!/bin/sh
[ "${1:-}" = --version ] && { echo "codex-cli ${FAKE_VERSION:-0.1.0}"; exit "${FAKE_VERSION_RC:-0}"; }
prev=""; out=""; sb=""; mdl=""; for a in "$@"; do [ "$prev" = -o ] && out="$a"; [ "$prev" = -s ] && sb="$a"; [ "$prev" = -m ] && mdl="$a"; prev="$a"; done
[ -n "${FAKE_REFUSE_MODEL:-}" ] && [ "$mdl" = "$FAKE_REFUSE_MODEL" ] && { echo "error: model $mdl is not supported"; exit 1; }
case "$*" in *"exactly the word OK"*) [ -n "${FAKE_SMOKE_ARGV:-}" ] && printf '%s\n' "$*" >> "$FAKE_SMOKE_ARGV"; echo "prompt: Reply with exactly the word OK and nothing else."; echo "${FAKE_SMOKE:-OK}"; exit "${FAKE_SMOKE_RC:-0}" ;; esac
isrev=""; for a in "$@"; do [ "$a" = review ] && isrev=1; done   # the bare subcommand token, never a word inside the prompt
if [ -n "$isrev" ] || [ "$sb" = read-only ]; then
  printf '%s\n' "$@" > "$FAKE_ARGV"; if read -r line; then echo "STDIN_HAD_DATA:$line"; else echo "STDIN_EMPTY"; fi; echo "PASS"
  [ -z "$out" ] || echo "PASS — the final message" > "$out"
  exit "${FAKE_REVIEW_RC:-0}"
fi
printf '%s\n' "$@" > "$FAKE_ARGV"
if read -r line; then echo "STDIN_HAD_DATA:$line"; else echo "STDIN_EMPTY"; fi
[ -z "${FAKE_TMPDIR_OUT:-}" ] || printf '%s\n' "${TMPDIR-unset}" > "$FAKE_TMPDIR_OUT"   # the agent temp this build session got
echo "hello from fake codex"
echo "PUSH_KEY=${RATCHET_ALLOW_PUSH-unset}"   # the launcher must have stripped it, even when the launching shell exported it
while [ "$#" -gt 0 ]; do [ "$1" = -C ] && { echo "new" > "$2/created-by-codex.txt"; break; }; shift; done   # write into the -C dir (real codex chdirs there)
exit 3
FAKE
  chmod +x "$d/bin/codex"
  # a fake git for fault injection: the one call whose argv contains FAKE_GIT_FAIL (a substring of the space-joined argv) exits FAKE_GIT_FAIL_RC; everything else reaches the real git
  mkdir -p "$d/fakegit"; real_git="$(command -v git)" || fail "no git on PATH"
  printf '#!/bin/sh\ncase " $* " in *" ${FAKE_GIT_FAIL:-<never>} "*) echo "git: injected failure on: $*" >&2; exit "${FAKE_GIT_FAIL_RC:-73}" ;; esac\nexec %s "$@"\n' "$(shq "$real_git")" > "$d/fakegit/git"
  chmod +x "$d/fakegit/git"
  # fake grep / sort / cat for fault injection: grep exits 2 when one argv token EQUALS FAKE_GREP_FAIL; sort exits FAKE_SORT_RC when set; cat exits 73 when one token equals FAKE_CAT_FAIL
  mkdir -p "$d/fakegrep" "$d/fakesort" "$d/fakecat"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "${FAKE_GREP_FAIL:-<never>}" ] && { echo "grep: injected failure" >&2; exit 2; }; done\nexec %s "$@"\n' "$(shq "$(command -v grep)")" > "$d/fakegrep/grep"
  printf '#!/bin/sh\n[ -z "${FAKE_SORT_RC:-}" ] || { echo "sort: injected failure" >&2; exit "$FAKE_SORT_RC"; }\nexec %s "$@"\n' "$(shq "$(command -v sort)")" > "$d/fakesort/sort"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "${FAKE_CAT_FAIL:-<never>}" ] && { echo "cat: injected failure" >&2; exit 73; }; done\nexec %s "$@"\n' "$(shq "$(command -v cat)")" > "$d/fakecat/cat"
  chmod +x "$d/fakegrep/grep" "$d/fakesort/sort" "$d/fakecat/cat"
  tb="$(timeout_bin)" || fail "no timeout/gtimeout on PATH"
  R="$d/repo"
  # an unedited kit copy refuses a real launch (dry-run still prints the command for inspection)
  if [ "$CODEX_MODEL" = "EDIT-ME" ]; then
    if "$BASH" "$0" --root "$R" PLAN-07 07.1 >/dev/null 2>&1; then fail "EDIT-ME model did not refuse a real launch"; fi
  fi
  # each mode refuses while a value IT uses reads EDIT-ME, naming every one, nothing launched: the build pin + sandbox for a stage (and --fix), the review pin for --review / --read
  printf 'fix across stages\n' > "$R/tmp/PLAN-07/fix-prompt.md"; printf 'read the draft\n' > "$R/tmp/PLAN-07/premise-prompt.md"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvE" DRIVE_STAGE_MODEL=m DRIVE_STAGE_REASONING=EDIT-ME DRIVE_STAGE_SANDBOX=EDIT-ME DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'a build launch needs: CODEX_REASONING CODEX_SANDBOX (still EDIT-ME)' <<< "$out" && [ ! -e "$d/argvE" ] && [ ! -e "$R/tmp/PLAN-07/07.1-run.log" ] || fail "an EDIT-ME build reasoning / sandbox should refuse the stage naming both (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvE" DRIVE_STAGE_MODEL=EDIT-ME DRIVE_STAGE_REASONING=x DRIVE_STAGE_SANDBOX=danger-full-access DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --fix PLAN-07 tmp/PLAN-07/fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'needs: CODEX_MODEL (still EDIT-ME)' <<< "$out" && [ ! -e "$d/argvE" ] && [ ! -e "$R/tmp/PLAN-07/fix-run.log" ] || fail "an EDIT-ME build model should refuse --fix (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvE" DRIVE_STAGE_REVIEW_MODEL=EDIT-ME DRIVE_STAGE_REVIEW_REASONING=x DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'a read needs: CODEX_REVIEW_MODEL (still EDIT-ME)' <<< "$out" && [ ! -e "$d/argvE" ] && [ ! -e "$R/tmp/PLAN-07/premise-read.log" ] || fail "an EDIT-ME review model should refuse --read (rc=$rc): $out"
  export DRIVE_STAGE_MODEL="fake-model-1" DRIVE_STAGE_REASONING="high" DRIVE_STAGE_SANDBOX="danger-full-access" DRIVE_STAGE_REVIEW_MODEL="fake-review-1" DRIVE_STAGE_REVIEW_REASONING="xhigh"
  CODEX_MODEL="$DRIVE_STAGE_MODEL"; CODEX_REASONING="$DRIVE_STAGE_REASONING"; CODEX_SANDBOX="$DRIVE_STAGE_SANDBOX"; CODEX_REVIEW_MODEL="$DRIVE_STAGE_REVIEW_MODEL"; CODEX_REVIEW_REASONING="$DRIVE_STAGE_REVIEW_REASONING"
  # preflight: the pin matches → OK; a moved CLI → refused with the recovery path; a failed smoke → refused; unpinned → refused
  PATH="$d/bin:$PATH" DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight >/dev/null 2>&1 || fail "preflight with a matching pin failed"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_VERSION=0.2.0 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -q 're-pin' <<< "$out" || fail "a moved CLI did not refuse with the recovery path: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_SMOKE=garbage DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -q 'did not complete' <<< "$out" || fail "a failed smoke did not refuse: $out"
  grep -Fq 'a model newer than codex 0.1.0: upgrade the CLI' <<< "$out" || fail "a failed smoke should name a too-old CLI as the usual cause of a refused model: $out"
  set +e; out="$(PATH="$d/bin:$PATH" DRIVE_STAGE_CODEX_VERSION= "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -q 'no pin' <<< "$out" || fail "an unpinned preflight should refuse and name the pin to set: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_SMOKE_RC=124 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -q 'did not complete' <<< "$out" || fail "a timed-out smoke whose echoed prompt contains OK passed: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_SMOKE='not OK' DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -q 'did not complete' <<< "$out" || fail "an answer of 'not OK' passed: $out"
  # K1: `codex --version` printing the pinned version but EXITING non-zero is a failed probe, not a match — even when the smoke would pass
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_VERSION_RC=23 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -Fq "'codex --version' failed (exit 23)" <<< "$out" || fail "a version probe exiting 23 passed the preflight: $out"
  set +e; PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv00" FAKE_VERSION_RC=23 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" PLAN-07 07.1 >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/argv00" ] && [ ! -e "$R/tmp/PLAN-07/07.1-run.log" ] || fail "a failing version probe still launched the stage (rc=$rc)"
  # K5: grep exiting 2 while parsing `codex --version` (the version text WAS printed) is a refusal naming grep, never a matched pin
  set +e; out="$(PATH="$d/fakegrep:$d/bin:$PATH" FAKE_GREP_FAIL='[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?' DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "a refused preflight should exit 1 (got $rc): $out"
  grep -Fq "grep failed (exit 2) parsing the output of 'codex --version'" <<< "$out" || fail "a grep failure on the version pattern did not refuse naming grep: $out"
  grep -Fq 'preflight OK' <<< "$out" && fail "a grep failure on the version pattern passed the preflight: $out"
  # the smoke's last line is read by bash alone: padding and trailing blank lines around OK still pass; nothing but OK does
  PATH="$d/bin:$PATH" FAKE_SMOKE="$(printf '  OK  \n\n')" DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" --preflight >/dev/null 2>&1 || fail "a padded OK with trailing blank lines should pass the smoke"
  # a real launch runs the preflight first: a moved CLI never launches; --no-preflight launches anyway
  set +e; PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv0" FAKE_VERSION=0.2.0 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" PLAN-07 07.1 >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/argv0" ] || fail "a moved CLI still launched the stage (rc=$rc)"
  [ ! -e "$R/tmp/PLAN-07/07.1-run.log" ] || fail "a refused preflight left a log behind"
  set +e; PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv0" FAKE_VERSION=0.2.0 DRIVE_STAGE_CODEX_VERSION=0.1.0 "$BASH" "$0" --root "$R" PLAN-07 07.1 --no-preflight >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 3 ] && [ -e "$d/argv0" ] || fail "--no-preflight did not launch past a moved CLI (rc=$rc)"
  rm -f "$d/argv0" "$R/tmp/PLAN-07/07.1-run.log" "$R/tmp/PLAN-07/07.1-binding" "$R/created-by-codex.txt"   # the binding too: the tags below start again at -c1
  export DRIVE_STAGE_CODEX_VERSION=0.1.0
  # dry-run: normal
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --dry-run)" || fail "dry-run exit non-zero"
  label="   # the launcher takes the run lock, writes the binding and the run-log header (line 1 of the log) first, then runs this"
  [ "$(sed -n '1p' <<< "$out")" = "env -u RATCHET_ALLOW_PUSH TMPDIR='$sr/repo-scratch/tmp/PLAN-07/' $tb $TIMEOUT_NORMAL codex exec -m 'fake-model-1' -c 'model_reasoning_effort=$CODEX_REASONING' -s 'danger-full-access' -C '$R' \"\$(printf '%s\\n' '[planner 07.1-c1]'; cat 'tmp/PLAN-07/07.1-prompt.md')\" < /dev/null >> 'tmp/PLAN-07/07.1-run.log' 2>&1$label" ] \
    || fail "dry-run normal command differs: $out"
  [ "$(grep -c . <<< "$out")" -eq 1 ] || fail "a stage dry-run should print just the command line: $out"
  # dry-run: --heavy
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --heavy --dry-run)" || fail "heavy dry-run exit non-zero"
  grep -Fq "$tb $TIMEOUT_HEAVY codex exec" <<< "$out" || fail "--heavy did not select the heavy timeout ($TIMEOUT_HEAVY): $out"
  # a project's own reasoning/timeout choices are honored (the block is configuration, not a constant the test pins)
  out="$(DRIVE_STAGE_REASONING=max DRIVE_STAGE_TIMEOUT=1800 DRIVE_STAGE_TIMEOUT_HEAVY=5400 "$BASH" "$0" --root "$R" PLAN-07 07.1 --heavy --dry-run)" || fail "override dry-run exit non-zero"
  grep -Fq "$tb 5400 codex exec -m 'fake-model-1' -c 'model_reasoning_effort=max' " <<< "$out" || fail "reasoning/timeout overrides not honored: $out"
  # dry-run: --resume (default resume prompt + resume log)
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --resume --dry-run)" || fail "resume dry-run exit non-zero"
  grep -Fq "cat 'tmp/PLAN-07/07.1-resume-prompt.md')\" < /dev/null >> 'tmp/PLAN-07/07.1-resume-run.log' 2>&1" <<< "$out" || fail "--resume paths differ: $out"
  # dry-run: --resume with an explicit prompt file
  printf 'r2\n' > "$R/tmp/PLAN-07/custom.md"
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --resume tmp/PLAN-07/custom.md --dry-run)" || fail "resume(file) dry-run exit non-zero"
  grep -Fq "cat 'tmp/PLAN-07/custom.md')\" < /dev/null >> 'tmp/PLAN-07/07.1-resume-run.log'" <<< "$out" || fail "--resume <file> not honored: $out"
  # workspace-write adds the repo's .git (a MAIN worktree: git dir and common dir both resolve to it — one grant); the default sandbox does not
  out="$(DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$R" PLAN-07 07.1 --dry-run)" || fail "workspace-write dry-run exit non-zero"
  grep -Fq -- "-s 'workspace-write' --add-dir '$R/.git' -C '$R'" <<< "$out" || fail "workspace-write did not add --add-dir <repo>/.git: $out"
  [ "$(grep -o -- '--add-dir' <<< "$out" || true)" = '--add-dir' ] || fail "a main worktree should get exactly one --add-dir: $out"
  # … and prints just the command under either sandbox: no layer1 line, no review reminder (the review is never the stage's; it is the other model's read of the committed range)
  [ "$(grep -c . <<< "$out")" -eq 1 ] || fail "workspace-write dry-run should print just the command line: $out"
  grep -Eq 'layer1|--review' <<< "$out" && fail "workspace-write dry-run still carries a layer1 line or a review reminder: $out"
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --sandbox workspace-write --dry-run)" || fail "--sandbox dry-run exit non-zero"
  grep -Fq -- "-s 'workspace-write' --add-dir '$R/.git' -C '$R'" <<< "$out" && [ "$(grep -c . <<< "$out")" -eq 1 ] || fail "--sandbox workspace-write should print the one command line with the git-dir grant: $out"
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --dry-run)"; grep -Fq -- '--add-dir' <<< "$out" && fail "default sandbox must not add --add-dir: $out"
  grep -Eq 'layer1|--review' <<< "$out" && fail "the default dry-run still carries a layer1 line or a review reminder: $out"
  [ "$(grep -c . <<< "$out")" -eq 1 ] || fail "the default dry-run should print just the command line: $out"
  # a RELATIVE --root (`.` from inside the repo, `repo` from its parent) is made absolute before the grants are built: the old helper
  # prefixed git's relative `.git` with the root as given and printed `./.git`; the grant must be the same absolute physical path the
  # absolute form prints (starts with `/`), from the dry-run and from the helper alone; a root that cannot be entered is a refusal naming it
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"   # $0 may be relative; the probes below cd first
  out="$(cd "$R" && DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$self" --root . PLAN-07 07.1 --dry-run)" || fail "relative-root (.) dry-run exit non-zero"
  grep -Fq -- "-s 'workspace-write' --add-dir '$R/.git' -C '.'" <<< "$out" || fail "a --root of . must print the absolute grant $R/.git (never ./.git): $out"
  out="$(cd "$d" && DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$self" --root repo PLAN-07 07.1 --dry-run)" || fail "relative-root (repo) dry-run exit non-zero"
  grep -Fq -- "--add-dir '$R/.git' -C 'repo'" <<< "$out" || fail "a --root of repo must print the absolute grant $R/.git (never repo/.git): $out"
  grep -Eq -- "--add-dir '[^/']" <<< "$out" && fail "a printed grant is not absolute: $out"
  [ "$(cd "$R" && git_write_dirs .)" = "$R/.git" ] || fail "git_write_dirs . from inside the repo should print $R/.git: $(cd "$R" && git_write_dirs .)"
  set +e; out="$(git_write_dirs "$d/nope" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "root '$d/nope' is not a directory that can be entered" <<< "$out" || fail "a root that does not exist should refuse naming it (rc=$rc): $out"
  grep -Fq 'rev-parse' <<< "$out" && fail "a missing root must be refused before git runs: $out"
  # a small-change task: plan-free prompt and log under tmp/bounded/
  mkdir -p "$R/tmp/bounded" && printf 'fix the spacing\n' > "$R/tmp/bounded/sidebar-spacing-prompt.md"
  out="$("$BASH" "$0" --root "$R" --bounded sidebar-spacing --dry-run)" || fail "bounded dry-run exit non-zero"
  grep -Fq "\"\$(printf '%s\\n' '[planner sidebar-spacing-c1]'; cat 'tmp/bounded/sidebar-spacing-prompt.md')\" < /dev/null >> 'tmp/bounded/sidebar-spacing-run.log' 2>&1" <<< "$out" || fail "bounded paths differ: $out"
  out="$("$BASH" "$0" --root "$R" --bounded sidebar-spacing --sandbox workspace-write --dry-run)" || fail "bounded workspace-write dry-run exit non-zero"
  grep -Fq -- "--add-dir '$R/.git' -C '$R' \"\$(printf '%s\\n' '[planner sidebar-spacing-c1]'; cat 'tmp/bounded/sidebar-spacing-prompt.md')\"" <<< "$out" && [ "$(grep -c . <<< "$out")" -eq 1 ] || fail "a bounded workspace-write dry-run should print the one command line with the git-dir grant: $out"
  set +e; "$BASH" "$0" --root "$R" --bounded 'bad slug' --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "a bounded slug with a space should be refused with 64 (got $rc)"
  set +e; "$BASH" "$0" --root "$R" PLAN-07 --bounded x --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "--bounded with a PLAN-NN should be refused with 64 (got $rc)"
  # EVO-81: a tmp/ that cannot be written means the build lock can never be made — exit 2 within seconds, naming the lock, nothing
  # launched (the old lock_take read the missing lock as "free" and called itself forever). Bounded by a timeout so a regression fails, never hangs
  if [ "$(id -u)" -ne 0 ]; then
    printf 'do stage 07.9\n' > "$R/tmp/PLAN-07/07.9-prompt.md"
    chmod 555 "$R/tmp"
    set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv81" "$tb" 20 "$BASH" "$0" --root "$R" PLAN-07 07.9 --no-preflight 2>&1)"; rc=$?; set -e
    chmod 755 "$R/tmp"
    [ "$rc" -eq 2 ] && grep -Fq "cannot make the run lock $R/tmp/.run-lock" <<< "$out" && [ ! -e "$d/argv81" ] && [ ! -e "$R/tmp/.run-lock" ] \
      || fail "EVO-81: an unwritable tmp/ should exit 2 naming the lock, nothing launched (rc=$rc): $(tail -n 3 <<< "$out")"
    rm -f "$R/tmp/PLAN-07/07.9-prompt.md" "$R/tmp/PLAN-07/07.9-run.log" "$R/tmp/PLAN-07/07.9-binding"
  fi
  # a real launch under workspace-write in a repo path WITH A SPACE passes --add-dir as one argument
  mkdir -p "$d/sp ace/tmp/PLAN-07"; ( cd "$d/sp ace" && git init -q && git config user.email t@t && git config user.name t && printf 'x\n' > a.txt && printf 'tmp/\n' > .gitignore && git add a.txt .gitignore && git commit -qm init )
  printf 'go\n' > "$d/sp ace/tmp/PLAN-07/07.1-prompt.md"
  sp_before="$(git -C "$d/sp ace" rev-parse --short HEAD)"
  # K2: the dry-run quotes the path with a space, and the printed line PASTED BACK (eval in the repo, fake codex on PATH) yields the same argv as the real launch below
  out="$(DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$d/sp ace" PLAN-07 07.1 --dry-run)" || fail "space-path dry-run exit non-zero"
  grep -Fq -- "--add-dir '$d/sp ace/.git' -C '$d/sp ace' \"\$(printf '%s\\n' '[planner 07.1-c1]'; cat 'tmp/PLAN-07/07.1-prompt.md')\"" <<< "$out" || fail "the dry-run did not quote the path with a space: $out"
  line="$(sed -n '1p' <<< "$out")"
  set +e; ( cd "$d/sp ace" && export RATCHET_ALLOW_PUSH=1 && PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv2p" eval "$line" ); set -e   # pasted into a shell that EXPORTED the push key: the printed line must strip it too
  [ -e "$d/argv2p" ] || fail "the pasted dry-run line did not reach the fake codex"
  grep -Fxq 'PUSH_KEY=unset' "$d/sp ace/tmp/PLAN-07/07.1-run.log" || fail "the pasted dry-run line passed RATCHET_ALLOW_PUSH to the Executor: $(grep -F 'PUSH_KEY=' "$d/sp ace/tmp/PLAN-07/07.1-run.log")"
  rm -f "$d/sp ace/tmp/PLAN-07/07.1-run.log" "$d/sp ace/created-by-codex.txt"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv2" DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$d/sp ace" PLAN-07 07.1 2>&1 >/dev/null)"; set -e
  grep -Fxq -- "$d/sp ace/.git" "$d/argv2" || fail "--add-dir path with a space was split: $(cat "$d/argv2")"
  grep -Fxq -- '--add-dir' "$d/argv2" || fail "--add-dir missing under workspace-write"
  cmp -s "$d/argv2p" "$d/argv2" || fail "the pasted dry-run line and the real launch built different argv: $(cat "$d/argv2p") vs $(cat "$d/argv2")"
  # the executor's grants are the worktree's git dirs only: one --add-dir (the repo's .git), never a reviewer's state dir or a network grant
  [ "$(grep -cx -- '--add-dir' "$d/argv2")" -eq 1 ] || fail "workspace-write must add exactly one --add-dir: $(cat "$d/argv2")"
  grep -Eq '\.codex|network_access' "$d/argv2" && fail "the executor's argv must carry the git-dir grants only, never a state dir or a network grant: $(cat "$d/argv2")"
  # a real workspace-write launch prints no layer1 line and no review reminder on stderr, and the log's line 1 is the header with the pre-run HEAD and no layer1 token
  grep -Eq 'layer1|--review' <<< "$out" && fail "a real workspace-write launch still prints a layer1 line or a review reminder on stderr: $out"
  head -n 1 "$d/sp ace/tmp/PLAN-07/07.1-run.log" | grep -Eq "^# drive-stage: before=$sp_before sandbox=workspace-write started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
    || fail "workspace-write run log header differs: $(head -n 1 "$d/sp ace/tmp/PLAN-07/07.1-run.log")"
  # a LINKED worktree (git worktree add — a parallel stream): <wt>/.git is a pointer FILE, so the grant is the worktree's git dir under
  # <main>/.git/worktrees/ AND the common dir <main>/.git, both resolved through git (never assumed from the root); the dry-run prints
  # exactly the argv the real launch passes; a git failure resolving them is a refusal with nothing written or launched
  WT="$d/wt"; git -C "$R" worktree add "$WT" -b wt-probe >/dev/null 2>&1 || fail "fixture: git worktree add failed"
  mkdir -p "$WT/tmp/PLAN-07" && printf 'go\n' > "$WT/tmp/PLAN-07/07.1-prompt.md"
  wt_gd="$(git -C "$WT" rev-parse --git-dir)"; wt_cd="$(git -C "$WT" rev-parse --git-common-dir)"
  [ -f "$WT/.git" ] || fail "fixture: a linked worktree's .git should be a pointer file"
  case "$wt_gd" in /*/.git/worktrees/wt) ;; *) fail "fixture: the linked worktree's git dir should be absolute, under .git/worktrees/: $wt_gd" ;; esac
  [ "$wt_cd" = "$(cd "$R" && pwd -P)/.git" ] || fail "fixture: the common dir should be the main repo's .git: $wt_cd"
  out="$(DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$WT" PLAN-07 07.1 --dry-run)" || fail "linked-worktree dry-run exit non-zero"
  grep -Fq -- "-s 'workspace-write' --add-dir '$wt_gd' --add-dir '$wt_cd' -C '$WT'" <<< "$out" || fail "a linked worktree's dry-run should grant its git dir (.git/worktrees/<name>) and the main repo's .git: $out"
  grep -Fq -- "--add-dir '$WT/.git'" <<< "$out" && fail "a linked worktree's .git pointer file must not be the grant: $out"
  line="$(sed -n '1p' <<< "$out")"
  set +e; ( cd "$WT" && PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv2wp" eval "$line" ); set -e
  [ -e "$d/argv2wp" ] || fail "the pasted linked-worktree dry-run line did not reach the fake codex"
  rm -f "$WT/tmp/PLAN-07/07.1-run.log" "$WT/created-by-codex.txt"
  set +e; PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv2w" DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$WT" PLAN-07 07.1 >/dev/null 2>&1; set -e
  [ -e "$d/argv2w" ] || fail "the real linked-worktree launch did not reach the fake codex"
  [ "$(grep -cx -- '--add-dir' "$d/argv2w")" -eq 2 ] || fail "a linked worktree must get exactly two --add-dir (its git dir and the common dir): $(cat "$d/argv2w")"
  grep -Fxq -- "$wt_gd" "$d/argv2w" && grep -Fxq -- "$wt_cd" "$d/argv2w" || fail "the real launch's argv should carry the worktree's git dir and the common dir: $(cat "$d/argv2w")"
  grep -Fxq -- "$WT/.git" "$d/argv2w" && fail "the real launch granted the pointer file instead of the git dirs: $(cat "$d/argv2w")"
  cmp -s "$d/argv2wp" "$d/argv2w" || fail "the pasted linked-worktree dry-run line and the real launch built different argv: $(cat "$d/argv2wp") vs $(cat "$d/argv2w")"
  grep -Eq '\.codex|network_access' "$d/argv2w" && fail "the executor's argv must carry the git-dir grants only, never a state dir or a network grant: $(cat "$d/argv2w")"
  rm -f "$WT/tmp/PLAN-07/07.1-run.log" "$WT/created-by-codex.txt"
  for injected in 'rev-parse --git-dir' 'rev-parse --git-common-dir'; do
    set +e; out="$(PATH="$d/fakegit:$d/bin:$PATH" FAKE_GIT_FAIL="$injected" FAKE_ARGV="$d/argv2wf" DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$WT" PLAN-07 07.1 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 1 ] && [ ! -e "$d/argv2wf" ] && [ ! -e "$WT/tmp/PLAN-07/07.1-run.log" ] && grep -Fq "git $injected failed in $WT (exit 73)" <<< "$out" || fail "a failing git $injected did not refuse the launch cleanly (rc=$rc): $out"
    set +e; out="$(PATH="$d/fakegit:$PATH" FAKE_GIT_FAIL="$injected" DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$WT" PLAN-07 07.1 --dry-run 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 1 ] && grep -Fq "git $injected failed" <<< "$out" || fail "a failing git $injected should refuse the dry-run too, never print an assumed grant (rc=$rc): $out"
  done
  git -C "$R" worktree remove --force "$WT" >/dev/null 2>&1 || fail "fixture: git worktree remove failed"
  # refusal: missing prompt
  if "$BASH" "$0" --root "$R" PLAN-07 07.2 --dry-run >/dev/null 2>&1; then fail "missing prompt did not refuse"; fi
  # real launch through the fake codex, with data on stdin to prove the < /dev/null redirect
  set +e
  out="$(printf 'tty-data\n' | RATCHET_ALLOW_PUSH=1 PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv" "$BASH" "$0" --root "$R" PLAN-07 07.1 2>&1)"; rc=$?   # the push key exported into the launch: it must not reach the Executor
  set -e
  [ "$rc" -eq 3 ] || fail "launch should exit with codex's status 3 (got $rc): $out"
  grep -Fxq 'PUSH_KEY=unset' "$R/tmp/PLAN-07/07.1-run.log" || fail "RATCHET_ALLOW_PUSH reached the Executor: $(grep -F 'PUSH_KEY=' "$R/tmp/PLAN-07/07.1-run.log")"
  head="$(git -C "$R" rev-parse --short HEAD)"
  [ "$out" = "PLAN-07 07.1 exit=3 log=tmp/PLAN-07/07.1-run.log head=$head changed=1 commit=none session=none rollout=none" ] || fail "result line differs: $out"
  grep -Fxq 'hello from fake codex' "$R/tmp/PLAN-07/07.1-run.log" || fail "transcript not captured in the log"
  grep -Fxq 'STDIN_EMPTY' "$R/tmp/PLAN-07/07.1-run.log" || fail "stdin was not /dev/null: $(cat "$R/tmp/PLAN-07/07.1-run.log")"
  # line 1 is the header (before= is the pre-run HEAD; no layer1 token), codex's output from line 2
  head -n 1 "$R/tmp/PLAN-07/07.1-run.log" | grep -Eq "^# drive-stage: before=$head sandbox=danger-full-access started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
    || fail "run log header differs: $(head -n 1 "$R/tmp/PLAN-07/07.1-run.log")"
  [ "$(sed -n '2p' "$R/tmp/PLAN-07/07.1-run.log")" = "STDIN_EMPTY" ] || fail "codex's output should start on line 2: $(sed -n '1,3p' "$R/tmp/PLAN-07/07.1-run.log")"
  want="$(printf 'exec\n-m\nfake-model-1\n-c\nmodel_reasoning_effort=%s\n-s\ndanger-full-access\n-C\n%s\n[planner 07.1-c1]\ndo stage 07.1\n' "$CODEX_REASONING" "$R")"   # the prompt is the tag line, then the file
  [ "$(cat "$d/argv")" = "$want" ] || fail "codex argv differs: $(cat "$d/argv")"
  # refusal: log exists; --again picks -r2
  if "$BASH" "$0" --root "$R" PLAN-07 07.1 --dry-run >/dev/null 2>&1; then fail "existing log did not refuse"; fi
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --again --dry-run)" || fail "--again dry-run exit non-zero"
  grep -Fq ">> 'tmp/PLAN-07/07.1-run-r2.log' 2>&1" <<< "$out" || fail "--again did not pick -r2: $out"
  # K1: a git failure BEFORE the launch is a refusal with nothing launched; one AFTER the run is exit 2 naming codex's status and the transcript — never a result line with a wrong count
  set +e; out="$(PATH="$d/fakegit:$d/bin:$PATH" FAKE_GIT_FAIL='rev-parse --short HEAD' FAKE_ARGV="$d/argv9" "$BASH" "$0" --root "$R" PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/argv9" ] && [ ! -e "$R/tmp/PLAN-07/07.1-run-r2.log" ] && grep -Fq 'rev-parse HEAD failed' <<< "$out" || fail "a pre-launch git failure did not refuse cleanly (rc=$rc): $out"
  for injected in 'diff --name-only' 'ls-files --others'; do
    n_before="$(count_logs "$R/tmp/PLAN-07" run-r)"
    set +e; out="$(PATH="$d/fakegit:$d/bin:$PATH" FAKE_GIT_FAIL="$injected" FAKE_GIT_FAIL_RC=41 FAKE_ARGV="$d/argv9" "$BASH" "$0" --root "$R" PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 2 ] || fail "a post-run git failure ($injected) should exit 2 (got $rc): $out"
    grep -Fq "git $injected" <<< "$out" && grep -Fq 'codex exit=3' <<< "$out" && grep -Fq 'transcript at tmp/PLAN-07/07.1-run-r' <<< "$out" || fail "the post-run failure message should name the git call, codex's status, and the transcript: $out"
    grep -Fq 'changed=' <<< "$out" && fail "a post-run git failure must not print a result line: $out"
    n_after="$(count_logs "$R/tmp/PLAN-07" run-r)"
    [ "$n_after" -eq $((n_before + 1)) ] && grep -Fxq 'hello from fake codex' "$R/tmp/PLAN-07/07.1-run-r$((n_before + 2)).log" || fail "the transcript of the failed-footprint run ($injected) was not kept"
    rm -f "$d/argv9"
  done
  # K5: the count's own tools — grep -c exiting 2 (never changed=0), sort failing — are exit 2 naming the tool, the transcript kept, no result line
  for tool in grep sort; do
    n_before="$(count_logs "$R/tmp/PLAN-07" run-r)"
    case "$tool" in
      grep) set +e; out="$(PATH="$d/fakegrep:$d/bin:$PATH" FAKE_GREP_FAIL=-c FAKE_ARGV="$d/argv9" "$BASH" "$0" --root "$R" PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e; want='grep -c failed (exit 2)' ;;
      sort) set +e; out="$(PATH="$d/fakesort:$d/bin:$PATH" FAKE_SORT_RC=73 FAKE_ARGV="$d/argv9" "$BASH" "$0" --root "$R" PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e; want='sort -u failed (exit 73)' ;;
    esac
    [ "$rc" -eq 2 ] && grep -Fq "$want" <<< "$out" && grep -Fq 'codex exit=3' <<< "$out" || fail "a $tool failure counting the changed paths should exit 2 naming it (rc=$rc): $out"
    grep -Fq 'changed=' <<< "$out" && fail "a $tool failure must not print a result line: $out"
    [ "$(count_logs "$R/tmp/PLAN-07" run-r)" -eq $((n_before + 1)) ] || fail "the transcript of the failed-count run ($tool) was not kept"
    rm -f "$d/argv9"
  done
  # K6: an unreadable prompt (cat exit 73; chmod 000 where not root) or an empty prompt is a refusal BEFORE the header — no log, no launch
  printf 'stage 07.3\n' > "$R/tmp/PLAN-07/07.3-prompt.md"
  set +e; out="$(PATH="$d/fakecat:$d/bin:$PATH" FAKE_CAT_FAIL="$R/tmp/PLAN-07/07.3-prompt.md" FAKE_ARGV="$d/argv10" "$BASH" "$0" --root "$R" PLAN-07 07.3 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'cannot read the prompt tmp/PLAN-07/07.3-prompt.md (cat exit 73)' <<< "$out" || fail "an unreadable prompt did not refuse (rc=$rc): $out"
  [ ! -e "$R/tmp/PLAN-07/07.3-run.log" ] && [ ! -e "$d/argv10" ] || fail "an unreadable prompt still wrote a header or launched"
  if [ "$(id -u)" -ne 0 ]; then
    chmod 000 "$R/tmp/PLAN-07/07.3-prompt.md"
    set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv10" "$BASH" "$0" --root "$R" PLAN-07 07.3 2>&1)"; rc=$?; set -e
    chmod 644 "$R/tmp/PLAN-07/07.3-prompt.md"
    [ "$rc" -eq 1 ] && grep -Fq 'cannot read the prompt' <<< "$out" || fail "a mode-000 prompt did not refuse (rc=$rc): $out"
    [ ! -e "$R/tmp/PLAN-07/07.3-run.log" ] && [ ! -e "$d/argv10" ] || fail "a mode-000 prompt still wrote a header or launched"
  fi
  : > "$R/tmp/PLAN-07/07.4-prompt.md"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv10" "$BASH" "$0" --root "$R" PLAN-07 07.4 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'is empty' <<< "$out" && [ ! -e "$R/tmp/PLAN-07/07.4-run.log" ] && [ ! -e "$d/argv10" ] || fail "an empty prompt did not refuse before the header (rc=$rc): $out"
  # --review, the review of a committed range as its own read-only invocation. Refusals first: an EDIT-ME mandate, a missing mandate file, no run log / no header and no --base (both remedies named), a bogus --base
  set +e; out="$(DRIVE_STAGE_REVIEW_MANDATE=.codex/agents/EDIT-ME-reviewer.toml "$BASH" "$0" --root "$R" --review PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'EDIT-ME' <<< "$out" || fail "an EDIT-ME mandate did not refuse --review (rc=$rc): $out"
  export DRIVE_STAGE_REVIEW_MANDATE=.codex/agents/t-reviewer.toml
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'mandate missing' <<< "$out" || fail "a missing mandate file did not refuse --review (rc=$rc): $out"
  mkdir -p "$R/.codex/agents" && printf 'developer_instructions = "review"\n' > "$R/.codex/agents/t-reviewer.toml"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.9 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'run the stage first' <<< "$out" && grep -Fq -- '--base' <<< "$out" || fail "no run log should refuse naming both remedies (rc=$rc): $out"
  printf 'no header here\n' > "$R/tmp/PLAN-07/07.8-run.log"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.8 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'no drive-stage header' <<< "$out" && grep -Fq -- '--base' <<< "$out" || fail "a header-less run log should refuse naming both remedies (rc=$rc): $out"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --base deadbeef 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'not a commit in this repo (git rev-parse --verify exit 1)' <<< "$out" || fail "a bogus --base should refuse as 'not a commit' with git's status (rc=$rc): $out"
  # K9: git itself failing on the --verify (exit 128) is named as a git failure with its status, not as "not a commit" — for the base and for HEAD
  set +e; out="$(PATH="$d/fakegit:$PATH" FAKE_GIT_FAIL='rev-parse --verify --quiet' FAKE_GIT_FAIL_RC=128 "$BASH" "$0" --root "$R" --review PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'git rev-parse --verify' <<< "$out" && grep -Fq 'failed (exit 128)' <<< "$out" || fail "a failing rev-parse --verify on the base should be named with its status (rc=$rc): $out"
  grep -Fq 'not a commit' <<< "$out" && fail "a git failure must not be reported as 'not a commit': $out"
  set +e; out="$(PATH="$d/fakegit:$PATH" FAKE_GIT_FAIL='rev-parse --verify --quiet HEAD^{commit}' FAKE_GIT_FAIL_RC=128 "$BASH" "$0" --root "$R" --review PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'git rev-parse --verify HEAD failed (exit 128)' <<< "$out" || fail "a failing rev-parse --verify on HEAD should be named with its status (rc=$rc): $out"
  # the fake stage committed nothing, so HEAD is still the header's before=: a review reads a COMMITTED range — refused (the dry-run and the real
  # review alike), naming both remedies, with nothing launched and no log (0.17's uncommitted-tree scope is retired)
  before="$(sed -n '1s/^# drive-stage: before=\([0-9a-f]*\) .*/\1/p' "$R/tmp/PLAN-07/07.1-run.log")"
  [ "$before" = "$head" ] || fail "the header's before= should be the pre-run HEAD $head: $before"
  for mode in --dry-run --no-preflight; do
    set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv3n" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 "$mode" 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 1 ] && grep -Fq "base equals head ($before): the range is empty and a review reads a committed range" <<< "$out" || fail "--review $mode with HEAD at the base should refuse (rc=$rc): $out"
    grep -Fq 'commit the Stage first, or pass --base <sha> for an earlier base' <<< "$out" || fail "the nothing-committed refusal should name both remedies: $out"
    grep -Eq 'review exit=|codex exec' <<< "$out" && fail "a refused review must print no result line and no command: $out"
    [ ! -e "$d/argv3n" ] && [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq 0 ] || fail "a refused review ($mode) still reached codex or left a log behind"
  done
  # the stage commits: the scope is the range before..head, as the two full shas, and the prompt TELLS the reviewer to run the diff (a custom
  # prompt and the CLI's diff selectors are mutually exclusive, so naming the range alone left it unread); codex's status is the exit status
  ( cd "$R" && git add -A && git commit -qm 'PLAN-07 / 07.1' )
  newhead="$(git -C "$R" rev-parse --short HEAD)"; beforefull="$(git -C "$R" rev-parse "$before")"; newheadfull="$(git -C "$R" rev-parse HEAD)"
  want_scope="ONLY the committed range $beforefull..$newheadfull — run 'git diff $beforefull..$newheadfull' (and 'git log --oneline $beforefull..$newheadfull') and review exactly that — "
  # K2: the --review dry-run pastes back to the same argv as the real review (the prompt carries apostrophes); the argv is exactly `exec -C <root> review <prompt>` — no -s, no --add-dir; stdin is /dev/null
  line="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --dry-run)" || fail "--review dry-run exit non-zero"
  grep -Fq "git diff $beforefull..$newheadfull" <<< "$line" && grep -Fq "git log --oneline $beforefull..$newheadfull" <<< "$line" || fail "the --review dry-run's prompt should tell the reviewer to run git diff (and git log) over the two full shas: $line"
  set +e; ( cd "$R" && PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv3p" eval "$line" ); set -e
  [ -e "$d/argv3p" ] && grep -Fxq 'PASS' "$R/tmp/PLAN-07/07.1-L1.log" || fail "the pasted --review dry-run line did not reach the fake codex: $line"
  rm -f "$R/tmp/PLAN-07/07.1-L1.log" "$R/tmp/PLAN-07/07.1-L1-verdict.md"
  set +e; out="$(printf 'tty-data\n' | PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv3" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "--review should exit with codex's status 0 (got $rc): $out"
  cmp -s "$d/argv3p" "$d/argv3" || fail "the pasted --review dry-run and the real review built different argv: $(cat "$d/argv3p") vs $(cat "$d/argv3")"
  [ "$out" = "PLAN-07 07.1 review exit=0 log=tmp/PLAN-07/07.1-L1.log verdict=tmp/PLAN-07/07.1-L1-verdict.md scope=$before..$newhead" ] || fail "review result line differs: $out"
  grep -Fxq 'PASS — the final message' "$R/tmp/PLAN-07/07.1-L1-verdict.md" || fail "the review's final message was not written to its verdict file (-o)"
  grep -Fxq 'PASS' "$R/tmp/PLAN-07/07.1-L1.log" || fail "the verdict is not in the review's log: $(cat "$R/tmp/PLAN-07/07.1-L1.log")"
  grep -Fxq 'STDIN_EMPTY' "$R/tmp/PLAN-07/07.1-L1.log" || fail "review stdin was not /dev/null: $(cat "$R/tmp/PLAN-07/07.1-L1.log")"
  # exactly `exec -C <root> review -m <review model> -c model_reasoning_effort=<review reasoning> -o <abs verdict> <prompt>`: the REVIEW pin, never the builder's
  [ "$(sed -n '1,10p' "$d/argv3")" = "$(printf 'exec\n-C\n%s\nreview\n-m\nfake-review-1\n-c\nmodel_reasoning_effort=xhigh\n-o\n%s/tmp/PLAN-07/07.1-L1-verdict.md' "$R" "$R")" ] || fail "review argv differs (the review pin and -o on the subcommand): $(cat "$d/argv3")"
  [ "$(grep -c . "$d/argv3")" -eq 11 ] || fail "review argv should be exactly exec -C <root> review -m -c -o <prompt>: $(cat "$d/argv3")"
  grep -Fxq 'fake-model-1' "$d/argv3" && fail "the review ran under the BUILDER's pin: $(cat "$d/argv3")"
  rp="$(sed -n '11p' "$d/argv3")"
  grep -Fq 'mandate in .codex/agents/t-reviewer.toml' <<< "$rp" || fail "review prompt lacks the mandate path: $rp"
  grep -Fq "${want_scope}PLAN-07 Stage 07.1" <<< "$rp" || fail "review prompt should carry the full-sha range and the git diff instruction: $rp"
  grep -Fqi 'uncommitted' <<< "$rp" && fail "the review prompt must not name an uncommitted scope: $rp"
  grep -Fq 'PASS or ISSUES (n findings)' <<< "$rp" || fail "review prompt lacks the verdict shape: $rp"
  grep -Fxq -- '-s' "$d/argv3" && fail "the review must never carry -s: $(cat "$d/argv3")"
  grep -Fxq -- '--add-dir' "$d/argv3" && fail "the review must never carry --add-dir: $(cat "$d/argv3")"
  # a second --review refuses; --again picks -L1-r2 (the dry-run prints the command and exits 0), and the real --again review writes it
  if "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --dry-run >/dev/null 2>&1; then fail "an existing review log did not refuse"; fi
  out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again --dry-run)" || fail "--review --again dry-run exit non-zero"
  [ "$out" = "$tb $TIMEOUT_NORMAL codex exec -C '$R' review -m 'fake-review-1' -c 'model_reasoning_effort=xhigh' -o '$R/tmp/PLAN-07/07.1-L1-r2-verdict.md' '$(printf '%s' "$rp" | sed "s/'/'\\\\''/g")' < /dev/null > 'tmp/PLAN-07/07.1-L1-r2.log' 2>&1" ] || fail "--review dry-run differs: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv4" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$out" = "PLAN-07 07.1 review exit=0 log=tmp/PLAN-07/07.1-L1-r2.log verdict=tmp/PLAN-07/07.1-L1-r2-verdict.md scope=$before..$newhead" ] || fail "committed-range review result line differs (rc=$rc): $out"
  grep -Fq "${want_scope}PLAN-07 Stage 07.1" "$d/argv4" || fail "review prompt should carry the full-sha range and the git diff instruction: $(cat "$d/argv4")"
  grep -Fxq 'PASS' "$R/tmp/PLAN-07/07.1-L1-r2.log" || fail "the -r2 verdict is not in its log"
  # the review's base is line 1's `before=` under BOTH header generations — this launcher's (`sandbox= started=`) and an older one's, which also
  # carried `layer1=<nested|external>` — through the helper and through --review; a header whose before= is empty is refused naming both remedies
  printf '# drive-stage: before=%s sandbox=danger-full-access started=2026-09-21T00:00:00Z\nbody\n' "$before" > "$R/tmp/PLAN-07/07.5-run.log"
  printf '# drive-stage: before=%s sandbox=danger-full-access layer1=nested started=2026-09-09T00:00:00Z\nbody\n' "$before" > "$R/tmp/PLAN-07/07.6-run.log"
  printf '# drive-stage: before=%s sandbox=workspace-write layer1=external started=2026-09-09T00:00:00Z\nbody\n' "$before" > "$R/tmp/PLAN-07/07.7-run.log"
  for st in 07.5 07.6 07.7; do
    got="$(review_base "$R" "tmp/PLAN-07/$st-run.log" "")" || fail "review_base refused the header in $st-run.log: $(head -n 1 "$R/tmp/PLAN-07/$st-run.log")"
    [ "$got" = "$beforefull" ] || fail "review_base should read before= as $beforefull from '$(head -n 1 "$R/tmp/PLAN-07/$st-run.log")': $got"
    out="$("$BASH" "$0" --root "$R" --review PLAN-07 "$st" --dry-run)" || fail "--review dry-run over the $st header exit non-zero"
    grep -Fq "ONLY the committed range $beforefull..$newheadfull — run " <<< "$out" && grep -Fq "git diff $beforefull..$newheadfull" <<< "$out" && grep -Fq "review exactly that — PLAN-07 Stage $st" <<< "$out" || fail "--review should scope the range from the $st header's before=: $out"
  done
  printf '# drive-stage: before= sandbox=danger-full-access started=2026-09-21T00:00:00Z\nbody\n' > "$R/tmp/PLAN-07/07.11-run.log"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.11 --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'names no before= sha' <<< "$out" && grep -Fq -- '--base' <<< "$out" || fail "a header with an empty before= should refuse naming both remedies (rc=$rc): $out"
  # a stage the Planner built has no launcher run log: --base alone is the base (no run log is needed when it is given), and without it the refusal still names both remedies
  [ ! -e "$R/tmp/PLAN-07/07.12-run.log" ] || fail "fixture: 07.12 should have no run log"
  out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.12 --base "$before" --dry-run)" || fail "--review --base with no run log should not refuse"
  grep -Fq "ONLY the committed range $beforefull..$newheadfull — run " <<< "$out" && grep -Fq "git diff $beforefull..$newheadfull" <<< "$out" && grep -Fq "review exactly that — PLAN-07 Stage 07.12" <<< "$out" && grep -Fq "> 'tmp/PLAN-07/07.12-L1.log' 2>&1" <<< "$out" || fail "--review --base with no run log should scope the range from --base and name the review's log: $out"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.12 --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'no run log' <<< "$out" && grep -Fq -- '--base' <<< "$out" || fail "--review with no run log and no --base should refuse naming --base (rc=$rc): $out"
  # the built-in prompt asks for the Verify: blocks where the plan has them and never calls them frozen (before the freeze they are not)
  grep -Fq "Re-prove the Stage's Verify: blocks where the plan has them" "$d/argv4" || fail "review prompt lacks the Verify: instruction: $(cat "$d/argv4")"
  grep -Fqi 'frozen' "$d/argv4" && fail "the review prompt must not call the Verify: blocks frozen: $(cat "$d/argv4")"
  # K1: the display shortening of the BASE fails while HEAD's succeeds → a refusal, nothing launched, no log — never a review scoped `..<head>`
  n_before="$(count_logs "$R/tmp/PLAN-07" L1)"
  set +e; out="$(PATH="$d/fakegit:$d/bin:$PATH" FAKE_GIT_FAIL="rev-parse --short $beforefull" FAKE_ARGV="$d/argv7" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/argv7" ] && grep -Fq "rev-parse --short $beforefull failed (exit 73)" <<< "$out" || fail "a failed base shortening did not refuse (rc=$rc): $out"
  grep -Fq 'review exit=' <<< "$out" && fail "a failed base shortening must not print a result line: $out"
  [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "a refused review left a log behind"
  # --base overrides the header: 07.1's header would give a range, but a --base that IS HEAD refuses, nothing launched, no log
  n_before="$(count_logs "$R/tmp/PLAN-07" L1)"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv5" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --base "$newhead" --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "base equals head ($newhead)" <<< "$out" || fail "--base at HEAD should override the header and refuse (rc=$rc): $out"
  [ ! -e "$d/argv5" ] && [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "a --base at HEAD still reached codex or left a log behind"
  # … and the other way on ONE tree: a run log whose header's before= IS HEAD refuses; the same stage with an explicit earlier --base is reviewed
  printf '# drive-stage: before=%s sandbox=danger-full-access started=2026-09-21T00:00:00Z\nbody\n' "$newhead" > "$R/tmp/PLAN-07/07.13-run.log"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv5" "$BASH" "$0" --root "$R" --review PLAN-07 07.13 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "base equals head ($newhead)" <<< "$out" && [ ! -e "$d/argv5" ] && [ ! -e "$R/tmp/PLAN-07/07.13-L1.log" ] || fail "a header whose before= is HEAD should refuse with nothing launched (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv5" "$BASH" "$0" --root "$R" --review PLAN-07 07.13 --base "$before" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$out" = "PLAN-07 07.13 review exit=0 log=tmp/PLAN-07/07.13-L1.log verdict=tmp/PLAN-07/07.13-L1-verdict.md scope=$before..$newhead" ] || fail "an explicit earlier --base on the same tree should be reviewed (rc=$rc): $out"
  grep -Fq "${want_scope}PLAN-07 Stage 07.13" "$d/argv5" && grep -Fxq 'PASS' "$R/tmp/PLAN-07/07.13-L1.log" || fail "the earlier---base review should carry the range and the git diff instruction: $(cat "$d/argv5")"
  set +e; PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv6" FAKE_REVIEW_RC=124 "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 124 ] || fail "--review should exit with codex's status 124 (got $rc)"
  # --head names the END of the range (default: the current HEAD). A later Stage lands — two commits after the base — and the read of 07.1 must not include it:
  # --head <07.1's commit> scopes exactly base..first (the prompt's diff instruction, the dry-run, and scope=); no --head still ends at the current HEAD
  ( cd "$R" && printf 'y\n' > b.txt && git add b.txt && git commit -qm 'PLAN-07 / 07.2' )
  head2="$(git -C "$R" rev-parse --short HEAD)"; head2full="$(git -C "$R" rev-parse HEAD)"
  [ "$head2full" != "$newheadfull" ] || fail "fixture: the second stage commit did not move HEAD"
  out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --head "$newhead" --again --dry-run)" || fail "--review --head dry-run exit non-zero"
  grep -Fq "git diff $beforefull..$newheadfull" <<< "$out" && grep -Fq "git log --oneline $beforefull..$newheadfull" <<< "$out" || fail "--head should end the dry-run's range at the named commit: $out"
  grep -Fq "$head2full" <<< "$out" && fail "--head <first> must keep the later Stage's commit out of the prompt: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv8" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --head "$newhead" --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq "^PLAN-07 07\.1 review exit=0 log=tmp/PLAN-07/07\.1-L1-r[0-9]+\.log verdict=tmp/PLAN-07/07\.1-L1-r[0-9]+-verdict\.md scope=$before\.\.$newhead\$" <<< "$out" || fail "--head <first> should scope the result line base..first (rc=$rc): $out"
  grep -Fq "${want_scope}PLAN-07 Stage 07.1" "$d/argv8" || fail "--head <first> should carry exactly base..first into the prompt: $(cat "$d/argv8")"
  grep -Fq "$head2full" "$d/argv8" && fail "--head <first> leaked the later Stage's commit into the prompt: $(cat "$d/argv8")"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv8d" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq " scope=$before\.\.$head2\$" <<< "$out" && grep -Fq "run 'git diff $beforefull..$head2full'" "$d/argv8d" || fail "no --head should still end the range at the current HEAD (rc=$rc): $out"
  # refusals, each with nothing launched and no log: a --head that is not a commit; a --head equal to the base; a base that is not an ancestor of the head
  # (the two reversed, and a sibling commit off the base's line); git itself failing on the ancestry check is named as git failing, never as "not an ancestor"
  side="$(git -C "$R" commit-tree "$(git -C "$R" rev-parse "$before^{tree}")" -p "$beforefull" -m side)" || fail "fixture: git commit-tree failed"
  n_before="$(count_logs "$R/tmp/PLAN-07" L1)"
  refused() {   # $1 what, $2 the message's fixed text, $3… the --review arguments
    local what="$1" want="$2" o r; shift 2
    set +e; o="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argv8r" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again "$@" 2>&1)"; r=$?; set -e
    [ "$r" -eq 1 ] && grep -Fq "$want" <<< "$o" || fail "$what should refuse (rc=$r): $o"
    grep -Eq 'review exit=|codex exec' <<< "$o" && fail "$what must print no result line and no command: $o"
    [ ! -e "$d/argv8r" ] && [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "$what still reached codex or left a log behind"
  }
  refused "a bogus --head" "head 'deadbeef' is not a commit in this repo (git rev-parse --verify exit 1)" --head deadbeef
  refused "a bogus --head (dry-run)" "head 'deadbeef' is not a commit in this repo" --head deadbeef --dry-run
  refused "a --head equal to the base" "base equals head ($before)" --head "$before"
  refused "a --head that is an ancestor of the base" "base $newhead is not an ancestor of head $before" --base "$newhead" --head "$before"
  refused "a --head off the base's line" "base $newhead is not an ancestor of head $(git -C "$R" rev-parse --short "$side")" --base "$newhead" --head "$side"
  set +e; out="$(PATH="$d/fakegit:$d/bin:$PATH" FAKE_GIT_FAIL='merge-base --is-ancestor' FAKE_ARGV="$d/argv8r" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --head "$newhead" --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "git merge-base --is-ancestor $before $newhead failed (exit 73)" <<< "$out" && [ ! -e "$d/argv8r" ] || fail "a failing git merge-base should refuse naming git and its status (rc=$rc): $out"
  grep -Fq 'not an ancestor' <<< "$out" && fail "a git failure must not be reported as 'not an ancestor': $out"
  [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "a failed ancestry check left a log behind"
  # a sibling off the base's line IS reviewable from the base (an ancestor of it): the check is ancestry, not "on the current branch"
  out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --head "$side" --again --dry-run)" || fail "a --head descending from the base should be accepted"
  grep -Fq "git diff $beforefull..$side" <<< "$out" || fail "--head <sibling> should end the range at it: $out"
  # a stage flag on --review, --base or --head without --review, or an EMPTY --head (an unset variable would silently widen the range to HEAD) is a usage error
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --head "" --again --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 64 ] && grep -Fq 'EMPTY value' <<< "$out" || fail "an empty --head should be refused with 64 (got $rc): $out"
  set +e; out="$("$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again --dry-run --head 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 64 ] && grep -Fq -- '--head needs a <sha>' <<< "$out" || fail "a trailing --head with no value should be refused with 64 and a message (got $rc): $out"
  set +e; "$BASH" "$0" --root "$R" PLAN-07 07.1 --head "$newhead" --again --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "--head without --review should be refused with 64 (got $rc)"
  set +e; "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --heavy --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "--review --heavy should be refused with 64 (got $rc)"
  set +e; "$BASH" "$0" --root "$R" PLAN-07 07.1 --base "$newhead" --again --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "--base without --review should be refused with 64 (got $rc)"
  # the preflight smokes the pin each mode is about to use (a smoke with no -m once passed while the pin itself was refused): --preflight alone smokes
  # every filled pin; a refused review pin fails it and keeps a --review and a --read from launching; a stage's smoke is the builder's pin alone
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_SMOKE_ARGV="$d/smk1" "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq -- '-m fake-model-1 -c model_reasoning_effort=high -s read-only' "$d/smk1" && grep -Fq -- '-m fake-review-1 -c model_reasoning_effort=xhigh -s read-only' "$d/smk1" \
    && [ "$(grep -c . "$d/smk1")" -eq 2 ] || fail "--preflight should smoke both pins, each under its own -m and reasoning (rc=$rc): $out / $(cat "$d/smk1" 2>/dev/null)"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_REFUSE_MODEL=fake-review-1 "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'the smoke under the pin fake-review-1 (xhigh) did not complete' <<< "$out" || fail "a refused review pin should fail the preflight naming it (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" DRIVE_STAGE_MODEL=EDIT-ME FAKE_SMOKE_ARGV="$d/smk2" "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'the build pin is not filled' <<< "$out" && [ "$(grep -c . "$d/smk2")" -eq 1 ] && grep -Fq 'fake-review-1' "$d/smk2" || fail "a builder-less project's --preflight should smoke the review pin alone (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" DRIVE_STAGE_MODEL=EDIT-ME DRIVE_STAGE_REVIEW_MODEL=EDIT-ME "$BASH" "$0" --root "$R" --preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'no pin is filled' <<< "$out" || fail "--preflight with no pin filled should refuse (rc=$rc): $out"
  n_before="$(count_logs "$R/tmp/PLAN-07" L1)"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_REFUSE_MODEL=fake-review-1 FAKE_ARGV="$d/argvR" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/argvR" ] && [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "a refused review pin should keep --review from launching (rc=$rc): $out"
  set +e; out="$(PATH="$d/bin:$PATH" DRIVE_STAGE_REVIEW_REASONING=EDIT-ME FAKE_ARGV="$d/argvR" "$BASH" "$0" --root "$R" --review PLAN-07 07.1 --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'a review needs: CODEX_REVIEW_REASONING (still EDIT-ME)' <<< "$out" && [ ! -e "$d/argvR" ] && [ "$(count_logs "$R/tmp/PLAN-07" L1)" -eq "$n_before" ] || fail "an EDIT-ME review reasoning should refuse --review naming it (rc=$rc): $out"
  # --read: one read-only read under the REVIEW pin, the prompt file's text as the prompt; <name> is the basename less .md and -prompt; the final message is the verdict file
  line="$("$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --dry-run)" || fail "--read dry-run exit non-zero"
  [ "$line" = "$tb $TIMEOUT_NORMAL codex exec -m 'fake-review-1' -c 'model_reasoning_effort=xhigh' -s read-only -C '$R' -o '$R/tmp/PLAN-07/premise-read-verdict.md' \"\$(cat '$R/tmp/PLAN-07/premise-prompt.md')\" < /dev/null >> 'tmp/PLAN-07/premise-read.log' 2>&1   # the launcher writes the read-log header (line 1 of the log) first, then runs this" ] || fail "--read dry-run differs: $line"
  set +e; out="$(printf 'tty\n' | PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvD" FAKE_SMOKE_ARGV="$d/smk3" "$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$out" = "PLAN-07 read exit=0 log=tmp/PLAN-07/premise-read.log verdict=tmp/PLAN-07/premise-read-verdict.md head=$(git -C "$R" rev-parse --short HEAD)" ] || fail "--read result line differs (rc=$rc): $out"
  [ "$(cat "$d/argvD")" = "$(printf 'exec\n-m\nfake-review-1\n-c\nmodel_reasoning_effort=xhigh\n-s\nread-only\n-C\n%s\n-o\n%s/tmp/PLAN-07/premise-read-verdict.md\nread the draft' "$R" "$R")" ] || fail "--read argv differs: $(cat "$d/argvD")"
  grep -Fxq 'STDIN_EMPTY' "$R/tmp/PLAN-07/premise-read.log" && grep -Fxq 'PASS — the final message' "$R/tmp/PLAN-07/premise-read-verdict.md" || fail "--read should run with stdin at /dev/null and write the verdict file"
  head -n 1 "$R/tmp/PLAN-07/premise-read.log" | grep -Eq "^# drive-stage: read head=$(git -C "$R" rev-parse HEAD) model=fake-review-1 started=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\$" \
    && [ "$(sed -n 2p "$R/tmp/PLAN-07/premise-read.log")" = STDIN_EMPTY ] || fail "--read's log should open with the header, the transcript after it: $(head -n 2 "$R/tmp/PLAN-07/premise-read.log")"
  [ "$(grep -c . "$d/smk3")" -eq 1 ] && grep -Fq 'fake-review-1' "$d/smk3" || fail "--read's preflight should smoke the review pin alone: $(cat "$d/smk3")"
  set +e; "$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --dry-run >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 1 ] || fail "an existing read log should refuse without --again (got $rc)"
  out="$("$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --again --dry-run)" && grep -Fq -- "-o '$R/tmp/PLAN-07/premise-read-r2-verdict.md'" <<< "$out" && grep -Fq ">> 'tmp/PLAN-07/premise-read-r2.log'" <<< "$out" || fail "--read --again should pick -read-r2 for the log and the verdict: $out"
  set +e; "$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/nope-prompt.md --dry-run >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -eq 1 ] || fail "a missing --read prompt should refuse (got $rc)"
  set +e; "$BASH" "$0" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --heavy --dry-run >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -eq 64 ] || fail "--read --heavy should be refused with 64 (got $rc)"
  set +e; "$BASH" "$0" --root "$R" --read PLAN-07 --dry-run >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -eq 64 ] || fail "--read with no prompt file should be refused with 64 (got $rc)"
  # --fix: a fresh build session under the BUILD pin and sandbox, log fix-run.log under the stage header; the result line reads `PLAN-NN fix …`
  out="$("$BASH" "$0" --root "$R" --fix PLAN-07 tmp/PLAN-07/fix-prompt.md --dry-run)" || fail "--fix dry-run exit non-zero"
  [ "$out" = "env -u RATCHET_ALLOW_PUSH TMPDIR='$sr/repo-scratch/tmp/PLAN-07/' $tb $TIMEOUT_NORMAL codex exec -m 'fake-model-1' -c 'model_reasoning_effort=high' -s 'danger-full-access' -C '$R' \"\$(printf '%s\\n' '[planner fix-c1]'; cat 'tmp/PLAN-07/fix-prompt.md')\" < /dev/null >> 'tmp/PLAN-07/fix-run.log' 2>&1$label" ] || fail "--fix dry-run differs: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvF" FAKE_SMOKE_ARGV="$d/smk4" "$BASH" "$0" --root "$R" --fix PLAN-07 tmp/PLAN-07/fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 3 ] && grep -Eq "^PLAN-07 fix exit=3 log=tmp/PLAN-07/fix-run\.log head=[0-9a-f]+ changed=[0-9]+ commit=[^ ]+ session=none rollout=none\$" <<< "$out" || fail "--fix result line differs (rc=$rc): $out"
  [ "$(cat "$d/argvF")" = "$(printf 'exec\n-m\nfake-model-1\n-c\nmodel_reasoning_effort=high\n-s\ndanger-full-access\n-C\n%s\n[planner fix-c1]\nfix across stages' "$R")" ] || fail "--fix argv differs: $(cat "$d/argvF")"
  head -n 1 "$R/tmp/PLAN-07/fix-run.log" | grep -Eq '^# drive-stage: before=[0-9a-f]+ sandbox=danger-full-access started=' || fail "--fix log should carry the stage header"
  [ "$(grep -c . "$d/smk4")" -eq 1 ] && grep -Fq 'fake-model-1' "$d/smk4" || fail "--fix's preflight should smoke the build pin alone: $(cat "$d/smk4")"
  out="$("$BASH" "$0" --root "$R" --fix PLAN-07 tmp/PLAN-07/fix-prompt.md --again --dry-run)" && grep -Fq ">> 'tmp/PLAN-07/fix-run-r2.log'" <<< "$out" || fail "--fix --again should pick fix-run-r2.log: $out"
  set +e; "$BASH" "$0" --root "$R" --fix PLAN-07 tmp/PLAN-07/fix-prompt.md --review --dry-run >/dev/null 2>&1; rc=$?; set -e; [ "$rc" -eq 64 ] || fail "--fix --review should be refused with 64 (got $rc)"
  # an absolute prompt path works as well as a repo-relative one, for --fix and for --resume <file> (Pensieve LOG, 2026-10-07)
  out="$("$BASH" "$0" --root "$R" --fix PLAN-07 "$R/tmp/PLAN-07/fix-prompt.md" --again --dry-run 2>&1)" && grep -Fq "cat '$R/tmp/PLAN-07/fix-prompt.md'" <<< "$out" \
    || fail "--fix should take an absolute prompt path: $out"
  printf 'resume from here\n' > "$d/abs-resume-prompt.md"
  out="$("$BASH" "$0" --root "$R" PLAN-07 07.1 --resume "$d/abs-resume-prompt.md" --again --dry-run 2>&1)" && grep -Fq "cat '$d/abs-resume-prompt.md'" <<< "$out" \
    || fail "--resume should take an absolute prompt path: $out"
  set +e; out="$("$BASH" "$0" --root "$R" --fix PLAN-07 "$d/no-such-prompt.md" --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "prompt file missing: $d/no-such-prompt.md" <<< "$out" || fail "a missing absolute --fix prompt should refuse, naming it (rc=$rc): $out"
  rm -f "$R/created-by-codex.txt"
  # a FILLED copy: the block's values (whatever this copy holds — EDIT-ME or a project's) replaced by fixed ones and every DRIVE_STAGE_* override
  # unset, so the file itself is the record: the stage runs the file's build pin, a read the file's review pin, and the file's pin gates the preflight
  mkdir -p "$d/fill"
  sed -E -e 's/^(CODEX_MODEL="\$\{DRIVE_STAGE_MODEL:-)[^}]*\}/\1filled-build}/' -e 's/^(CODEX_REASONING="\$\{DRIVE_STAGE_REASONING:-)[^}]*\}/\1medium}/' \
    -e 's/^(CODEX_REVIEW_MODEL="\$\{DRIVE_STAGE_REVIEW_MODEL:-)[^}]*\}/\1filled-review}/' -e 's/^(CODEX_REVIEW_REASONING="\$\{DRIVE_STAGE_REVIEW_REASONING:-)[^}]*\}/\1high}/' \
    -e 's/^(CODEX_SANDBOX="\$\{DRIVE_STAGE_SANDBOX:-)[^}]*\}/\1danger-full-access}/' -e 's/^(CODEX_VERSION="\$\{DRIVE_STAGE_CODEX_VERSION-)[^}]*\}/\10.1.0}/' \
    -e 's|^(REVIEW_MANDATE="\$\{DRIVE_STAGE_REVIEW_MANDATE:-)[^}]*\}|\1.codex/agents/t-reviewer.toml}|' "$0" > "$d/fill/drive-stage.sh" || fail "fixture: sed failed filling the copy"
  for v in 'CODEX_MODEL=.*filled-build' 'CODEX_REASONING=.*medium' 'CODEX_REVIEW_MODEL=.*filled-review' 'CODEX_REVIEW_REASONING=.*high' 'CODEX_SANDBOX=.*danger-full-access' 'CODEX_VERSION=.*0\.1\.0' 'REVIEW_MANDATE=.*t-reviewer'; do
    grep -Eq "^$v" "$d/fill/drive-stage.sh" || fail "fixture: the filled copy lacks $v"
  done
  set +e; out="$(env -u DRIVE_STAGE_MODEL -u DRIVE_STAGE_REASONING -u DRIVE_STAGE_REVIEW_MODEL -u DRIVE_STAGE_REVIEW_REASONING -u DRIVE_STAGE_SANDBOX -u DRIVE_STAGE_CODEX_VERSION -u DRIVE_STAGE_REVIEW_MANDATE \
    PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvG" FAKE_SMOKE_ARGV="$d/smk5" "$BASH" "$d/fill/drive-stage.sh" --root "$R" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$(sed -n '2,5p' "$d/argvG")" = "$(printf -- '-m\nfilled-review\n-c\nmodel_reasoning_effort=high')" ] && grep -Fq -- '-m filled-review -c model_reasoning_effort=high' "$d/smk5" \
    && gl="$(sed -n 's/^PLAN-07 read exit=0 log=\([^ ]*\) .*/\1/p' <<< "$out")" && [ -n "$gl" ] && head -n 1 "$R/$gl" | grep -Eq "^# drive-stage: read head=[0-9a-f]{40} model=filled-review started=" || fail "a filled copy's read should run and smoke the file's review pin (rc=$rc): $out / $(cat "$d/argvG" 2>/dev/null)"
  out="$(env -u DRIVE_STAGE_MODEL -u DRIVE_STAGE_REASONING -u DRIVE_STAGE_SANDBOX "$BASH" "$d/fill/drive-stage.sh" --root "$R" PLAN-07 07.3 --dry-run)" \
    && grep -Fq "codex exec -m 'filled-build' -c 'model_reasoning_effort=medium' -s 'danger-full-access'" <<< "$out" || fail "a filled copy's stage dry-run should print the file's build pin and sandbox: $out"
  # ---- one session per Stage (v0.20): the binding, the tags, the lock, --continue/--wait/--peek/--abandon, --pane ------------------
  if ! command -v jq >/dev/null 2>&1; then
    echo "SELF-TEST NOTE: jq is not on PATH — the session tests (--continue, --wait, --peek, --abandon, --pane) were skipped; those modes refuse without it"
  else
  mkdir -p "$d/bin2" "$d/bin3" "$d/fh"
  # fake-turn <session> <text> <C|A|R> <cwd>: one turn appended to the session's record (task_started, the UserMessage, an agent message, a command, then its end)
  cat > "$d/bin2/fake-turn" <<'FAKE'
#!/bin/sh
S="${CODEX_HOME:?}/sessions/2026/09/23"; mkdir -p "$S"; f="$S/rollout-2026-09-23T00-00-00-$1.jsonl"
[ -f "$f" ] || printf '{"type":"session_meta","payload":{"id":"%s","cwd":"%s"}}\n' "$1" "$4" > "$f"
n=$(( $(cat "$S/.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$S/.n"; t="t$n"; txt="$(printf '%s' "$2" | jq -Rs .)"
printf '{"type":"event_msg","payload":{"type":"task_started","turn_id":"%s"}}\n' "$t" >> "$f"
printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"%s","item":{"type":"UserMessage","content":[{"type":"text","text":%s}]}}}\n' "$t" "$txt" >> "$f"
printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"%s","item":{"type":"AgentMessage","content":[{"type":"Text","text":"working on it"}]}}}\n' "$t" >> "$f"
printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"%s","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","make test"]}}}\n' "$t" >> "$f"
printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"%s","item":{"type":"FileChange","changes":{"%s/src/a.swift":{"type":"update"}}}}}\n' "$t" "$4" >> "$f"
case "$3" in
  C) printf '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"%s","last_agent_message":"done"}}\n' "$t" >> "$f" ;;
  A) printf '{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"%s","reason":"interrupted"}}\n' "$t" >> "$f" ;;
esac
printf '%s %s\n' "$f" "$t" > "$S/.last"
FAKE
  # fake-commit <repo> <message>: the Executor's commit
  printf '#!/bin/sh\n[ -n "$2" ] || exit 0\ncd "$1" && printf "%%s\\n" "$2" >> work.txt && git add work.txt && git commit -qm "$2"\n' > "$d/bin2/fake-commit"
  # a session-aware fake codex: exec [flags] [resume <id>] <prompt> appends one turn (FAKE_END, default C) to the session's record (FAKE_SESSION for a new one);
  # queue --thread <id> --message <text> appends one (FAKE_QUEUE_RUN: C | A | R | none); FAKE_COMMIT commits after either
  cat > "$d/bin2/codex" <<'FAKE'
#!/bin/sh
[ "${1:-}" = --version ] && { echo "codex-cli 0.1.0"; exit 0; }
case "$*" in *"exactly the word OK"*) echo OK; exit 0 ;; esac
B="$(dirname "$0")"
if [ "$1" = queue ]; then
  printf '%s\n' "$@" > "${FAKE_ARGV:-/dev/null}"
  [ -z "${FAKE_QUEUE_FAIL:-}" ] || { echo "queue: failed"; exit 1; }
  echo "Queued message q1 for thread $3."
  [ "${FAKE_QUEUE_RUN:-C}" = none ] || { "$B/fake-turn" "$3" "$5" "${FAKE_QUEUE_RUN:-C}" "${FAKE_REPO:-}"; "$B/fake-commit" "${FAKE_REPO:-}" "${FAKE_COMMIT:-}"; }
  exit 0
fi
root=""; sid=""; prev=""; isres=""
for a in "$@"; do [ "$prev" = -C ] && root="$a"; [ "$prev" = resume ] && sid="$a"; [ "$a" = resume ] && isres=1; prev="$a"; done
printf '%s\n' "$@" > "${FAKE_ARGV:-/dev/null}"
for last; do :; done
[ -n "$isres" ] || sid="${FAKE_SESSION:-}"
[ -z "$sid" ] || echo "session id: $sid"
echo "PUSH_KEY=${RATCHET_ALLOW_PUSH-unset}"
[ -z "${FAKE_TERM_LAUNCHER:-}" ] || kill -TERM "$(ps -o ppid= -p "$PPID" | tr -d ' ')"   # the launcher (timeout's parent) is told to stop mid-run
[ -z "$sid" ] || "$B/fake-turn" "$sid" "$last" "${FAKE_END:-C}" "$(cd "$root" && pwd -P)"
"$B/fake-commit" "$root" "${FAKE_COMMIT:-}"
exit "${FAKE_RC:-0}"
FAKE
  # a fake herdr for --pane: state under $FAKE_HERDR (calls.log, agent.<name> = "<name> <pane> <session>", fail.<cmd>.<sub> = "<code> <times>")
  cat > "$d/bin3/herdr" <<'FAKE'
#!/bin/sh
H="${FAKE_HERDR:?}"; B2="${FAKE_BIN2:?}"; printf '%s\n' "$*" >> "$H/calls.log"
die() { echo "{\"error\":{\"code\":\"$1\"}}" >&2; exit 1; }
if [ -f "$H/fail.$1.$2" ]; then read -r code times < "$H/fail.$1.$2"; if [ "${times:-9}" -gt 0 ]; then echo "$code $(( ${times:-9} - 1 ))" > "$H/fail.$1.$2"; die "$code"; fi; fi
case "$1 $2" in
  "status --json") v="${FAKE_HERDR_VERSION:-0.9.1}"; echo "{\"client\":{\"version\":\"$v\"},\"server\":{\"running\":${FAKE_HERDR_RUNNING:-true},\"version\":\"$v\"}}" ;;
  "tab create") n=$(( $(cat "$H/tabs" 2>/dev/null || echo 1) + 1 )); echo "$n" > "$H/tabs"; echo "{\"result\":{\"tab\":{\"tab_id\":\"w1:t$n\"},\"root_pane\":{\"pane_id\":\"w1:p$n\"}}}" ;;
  "tab close") grep -qx "$3" "$H/closed" 2>/dev/null && die tab_not_found; echo "$3" >> "$H/closed"; p="w1:p${3#w1:t}"; for f in "$H"/agent.*; do [ -f "$f" ] && grep -q " $p " "$f" && rm -f "$f"; done; echo '{"result":{"type":"ok"}}' ;;
  "agent start")
    name="$3"; pane=""; root=""; prev=""; for a in "$@"; do [ "$prev" = --pane ] && pane="$a"; [ "$prev" = -C ] && root="$a"; prev="$a"; done
    for last; do :; done
    sid="${FAKE_SESSION:-}"; proot="$(cd "$root" && pwd -P)"
    if [ -n "${FAKE_PANE_DUP:-}" ]; then "$B2/fake-turn" dup-a "$last" R "$proot"; "$B2/fake-turn" dup-b "$last" R "$proot"; sid=""
    elif [ -n "$sid" ]; then "$B2/fake-turn" "$sid" "$last" "${FAKE_PANE_END:-C}" "$proot"; "$B2/fake-commit" "$root" "${FAKE_PANE_COMMIT:-}"; fi
    if [ -n "${FAKE_NOT_READY:-}" ]; then echo "- $pane ${sid} " > "$H/agent.$pane"; die agent_not_ready; fi   # Herdr leaves a start that was not ready UNNAMED (probed live)
    echo "$name $pane ${sid} " > "$H/agent.$pane"
    echo "{\"result\":{\"type\":\"agent_started\",\"agent\":{\"name\":\"$name\",\"pane_id\":\"$pane\"}}}" ;;
  "agent get") [ ! -f "$H/reply.agent.get" ] || { cat "$H/reply.agent.get"; exit 0; }   # a canned reply (exit 0), for the reply-shape tests
    hit=""; for f in "$H"/agent.*; do [ -f "$f" ] || continue; read -r n p s < "$f"; { [ "$n" = "$3" ] || [ "$p" = "$3" ]; } && hit="$f" && break; done
    [ -n "$hit" ] || die agent_not_found; read -r n p s < "$hit"; nj="\"$n\""; [ "$n" != - ] || nj=null
    if [ -n "$s" ]; then sj="{\"value\":\"$s\"}"; else sj=null; fi
    st=idle; sn=""; [ ! -f "$H/status.$p" ] || read -r st sn < "$H/status.$p"
    if [ -n "$sn" ]; then if [ "$sn" -gt 0 ]; then echo "$st $((sn - 1))" > "$H/status.$p"; else st=idle; fi; fi   # `<status> N`: that status for N more reads, then idle
    echo "{\"result\":{\"agent\":{\"agent\":\"codex\",\"name\":$nj,\"pane_id\":\"$p\",\"agent_session\":$sj,\"agent_status\":\"$st\"}}}" ;;
  "agent rename") for f in "$H"/agent.*; do [ -f "$f" ] || continue; read -r n p s < "$f"; [ "$p" = "$3" ] && echo "$4 $p $s " > "$f"; done; echo '{"result":{"type":"ok"}}' ;;
  "agent send-keys")
    if [ "$4" = esc ] && [ -z "${FAKE_ESC_IGNORED:-}" ]; then S="${CODEX_HOME:?}/sessions/2026/09/23"; read -r f t < "$S/.last"; printf '{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"%s","reason":"interrupted"}}\n' "$t" >> "$f"; fi
    if [ "$4" = ctrl+c ] && [ -z "${FAKE_QUIT_IGNORED:-}" ]; then for f in "$H"/agent.*; do [ -f "$f" ] || continue; read -r n p s < "$f"; [ "$p" = "$3" ] && rm -f "$f"; done; fi   # an idle Codex quits on one Ctrl-C (probed)
    echo '{"result":{"type":"ok"}}' ;;
  *) echo '{"result":{"type":"ok"}}' ;;
esac
FAKE
  chmod +x "$d/bin2/fake-turn" "$d/bin2/fake-commit" "$d/bin2/codex" "$d/bin3/herdr"
  SR="$d/srepo"; mkdir -p "$SR/tmp/PLAN-09"
  ( cd "$SR" && git init -q && git config user.email t@t && git config user.name t && printf 'x\n' > a.txt && printf 'tmp/\n' > .gitignore && git add -A && git commit -qm init )
  for st in 09.1 09.2 09.3 09.4 09.5 09.6; do printf 'do stage %s\nsecond line\n' "$st" > "$SR/tmp/PLAN-09/$st-prompt.md"; done
  P2="$d/bin2:$PATH"; SB="$SR/tmp/PLAN-09"; LK="$SR/tmp/.run-lock"
  bget() { kv_get "$SB/$1-binding" "$2"; }
  # S1 a headless Stage: the tag rides the prompt, the binding records the session, the record is copied (mode 600), the lock is gone after
  set +e; out="$(PATH="$P2" FAKE_SESSION=sess-1 FAKE_COMMIT='PLAN-09 / 09.1' FAKE_ARGV="$d/sa1" "$BASH" "$0" --root "$SR" PLAN-09 09.1 2>&1)"; rc=$?; set -e
  h="$(git -C "$SR" rev-parse --short HEAD)"
  [ "$rc" -eq 0 ] && [ "$out" = "PLAN-09 09.1 exit=0 log=tmp/PLAN-09/09.1-run.log head=$h changed=1 commit=$h session=sess-1 rollout=tmp/PLAN-09/09.1-rollout.jsonl" ] || fail "S1: the session-aware result line differs (rc=$rc): $out"
  [ "$(bget 09.1 state)" = settled ] && [ "$(bget 09.1 session)" = sess-1 ] && [ "$(bget 09.1 attempt)" = 1 ] && [ "$(bget 09.1 tag)" = '[planner 09.1-c1]' ] && [ "$(bget 09.1 mode)" = headless ] || fail "S1: the binding differs: $(cat "$SB/09.1-binding")"
  [ "$(stat -f %Lp "$SB/09.1-rollout.jsonl" 2>/dev/null || stat -c %a "$SB/09.1-rollout.jsonl")" = 600 ] || fail "S1: the session record's copy is not mode 600"
  [ ! -e "$LK" ] || fail "S1: a settled run left its lock"
  [ "$(sed -n '10p' "$d/sa1")" = '[planner 09.1-c1]' ] && [ "$(sed -n '11p' "$d/sa1")" = 'do stage 09.1' ] || fail "S1: the prompt should be the tag line, then the file: $(cat "$d/sa1")"
  # S2 --continue, headless: `exec … resume <id>` with the next tag; its own log (-rN on a repeat); the copy refreshed; a commit reported
  printf 'fix F1\n' > "$SB/09.1-fix-prompt.md"
  out="$("$BASH" "$0" --root "$SR" PLAN-09 09.1 --continue tmp/PLAN-09/09.1-fix-prompt.md --dry-run)" || fail "S2: --continue dry-run exit non-zero"
  grep -Fq -- "-C '$SR' resume 'sess-1' \"\$(printf '%s\\n' '[planner 09.1-c2]'; cat '$SB/09.1-fix-prompt.md')\" < /dev/null >> 'tmp/PLAN-09/09.1-continue-run.log' 2>&1" <<< "$out" || fail "S2: the --continue dry-run differs: $out"
  set +e; out="$(PATH="$P2" FAKE_COMMIT='PLAN-09 / 09.1 fix' FAKE_ARGV="$d/sa2" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  h2="$(git -C "$SR" rev-parse --short HEAD)"
  [ "$rc" -eq 0 ] && [ "$out" = "PLAN-09 09.1 exit=0 log=tmp/PLAN-09/09.1-continue-run.log head=$h2 changed=1 commit=$h2 session=sess-1 rollout=tmp/PLAN-09/09.1-rollout.jsonl" ] || fail "S2: the --continue result line differs (rc=$rc): $out"
  [ "$(sed -n '8,11p' "$d/sa2")" = "$(printf -- '-C\n%s\nresume\nsess-1' "$SR")" ] && [ "$(sed -n '12p' "$d/sa2")" = '[planner 09.1-c2]' ] && [ "$(sed -n '13p' "$d/sa2")" = 'fix F1' ] || fail "S2: --continue argv differs: $(cat "$d/sa2")"
  [ "$(grep -c 'UserMessage' "$SB/09.1-rollout.jsonl")" -eq 2 ] && [ "$(bget 09.1 attempt)" = 2 ] && [ "$(bget 09.1 state)" = settled ] || fail "S2: the copy or the binding was not refreshed"
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'log=tmp/PLAN-09/09.1-continue-run-r2.log' <<< "$out" && [ "$(bget 09.1 tag)" = '[planner 09.1-c3]' ] || fail "S2: a second --continue should log -r2 and tag -c3 (rc=$rc): $out"
  # S3 refusals, nothing sent: no binding; an unsettled last message; the record gone
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa3" "$BASH" "$0" --root "$SR" PLAN-09 09.2 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'records no session' <<< "$out" && grep -Fq -- '--resume' <<< "$out" && [ ! -e "$d/sa3" ] || fail "S3: --continue with no binding should refuse naming --resume (rc=$rc): $out"
  cp "$SB/09.1-binding" "$d/b.save"; sed 's/^state=.*/state=sent/' "$d/b.save" > "$SB/09.1-binding"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa3" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "not settled" <<< "$out" && grep -Fq 'never re-sent' <<< "$out" && [ ! -e "$d/sa3" ] || fail "S3: --continue over an unsettled message should refuse (rc=$rc): $out"
  sed 's|^rollout=.*|rollout=/nonexistent/rollout.jsonl|' "$d/b.save" > "$SB/09.1-binding"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa3" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'record is gone' <<< "$out" && [ ! -e "$d/sa3" ] || fail "S3: --continue with its record gone should refuse naming --resume (rc=$rc): $out"
  cp "$d/b.save" "$SB/09.1-binding"
  # S4 turn_state: only the tagged message's own turn settles it — never an earlier turn's mark, a human turn, a quoted tag; a half-written last line is skipped
  tsf="$d/ts.jsonl"
  { printf '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t0"}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"t1","item":{"type":"UserMessage","content":[{"type":"text","text":"see [planner 01.1-c2] later"}]}}}\n'
    printf '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t1"}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"t2","item":{"type":"UserMessage","content":[{"type":"text","text":"[planner 01.1-c2]\\ngo"}]}}}\n'; } > "$tsf"
  [ "$(turn_state "$tsf" 0 '[planner 01.1-c2]')" = "running t2" ] || fail "S4: a stale mark, a human turn or a quoted tag settled the message: $(turn_state "$tsf" 0 '[planner 01.1-c2]')"
  printf '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"t2"}}\n{"type":"event_msg","payl' >> "$tsf"
  [ "$(turn_state "$tsf" 0 '[planner 01.1-c2]')" = "complete t2" ] || fail "S4: the tagged turn's complete (with a half-written last line after it) should settle it"
  [ "$(turn_state "$tsf" 4 '[planner 01.1-c2]')" = pending ] || fail "S4: a message sent after line 4 must not match the earlier one"
  printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"t3","item":{"type":"UserMessage","content":[{"type":"text","text":"[planner 01.1-c3] x"}]}}}\n{"type":"event_msg","payload":{"type":"turn_aborted","turn_id":"t3"}}\n' > "$d/ts2.jsonl"
  [ "$(turn_state "$d/ts2.jsonl" 0 '[planner 01.1-c3]')" = "aborted t3" ] || fail "S4: an aborted turn should read aborted"
  # S4b (B8) a human message whose FIRST block is prose and a later block quotes the tag never matches: only the message that opens with it
  { printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"h1","item":{"type":"UserMessage","content":[{"type":"text","text":"look at this: "},{"type":"text","text":"[planner 01.1-c4] do it"}]}}}\n'
    printf '{"type":"event_msg","payload":{"type":"task_complete","turn_id":"h1"}}\n'
    printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"t4","item":{"type":"UserMessage","content":[{"type":"text","text":"[planner 01.1-c4]"},{"type":"text","text":"\\ngo"}]}}}\n'; } > "$d/ts3.jsonl"
  [ "$(turn_state "$d/ts3.jsonl" 0 '[planner 01.1-c4]')" = "running t4" ] || fail "S4b: a tag quoted in a later block of a human message settled the message: $(turn_state "$d/ts3.jsonl" 0 '[planner 01.1-c4]')"
  # S5 the run lock: live refuses; pid reuse (a live pid, another start time) and a dead pid are stale — stale refuses; a fresh owner-less dir is starting; a stale review lock is swept
  sleep 30 & lp=$!
  mkdir "$LK"; printf 'pid=%s\nstart=%s\nwhat=held\nat=x\n' "$lp" "$(proc_start "$lp")" > "$LK/owner"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa5" "$BASH" "$0" --root "$SR" PLAN-09 09.2 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "another run holds" <<< "$out" && [ ! -e "$d/sa5" ] && [ ! -e "$SB/09.2-run.log" ] || fail "S5: a live run lock should refuse with nothing launched (rc=$rc): $out"
  printf 'pid=%s\nstart=Thu Jan 1 00:00:00 1970\nwhat=held\nat=x\n' "$$" > "$LK/owner"
  [ "$(lock_state "$LK")" = stale ] || fail "S5: a live pid with another start time (reuse) should read stale"
  kill "$lp" 2>/dev/null || true; wait "$lp" 2>/dev/null || true
  printf 'pid=%s\nstart=x\nwhat=held\nplan=PLAN-09\nstage=09.1\nat=x\n' "$lp" > "$LK/owner"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa5" "$BASH" "$0" --root "$SR" PLAN-09 09.2 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "is STALE" <<< "$out" && grep -Fq -- '--wait for PLAN-09 09.1' <<< "$out" && [ ! -e "$d/sa5" ] || fail "S5: a stale run lock should refuse naming --wait for its own Stage (rc=$rc): $out"
  # S5b (B2) --wait never takes over ANOTHER Stage's stale lock: 09.2's --wait leaves 09.1's lock exactly as it was
  cp "$LK/owner" "$d/own.save"; sed 's/^stage=.*/stage=09.2/' "$d/own.save" > "$LK/owner"; cp "$LK/owner" "$d/own2.save"   # 09.2's launcher died
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'belongs to PLAN-09 09.2' <<< "$out" && cmp -s "$LK/owner" "$d/own2.save" || fail "S5b: --wait must refuse another Stage's stale lock, untouched (rc=$rc): $out"
  cp "$d/own.save" "$LK/owner"
  # S5c (B3) a takeover claims <lock>.claim first: a claim already there (another taker, or one killed mid-takeover) refuses, the lock untouched
  mkdir "$LK.claim"
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "$LK.claim" <<< "$out" && cmp -s "$LK/owner" "$d/own.save" && [ -d "$LK.claim" ] || fail "S5c: a held claim should refuse the takeover and leave the lock alone (rc=$rc): $out"
  rmdir "$LK.claim"
  # S5d (A4) a ps that fails is never "the owner is gone": the lock reads unreadable (2), never stale
  mkdir -p "$d/fakeps"; printf '#!/bin/sh\nexit 1\n' > "$d/fakeps/ps"; chmod +x "$d/fakeps/ps"
  mkdir "$d/lk5"; printf 'pid=%s\nstart=%s\nwhat=live\nplan=PLAN-09\nstage=09.1\nat=x\n' "$$" "$(proc_start "$$")" > "$d/lk5/owner"
  set +e; st5="$( PATH="$d/fakeps:$PATH"; hash -r; lock_state "$d/lk5" 2>/dev/null )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 2 ] && [ "$st5" != stale ] || fail "S5d: a failing ps read a live owner as '$st5' (rc=$rc), not a failure"
  rm -rf "$d/lk5"
  # … and --wait takes it over: 09.1's last message (c3) is complete in the record — the result line, the lock released
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'took over the stale run lock' <<< "$out" && grep -Fq 'nothing to wait for' <<< "$out" && grep -Eq '^PLAN-09 09\.1 exit=0 .* pane=none settled=yes$' <<< "$out" && [ ! -e "$LK" ] || fail "S5: --wait should take a stale lock over and release it (rc=$rc): $out"
  mkdir "$LK"
  [ "$(lock_state "$LK")" = starting ] || fail "S5: a fresh owner-less lock dir should read starting"
  # … and a clock that fails, or reads non-numeric, is exit 2 — never `starting` (Codex r2 NB1)
  set +e; out="$(date() { return 1; }; lock_state "$LK" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && ! grep -Eqx 'starting|stale' <<< "$out" || fail "S5: a failing clock must make lock_state exit 2 (rc=$rc): $out"
  set +e; out="$(date() { echo soon; }; lock_state "$LK" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] || fail "S5: a non-numeric clock must make lock_state exit 2 (rc=$rc): $out"
  rmdir "$LK"
  mkdir "$SB/.run-lock-09.1-L1"; printf 'pid=%s\nstart=x\nwhat=review\nat=x\n' "$lp" > "$SB/.run-lock-09.1-L1/owner"
  set +e; out="$(PATH="$P2" FAKE_SESSION=sess-2 "$BASH" "$0" --root "$SR" PLAN-09 09.2 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'removed a stale review lock .run-lock-09.1-L1' <<< "$out" && [ ! -e "$SB/.run-lock-09.1-L1" ] || fail "S5: the next launch should sweep a stale review lock (rc=$rc): $out"
  # S6 --wait on a message that never reaches the record: 75, uncertain, the lock KEPT (stale once --wait exits); --continue refuses; --abandon settles and releases
  cp "$SB/09.2-binding" "$d/b2.save"; n2="$(line_count "$(kv_get "$d/b2.save" rollout)")" || fail "S6: fixture: the record's length"
  [ "$n2" -gt 0 ] || fail "S6: fixture: 09.2's record is empty"
  sed -e 's/^state=.*/state=sent/' -e 's/^tag=.*/tag=[planner 09.2-c9]/' -e "s/^lines=.*/lines=$n2/" -e "s/^sent_s=.*/sent_s=$(date +%s)/" "$d/b2.save" > "$SB/09.2-binding"
  set +e; out="$(PATH="$P2" DRIVE_STAGE_PANE_DELIVERY=1 DRIVE_STAGE_POLL=0.2 "$BASH" "$0" --root "$SR" PLAN-09 09.2 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 75 ] && [ "$(bget 09.2 state)" = uncertain ] && grep -Eq 'exit=75 .* settled=no$' <<< "$out" && [ "$(lock_state "$LK")" = stale ] || fail "S6: an undelivered message should read 75/uncertain and leave a stale lock (rc=$rc): $out"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa6" "$BASH" "$0" --root "$SR" PLAN-09 09.2 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && [ ! -e "$d/sa6" ] || fail "S6: --continue over an uncertain message should refuse (rc=$rc): $out"
  out="$("$BASH" "$0" --root "$SR" PLAN-09 09.2 --abandon 2>&1)" || fail "S6: --abandon failed: $out"
  grep -Fq 'abandoned [planner 09.2-c9] (was uncertain)' <<< "$out" && [ "$(bget 09.2 state)" = settled ] && [ ! -e "$LK" ] || fail "S6: --abandon should settle the message and release the lock: $out"
  # S7 --peek: the state, and the last items — the tagged messages as sent, an untagged one as the human's
  printf '{"type":"event_msg","payload":{"type":"item_completed","turn_id":"tx","item":{"type":"UserMessage","content":[{"type":"text","text":"hey codex, also rename it"}]}}}\n' >> "$(bget 09.1 rollout)"
  out="$(DRIVE_STAGE_PEEK_N=20 "$BASH" "$0" --root "$SR" PLAN-09 09.1 --peek)" || fail "S7: --peek failed: $out"
  grep -Eq '^PLAN-09 09\.1 peek session=sess-1 state=settled message=\[planner 09\.1-c3\] turn=complete ' <<< "$out" && grep -Fq '  sent:  [planner 09.1-c1] do stage 09.1' <<< "$out" && grep -Fq '  agent: working on it' <<< "$out" \
    && grep -Fq '  exec:  make test' <<< "$out" && grep -Fq '  edit:  update src/a.swift' <<< "$out" && grep -Fq '  human: hey codex, also rename it   (untagged)' <<< "$out" || fail "S7: --peek output differs: $out"
  # S8 --pane (a fake herdr): the gate first; then a tab, `agent start` with the pinned argv and the one-line pointer, the session from Herdr, the turn from the record
  : > "$d/fh/calls.log"; export FAKE_HERDR="$d/fh" FAKE_BIN2="$d/bin2"; P3="$d/bin3:$d/bin2:$PATH"
  set +e; out="$(PATH="$P3" "$BASH" "$0" --root "$SR" PLAN-09 09.3 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'inside Herdr only' <<< "$out" && ! grep -q 'tab create' "$d/fh/calls.log" || fail "S8: --pane outside Herdr should refuse before any call (rc=$rc): $out"
  set +e; out="$(PATH="$P3" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 FAKE_HERDR_RUNNING=false "$BASH" "$0" --root "$SR" PLAN-09 09.3 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'server is not running' <<< "$out" && ! grep -q 'tab create' "$d/fh/calls.log" || fail "S8: a stopped Herdr server should refuse before a tab is made (rc=$rc): $out"
  pe() { PATH="$P3" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 DRIVE_STAGE_PROJECT=proj DRIVE_STAGE_POLL=0.2 DRIVE_STAGE_PANE_DELIVERY=3 DRIVE_STAGE_TIMEOUT=8 DRIVE_STAGE_ESC_WAIT=2 "$@"; }   # a short bound: a regression fails in seconds, never hangs
  set +e; out="$(pe env FAKE_HERDR_VERSION=1.0.0 FAKE_SESSION=pane-3 FAKE_PANE_COMMIT='PLAN-09 / 09.3' "$BASH" "$0" --root "$SR" PLAN-09 09.3 --pane 2>&1)"; rc=$?; set -e   # another Herdr version runs: the kit pins none
  h3="$(git -C "$SR" rev-parse --short HEAD)"
  [ "$rc" -eq 0 ] && grep -Eq "^PLAN-09 09\.3 exit=0 log=tmp/PLAN-09/09\.3-run\.log head=$h3 changed=[0-9]+ commit=$h3 session=pane-3 rollout=tmp/PLAN-09/09\.3-rollout\.jsonl pane=w1:p2 settled=yes\$" <<< "$out" || fail "S8: the pane result line differs (rc=$rc): $out"
  grep -Fxq "tab create --workspace w1 --cwd $SR --label executor (09.3) --env DISABLE_AUTO_UPDATE=true --env RATCHET_ALLOW_PUSH= --env TMPDIR=$sr/${SR##*/}-scratch/tmp/PLAN-09/ --env XP_SCRATCH_PARENT=$sr --no-focus" "$d/fh/calls.log" || fail "S8: tab create differs: $(cat "$d/fh/calls.log")"
  grep -Fxq "agent start proj-codex-09-3 --kind codex --pane w1:p2 --timeout 30000 -- -m fake-model-1 -c model_reasoning_effort=high -s danger-full-access -a never -c check_for_update_on_startup=false -C $SR [planner 09.3-c1] Your prompt is the file tmp/PLAN-09/09.3-prompt.md: read it in full and carry it out." "$d/fh/calls.log" || fail "S8: agent start differs: $(cat "$d/fh/calls.log")"
  grep -Fxq 'session id: pane-3' "$SB/09.3-run.log" && [ "$(bget 09.3 mode)" = pane ] && [ "$(bget 09.3 agent)" = proj-codex-09-3 ] && [ "$(bget 09.3 tab)" = w1:t2 ] && [ "$(bget 09.3 state)" = settled ] && [ ! -e "$LK" ] || fail "S8: the pane binding or log differs: $(cat "$SB/09.3-binding")"
  # S9 --continue into the live pane: `codex queue --thread <id>` with the next tag, then the same wait
  printf 'fix pane F1\n' > "$SB/09.3-fix-prompt.md"
  set +e; out="$(pe env FAKE_ARGV="$d/sa9" FAKE_REPO="$SR" FAKE_COMMIT='PLAN-09 / 09.3 fix' "$BASH" "$0" --root "$SR" PLAN-09 09.3 --continue tmp/PLAN-09/09.3-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq '^PLAN-09 09\.3 exit=0 log=tmp/PLAN-09/09\.3-continue-run\.log .* session=pane-3 rollout=tmp/PLAN-09/09\.3-rollout\.jsonl pane=w1:p2 settled=yes$' <<< "$out" || fail "S9: a queued --continue's result differs (rc=$rc): $out"
  [ "$(sed -n '1,4p' "$d/sa9")" = "$(printf 'queue\n--thread\npane-3\n--message')" ] && [ "$(sed -n '5p' "$d/sa9")" = '[planner 09.3-c2]' ] && [ "$(sed -n '6p' "$d/sa9")" = 'fix pane F1' ] || fail "S9: the queue argv differs: $(cat "$d/sa9")"
  # S10 the next Stage's launch closes the settled Stage's tab; agent_pane_busy is retried
  printf 'agent_pane_busy 2\n' > "$d/fh/fail.agent.start"
  set +e; out="$(pe env FAKE_SESSION=pane-4 "$BASH" "$0" --root "$SR" PLAN-09 09.4 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fxq 'tab close w1:t2' "$d/fh/calls.log" && [ "$(grep -c '^agent start proj-codex-09-4' "$d/fh/calls.log")" -eq 3 ] && [ -z "$(bget 09.3 tab)" ] || fail "S10: busy retries or the settled tab's close differ (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  # S11 --continue when the pane's Codex is gone: the session continues headless
  set +e; out="$(pe env FAKE_ARGV="$d/sa11" "$BASH" "$0" --root "$SR" PLAN-09 09.3 --continue tmp/PLAN-09/09.3-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'continuing its session headless' <<< "$out" && grep -Fxq resume "$d/sa11" && grep -Fxq pane-3 "$d/sa11" && [ "$(bget 09.3 mode)" = headless ] || fail "S11: a gone pane should fall back to a headless resume (rc=$rc): $out"
  # S12 Herdr's start says not ready (Codex busy with its prompt, or behind a dialog): the record decides — a turn that shows and completes is a
  # normal result; one that never shows is 75, uncertain, the lock kept (stale once the launcher exits); --abandon clears it
  set +e; out="$(pe env FAKE_SESSION=pane-5 FAKE_NOT_READY=1 "$BASH" "$0" --root "$SR" PLAN-09 09.5 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq '^PLAN-09 09\.5 exit=0 .* session=pane-5 .* settled=yes$' <<< "$out" || fail "S12: a not-ready start whose turn shows in the record should complete (rc=$rc): $out"
  grep -Fxq "agent rename w1:p4 proj-codex-09-5" "$d/fh/calls.log" || fail "S12: an unnamed Codex (a start that was not ready) should get its name back: $(cat "$d/fh/calls.log")"
  printf 'do stage 09.8\n' > "$SB/09.8-prompt.md"
  set +e; out="$(pe env FAKE_NOT_READY=1 "$BASH" "$0" --root "$SR" PLAN-09 09.8 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 75 ] && grep -Fq 'no session record for proj-codex-09-8 within 3s' <<< "$out" && [ "$(bget 09.8 state)" = uncertain ] && [ "$(lock_state "$LK")" = stale ] || fail "S12: a start whose turn never shows should read 75 with the lock kept (rc=$rc): $out"
  "$BASH" "$0" --root "$SR" PLAN-09 09.8 --abandon >/dev/null 2>&1 || fail "S12: --abandon failed"
  # S13 the time budget: the bound Escs the running turn, then quits the Stage's Codex (Ctrl-C) — no message is queued into an interrupted Codex
  # (it would never be delivered); 124, settled once the pane no longer holds Codex, and the Planner's next word is a headless --continue
  set +e; out="$(pe env FAKE_SESSION=pane-6 FAKE_PANE_END=R FAKE_ARGV="$d/sa13" DRIVE_STAGE_TIMEOUT=1 DRIVE_STAGE_ESC_WAIT=3 "$BASH" "$0" --root "$SR" PLAN-09 09.6 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 124 ] && grep -Eq "exit=124 .* commit=none .* settled=yes\$" <<< "$out" && grep -Fxq 'agent send-keys w1:p6 esc' "$d/fh/calls.log" && grep -Fxq 'agent send-keys w1:p6 ctrl+c' "$d/fh/calls.log" || fail "S13: the time budget should Esc, then quit Codex (rc=$rc): $out"
  [ ! -e "$d/sa13" ] || fail "S13: nothing may be queued into an interrupted Codex: $(cat "$d/sa13")"
  set +e; out="$(pe env FAKE_ARGV="$d/sa13b" FAKE_COMMIT='PLAN-09 / 09.6 wrap' "$BASH" "$0" --root "$SR" PLAN-09 09.6 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fxq resume "$d/sa13b" && grep -Fxq pane-6 "$d/sa13b" || fail "S13: after the bound, --continue should resume the session headless (rc=$rc): $out"
  printf 'do stage 09.10\n' > "$SB/09.10-prompt.md"
  set +e; out="$(pe env FAKE_SESSION=pane-10 FAKE_PANE_END=R FAKE_ESC_IGNORED=1 FAKE_QUIT_IGNORED=1 DRIVE_STAGE_TIMEOUT=1 DRIVE_STAGE_ESC_WAIT=1 "$BASH" "$0" --root "$SR" PLAN-09 09.10 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 124 ] && grep -Eq 'exit=124 .* settled=no$' <<< "$out" && [ "$(bget 09.10 state)" = uncertain ] && [ "$(lock_state "$LK")" = stale ] || fail "S13: a Codex that neither stops nor quits should leave the message unsettled and the lock kept (rc=$rc): $out"
  "$BASH" "$0" --root "$SR" PLAN-09 09.10 --abandon >/dev/null 2>&1 || fail "S13: --abandon failed"
  # S14 two candidate session records (Herdr reports none): never guessed — 75, uncertain
  printf 'do stage 09.7\n' > "$SB/09.7-prompt.md"
  set +e; out="$(pe env FAKE_PANE_DUP=1 "$BASH" "$0" --root "$SR" PLAN-09 09.7 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 75 ] && grep -Fq 'two candidate session records' <<< "$out" && [ "$(bget 09.7 state)" = uncertain ] || fail "S14: two candidates should stop, never guess (rc=$rc): $out"
  "$BASH" "$0" --root "$SR" PLAN-09 09.7 --abandon >/dev/null 2>&1 || fail "S14: --abandon failed"
  # S15 --continue into a live pane whose last turn a human interrupted (Esc): refused — a queued message would never be delivered, and a human may be steering
  printf 'do stage 09.11\n' > "$SB/09.11-prompt.md"
  set +e; out="$(pe env FAKE_SESSION=pane-11 "$BASH" "$0" --root "$SR" PLAN-09 09.11 --pane 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] || fail "S15: fixture: the pane launch failed (rc=$rc): $out"
  "$d/bin2/fake-turn" pane-11 "stop, try the other approach" A "$(cd "$SR" && pwd -P)"
  set +e; out="$(pe env FAKE_ARGV="$d/sa15" "$BASH" "$0" --root "$SR" PLAN-09 09.11 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'was interrupted' <<< "$out" && [ ! -e "$d/sa15" ] && [ "$(bget 09.11 state)" = settled ] && [ ! -e "$LK" ] || fail "S15: --continue into an interrupted Codex should refuse with nothing sent (rc=$rc): $out"
  # S16 a headless launcher stopped mid-run (TERM while Codex works): the message is unsettled, so its exit KEEPS the run lock (stale once it is gone);
  # --wait takes it over, finds the session through the run log, and settles it from the record
  printf 'do stage 09.9\n' > "$SB/09.9-prompt.md"
  set +e; out="$(PATH="$P2" FAKE_SESSION=sess-16 FAKE_TERM_LAUNCHER=1 "$BASH" "$0" --root "$SR" PLAN-09 09.9 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 143 ] && [ "$(bget 09.9 state)" = sent ] && [ "$(lock_state "$LK")" = stale ] || fail "S16: a launcher stopped mid-send should keep its lock (rc=$rc, state $(bget 09.9 state)): $out"
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.9 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq '^PLAN-09 09\.9 exit=0 .* session=sess-16 .* pane=none settled=yes$' <<< "$out" && [ ! -e "$LK" ] || fail "S16: --wait should settle the stopped launcher's message (rc=$rc): $out"
  # S15b (last_turn) an unreadable record is a tool failure (exit 2), never the interrupted-Codex refusal's verdict (1)
  ro11="$(bget 09.11 rollout)"; chmod 000 "$ro11"
  set +e; out="$(pe env FAKE_ARGV="$d/sa15b" "$BASH" "$0" --root "$SR" PLAN-09 09.11 --continue tmp/PLAN-09/09.1-fix-prompt.md 2>&1)"; rc=$?; set -e
  chmod 600 "$ro11"
  [ "$rc" -eq 2 ] && [ ! -e "$d/sa15b" ] || fail "S15b: an unreadable record should be exit 2 with nothing sent (rc=$rc): $out"
  # S17 (B1) a <binding>.new is READ, never promoted, by --peek and a --pane dry-run: neither changes a file
  cp "$SB/09.1-binding" "$d/b17.save"
  sed -e 's/^state=.*/state=sent/' -e 's/^tag=.*/tag=[planner 09.1-c9]/' "$d/b17.save" > "$SB/09.1-binding.new"; cp "$SB/09.1-binding.new" "$d/b17new.save"
  out="$(DRIVE_STAGE_PEEK_N=2 "$BASH" "$0" --root "$SR" PLAN-09 09.1 --peek 2>&1)" || fail "S17: --peek failed: $out"
  grep -Fq 'message=[planner 09.1-c9]' <<< "$out" && cmp -s "$SB/09.1-binding.new" "$d/b17new.save" && cmp -s "$SB/09.1-binding" "$d/b17.save" || fail "S17: --peek must read the .new and change no file: $out"
  set +e; out="$(DRIVE_STAGE_PROJECT=proj "$BASH" "$0" --root "$SR" PLAN-09 09.1 --pane --again --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'not settled' <<< "$out" && cmp -s "$SB/09.1-binding.new" "$d/b17new.save" && cmp -s "$SB/09.1-binding" "$d/b17.save" || fail "S17: a --pane dry-run must change no file, and refuse beside a message in flight (rc=$rc): $out"
  rm -f "$SB/09.1-binding.new"
  # S18 (A1) --wait whose record search FAILS (find exits 1 with partial output) is exit 2, never "no session record yet" (75); the lock is kept
  mkdir -p "$d/fakefind"; printf '#!/bin/sh\necho /partial/rollout.jsonl\nexit 1\n' > "$d/fakefind/find"; chmod +x "$d/fakefind/find"
  sed -e 's/^state=.*/state=sent/' -e 's/^rollout=.*/rollout=/' -e 's/^tag=.*/tag=[planner 09.12-c1]/' -e 's|^log=.*|log=tmp/PLAN-09/09.1-run.log|' "$d/b17.save" > "$SB/09.12-binding"
  set +e; out="$(PATH="$d/fakefind:$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.12 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && grep -Fq 'find failed' <<< "$out" && [ -d "$LK" ] || fail "S18: a failing record search should be exit 2 with the lock kept (rc=$rc): $out"
  rm -rf "$LK" "$SB/09.12-binding"
  # S19 (A6) the launcher's own log lines and the queue reply are never silently lost
  set +e; log_note "$d/no-such-dir/x.log" "hi" 2>/dev/null; rc=$?; set -e
  [ "$rc" -eq 2 ] || fail "S19: a failed log append should be 2 (got $rc)"
  set +e; ( PATH="$d/bin2:$PATH"; hash -r; B_session=zz; FAKE_QUEUE_RUN=none; export FAKE_QUEUE_RUN; queue_msg "$d/no-such-dir" x.log "hi" ) 2>/dev/null; rc=$?; set -e; hash -r
  [ "$rc" -ne 0 ] || fail "S19: a queue reply that cannot be logged should read uncertain (non-zero), got 0"
  # S20 (B5) an interrupted --fix is recoverable through the CLI: fix-binding, `PLAN-09 fix --wait` settles it; a new --fix waits for that
  printf 'fix across stages\n' > "$SB/fix-prompt.md"
  set +e; out="$(PATH="$P2" FAKE_SESSION=sess-fix FAKE_TERM_LAUNCHER=1 "$BASH" "$0" --root "$SR" --fix PLAN-09 tmp/PLAN-09/fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 143 ] && [ "$(bget fix state)" = sent ] && [ "$(bget fix tag)" = '[planner fix-c1]' ] && [ "$(lock_state "$LK")" = stale ] || fail "S20: an interrupted --fix should keep its binding unsettled and its lock (rc=$rc): $out"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa20" "$BASH" "$0" --root "$SR" --fix PLAN-09 tmp/PLAN-09/fix-prompt.md --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'not settled' <<< "$out" && [ ! -e "$d/sa20" ] || fail "S20: a new --fix over an unsettled batch should refuse (rc=$rc): $out"
  out="$("$BASH" "$0" --root "$SR" PLAN-09 fix --peek 2>&1)" && grep -Fq 'message=[planner fix-c1]' <<< "$out" || fail "S20: PLAN-09 fix --peek should read the batch: $out"
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 fix --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq '^PLAN-09 fix exit=0 .* session=sess-fix .* pane=none settled=yes$' <<< "$out" && [ ! -e "$LK" ] || fail "S20: PLAN-09 fix --wait should settle the batch (rc=$rc): $out"
  set +e; out="$(PATH="$P2" FAKE_SESSION=sess-fix2 "$BASH" "$0" --root "$SR" --fix PLAN-09 tmp/PLAN-09/fix-prompt.md --again 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'log=tmp/PLAN-09/fix-run-r2.log' <<< "$out" && [ "$(bget fix tag)" = '[planner fix-c2]' ] && [ "$(bget fix session)" = sess-fix2 ] || fail "S20: a new --fix after a settled batch is a fresh session (rc=$rc): $out"
  set +e; "$BASH" "$0" --root "$SR" PLAN-09 fix --continue tmp/PLAN-09/fix-prompt.md >/dev/null 2>&1; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "S20: a fix batch is never --continued (got $rc)"
  # S21 (B6) an agent start failing with an UNCLASSIFIED error is uncertain — the binding and the lock kept, never "nothing sent";
  # (NB12) an unreadable binding in the plan's workspace is named as a warning when the settled tabs are closed
  printf 'do stage 09.21\n' > "$SB/09.21-prompt.md"; printf 'weird_error 1\n' > "$d/fh/fail.agent.start"
  printf 'state=settled\n' > "$SB/09.99-binding"; chmod 000 "$SB/09.99-binding"
  set +e; out="$(pe env FAKE_SESSION=pane-21 "$BASH" "$0" --root "$SR" PLAN-09 09.21 --pane 2>&1)"; rc=$?; set -e
  chmod 600 "$SB/09.99-binding"; rm -f "$SB/09.99-binding" "$d/fh/fail.agent.start"
  [ "$rc" -eq 75 ] && ! grep -Fq 'nothing sent' <<< "$out" && [ "$(bget 09.21 state)" = uncertain ] && [ "$(lock_state "$LK")" = stale ] || fail "S21: an unclassified start error must stay uncertain with the lock kept (rc=$rc): $out"
  grep -Fq "09.99-binding could not be read: its Stage's tab, if any, is left open" <<< "$out" || fail "S21: an unreadable binding should be named as a warning: $out"
  "$BASH" "$0" --root "$SR" PLAN-09 09.21 --abandon >/dev/null 2>&1 || fail "S21: --abandon failed"
  # S22 (B7) --abandon whose settle write fails keeps the lock (the durable binding is still unsettled)
  sed -e 's/^state=.*/state=sent/' -e 's/^tag=.*/tag=[planner 09.22-c1]/' "$d/b17.save" > "$SB/09.22-binding"
  chmod 555 "$SB"
  set +e; out="$("$BASH" "$0" --root "$SR" PLAN-09 09.22 --abandon 2>&1)"; rc=$?; set -e
  chmod 755 "$SB"
  [ "$rc" -eq 2 ] && [ -d "$LK" ] && [ "$(bget 09.22 state)" = sent ] || fail "S22: a failed settle write must keep the lock (rc=$rc): $out"
  out="$("$BASH" "$0" --root "$SR" PLAN-09 09.22 --abandon 2>&1)" && [ "$(bget 09.22 state)" = settled ] && [ ! -e "$LK" ] || fail "S22: a second --abandon should settle it and release: $out"
  # S23 (B9) no second session for a Stage: --resume refused while its session record exists; --again refused over an unsettled message
  printf 'resume 09.1\n' > "$SB/09.1-resume-prompt.md"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa23" "$BASH" "$0" --root "$SR" PLAN-09 09.1 --resume 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'is on record' <<< "$out" && grep -Fq -- '--continue' <<< "$out" && [ ! -e "$d/sa23" ] && [ ! -e "$SB/09.1-resume-run.log" ] || fail "S23: --resume over a recorded session should refuse (rc=$rc): $out"
  sed -e 's/^state=.*/state=uncertain/' "$d/b17.save" > "$SB/09.1-binding"
  set +e; out="$("$BASH" "$0" --root "$SR" PLAN-09 09.1 --again --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "'uncertain', not settled" <<< "$out" || fail "S23: --again over an unsettled message should refuse (rc=$rc): $out"
  sed -e 's/^session=.*/session=gone-1/' -e 's|^rollout=.*|rollout=/nonexistent/r.jsonl|' "$d/b17.save" > "$SB/09.1-binding"
  out="$("$BASH" "$0" --root "$SR" PLAN-09 09.1 --resume --dry-run 2>&1)" || fail "S23: --resume with the record gone should be allowed: $out"
  cp "$d/b17.save" "$SB/09.1-binding"
  # S24 (r2) a stale OWNER-LESS build lock with no binding anywhere (its launcher died between mkdir and its owner write, long ago):
  # --wait recovers it through the public CLI — nothing was sent
  [ ! -e "$LK" ] || fail "S24: fixture — the build lock should be free here"
  mkdir "$LK"; touch -t 202001010000 "$LK"
  set +e; out="$("$BASH" "$0" --root "$SR" PLAN-09 09.30 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'took over the stale build lock tmp/.run-lock' <<< "$out" && grep -Fq 'nothing was sent' <<< "$out" && [ ! -e "$LK" ] || fail "S24: --wait should recover an owner-less stale lock with no binding (rc=$rc): $out"
  # S25 (r2) a stale lock NAMED for 09.40 whose launcher died before writing any binding: 09.41 --wait refuses naming 09.40, untouched;
  # 09.40 --abandon recovers it and releases it
  sh -c 'exit 0' & dp=$!; wait "$dp" 2>/dev/null || true
  mkdir "$LK"; printf 'pid=%s\nstart=x\nwhat=PLAN-09 09.40 build\nplan=PLAN-09\nstage=09.40\nat=x\n' "$dp" > "$LK/owner"; cp "$LK/owner" "$d/own25.save"
  set +e; out="$("$BASH" "$0" --root "$SR" PLAN-09 09.41 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'belongs to PLAN-09 09.40' <<< "$out" && cmp -s "$LK/owner" "$d/own25.save" || fail "S25: another Stage's --wait must refuse naming 09.40, the lock untouched (rc=$rc): $out"
  set +e; out="$("$BASH" "$0" --root "$SR" PLAN-09 09.40 --abandon 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq 'nothing was sent' <<< "$out" && [ ! -e "$LK" ] || fail "S25: 09.40 --abandon should recover its own stale lock with no binding (rc=$rc): $out"
  # S26 (r2 codex 1) a ps that fails for the TARGET only (exit 73) while it still reads this shell is a failed lookup, never "gone"
  sleep 30 & lp26=$!
  mkdir -p "$d/fakeps26"; printf '#!/bin/sh\ncase "$4" in %s) exec /bin/ps "$@" ;; esac\nexit 73\n' "$$" > "$d/fakeps26/ps"; chmod +x "$d/fakeps26/ps"
  mkdir "$d/lk26"; printf 'pid=%s\nstart=%s\nwhat=live\nplan=PLAN-09\nstage=09.1\nat=x\n' "$lp26" "$(proc_start "$lp26")" > "$d/lk26/owner"
  set +e; st26="$( PATH="$d/fakeps26:$PATH"; hash -r; lock_state "$d/lk26" 2>/dev/null )"; rc=$?; set -e; hash -r
  kill "$lp26" 2>/dev/null || true; wait "$lp26" 2>/dev/null || true; rm -rf "$d/lk26"
  [ "$rc" -eq 2 ] && [ "$st26" != stale ] || fail "S26: a ps failing for the target only read a live owner as '$st26' (rc=$rc), not a failure"
  # S27 (r2 NB2) an unreadable owner file is a tool failure: a build exits 2 (not 1), nothing launched, the lock untouched
  mkdir "$LK"; printf 'pid=1\nstart=x\n' > "$LK/owner"; chmod 000 "$LK/owner"
  set +e; out="$(PATH="$P2" FAKE_ARGV="$d/sa27" "$BASH" "$0" --root "$SR" PLAN-09 09.2 --again 2>&1)"; rc=$?; set -e
  chmod 600 "$LK/owner"
  [ "$rc" -eq 2 ] && [ ! -e "$d/sa27" ] && [ -f "$LK/owner" ] || fail "S27: an unreadable lock owner should exit 2 with nothing launched (rc=$rc): $out"
  rm -f "$LK/owner"; rmdir "$LK"
  # S28 (r2 codex 8) a takeover claim that cannot be removed is named and is a failure (2), never silently left
  mkdir -p "$d/claim28/x"
  set +e; out="$(claim_drop "$d/claim28" 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && grep -Fq "$d/claim28" <<< "$out" && grep -Fq 'by hand' <<< "$out" || fail "S28: a claim that cannot be removed must be named, exit 2 (rc=$rc): $out"
  rm -rf "$d/claim28"
  # S29 (r2 codex 8) --wait whose "no record yet" state cannot be written is a failure (2), the lock kept — never 75 over an unwritten state
  sed -e 's/^state=.*/state=sent/' -e 's/^session=.*/session=/' -e 's/^rollout=.*/rollout=/' -e 's/^mode=.*/mode=headless/' -e 's|^log=.*|log=tmp/PLAN-09/09.29-run.log|' -e 's/^tag=.*/tag=[planner 09.29-c1]/' "$d/b17.save" > "$SB/09.29-binding"
  printf '# drive-stage: before=x\n' > "$SB/09.29-run.log"
  chmod 555 "$SB"
  set +e; out="$(PATH="$P2" "$BASH" "$0" --root "$SR" PLAN-09 09.29 --wait 2>&1)"; rc=$?; set -e
  chmod 755 "$SB"
  [ "$rc" -eq 2 ] && [ -d "$LK" ] || fail "S29: a failed binding write on --wait's no-record branch must be 2 with the lock kept (rc=$rc): $out"
  "$BASH" "$0" --root "$SR" PLAN-09 09.29 --abandon >/dev/null 2>&1 && [ ! -e "$LK" ] || fail "S29: --abandon should settle it and release"
  # S30 (v0.22) inside Herdr the pane is the default: a build Stage and a --bounded small change open a tab with no --pane; --headless
  # opts out; --resume, --fix and --read stay headless; --pane with --headless is a usage error; a failed gate refuses, naming --headless
  printf 'do stage 09.50\n' > "$SB/09.50-prompt.md"; printf 'resume 09.50\n' > "$SB/09.50-resume-prompt.md"; printf 'read it\n' > "$SB/premise-prompt.md"
  out="$(pe "$BASH" "$0" --root "$SR" PLAN-09 09.50 --dry-run 2>&1)" && grep -q '^herdr tab create ' <<< "$out" && grep -Fq "herdr agent start 'proj-codex-09-50'" <<< "$out" || fail "S30: inside Herdr a Stage should default to a pane: $out"
  out="$(pe "$BASH" "$0" --root "$SR" PLAN-09 09.50 --headless --dry-run 2>&1)" && grep -q '^env -u RATCHET_ALLOW_PUSH .* codex exec ' <<< "$out" && ! grep -q 'herdr' <<< "$out" || fail "S30: --headless should launch without a pane inside Herdr: $out"
  out="$(pe "$BASH" "$0" --root "$SR" PLAN-09 09.50 --resume --dry-run 2>&1)" && grep -q ' codex exec ' <<< "$out" && ! grep -q 'tab create' <<< "$out" || fail "S30: --resume should stay headless inside Herdr: $out"
  out="$(pe "$BASH" "$0" --root "$SR" --fix PLAN-09 tmp/PLAN-09/fix-prompt.md --again --dry-run 2>&1)" && grep -q ' codex exec ' <<< "$out" && ! grep -q 'tab create' <<< "$out" || fail "S30: --fix should stay headless inside Herdr: $out"
  out="$(pe "$BASH" "$0" --root "$SR" --read PLAN-09 tmp/PLAN-09/premise-prompt.md --dry-run 2>&1)" && grep -q ' codex exec ' <<< "$out" && ! grep -q 'tab create' <<< "$out" || fail "S30: --read should stay headless inside Herdr: $out"
  set +e; out="$(pe "$BASH" "$0" --root "$SR" PLAN-09 09.50 --pane --headless --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 64 ] || fail "S30: --pane with --headless should be a usage error (rc=$rc): $out"
  : > "$d/fh/calls.log"
  set +e; out="$(pe env FAKE_HERDR_RUNNING=false FAKE_ARGV="$d/sa30" "$BASH" "$0" --root "$SR" PLAN-09 09.50 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'server is not running' <<< "$out" && grep -Fq 'pass --headless' <<< "$out" && ! grep -q 'tab create' "$d/fh/calls.log" && [ ! -e "$d/sa30" ] || fail "S30: a failed gate under the default should refuse naming --headless, nothing launched (rc=$rc): $out"
  # … a --bounded small change in its own tab: the slug lowercased, anything outside [a-z0-9-] turned into -, scratch under tmp/bounded/
  mkdir -p "$SR/tmp/bounded"; printf 'fix the spacing\n' > "$SR/tmp/bounded/Side_Bar.spacing-prompt.md"
  : > "$d/fh/calls.log"
  set +e; out="$(pe env FAKE_SESSION=pane-b1 FAKE_PANE_COMMIT='sidebar spacing' "$BASH" "$0" --root "$SR" --bounded Side_Bar.spacing 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Eq '^bounded Side_Bar\.spacing exit=0 log=tmp/bounded/Side_Bar\.spacing-run\.log .* session=pane-b1 rollout=tmp/bounded/Side_Bar\.spacing-rollout\.jsonl pane=w1:p[0-9]+ settled=yes$' <<< "$out" || fail "S30: a --bounded pane run's result differs (rc=$rc): $out"
  grep -Eq '^tab create --workspace w1 --cwd .* --label executor \(Side_Bar\.spacing\) ' "$d/fh/calls.log" && grep -Fq 'agent start proj-codex-side-bar-spacing --kind codex' "$d/fh/calls.log" \
    && grep -Fq '[planner Side_Bar.spacing-c1] Your prompt is the file tmp/bounded/Side_Bar.spacing-prompt.md' "$d/fh/calls.log" || fail "S30: the --bounded tab or agent start differs: $(cat "$d/fh/calls.log")"
  [ "$(kv_get "$SR/tmp/bounded/Side_Bar.spacing-binding" mode)" = pane ] && [ ! -e "$LK" ] || fail "S30: the --bounded pane binding differs, or the lock stayed: $(cat "$SR/tmp/bounded/Side_Bar.spacing-binding")"
  [ -z "$(kv_get "$SR/tmp/bounded/Side_Bar.spacing-binding" tab)" ] && grep -q '^tab close w1:t' "$d/fh/calls.log" || fail "S30: a settled small change should close its own tab at once (v0.29): $(cat "$d/fh/calls.log")"
  # … a slug whose agent name is over Herdr's 32 characters refuses before anything is made, naming --headless (which still launches it);
  # the name is checked before the prompt file, so a long slug with no prompt yet gets that refusal first (Pensieve LOG, 2026-10-08)
  set +e; out="$(pe "$BASH" "$0" --root "$SR" --bounded a-very-long-slug-for-herdr --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "over Herdr's 32 characters" <<< "$out" && ! grep -Fq 'prompt file missing' <<< "$out" || fail "S30: a long slug with no prompt should refuse on the name first (rc=$rc): $out"
  printf 'x\n' > "$SR/tmp/bounded/a-very-long-slug-for-herdr-prompt.md"
  set +e; out="$(pe "$BASH" "$0" --root "$SR" --bounded a-very-long-slug-for-herdr --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq "over Herdr's 32 characters" <<< "$out" && grep -Fq -- '--headless' <<< "$out" || fail "S30: a long slug should refuse naming --headless (rc=$rc): $out"
  out="$(pe "$BASH" "$0" --root "$SR" --bounded a-very-long-slug-for-herdr --headless --dry-run 2>&1)" && grep -q ' codex exec ' <<< "$out" || fail "S30: --headless should launch a long slug: $out"
  # S31 (v0.22 r1) `--bounded fix`: a slug named "fix" is a small change like any other — a pane by default inside Herdr, a pane with
  # --pane, headless outside Herdr (the old dispatch read the slug as the fix batch: headless, and 64 with --pane)
  printf 'fix it\n' > "$SR/tmp/bounded/fix-prompt.md"
  out="$(pe "$BASH" "$0" --root "$SR" --bounded fix --dry-run 2>&1)" && grep -Fq "herdr agent start 'proj-codex-fix'" <<< "$out" || fail "S31: --bounded fix inside Herdr should default to a pane: $out"
  set +e; out="$(pe "$BASH" "$0" --root "$SR" --bounded fix --pane --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq "herdr agent start 'proj-codex-fix'" <<< "$out" || fail "S31: --bounded fix --pane should open a pane (rc=$rc): $out"
  out="$("$BASH" "$0" --root "$SR" --bounded fix --dry-run 2>&1)" && grep -q ' codex exec ' <<< "$out" && grep -Fq "'tmp/bounded/fix-run.log'" <<< "$out" || fail "S31: --bounded fix outside Herdr should run headless: $out"
  # S32 (v0.22 r1) the next launch closes a settled Stage's tab only while Herdr reads that pane's Codex idle or done: working (a human
  # typed a follow-up), or a read that fails, leaves it open with one line and never refuses; a pane that no longer holds Codex is closed
  mkdir -p "$d/cst"; cstb="$d/cst/09.60-binding"
  mk32() { printf 'mode=pane\nsession=s60\npane=w1:p60\ntab=w1:t60\nagent=proj-codex-09-60\nstate=settled\ntag=[planner 09.60-c1]\n' > "$cstb"; echo "proj-codex-09-60 w1:p60 s60 " > "$d/fh/agent.w1:p60"; : > "$d/fh/calls.log"; }
  mk32; echo working > "$d/fh/status.w1:p60"
  set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && ! grep -q 'tab close' "$d/fh/calls.log" && [ "$(kv_get "$cstb" tab)" = w1:t60 ] && grep -Fq 'left open' <<< "$out" || fail "S32: a working Codex's tab must be left open, named (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  mk32; printf 'weird_error 1\n' > "$d/fh/fail.agent.get"; echo idle > "$d/fh/status.w1:p60"
  set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r; rm -f "$d/fh/fail.agent.get"
  [ "$rc" -eq 0 ] && ! grep -q 'tab close' "$d/fh/calls.log" && [ "$(kv_get "$cstb" tab)" = w1:t60 ] && grep -Fq 'left open' <<< "$out" || fail "S32: a failed agent read must leave the tab open, never read as idle (rc=$rc): $out"
  mk32; echo idle > "$d/fh/status.w1:p60"
  set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && grep -Fxq 'tab close w1:t60' "$d/fh/calls.log" && [ -z "$(kv_get "$cstb" tab)" ] || fail "S32: an idle Codex's tab should be closed (rc=$rc): $out"
  mk32; rm -f "$d/fh/agent.w1:p60" "$d/fh/status.w1:p60"
  set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && grep -Fxq 'tab close w1:t60' "$d/fh/calls.log" && [ -z "$(kv_get "$cstb" tab)" ] || fail "S32: a pane that no longer holds Codex should be closed (rc=$rc): $out"
  # … (r2) a successful read whose reply isn't an agent object with a string kind never reads as "Codex gone": `{}`, a reply with no
  # .result.agent, and an agent object with a status but no kind all leave the tab open, named; a kind that isn't codex (a shell) closes it
  for rp in '{}' '{"result":{"type":"ok"}}' '{"result":{"agent":{"pane_id":"w1:p60","agent_status":"working"}}}'; do
    mk32; printf '%s\n' "$rp" > "$d/fh/reply.agent.get"
    set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r
    [ "$rc" -eq 0 ] && ! grep -q 'tab close' "$d/fh/calls.log" && [ "$(kv_get "$cstb" tab)" = w1:t60 ] && grep -Fq 'left open' <<< "$out" || fail "S32: the reply $rp must leave the tab open, named (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  done
  mk32; printf '%s\n' '{"result":{"agent":{"agent":"shell","pane_id":"w1:p60","agent_status":"idle"}}}' > "$d/fh/reply.agent.get"
  set +e; out="$( PATH="$P3"; hash -r; close_settled_tabs "$d" cst 2>&1 )"; rc=$?; set -e; hash -r; rm -f "$d/fh/reply.agent.get"
  [ "$rc" -eq 0 ] && grep -Fxq 'tab close w1:t60' "$d/fh/calls.log" && [ -z "$(kv_get "$cstb" tab)" ] || fail "S32: a pane back at a shell should be closed (rc=$rc): $out"
  # S34 (v0.29) a Stage keeps its tab through --wait (S8: the next --continue queues into the live pane). A small change closes its tab when it
  # settles, under the sweep's guard: close_on_settle re-reads a Codex that still reads working for up to DRIVE_STAGE_SETTLE_TAB_WAIT s (Herdr
  # trails the record), then leaves it open, named; outside Herdr it is left open, named
  printf 'do stage 09.61
' > "$SB/09.61-prompt.md"; printf 'do stage 09.62
' > "$SB/09.62-prompt.md"
  set +e; out="$(pe env FAKE_SESSION=pane-61 "$BASH" "$0" --root "$SR" PLAN-09 09.61 --pane 2>&1)"; rc=$?; set -e
  t61="$(bget 09.61 tab)"; p61="$(bget 09.61 pane)"
  [ "$rc" -eq 0 ] && [ -n "$t61" ] && [ "$(bget 09.61 state)" = settled ] || fail "S34: fixture — 09.61's pane launch should settle and keep its tab (rc=$rc): $out"
  n61="$(line_count "$(bget 09.61 rollout)")" || fail "S34: fixture — the record's length"   # a message still out (sent), whose turn then completes
  sed -e 's/^state=.*/state=sent/' -e 's/^tag=.*/tag=[planner 09.61-c9]/' -e "s/^lines=.*/lines=$n61/" -e "s/^sent_s=.*/sent_s=$(date +%s)/" "$SB/09.61-binding" > "$SB/09.61-binding.tmp" && mv "$SB/09.61-binding.tmp" "$SB/09.61-binding" || fail "S34: fixture — the binding"
  "$d/bin2/fake-turn" pane-61 "[planner 09.61-c9] one more thing" C "$(cd "$SR" && pwd -P)"
  echo idle > "$d/fh/status.$p61"; : > "$d/fh/calls.log"
  set +e; out="$(pe env DRIVE_STAGE_SETTLE_TAB_WAIT=5 "$BASH" "$0" --root "$SR" PLAN-09 09.61 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && ! grep -q '^tab close' "$d/fh/calls.log" && [ "$(bget 09.61 tab)" = "$t61" ] && ! grep -Fq 'left open' <<< "$out" \
    || fail "S34: --wait on a Stage should keep its tab open until the Stage ends (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  grep -Eq '^PLAN-09 09\.61 exit=0 .* settled=yes$' <<< "$out" || fail "S34: --wait should have waited the message out: $out"
  # close_on_settle itself, on 09.61's settled binding: a busy Codex is re-read until it reads idle, then the tab closes
  echo 'working 2' > "$d/fh/status.$p61"; : > "$d/fh/calls.log"
  set +e; out="$( export PATH="$P3" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1; hash -r; SETTLE_TAB_WAIT=5; POLL=0.2; close_on_settle "$SB/09.61-binding" 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && grep -Fxq "tab close $t61" "$d/fh/calls.log" && [ -z "$(bget 09.61 tab)" ] && [ "$(grep -c "^agent get $p61\$" "$d/fh/calls.log")" -ge 3 ] && ! grep -Fq 'left open' <<< "$out" \
    || fail "S34: close_on_settle should close a settled run's tab once its Codex reads idle, re-reading a busy one (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  set +e; out="$(pe env FAKE_SESSION=pane-62 "$BASH" "$0" --root "$SR" PLAN-09 09.62 --pane 2>&1)"; rc=$?; set -e
  t62="$(bget 09.62 tab)"; p62="$(bget 09.62 pane)"; [ "$rc" -eq 0 ] && [ -n "$t62" ] || fail "S34: fixture — 09.62's pane launch (rc=$rc): $out"
  echo working > "$d/fh/status.$p62"; : > "$d/fh/calls.log"
  set +e; out="$( export PATH="$P3" HERDR_ENV=1 HERDR_WORKSPACE_ID=w1; hash -r; SETTLE_TAB_WAIT=1; POLL=0.2; close_on_settle "$SB/09.62-binding" 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && ! grep -q '^tab close' "$d/fh/calls.log" && [ "$(bget 09.62 tab)" = "$t62" ] && grep -Fq "tab $t62 is left open — its Codex reads working" <<< "$out" \
    || fail "S34: a Codex still working after the wait should leave the tab open, named (rc=$rc): $out"
  set +e; out="$( export PATH="$P3"; unset HERDR_ENV; hash -r; close_on_settle "$SB/09.62-binding" 2>&1 )"; rc=$?; set -e; hash -r
  [ "$rc" -eq 0 ] && [ "$(bget 09.62 tab)" = "$t62" ] && grep -Fq "tab $t62 is left open — no tested Herdr" <<< "$out" || fail "S34: outside Herdr the tab should be left open, named (rc=$rc): $out"
  rm -f "$d/fh/status.$p62"
  # … and a small change's queued --continue into its live pane closes the tab when that message settles (its first run's tab left open: busy)
  printf 'small one\n' > "$SR/tmp/bounded/s34-prompt.md"; printf 'and its fix\n' > "$SR/tmp/bounded/s34-fix-prompt.md"
  pn=$(( $(cat "$d/fh/tabs") + 1 )); echo working > "$d/fh/status.w1:p$pn"
  set +e; out="$(pe env FAKE_SESSION=pane-s34 DRIVE_STAGE_SETTLE_TAB_WAIT=0 "$BASH" "$0" --root "$SR" --bounded s34 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$(kv_get "$SR/tmp/bounded/s34-binding" tab)" = "w1:t$pn" ] || fail "S34: fixture — the small change's tab should stay open while its Codex reads working (rc=$rc): $out"
  rm -f "$d/fh/status.w1:p$pn"; : > "$d/fh/calls.log"
  set +e; out="$(pe env FAKE_ARGV="$d/sa34" FAKE_REPO="$SR" "$BASH" "$0" --root "$SR" --bounded s34 --continue tmp/bounded/s34-fix-prompt.md 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fxq queue "$d/sa34" && grep -Fxq "tab close w1:t$pn" "$d/fh/calls.log" && [ -z "$(kv_get "$SR/tmp/bounded/s34-binding" tab)" ] \
    || fail "S34: a small change's queued --continue should close its tab when it settles (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  # … and a small change's --wait closes its tab once its Codex reads idle (its own run left the tab open: busy)
  printf 'another small one\n' > "$SR/tmp/bounded/s35-prompt.md"
  pn=$(( $(cat "$d/fh/tabs") + 1 )); echo working > "$d/fh/status.w1:p$pn"
  set +e; out="$(pe env FAKE_SESSION=pane-s35 DRIVE_STAGE_SETTLE_TAB_WAIT=0 "$BASH" "$0" --root "$SR" --bounded s35 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && [ "$(kv_get "$SR/tmp/bounded/s35-binding" tab)" = "w1:t$pn" ] || fail "S34: fixture — s35's tab should stay open while its Codex reads working (rc=$rc): $out"
  rm -f "$d/fh/status.w1:p$pn"; : > "$d/fh/calls.log"
  set +e; out="$(pe "$BASH" "$0" --root "$SR" --bounded s35 --wait 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fxq "tab close w1:t$pn" "$d/fh/calls.log" && [ -z "$(kv_get "$SR/tmp/bounded/s35-binding" tab)" ] \
    || fail "S34: a small change's --wait should close its settled tab (rc=$rc): $out / $(cat "$d/fh/calls.log")"
  # S33 (v0.22 r1) the agent name's lowercase step failing (after printing its input unchanged) is exit 2, never a name built on its
  # output — for the Stage's part and for the project's (no DRIVE_STAGE_PROJECT: the folder name); no pipe hides the first step's status
  # The fake fails only on the one input FAKE_TR_ON names (the Stage's 09.50, or the folder name srepo), so each assertion proves its own step
  mkdir -p "$d/faketr"; rtr="$(shq "$(command -v tr)")"
  printf '#!/bin/sh\nif [ "$1" = A-Z ]; then in="$(cat)"; if [ "$in" = "$FAKE_TR_ON" ]; then printf "%%s\\n" "$in"; echo "tr: injected failure" >&2; exit 73; fi; printf "%%s\\n" "$in" | %s "$@"; exit $?; fi\nexec %s "$@"\n' "$rtr" "$rtr" > "$d/faketr/tr"; chmod +x "$d/faketr/tr"
  set +e; out="$(PATH="$d/faketr:$P3" FAKE_TR_ON=09.50 HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 DRIVE_STAGE_PROJECT=proj "$BASH" "$0" --root "$SR" PLAN-09 09.50 --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && grep -Fq "tr failed lowercasing '09.50'" <<< "$out" && ! grep -q 'herdr agent start' <<< "$out" || fail "S33: a failing tr in the Stage's part of the agent name should be exit 2 (rc=$rc): $out"
  set +e; out="$(PATH="$d/faketr:$P3" FAKE_TR_ON=srepo HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 "$BASH" "$0" --root "$SR" PLAN-09 09.50 --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 2 ] && grep -Fq "tr failed lowercasing 'srepo'" <<< "$out" && ! grep -q 'herdr agent start' <<< "$out" || fail "S33: a failing tr in the project's part of the agent name should be exit 2 (rc=$rc): $out"
  unset FAKE_HERDR FAKE_BIN2
  fi
  # SP (v0.25) split-repo mode: RATCHET_RECORDS in the code repo's script/ratchet.conf names a nested records repo (modules/split-repo.md).
  # -C and every run file stay in the code repo (the brief's acceptance 5); a build's message carries the [split-repo] line after the tag;
  # workspace-write grants the records repo's git dir too; the header ends records=; the result line adds records-head / records-commit and
  # changed= counts both repos; a read and a review name the records repo; one repo prints none of it; a bad records root is exit 2
  SP="$d/split"; mkdir -p "$SP/script" "$SP/tmp/PLAN-07"; printf 'RATCHET_RECORDS=private\n' > "$SP/script/ratchet.conf"
  ( cd "$SP" && git init -q && git config user.email t@t && git config user.name t && printf 'x\n' > a.txt && printf 'tmp/\n/private\n' > .gitignore \
    && git add a.txt .gitignore script/ratchet.conf && git commit -qm init && git init -q private && cd private && git config user.email t@t && git config user.name t \
    && printf '# LOG\n' > LOG.md && git add LOG.md && git commit -qm init ) >/dev/null || fail "SP: fixture"
  printf 'do stage 07.1\n' > "$SP/tmp/PLAN-07/07.1-prompt.md"; printf 'read it\n' > "$SP/tmp/PLAN-07/premise-prompt.md"
  out="$(DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$SP" PLAN-07 07.1 --dry-run 2>&1)" || fail "SP: the split dry-run failed: $out"
  grep -Fq -- " -C '$SP' " <<< "$out" && grep -Fq ">> 'tmp/PLAN-07/07.1-run.log' 2>&1" <<< "$out" || fail "SP: -C must be the code root and the run log under the code repo's tmp/: $out"
  grep -Fq -- "--add-dir '$SP/.git'" <<< "$out" && grep -Fq -- "--add-dir '$SP/private/.git'" <<< "$out" || fail "SP: workspace-write must grant both repos' git dirs: $out"
  grep -Fq "'[split-repo] The records (PLAN.md, the LOG, the plan files) are the separate git repo at private/" <<< "$out" && grep -Fq 'Code: <short sha>' <<< "$out" || fail "SP: the dry-run's message must carry the build note: $out"
  out="$(HERDR_ENV=1 HERDR_WORKSPACE_ID=w1 DRIVE_STAGE_PROJECT=proj "$BASH" "$0" --root "$SP" PLAN-07 07.1 --dry-run 2>&1)" || fail "SP: the split pane dry-run failed: $out"
  grep -Fq "read it in full and carry it out. [split-repo] The records" <<< "$out" || fail "SP: a pane launch's pointer must carry the note on its one line: $out"
  # the real launch (fake codex): the argv's message is tag, note, prompt; the header ends records=<short>; the result line adds the records fields
  rsh="$(git -C "$SP/private" rev-parse --short HEAD)"; csh="$(git -C "$SP" rev-parse --short HEAD)"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvSP" "$BASH" "$0" --root "$SP" PLAN-07 07.1 --no-preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 3 ] && [ "$out" = "PLAN-07 07.1 exit=3 log=tmp/PLAN-07/07.1-run.log head=$csh changed=1 commit=none session=none rollout=none records-head=$rsh records-commit=none" ] \
    || fail "SP: the split result line differs (rc=$rc): $out"
  head -n 1 "$SP/tmp/PLAN-07/07.1-run.log" | grep -Eq "^# drive-stage: before=$csh sandbox=danger-full-access started=[0-9TZ:-]+ records=$rsh\$" || fail "SP: the header must end records=$rsh: $(head -n 1 "$SP/tmp/PLAN-07/07.1-run.log")"
  [ "$(sed -n '/^\[planner 07.1-c1\]$/,$p' "$d/argvSP")" = "$(printf '[planner 07.1-c1]\n%s\ndo stage 07.1' "$( ( REC_REL=private; split_note build PLAN-07 ) )")" ] || fail "SP: the message must be the tag, the note, then the prompt: $(cat "$d/argvSP")"
  # where the Code: line goes: a Stage or --fix build names the plan's evidence entry; a --bounded small change its LOG entry, never a plan's files
  ns="$( ( REC_REL=private; split_note build PLAN-07 ) )"; nb="$( ( REC_REL=private; split_note build bounded ) )"
  grep -Fq "the plan's evidence entry (docs/plans/PLAN-NN-review/EVIDENCE.md there)" <<< "$ns" && ! grep -Fq 'LOG entry carrying' <<< "$ns" || fail "SP: a Stage build's note must name the evidence entry: $ns"
  grep -Fq "the small change's LOG entry carrying a \`Code: <short sha>\` line" <<< "$nb" && grep -Fq "A closed plan's files are never edited." <<< "$nb" && ! grep -Fq 'EVIDENCE.md' <<< "$nb" \
    || fail "SP: a --bounded build's note must put the Code: line in its LOG entry, never a plan's evidence file: $nb"
  grep -Fxq 'rhead='"$(git -C "$SP/private" rev-parse HEAD)" "$SP/tmp/PLAN-07/07.1-binding" || fail "SP: the binding must keep the records HEAD: $(cat "$SP/tmp/PLAN-07/07.1-binding")"
  # a records-only change: result_line reads the records commit and counts its paths (never commit=none alone)
  ( cd "$SP/private" && printf '\n## e\nCode: %s\n' "$csh" >> LOG.md && git commit -qam 'PLAN-07 / 07.1 — records' && printf 'n\n' > new.md ) >/dev/null || fail "SP: records commit"
  out="$( REC_REL=private; REC="$SP/private"; bind_clear; bind_read "$SP/tmp/PLAN-07/07.1-binding"; R_SESSION=none; R_COPY=none; rm -f "$SP/created-by-codex.txt"; result_line "$SP" PLAN-07 07.1 0 tmp/PLAN-07/07.1-run.log "$csh" "" 2>&1 )" || fail "SP: result_line failed: $out"
  [ "$out" = "PLAN-07 07.1 exit=0 log=tmp/PLAN-07/07.1-run.log head=$csh changed=2 commit=none session=none rollout=none records-head=$(git -C "$SP/private" rev-parse --short HEAD) records-commit=$(git -C "$SP/private" rev-parse --short HEAD)" ] \
    || fail "SP: a records commit must show as records-commit=<sha> with both its paths counted: $out"
  out="$( REC_REL=private; REC="$SP/private"; bind_clear; B_head="$(git -C "$SP" rev-parse HEAD)"; R_SESSION=none; R_COPY=none; result_line "$SP" PLAN-07 07.1 0 tmp/PLAN-07/07.1-run.log "$csh" "" 2>&1 )" || fail "SP: result_line with an old binding failed: $out"
  grep -Fq " records-commit=unknown" <<< "$out" || fail "SP: a binding with no rhead must read records-commit=unknown, never a guess: $out"
  rm -f "$SP/private/new.md"
  # a read names the records repo (dry-run and header); a review names it and the Stage's records range from the header
  out="$("$BASH" "$0" --root "$SP" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --dry-run 2>&1)" || fail "SP: the read dry-run failed: $out"
  grep -Fq "\"\$(printf '%s\\n' '[split-repo] The records (PLAN.md, the LOG, the plan files) are the separate git repo at private/ (modules/split-repo.md): read the plan and the LOG there.'; cat '$SP/tmp/PLAN-07/premise-prompt.md')\"" <<< "$out" || fail "SP: the read's dry-run must put the read note before the prompt: $out"
  set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvSPr" "$BASH" "$0" --root "$SP" --read PLAN-07 tmp/PLAN-07/premise-prompt.md --no-preflight 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 0 ] && grep -Fq " records-head=$(git -C "$SP/private" rev-parse --short HEAD)" <<< "$out" && head -n 1 "$SP/tmp/PLAN-07/premise-read.log" | grep -Fq " records=$(git -C "$SP/private" rev-parse HEAD)" \
    && grep -Fq '[split-repo] The records' "$d/argvSPr" || fail "SP: a read must record and name the records repo (rc=$rc): $out / $(cat "$d/argvSPr")"
  ( cd "$SP" && printf 'y\n' > b.txt && git add b.txt && git commit -qm 'PLAN-07 / 07.1 — code' ) >/dev/null || fail "SP: code commit"
  mkdir -p "$SP/.codex/agents" && printf 'x\n' > "$SP/.codex/agents/t-reviewer.toml"
  out="$(DRIVE_STAGE_REVIEW_MANDATE=.codex/agents/t-reviewer.toml "$BASH" "$0" --root "$SP" --review PLAN-07 07.1 --dry-run 2>&1)" || fail "SP: the split review dry-run failed: $out"
  grep -Fq "Split-repo mode (modules/split-repo.md): the records (PLAN.md, the LOG, the plan file and its Verify: blocks, and the evidence file holding its proof table) are the separate git repo at private/" <<< "$out" \
    && grep -Fq "git -C private diff $(git -C "$SP/private" rev-parse "$rsh")..$(git -C "$SP/private" rev-parse HEAD)" <<< "$out" || fail "SP: the review must name the records repo and the Stage's records range: $out"
  grep -Fq "It runs to the records HEAD, so it may include later Stages" <<< "$out" && grep -Fq "are the commits under its own subject" <<< "$out" \
    && ! grep -Fq "records half is the range" <<< "$out" || fail "SP: the records range must be labelled as running to the records HEAD, never as the Stage's own half: $out"
  sed '1s/ records=[0-9a-f]*$/ records=0000000/' "$SP/tmp/PLAN-07/07.1-run.log" > "$SP/t" && mv "$SP/t" "$SP/tmp/PLAN-07/07.1-run.log"
  set +e; out="$(DRIVE_STAGE_REVIEW_MANDATE=.codex/agents/t-reviewer.toml "$BASH" "$0" --root "$SP" --review PLAN-07 07.1 --dry-run 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'records=0000000 is not a commit in the records repo private' <<< "$out" || fail "SP: a header records= that isn't a commit must refuse, never guess a range (rc=$rc): $out"
  # an EMPTY environment RATCHET_RECORDS leaves the conf in force (every kit script reads it so): still split-repo
  out="$(RATCHET_RECORDS= DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)" || fail "SP: the dry-run with an empty environment value failed: $out"
  grep -Fq '[split-repo]' <<< "$out" && grep -Fq 'private/.git' <<< "$out" || fail "SP: an empty RATCHET_RECORDS in the environment must leave the conf's records repo in force: $out"
  # one repo prints none of it: the same fixture with a conf that names no records repo
  printf '# one repo\n' > "$SP/script/ratchet.conf"
  out="$(DRIVE_STAGE_SANDBOX=workspace-write "$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)" || fail "SP: the one-repo dry-run failed: $out"
  grep -Fq 'split-repo' <<< "$out" && fail "SP: one repo must print no split-repo line: $out"
  grep -Fq 'private/.git' <<< "$out" && fail "SP: one repo must grant no records git dir: $out"
  # trailing slashes are stripped; a non-empty environment value wins over the conf, trailing slash and all
  printf 'RATCHET_RECORDS=private//\n' > "$SP/script/ratchet.conf"
  out="$("$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)" && grep -Fq 'separate git repo at private/ ' <<< "$out" || fail "SP: the conf's trailing slashes must be stripped: $out"
  printf 'RATCHET_RECORDS=nope\n' > "$SP/script/ratchet.conf"
  out="$(RATCHET_RECORDS=private/ "$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)" && grep -Fq 'separate git repo at private/ ' <<< "$out" || fail "SP: a non-empty environment RATCHET_RECORDS must win over the conf's: $out"
  # a records root that can't be used is exit 2, never one repo: missing, not its own repo, absolute, a conf that fails to source, a
  # symlink along the path (the link itself, or a linked parent), a '.', '..' or empty component
  ln -s "$SP/private" "$SP/lnk"; mkdir -p "$SP/real" && git init -q "$SP/real/rec" && ln -s "$SP/real" "$SP/via" || fail "SP: symlink fixture"
  for bad in 'RATCHET_RECORDS=nope' 'RATCHET_RECORDS=tmp' "RATCHET_RECORDS=$SP/private" 'false' 'RATCHET_RECORDS=lnk' 'RATCHET_RECORDS=via/rec' \
      'RATCHET_RECORDS=./private' 'RATCHET_RECORDS=private/../private' 'RATCHET_RECORDS=real//rec'; do
    printf '%s\n' "$bad" > "$SP/script/ratchet.conf"
    set +e; out="$("$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 2 ] && ! grep -q 'codex exec' <<< "$out" || fail "SP: the conf line '$bad' must be exit 2 with nothing printed to run (rc=$rc): $out"
    case "$bad" in *lnk|*via/rec) grep -Fq 'a symlink along the path' <<< "$out" || fail "SP: '$bad' must be refused as a symlinked path: $out" ;;
      *./private|*../private|*//rec) grep -Fq "a '.', '..' or empty component" <<< "$out" || fail "SP: '$bad' must be refused for its components: $out" ;; esac
  done
  printf 'RATCHET_RECORDS=real/rec\n' > "$SP/script/ratchet.conf"   # control: the same repo with no symlink passes the rule
  out="$("$BASH" "$0" --root "$SP" PLAN-07 07.1 --again --dry-run 2>&1)" && grep -Fq 'separate git repo at real/rec/ ' <<< "$out" || fail "SP: real/rec (no symlink) must pass the path rule: $out"
  rm -f "$SP/lnk" "$SP/via"; rm -rf "$SP/real"
  printf 'RATCHET_RECORDS=private\n' > "$SP/script/ratchet.conf"
  # SC (v0.30): a build session's agent temp is outside the repo, under the project's scratch root (protocol/context-discipline.md
  # § Workspace): <the main checkout's parent>/<its folder>-scratch/tmp/<PLAN-NN|bounded>/; XP_SCRATCH_PARENT replaces the parent. Anything that
  # fails keeps the inherited TMPDIR with one line; a dry-run prints it and makes nothing
  SC="$d/screpo"; mkdir -p "$SC/tmp/PLAN-07" "$SC/tmp/bounded"
  ( cd "$SC" && git init -q && git config user.email t@t && git config user.name t && printf 'x\n' > a.txt && printf 'tmp/\n' > .gitignore && git add a.txt .gitignore && git commit -qm init ) >/dev/null || fail "SC: fixture"
  printf 'do stage 07.1\n' > "$SC/tmp/PLAN-07/07.1-prompt.md"; printf 'tweak\n' > "$SC/tmp/bounded/tw-prompt.md"
  scl() { set +e; out="$(PATH="$d/bin:$PATH" FAKE_ARGV="$d/argvSC" FAKE_TMPDIR_OUT="$d/scT" TMPDIR="$d/inherited/" "$@" 2>&1)"; rc=$?; set -e; }
  [ "$( unset XP_SCRATCH_PARENT; xp_scratch_root "$SC" )" = "$d/screpo-scratch" ] || fail "SC: the main checkout's scratch root differs: $( unset XP_SCRATCH_PARENT; xp_scratch_root "$SC" 2>&1 )"
  git -C "$SC" worktree add -q --detach "$d/screpo-PLAN-07" 2>/dev/null || fail "SC: worktree"
  [ "$( unset XP_SCRATCH_PARENT; xp_scratch_root "$d/screpo-PLAN-07" )" = "$d/screpo-scratch" ] || fail "SC: a stream's worktree must map to its project's root, never <worktree>-scratch: $( unset XP_SCRATCH_PARENT; xp_scratch_root "$d/screpo-PLAN-07" 2>&1 )"
  git init -q --separate-git-dir "$d/sep.git" "$d/sepwt" >/dev/null || fail "SC: separate git dir"
  [ "$( unset XP_SCRATCH_PARENT; xp_scratch_root "$d/sepwt" )" = "$d/sepwt-scratch" ] || fail "SC: a git dir kept elsewhere must map to the checkout itself: $( unset XP_SCRATCH_PARENT; xp_scratch_root "$d/sepwt" 2>&1 )"
  [ "$(xp_scratch_tmpdir "$SC" PLAN-07)" = "$sr/screpo-scratch/tmp/PLAN-07/" ] && [ "$(xp_scratch_tmpdir "$SC" bounded)" = "$sr/screpo-scratch/tmp/bounded/" ] || fail "SC: the plan's and the small changes' TMPDIR differ"
  for bad in PLAN-0x PLAN- ../x '' bounded/..; do
    set +e; out="$(xp_scratch_tmpdir "$SC" "$bad" 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 1 ] && grep -Fq 'is not PLAN-NN or bounded' <<< "$out" || fail "SC: the name '$bad' must be refused (rc=$rc): $out"
  done
  for bad in rel/x /; do
    set +e; out="$(XP_SCRATCH_PARENT="$bad"; xp_scratch_tmpdir "$SC" PLAN-07 2>&1)"; rc=$?; set -e
    [ "$rc" -eq 1 ] && grep -Fq 'is not an absolute folder below /' <<< "$out" || fail "SC: the override '$bad' must be refused (rc=$rc): $out"
  done
  set +e; out="$(XP_SCRATCH_PARENT="/$(printf '%051d' 0)"; xp_scratch_tmpdir "$SC" PLAN-07 2>&1)"; rc=$?; set -e   # / + 51 + /screpo-scratch/tmp/PLAN-07/ = 80: fits
  [ "$rc" -eq 0 ] || fail "SC: an 80-byte TMPDIR must pass (rc=$rc): $out"
  set +e; out="$(XP_SCRATCH_PARENT="/$(printf '%052d' 0)"; xp_scratch_tmpdir "$SC" PLAN-07 2>&1)"; rc=$?; set -e   # 81: over
  [ "$rc" -eq 1 ] && grep -Fq 'over 80' <<< "$out" && grep -Fq 'set XP_SCRATCH_PARENT to a shorter folder' <<< "$out" || fail "SC: an 81-byte TMPDIR must be refused, naming the override (rc=$rc): $out"
  # bytes, not characters: 30 two-byte letters make 59 characters but 89 bytes under a UTF-8 locale
  mb=""; i=0; while [ "$i" -lt 30 ]; do mb="$mb$(printf '\303\251')"; i=$((i + 1)); done
  set +e; out="$(LC_ALL=en_US.UTF-8; XP_SCRATCH_PARENT="/$mb"; xp_scratch_tmpdir "$SC" PLAN-07 2>&1)"; rc=$?; set -e
  [ "$rc" -eq 1 ] && grep -Fq 'is 89 bytes, over 80' <<< "$out" || fail "SC: the cap must count bytes, not characters (rc=$rc): $out"
  # one XP_SCRATCH_PARENT, two projects: each keeps its own root (a PLAN-07 in one never shares a folder with the other's)
  git init -q "$d/pa" && git init -q "$d/pb" || fail "SC: two projects"
  [ "$(XP_SCRATCH_PARENT="$sr/"; xp_scratch_root "$d/pa")" = "$sr/pa-scratch" ] && [ "$(XP_SCRATCH_PARENT="$sr/"; xp_scratch_root "$d/pb")" = "$sr/pb-scratch" ] \
    || fail "SC: two projects under one XP_SCRATCH_PARENT must get distinct roots: $(XP_SCRATCH_PARENT="$sr/"; xp_scratch_root "$d/pa" 2>&1) / $(XP_SCRATCH_PARENT="$sr/"; xp_scratch_root "$d/pb" 2>&1)"
  # a real build: the session's TMPDIR is the plan's, made; nothing said
  scl "$BASH" "$0" --root "$SC" PLAN-07 07.1 --no-preflight
  [ "$rc" -eq 3 ] && [ "$(cat "$d/scT")" = "$sr/screpo-scratch/tmp/PLAN-07/" ] && [ -d "$sr/screpo-scratch/tmp/PLAN-07" ] && ! grep -Fq 'keeps TMPDIR' <<< "$out" || fail "SC: a build's session must get the plan's agent temp (rc=$rc, TMPDIR=$(cat "$d/scT" 2>&1)): $out"
  # a small change: the bounded folder
  scl "$BASH" "$0" --root "$SC" --bounded tw --headless --no-preflight
  [ "$rc" -eq 3 ] && [ "$(cat "$d/scT")" = "$sr/screpo-scratch/tmp/bounded/" ] || fail "SC: a small change's session must get the bounded agent temp (rc=$rc, TMPDIR=$(cat "$d/scT" 2>&1)): $out"
  # an unusable override, or a folder that can't be made: the run goes on with the inherited TMPDIR, said once
  XP_SCRATCH_PARENT=rel scl "$BASH" "$0" --root "$SC" PLAN-07 07.1 --again --no-preflight
  [ "$rc" -eq 3 ] && [ "$(cat "$d/scT")" = "$d/inherited/" ] && [ "$(grep -c 'keeps TMPDIR' <<< "$out")" -eq 1 ] || fail "SC: an unusable root must keep the inherited TMPDIR, said once (rc=$rc, TMPDIR=$(cat "$d/scT" 2>&1)): $out"
  mkdir "$sr/ro" && chmod 555 "$sr/ro"
  XP_SCRATCH_PARENT="$sr/ro/x" scl "$BASH" "$0" --root "$SC" PLAN-07 07.1 --again --no-preflight
  chmod 755 "$sr/ro"
  [ "$rc" -eq 3 ] && [ "$(cat "$d/scT")" = "$d/inherited/" ] && grep -Fq "cannot create or write $sr/ro/x/screpo-scratch/tmp/PLAN-07/" <<< "$out" || fail "SC: a folder that can't be made must keep the inherited TMPDIR (rc=$rc, TMPDIR=$(cat "$d/scT" 2>&1)): $out"
  # a pane's shell starts from Herdr's environment: when no agent temp could be chosen it still gets the inherited TMPDIR, and it always
  # gets XP_SCRATCH_PARENT when set, so the session's own launcher and tidy compute the same root
  : > "$d/fh/calls.log"; printf 'do 09.88\n' > "$SR/tmp/PLAN-09/09.88-prompt.md"; mkdir -p "$d/inh"
  set +e; out="$(pe env FAKE_HERDR="$d/fh" FAKE_BIN2="$d/bin2" XP_SCRATCH_PARENT=rel TMPDIR="$d/inh/" FAKE_SESSION=pane-88 FAKE_PANE_COMMIT='PLAN-09 / 09.88' "$BASH" "$0" --root "$SR" PLAN-09 09.88 --pane 2>&1)"; rc=$?; set -e
  grep -Fxq "tab create --workspace w1 --cwd $SR --label executor (09.88) --env DISABLE_AUTO_UPDATE=true --env RATCHET_ALLOW_PUSH= --env TMPDIR=$d/inh/ --env XP_SCRATCH_PARENT=rel --no-focus" "$d/fh/calls.log" \
    || fail "SC: a pane with no agent temp must still get the inherited TMPDIR, and XP_SCRATCH_PARENT (rc=$rc): $out / $(grep '^tab create' "$d/fh/calls.log")"
  # a dry-run prints the TMPDIR on the command and makes nothing; a --continue's prints it too
  rm -rf "$sr/screpo-scratch"
  out="$("$BASH" "$0" --root "$SC" PLAN-07 07.1 --again --dry-run 2>&1)" && grep -Fq "env -u RATCHET_ALLOW_PUSH TMPDIR='$sr/screpo-scratch/tmp/PLAN-07/' " <<< "$out" && [ ! -e "$sr/screpo-scratch" ] || fail "SC: a dry-run must print the TMPDIR and make nothing: $out"
  echo "SELF-TEST OK"; exit 0
fi

if [ "$preflight_only" -eq 1 ]; then   # every pin that is filled, each smoked under its own model (a builder-less project fills only the review pin)
  n=0
  for pin in "$CODEX_MODEL|$CODEX_REASONING|build" "$CODEX_REVIEW_MODEL|$CODEX_REVIEW_REASONING|review"; do
    m="${pin%%|*}"; r="${pin#*|}"; r="${r%%|*}"; w="${pin##*|}"
    case "$m$r" in *EDIT-ME*) echo "drive-stage: preflight — the $w pin is not filled (EDIT-ME); not smoked" ;; *) preflight "$ROOT" "$m" "$r" || exit 1; echo "drive-stage: preflight OK — the $w pin $m ($r)"; n=$((n+1)) ;; esac
  done
  [ "$n" -gt 0 ] || { echo "drive-stage: preflight — no pin is filled: edit the invocation block first" >&2; exit 1; }
  exit 0
fi
records_resolve "$ROOT" || exit 2   # split-repo mode's records root (REC_REL, REC); one repo leaves both empty
trap on_exit EXIT; trap 'exit 130' INT; trap 'exit 143' TERM   # the run lock is dropped on exit only when the run is settled (on_exit)
sess=0; for f in "$waitmode" "$peekmode" "$abandonmode"; do sess=$((sess + f)); done; [ -z "$cont_prompt" ] || sess=$((sess + 1))
if [ "$readmode" -eq 1 ] || [ "$fixmode" -eq 1 ]; then
  [ "$readmode" -eq 0 ] || [ "$fixmode" -eq 0 ] || { echo "drive-stage: --read and --fix are two modes — pick one" >&2; exit 64; }
  [ "$review" -eq 0 ] && [ -z "$bounded" ] && [ "$resume" -eq 0 ] && [ -z "$base" ] && [ "$rhead_set" -eq 0 ] && [ "$sess" -eq 0 ] && [ "$panemode" -eq 0 ] || { echo "drive-stage: --read/--fix take PLAN-NN <prompt-file> [--again] [--dry-run] [--no-preflight] (--fix also --heavy, --sandbox); they always run headless" >&2; exit 64; }
  case "$plan" in PLAN-[0-9]*) ;; *) echo "drive-stage: --read/--fix need PLAN-NN <prompt-file> (got '${plan:-}')" >&2; exit 64 ;; esac
  [ -n "$stage" ] || { echo "drive-stage: --read/--fix need a <prompt-file> after PLAN-NN" >&2; exit 64; }
  if [ "$readmode" -eq 1 ]; then
    [ "$heavy" -eq 0 ] && [ "$sandbox_set" -eq 0 ] || { echo "drive-stage: --read is read-only by design (no --heavy/--sandbox)" >&2; exit 64; }
    read_plan "$ROOT" "$plan" "$stage" "$again" "$dry"; exit $?
  fi
  scratch_env "$ROOT" "$plan" "$dry"; drive "$ROOT" "$plan" fix "$heavy" 0 "$stage" "$again" "$dry" 1; exit $?
fi
if [ -n "$bounded" ]; then
  [ -z "$plan" ] || { echo "drive-stage: --bounded takes no PLAN-NN" >&2; exit 64; }
  case "$bounded" in *[!A-Za-z0-9._-]*|"") echo "drive-stage: --bounded slug must be [A-Za-z0-9._-]+ (got '$bounded')" >&2; exit 64 ;; esac
  plan=bounded; stage="$bounded"
fi
case "$plan" in PLAN-[0-9]*|bounded) ;; *) echo 'usage: drive-stage.sh PLAN-NN NN.X [--heavy] [--sandbox <mode>] [--pane | --headless] [--resume [<prompt-file>]] [--again] [--dry-run] | PLAN-NN NN.X --continue <prompt-file> | --wait | --peek | --abandon | --bounded <slug> [flags] | --review PLAN-NN NN.X [--base <sha>] [--head <sha>] [--again] [--dry-run] | --read PLAN-NN <prompt-file> [--again] [--dry-run] | --fix PLAN-NN <prompt-file> [--again] [--dry-run]' >&2; exit 64 ;; esac
if [ "$plan" != bounded ]; then case "$stage" in
  [0-9]*.[0-9]*) ;;
  fix) [ "$sess" -gt 0 ] && [ -z "$cont_prompt" ] || { echo "drive-stage: 'fix' names the last --fix batch's session for --wait, --peek and --abandon only — a fix batch is never continued (a new --fix is a fresh session)" >&2; exit 64; } ;;
  *) echo "drive-stage: stage must look like NN.X (got '${stage:-}')" >&2; exit 64 ;;
esac; fi
if [ "$review" -eq 1 ]; then
  [ "$heavy" -eq 0 ] && [ "$resume" -eq 0 ] && [ "$sandbox_set" -eq 0 ] && [ "$sess" -eq 0 ] && [ "$panemode" -eq 0 ] || { echo "drive-stage: --review takes only --base, --head, --again, --dry-run, --no-preflight (no --heavy/--resume/--sandbox: the review is read-only by design)" >&2; exit 64; }
  [ "$rhead_set" -eq 0 ] || [ -n "$rhead" ] || { echo "drive-stage: --head was given an EMPTY value (an unset variable?) — refused, never read as the current HEAD: that would silently widen the range to every later Stage" >&2; exit 64; }
  review "$ROOT" "$plan" "$stage" "$base" "$again" "$dry" "$rhead"; exit $?
fi
[ -z "$base" ] || { echo "drive-stage: --base belongs to --review" >&2; exit 64; }
[ "$rhead_set" -eq 0 ] || { echo "drive-stage: --head belongs to --review" >&2; exit 64; }
if [ "$sess" -gt 0 ]; then   # the Stage's session: continue it, reattach, look, or settle — PLAN-NN NN.X or --bounded <slug>
  [ "$sess" -eq 1 ] || { echo "drive-stage: --continue, --wait, --peek and --abandon are four modes — pick one" >&2; exit 64; }
  [ "$resume" -eq 0 ] && [ "$again" -eq 0 ] && [ "$panemode" -eq 0 ] && [ "$headless" -eq 0 ] || { echo "drive-stage: --continue/--wait/--peek/--abandon take no --resume, --again, --pane or --headless (the mode follows the Stage's binding)" >&2; exit 64; }
  if [ -n "$cont_prompt" ]; then scratch_env "$ROOT" "$plan" "$dry"; cont "$ROOT" "$plan" "$stage" "$cont_prompt" "$heavy" "$dry"; exit $?; fi
  [ "$dry" -eq 0 ] && [ "$sandbox_set" -eq 0 ] || { echo "drive-stage: --wait/--peek/--abandon send nothing (no --dry-run, no --sandbox)" >&2; exit 64; }
  if [ "$waitmode" -eq 1 ]; then wait_run "$ROOT" "$plan" "$stage" "$heavy"; exit $?; fi
  [ "$heavy" -eq 0 ] || { echo "drive-stage: --peek/--abandon take no --heavy" >&2; exit 64; }
  if [ "$peekmode" -eq 1 ]; then peek "$ROOT" "$plan" "$stage" "${DRIVE_STAGE_PEEK_N:-8}"; exit $?; fi
  abandon "$ROOT" "$plan" "$stage"; exit $?
fi
if [ "$panemode" -eq 1 ] || { [ "$headless" -eq 0 ] && [ "${HERDR_ENV:-}" = 1 ] && [ "$resume" -eq 0 ]; }; then
  # a pane: asked for (--pane), or the default inside Herdr for a build Stage or a --bounded small change; --headless opts out
  [ "$headless" -eq 0 ] || { echo "drive-stage: --pane and --headless are two modes — pick one" >&2; exit 64; }
  [ "$resume" -eq 0 ] || { echo "drive-stage: --pane runs a build Stage or a --bounded small change (no --resume — that fallback is headless)" >&2; exit 64; }
  scratch_env "$ROOT" "$plan" "$dry"; drive_pane "$ROOT" "$plan" "$stage" "$heavy" "$again" "$dry"; exit $?
fi
scratch_env "$ROOT" "$plan" "$dry"
drive "$ROOT" "$plan" "$stage" "$heavy" "$resume" "$resume_prompt" "$again" "$dry"
