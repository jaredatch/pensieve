#!/usr/bin/env bash
# tmp-tidy.sh: at a plan's close, tracks the scratch files the plan still cites and archives the rest. Its --check mode
# keeps tmp/ from collecting strays between plans. Rule: protocol/context-discipline.md § Workspace.
#
# Kit copy: install as script/tmp-tidy.sh. It has no project literals: the repo root is where the script lives (or --root).
#
# Usage
#   tmp-tidy.sh --plan PLAN-NN [--dry-run]   preview: sort the files, resolve every cite, print the manifest and the
#                                            UNRESOLVED list. Writes only under mktemp.
#   tmp-tidy.sh --plan PLAN-NN --apply       copy the evidence into <plans dir>/PLAN-NN-review/{prompts,reviews,notes,probes,
#                                            shots}/ with a MANIFEST.md, write archive/plans/PLAN-NN.tar.zst (.tar.gz without
#                                            zstd) and its .list, then delete tmp/PLAN-NN only if nothing is UNRESOLVED and
#                                            every file is in the .list
#   A git checkout under tmp/PLAN-NN (any entry named .git: a file, dir or symlink, tmp/PLAN-NN's own included) stops both
#   modes before anything is read: named, exit 1, nothing tracked, archived or deleted until it is removed. Keep its diff and log.
#   tmp-tidy.sh --check                      fail if tmp/ holds anything older than 24 h besides PLAN-*/ folders, the resume
#                                            note (resume-note.md, clear-continue.md, and any $TMP_TIDY_KEEP names) and
#                                            young files in tmp/bounded/. An old tmp/.run-lock is reported as a lock to
#                                            settle with the launcher; an old .run-lock.claim as one to remove by hand.
#   tmp-tidy.sh --self-test                  fixture run under mktemp; prints SELF-TEST OK
#   --root DIR                               point any mode at another repo root (the self-test uses it)
#   --records DIR                            --plan's records root: where the plan file, the LOG, its rotated months, the
#                                            review dir and archive/plans/ live. tmp/ is always under --root.
#
# Split-repo mode (modules/split-repo.md). The default records root is --root, unless RATCHET_RECORDS names one: the
# environment's value, else the one in <root>/script/ratchet.conf (sourced in a subshell), a path from the code repo's top
# such as `private`. Trailing slashes are stripped. It must be relative, with no '.', '..' or empty component and no symlink
# along it, and a directory that is its own git work tree, or --plan exits 2 (never a fall back to one repo).
#
# The paths (as the ratchet reads them, from <root>/script/ratchet.conf, else the environment): RATCHET_PLANS_DIR (docs/plans)
# holds the plan files and the review dirs, RATCHET_LOG (docs/LOG.md) is the LOG, and <its dir>/log/*.md are its rotated months,
# all under the records root. An empty RATCHET_PLANS_DIR (Lite's inline plans) has nothing for --plan to tidy: exit 2.
# The MANIFEST's paths stay relative to the records root, where the close guard reads them. --check reads tmp/ only.
#
# Settings (environment): TMP_TIDY_SHOT_CAP_KB (400), TMP_TIDY_DIR_CAP_KB (2000; below), TMP_TIDY_OPAQUE (below),
# TMP_TIDY_KEEP (--check), TMP_TIDY_COMPRESSOR=gzip.
#
# Exit codes: 0 clean · 1 something UNRESOLVED or a git checkout (--plan), or a stray (--check) · 2 a tool failed, or a
# cite can't be parsed, or the LOG is missing (never read as UNRESOLVED, as "no checkout", as "no cites" or as
# "nothing to track")
#
# Where files go (first match wins):
#   shots     .png .jpg .jpeg .svg anywhere, gate folders included. Tracked only when cited (by path, folder or pattern)
#             and at or under $TMP_TIDY_SHOT_CAP_KB (default 400; 1 KB = 1000 bytes). Otherwise archived; the cite still
#             resolves through the archive.
#   reviews   a *verdict* file under 200 KB; also names with last, note, -rev-, disposition or findings under 200 KB
#   prompts   *prompt* files (not .log)
#   probes    source and script files by extension (.swift .sh .py .awk .mjs .js .ts .rb .go .rs .kt .java .c .cc .cpp .h
#             .m; not .bak)
#   notes     other .md under 200 KB
#   archive   everything else. Exception: a cited file under 200 KB that isn't a .log, .err or session-record copy
#             (*rollout*.jsonl) and isn't under a gate folder is tracked under reviews/ so the cite stays readable in git.
#   Under gate/, *-gate/ or gate-*/, a cited note is tracked like any note; uncited files and oversized shots are archived.
#   opaque    a directory named *.xcresult, or matching a glob in TMP_TIDY_OPAQUE (space-separated base-name globs, e.g.
#             `*.app *.xcarchive`), is one item: never walked, never tracked, archived whole. The .list names it once, as
#             `PLAN-NN/<path>/`; a cite of it, or of a path inside it, resolves through that line. (A test bundle holds
#             tens of thousands of files: PLAN-40's 53 bundles made a dry run take over 20 minutes.)
#   dir cap   a cited DIRECTORY whose members this run would track total more than TMP_TIDY_DIR_CAP_KB (default 2000; a whole
#             number of KB, 1 KB = 1000 bytes) is archived whole: none of its members is tracked for that cite, and the
#             MANIFEST reads `archived (dir over cap)`. A member cited on its own is still decided on its own.
#
# How cites resolve. Cites are read from the plan file, the LOG (which must exist) and its rotated months (<LOG's dir>/log/*.md). A cite resolves if the path is on
# disk, tracked, or an archive member (exact, or a folder or prefix match). A pattern cite (.X, .N, .., a * glob, a {a,b}
# brace set, including an empty alternative like L1{,-r2}.log) needs at least one member and matches whole names only.
# Not cites: another plan's tmp/PLAN-MM/ path, the placeholder tmp/PLAN-NN/… itself, wildcards alone (tmp/**, tmp/*),
# and a legacy bare tmp/x cite in the LOG that doesn't resolve here. A cite with a comma outside braces is refused
# (exit 2): write a brace set or two cites.
#
# The archive is the membership authority. The .list beside it is derived from the verified archive (rewritten by --apply
# when they disagree), and the guards check that the list is non-empty and its archive sits beside it.
#
# Shell rules: bash 3.2 and BSD tools. `set -eu`, never pipefail, so no producer sits on the left of a pipe: every listing,
# archive step and lookup is captured and checked (exit 2 naming the tool). grep is read three ways (0 hit, 1 none, else
# an error). `find -mmin` for ages, `wc -c` for sizes, `touch -t` in the self-test, no mapfile or associative arrays.
set -eu

SCRIPT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="$SCRIPT_ROOT"
mode="dry-run"; plan=""; do_check=0; do_selftest=0; RECORDS=""; records_set=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --plan)      plan="${2:-}"; shift 2 ;;
    --dry-run)   mode="dry-run"; shift ;;
    --apply)     mode="apply"; shift ;;
    --check)     do_check=1; shift ;;
    --self-test) do_selftest=1; shift ;;
    --root)      ROOT="${2:-}"; shift 2 ;;
    --records)   RECORDS="${2:-}"; records_set=1; shift 2 ;;
    *) echo "tmp-tidy: unknown arg: $1" >&2; exit 64 ;;
  esac
done

SIZE_CAP=200000   # bytes; the "small evidence" line — cited files under it are tracked, larger ones archived
[ "$do_selftest" -eq 0 ] || unset TMP_TIDY_SHOT_CAP_KB TMP_TIDY_KEEP TMP_TIDY_DIR_CAP_KB TMP_TIDY_OPAQUE RATCHET_RECORDS RATCHET_LOG RATCHET_PLANS_DIR   # the self-test proves the CODE at its defaults (its cap probes set their own value); an exported override would move its fixtures
SHOT_CAP_KB="${TMP_TIDY_SHOT_CAP_KB:-}"; [ -n "$SHOT_CAP_KB" ] || SHOT_CAP_KB=400   # the shot cap: a CITED shot at or under it is tracked, wherever it lives; over it, archive-only
case "$SHOT_CAP_KB" in *[!0-9]*|????????*) echo "tmp-tidy: TMP_TIDY_SHOT_CAP_KB must be a whole number of KB, at most 7 digits (got '$SHOT_CAP_KB')" >&2; exit 64 ;; esac   # refused, never read as the default: a typo'd cap would track or archive the wrong set silently
SHOT_CAP=$((10#$SHOT_CAP_KB * 1000))   # bytes, 1 KB = 1000 as SIZE_CAP's 200 KB; 10# so a leading zero is not read as octal
DIR_CAP_KB="${TMP_TIDY_DIR_CAP_KB:-}"; [ -n "$DIR_CAP_KB" ] || DIR_CAP_KB=2000   # the dir cap: a cited directory whose would-be-tracked members total more is archived whole
case "$DIR_CAP_KB" in *[!0-9]*|????????*) echo "tmp-tidy: TMP_TIDY_DIR_CAP_KB must be a whole number of KB, at most 7 digits (got '$DIR_CAP_KB')" >&2; exit 64 ;; esac   # refused, never read as the default
DIR_CAP=$((10#$DIR_CAP_KB * 1000))
OPAQUE="*.xcresult ${TMP_TIDY_OPAQUE:-}"   # base-name globs of directories kept whole (never walked, never tracked); * and ? only
OPAQUE_FIND=(); OPAQUE_ERE=""   # the find expression that prunes them, and the ERE alternation (one component) the list collapse matches
set -f
for og in $OPAQUE; do
  case "$og" in */*|*[![:alnum:]._*?+@-]*) echo "tmp-tidy: TMP_TIDY_OPAQUE holds '$og' — a base-name glob of letters, digits, . _ - + @ and the wildcards * ?, never a path" >&2; set +f; exit 64 ;; esac
  [ "${#OPAQUE_FIND[@]}" -eq 0 ] || OPAQUE_FIND+=(-o)
  OPAQUE_FIND+=(-name "$og")
  oe="$(printf '%s' "$og" | sed -e 's/[.+]/\\&/g' -e 's/\*/[^\/]*/g' -e 's/?/[^\/]/g')" || { echo "tmp-tidy: sed failed (exit $?) reading TMP_TIDY_OPAQUE" >&2; set +f; exit 2; }
  OPAQUE_ERE="$OPAQUE_ERE${OPAQUE_ERE:+|}$oe"
done
set +f
# ---------- compressor (zstd preferred, gzip fallback; the archive's own listing is the membership authority either way) ----------
if [ "${TMP_TIDY_COMPRESSOR:-}" = gzip ] || ! command -v zstd >/dev/null 2>&1; then ARCHIVE_EXT=".tar.gz"; else ARCHIVE_EXT=".tar.zst"; fi
compress()   { case "$1" in *.tar.zst) zstd -T0 -19 -q -f -o "$1" ;; *) gzip -9 -c > "$1" ;; esac; }   # stdin → $1, by the file's suffix
verify_ar()  { case "$1" in *.tar.zst) zstd -t -q "$1" ;; *) gzip -t "$1" ;; esac; }
decompress() { case "$1" in *.tar.zst) zstd -dc "$1" ;; *) gzip -dc "$1" ;; esac; }                       # $1 → stdout
find_arc()   { local e; for e in .tar.zst .tar.gz; do [ -f "$1/archive/plans/$2$e" ] && { printf '%s' "$1/archive/plans/$2$e"; return 0; }; done; return 1; }   # an existing archive, either suffix
TAB="$(printf '\t')"   # BSD sed has no \t — splice a literal tab

# ---------- helpers ----------
lower() { tr 'A-Z' 'a-z' <<< "$1"; }   # a here-string, never a pipe: the status is tr's
fsize() { local n; n="$(wc -c < "$1")" || return 2; n="${n//[[:space:]]/}"; [ -n "$n" ] || return 2; printf '%s' "$n"; }   # bytes; captured, then checked
fcount() { local n; n="$(wc -l < "$1")" || return 2; n="${n//[[:space:]]/}"; [ -n "$n" ] || return 2; printf '%s' "$n"; }   # lines; a count the delete gate reads
g() {   # grep, three ways: 0 matches, 1 none (both fine — the output is the answer), anything else grep itself failed: a line naming it, exit 2
  local rc=0; grep "$@" || rc=$?
  [ "$rc" -le 1 ] || { echo "tmp-tidy: grep failed (exit $rc): grep $*" >&2; return 2; }
  return 0
}
has_line() {   # $1 = a literal line, $2 = file → 0 present, 1 absent, 2 grep failed (a line naming it) — never "absent" on a failure
  local rc=0; grep -Fxq -- "$1" "$2" || rc=$?
  case "$rc" in 0|1) return "$rc" ;; esac
  echo "tmp-tidy: grep failed (exit $rc) looking up '$1' in $2" >&2; return 2
}
wildcard_only() {   # $1 = a cite's path under tmp/ (or under tmp/PLAN-NN/) → 0 iff it names no literal character — `**`, `*/*`, `{,}` —
  # so it is prose about tmp/, not a cite of anything (a rotated LOG's `"tmp/**"` once made every plan's scratch trackable)
  local pat='[*/.{},]' lit; lit="${1//$pat/}"   # the class in a variable: a literal `}` inside the expansion would end it
  [ -z "$lit" ]
}
ere_escape() {   # literal → ERE-safe (paths never carry a backslash; `/` is not special to grep -E)
  # `[` is listed LAST in the bracket: BSD sed reads `[.` / `[:` / `[=` inside a bracket as a collating-class opener
  printf '%s' "$1" | sed -e 's/[]*.^$+?(){}|[]/\\&/g'
}
is_pattern_cite() {   # the migration's rule: `.X`, `.N` (a stage wildcard), `..` (a range), a `*` glob or a `{a,b}` brace set marks a pattern citation
  case "$1" in
    *.X|*.X[^A-Za-z0-9]*|*.N|*.N[^A-Za-z0-9]*|*..*|*\**|*\{*\}*) return 0 ;;
  esac
  return 1
}
pattern_to_ere() {   # `stage-02.X-run.log` → `^stage-02\.[0-9]+-run\.log`; `gate-*.png` → `gate-[^/]*\.png`; `panel-{dark,light}.png` → `panel-(dark|light)\.png`
  # an EMPTY alternative anywhere in a brace set — `L1{,-r2}.log`, `x{a,}.log`, `x{a,,b}.log` — is dropped from the group and the group made
  # optional: `L1(-r2)?\.log`, `x(a)?\.log`, `x(a|b)?\.log`. BSD grep -E refuses `(|-r2)` ("empty (sub)expression", rc 2) and the cite read
  # UNRESOLVED with both files on disk (the field's `34.3-layer1{,-r2}.log`); a set of nothing but empties (`{,}`) is dropped whole. The awk
  # pass walks the finished ERE: a backslash pair rides along whole (an escaped literal paren is never a group), brace sets do not nest
  # (cites_in admits none), and a group left unclosed is handed to grep as written, so it refuses rather than matching something else
  # Three captured steps, each checked (exit 2 names the tool): this runs inside resolve's command substitution, where bash clears -e, so an
  # unchecked failure would hand grep half an ERE. `printf | tool` keeps a builtin on the left — the pipeline's status is the tool's
  local e
  e="$(ere_escape "$1")" || { echo "tmp-tidy: pattern_to_ere — escaping '$1' failed (exit $?)" >&2; return 2; }
  e="$(printf '%s\n' "$e" | sed -e 's/\\\.X/\\.[0-9]+/g' -e 's/\\\.N/\\.[0-9]+/g' -e 's/\\\.\\\./[0-9.]*/g' -e 's/\\\*/[^\/]*/g' -e 's/\\{/(/g' -e 's/\\}/)/g' -e 's/,/|/g')" \
    || { echo "tmp-tidy: pattern_to_ere — sed failed (exit $?) on '$1'" >&2; return 2; }
  e="$(printf '%s\n' "$e" | awk '{
        n = length($0); out = ""; ingrp = 0; grp = ""; alt = ""; opt = 0
        for (i = 1; i <= n; i++) {
          c = substr($0, i, 1)
          if (c == "\\") { c = substr($0, i, 2); i++ }
          else if (!ingrp && c == "(") { ingrp = 1; grp = ""; alt = ""; opt = 0; continue }
          else if (ingrp && (c == "|" || c == ")")) {
            if (alt == "") opt = 1; else grp = (grp == "" ? alt : grp "|" alt)
            alt = ""
            if (c == ")") { if (grp != "") out = out "(" grp ")" (opt ? "?" : ""); ingrp = 0 }
            continue
          }
          if (ingrp) alt = alt c; else out = out c
        }
        if (ingrp) out = out "(" grp (grp != "" ? "|" : "") alt
        printf "%s", out
      }')" || { echo "tmp-tidy: pattern_to_ere — awk failed (exit $?) on '$1'" >&2; return 2; }
  printf '%s' "$e"
}

is_gate_path() {   # $1 = rel path under tmp/PLAN-NN → 0 iff it lives under a gate dir: gate/, <x>-gate/, gate-<x>/ (a driven gate's bulk). ONE spelling for both readers — categorize and the cited loop — since a dir named gate-34.2/ once dodged the two-pattern form
  case "$1" in gate/*|*-gate/*|gate-*/*) return 0 ;; esac
  return 1
}

is_opaque_name() {   # $1 = a base name → 0 iff it matches an opaque glob (OPAQUE): a bundle directory kept whole
  local og rc=1
  set -f
  for og in $OPAQUE; do case "$1" in $og) rc=0; break ;; esac; done
  set +f
  return "$rc"
}
opaque_cut() {   # $1 = a path under tmp/PLAN-NN (as cited) → the path cut after its first opaque component, with a trailing `/`
  # (`r/a.xcresult/Data/x` → `r/a.xcresult/`); unchanged when no component is opaque. A cite into a bundle resolves through the bundle's one line
  local rest="$1" out="" c
  while [ -n "$rest" ]; do
    c="${rest%%/*}"
    if [ "$c" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
    out="$out$c"
    case "$c" in ""|*[*?{}[]*) ;; *) if is_opaque_name "$c"; then printf '%s/\n' "$out"; return 0; fi ;; esac   # a literal component only: a pattern is resolve's
    [ -z "$rest" ] || out="$out/"
  done
  printf '%s\n' "$1"
}
collapse_list() {   # $1 = a tar listing (one member per line) → stdout: the same listing with every member under an opaque bundle replaced by the
  # bundle's own `PLAN-NN/<path>/` line, once, in first-seen order. The first component (PLAN-NN) is never a bundle. 2 (named) when awk fails
  TT_OPQ_RE="^($OPAQUE_ERE)\$" awk '   # the ERE through the environment: `-v` would read its backslashes as escapes
    BEGIN { re = ENVIRON["TT_OPQ_RE"] }
    { n = split($0, c, "/"); out = c[1]; hit = 0
      for (i = 2; i <= n; i++) { if (c[i] == "") break; out = out "/" c[i]; if (c[i] ~ re) { hit = 1; break } }
      line = hit ? out "/" : $0
      if (!(line in seen)) { seen[line] = 1; print line } }' "$1" || { echo "tmp-tidy: awk failed (exit $?) collapsing the opaque bundles in $1" >&2; return 2; }
}
rel_path_ok() {   # $1 = a path from a root, $2 = its setting's name → 0 iff it is relative, names no `.`, `..` or empty component, and holds
  # only letters, digits and . _ - / (it is spliced into sed and printed into the MANIFEST); 2 (named) otherwise
  case "$1" in
    ""|/*) echo "tmp-tidy: $2='$1' must be a non-empty path from its root, not an absolute one" >&2; return 2 ;;
    *[!A-Za-z0-9._/-]*) echo "tmp-tidy: $2='$1' may hold only letters, digits and . _ - /" >&2; return 2 ;;
  esac
  case "/$1/" in */./*|*/../*|*//*) echo "tmp-tidy: $2='$1' names a '.', '..' or empty component" >&2; return 2 ;; esac
  return 0
}
resolve_records() {   # $1 = root → REC (the records root), REC_LABEL, LOG_REL, LOGDIR_REL, PLANS_REL. The keys are read the way ratchet.sh reads
  # them: <root>/script/ratchet.conf is sourced ONCE in a subshell. RATCHET_RECORDS: a non-empty environment value wins, else the conf's,
  # else one repo. RATCHET_LOG and RATCHET_PLANS_DIR: the conf sourced over the inherited environment, as in the
  # ratchet (its assignments win; a conf that reads the environment sees it), then the ratchet's defaults, docs/LOG.md and docs/plans (an empty RATCHET_LOG is the default; an explicitly empty
  # RATCHET_PLANS_DIR is Lite's inline plans, which have no plan file for --plan to tidy). The rotated LOG months are
  # $(dirname RATCHET_LOG)/log/*.md. --records names the records root outright. The records path rule (modules/split-repo.md):
  # trailing slashes stripped; refused (2, named) when absolute, with a '.', '..' or empty component, with a symlink anywhere along it
  # (its physical path must be its lexical one under the root), or not the top of its own git work tree — never a fall back to one repo
  local root="$1" conf out rc=0 rv="" rr rootp phys top
  conf="$root/script/ratchet.conf"
  # one subshell, the inherited environment kept (never cleared first): the conf is sourced over it exactly as ratchet.sh sources it,
  # so a conf written RATCHET_LOG="${RATCHET_LOG:-docs/LOG.md}" sees the environment here too; the effective, defaulted values are
  # computed inside with the ratchet's own expansions (`:=` for the LOG, `=` for the plans dir, whose explicit empty survives)
  out="$( e="${RATCHET_RECORDS:-}"; set +u   # the ratchet sources its conf before its own `set -eu`: a conf naming an unset variable reads it empty there too
          if [ -f "$conf" ]; then . "$conf" >/dev/null || exit $?; fi
          [ -z "$e" ] || RATCHET_RECORDS="$e"
          : "${RATCHET_LOG:=docs/LOG.md}"; : "${RATCHET_PLANS_DIR=docs/plans}"
          printf '%s\t%s\t%s' "${RATCHET_RECORDS:-}" "$RATCHET_LOG" "$RATCHET_PLANS_DIR" )" || rc=$?
  [ "$rc" -eq 0 ] || { echo "tmp-tidy: sourcing $conf failed (exit $rc) — the records root, the LOG and the plans dir can't be read" >&2; return 2; }
  rv="${out%%"$TAB"*}"; out="${out#*"$TAB"}"; LOG_REL="${out%%"$TAB"*}"; PLANS_REL="${out#*"$TAB"}"
  while :; do case "$PLANS_REL" in */) PLANS_REL="${PLANS_REL%/}" ;; *) break ;; esac; done
  [ -n "$PLANS_REL" ] || { echo "tmp-tidy: RATCHET_PLANS_DIR is empty (Lite's inline plans): there is no plan file or review dir for --plan to tidy" >&2; return 2; }
  rel_path_ok "$LOG_REL" RATCHET_LOG || return 2
  rel_path_ok "$PLANS_REL" RATCHET_PLANS_DIR || return 2
  case "$LOG_REL" in */*) LOGDIR_REL="${LOG_REL%/*}/log" ;; *) LOGDIR_REL=log ;; esac
  if [ "$records_set" -eq 1 ]; then
    [ -n "$RECORDS" ] && [ -d "$RECORDS" ] || { echo "tmp-tidy: --records '${RECORDS}' is not a directory" >&2; return 2; }
    REC="$(cd "$RECORDS" && pwd)" || { echo "tmp-tidy: cannot enter --records $RECORDS" >&2; return 2; }
    REC_LABEL="$REC/"; return 0
  fi
  REC="$root"; REC_LABEL=""
  rr="$rv"   # computed in the subshell above: a non-empty environment value outranks the conf, as ratchet.sh and kit/herdr read it
  [ -n "$rr" ] || return 0
  while :; do case "$rr" in */) rr="${rr%/}" ;; *) break ;; esac; done
  case "$rr" in ""|/*) echo "tmp-tidy: RATCHET_RECORDS='$rr' must be a path from the code repo's top, not an absolute one" >&2; return 2 ;; esac
  case "/$rr/" in */./*|*/../*|*//*) echo "tmp-tidy: RATCHET_RECORDS='$rr' names a '.', '..' or empty component" >&2; return 2 ;; esac
  rootp="$(cd "$root" 2>/dev/null && pwd -P)" || { echo "tmp-tidy: cannot enter the root $root" >&2; return 2; }
  phys="$(cd "$root/$rr" 2>/dev/null && pwd -P)" || { echo "tmp-tidy: RATCHET_RECORDS=$rr names no directory under $root" >&2; return 2; }
  [ "$phys" = "$rootp/$rr" ] || { echo "tmp-tidy: RATCHET_RECORDS=$rr — a symlink along the path leads to $phys; the records repo must sit at $rootp/$rr itself (a linked records path would run hooks git never finds)" >&2; return 2; }
  top="$(git -C "$phys" rev-parse --show-toplevel 2>/dev/null)" || { echo "tmp-tidy: RATCHET_RECORDS=$rr — $phys is not a git work tree" >&2; return 2; }
  top="$(cd "$top" 2>/dev/null && pwd -P)" || { echo "tmp-tidy: RATCHET_RECORDS=$rr — cannot enter the work tree git names for $phys" >&2; return 2; }
  [ "$top" = "$phys" ] || { echo "tmp-tidy: RATCHET_RECORDS=$rr — $phys is inside the work tree $top, not the top of its own repo" >&2; return 2; }
  REC="$root/$rr"; REC_LABEL="$rr/"
}

categorize() {   # $1 = rel path under tmp/PLAN-NN, $2 = size → prints probes|prompts|shots|reviews|notes|archive
  local rel="$1" size="$2" l
  l="$(lower "${rel##*/}")" || return 2
  case "$l" in *.png|*.jpg|*.jpeg|*.svg) echo shots; return ;; esac   # first: a shot is a shot wherever it lives and whatever its name (a gate dir, a `…-prompt.png`) — whether it is TRACKED is the cited loop's call: cited and within the shot cap
  if is_gate_path "$rel"; then echo archive; return; fi   # uncited, a gate dir's bulk is archive-only; CITED, a file there gets the decision below (the cited loop asks base_category)
  base_category "$l" "$size"
}
base_category() {   # $1 = lowercased base name, $2 = size → the category a file gets by its name and size alone (no shot, no gate rule)
  local l="$1" size="$2"
  case "$l" in
    *.bak) ;;
    *.swift|*.sh|*.py|*.awk|*.mjs|*.js|*.ts|*.rb|*.go|*.rs|*.kt|*.java|*.c|*.cc|*.cpp|*.h|*.m) echo probes; return ;;
  esac
  case "$l" in *verdict*) if [ "$size" -lt "$SIZE_CAP" ]; then echo reviews; else echo archive; fi; return ;; esac   # before the prompt rule: the launcher's
  # verdicts keep a prompt file's name (`prompt-review-read-verdict.md`, `prefreeze-prompt-r2-read-verdict.md`) and once filed under prompts/
  case "$l" in *prompt*) case "$l" in *.log) ;; *) echo prompts; return ;; esac ;; esac
  if [ "$size" -lt "$SIZE_CAP" ]; then
    case "$l" in *last*|*verdict*|*note*|*-rev-*|*disposition*|*findings*) echo reviews; return ;; esac
    case "$l" in *.md) echo notes; return ;; esac
  fi
  echo archive
}

# every `tmp/...` path a doc cites, one per line, as written (trailing .,;:) punctuation stripped); 2 (a line naming the tool, or
# the cite) when a producer fails or a cite carries a comma outside braces — a syntax the converter cannot hold as one path
cites_in() {   # $1 = file
  local hits bad rc=0 pat='(^|[^/A-Za-z0-9_])tmp/([A-Za-z0-9._/@+*-]|\{[A-Za-z0-9._,-]+\})+'
  hits="$(grep -oE -e "$pat" -- "$1")" || rc=$?   # `*` and `{a,b}` ride along: a glob or brace set is a pattern cite
  case "$rc" in 0) ;; 1) return 0 ;; *) echo "tmp-tidy: grep failed (exit $rc) reading the cites in $1" >&2; return 2 ;; esac
  rc=0; bad="$(grep -oE -e "$pat,[A-Za-z0-9._/@+*{-]" -- "$1")" || rc=$?   # a comma INSIDE the path, outside braces (`a,b.log`): the cite would be cut at the comma
  case "$rc" in
    0) bad="$(sed -E 's/^[^t]*//' <<< "$bad")" || bad="(sed failed naming it)"
       while IFS= read -r c; do echo "tmp-tidy: $1 cites \`${c}…\` — a comma outside braces cannot be read as one path; write a brace set (\`{a,b}\`) or two cites" >&2; done <<< "$bad"
       return 2 ;;
    1) ;;
    *) echo "tmp-tidy: grep failed (exit $rc) checking the cites in $1" >&2; return 2 ;;
  esac
  hits="$(sed -E -e 's/^[^t]//' -e 's/[.,;:)]+$//' <<< "$hits")" || { echo "tmp-tidy: sed failed (exit $?) trimming the cites in $1" >&2; return 2; }
  g -v -e '^tmp/clear-continue\.md$' -e '^tmp/resume-note\.md$' -e '^tmp/$' <<< "$hits" || return 2
}

# ---------- resolution against a member list ----------
serialize_hits() {   # $1 = newline-separated member lines → prints `<count><TAB><rel1><TAB><rel2>…` for the FILES among them (a `dir/` line is dropped,
  # an opaque bundle's `x.xcresult/` line kept: the bundle is one member).
  # Parameter expansion alone — no tr/sed/wc, no here-string temp file: the list was once joined with `tr | sed` INSIDE a printf argument, whose
  # status nothing reads; a failing `tr` printed `pattern<TAB>2<TAB>` — two claimed matches, no paths — and the selection tracked nothing at exit 0
  local rem="$1" line n=0 out="" b nl='
'
  while [ -n "$rem" ]; do
    line="${rem%%"$nl"*}"
    if [ "$line" = "$rem" ]; then rem=""; else rem="${rem#*"$nl"}"; fi
    case "$line" in
      "") continue ;;
      */) b="${line%/}"; b="${b##*/}"; is_opaque_name "$b" || continue ;;   # a directory line is dropped — unless it is an opaque bundle, which is one member
    esac
    n=$((n+1)); out="$out${out:+$TAB}$line"
  done
  printf '%s\t%s\n' "$n" "$out"
}
# $1 = rest (path relative to tmp/PLAN-NN), $2 = file of known rels (one per line, dirs with trailing /)
# prints: exact<TAB>rel | prefix<TAB>count<TAB>rel1<TAB>rel2… (all of them) | pattern<TAB>count<TAB>rel1<TAB>rel2… (all of them) | missing
# returns 2 (a line on stderr naming the tool) when a producer of a match LIST fails — never a count with no paths; every caller refuses on it
resolve() {
  local rest="${1%/}" members="$2" hits ser ere rc dircite=0 isdir
  case "$1" in */) dircite=1 ;; esac
  # every lookup three ways (has_line / the grep's own status): a failing grep is exit 2, never "absent" — a dir cite whose listing failed
  # once read as an empty directory, and its files were never tracked
  if [ "$dircite" -eq 0 ]; then rc=0; has_line "$rest" "$members" || rc=$?; case "$rc" in 0) printf 'exact\t%s\n' "$rest"; return 0 ;; 1) ;; *) return 2 ;; esac; fi   # a trailing-slash cite never resolves to a regular file
  isdir=0; rc=0; has_line "$rest/" "$members" || rc=$?; case "$rc" in 0) isdir=1; dircite=1 ;; 1) ;; *) return 2 ;; esac   # cited a directory by name
  if [ "$dircite" -eq 1 ]; then                                                     # a directory cite expands to its members;
    ere="^$(ere_escape "$rest")/" || { echo "tmp-tidy: resolve — escaping '$rest' failed" >&2; return 2; }   # a FILE cite never falls back to a prefix
    rc=0; hits="$(grep -E -e "$ere" -- "$members")" || rc=$?                        # (07.1-verdict.md must not resolve to 07.1-verdict.md.bak)
    case "$rc" in 0|1) ;; *) echo "tmp-tidy: resolve — grep failed (exit $rc) listing the members under '$rest/'" >&2; return 2 ;; esac
    ser="$(serialize_hits "$hits")" || { echo "tmp-tidy: resolve — listing the members under '$rest/' failed (exit $?)" >&2; return 2; }   # drops the `dir/` lines
    if [ "${ser%%"$TAB"*}" != 0 ]; then printf 'prefix\t%s\n' "$ser"; return 0; fi
    if [ "$isdir" -eq 1 ]; then printf 'exact\t%s/\n' "$rest"; return 0; fi        # an empty cited dir that exists
    printf 'missing\n'; return 0                                                        # a trailing-slash cite of nothing
  fi
  if is_pattern_cite "$rest"; then
    # a WHOLE-name match against the rel path — the two readings a plain cite gets: a file of that name, or a directory of that name and what is
    # beneath it (anchored at `^` alone, `x{,a}.log` resolved against `x.log.bak` with both intended logs missing). Capture, then check, then print:
    # the ERE (pattern_to_ere names its failing tool), the grep three ways (0 hits, 1 none, anything else grep itself failed — not "no match"),
    # and the list (serialize_hits drops the `dir/` lines and counts) — every hit, as `prefix` prints them, so the tracked selection decides each
    ere="$(pattern_to_ere "$rest")" || return 2
    ere="^$ere(/.*)?\$"
    rc=0; hits="$(grep -E -e "$ere" -- "$members")" || rc=$?
    case "$rc" in 0|1) ;; *) echo "tmp-tidy: resolve — grep failed (exit $rc) matching the pattern cite '$rest' as $ere" >&2; return 2 ;; esac
    ser="$(serialize_hits "$hits")" || { echo "tmp-tidy: resolve — listing the matches of '$rest' failed (exit $?)" >&2; return 2; }
    printf 'pattern\t%s\n' "$ser"; return 0
  fi
  printf 'missing\n'
}

# ---------- --check ----------
check_tmp() {   # $1 = repo root; 0 iff tmp/ holds only PLAN-*/ dirs, the resume note, or entries younger than 24 h; 1 on a stray;
  # 2 when a scan fails — every find captured and checked, never read as "clean" (a find that failed once printed "tmp/ clean")
  local root="$1" bad=0 e name entries old
  [ -d "$root/tmp" ] || return 0
  entries="$(find "$root/tmp" -mindepth 1 -maxdepth 1)" || { echo "tmp-tidy: --check — listing tmp/ failed (find exit $?)" >&2; return 2; }
  [ -n "$entries" ] || return 0
  entries="$(sort <<< "$entries")" || { echo "tmp-tidy: --check — sort failed (exit $?)" >&2; return 2; }
  while IFS= read -r e; do
    [ -n "$e" ] || continue
    name="${e##*/}"
    case "$name" in
      resume-note.md|clear-continue.md) continue ;;              # the resume carrier (playbook default, and the field's name)
      PLAN-[0-9]*) [ -d "$e" ] && continue ;;
      bounded) if [ -d "$e" ]; then                             # small-change scratch: judge each file's age, not the dir's mtime
                 old="$(find "$e" -type f -mmin +1440)" || { echo "tmp-tidy: --check — scanning tmp/bounded/ failed (find exit $?)" >&2; return 2; }
                 if [ -n "$old" ]; then
                   while IFS= read -r f; do [ -n "$f" ] && echo "tmp-tidy: stray in tmp/bounded/ (older than 24 h): ${f#$root/}"; done <<< "$old"
                   bad=1
                 fi
                 continue
               fi ;;
    esac
    case ":${TMP_TIDY_KEEP:-}:" in *":$name:"*) continue ;; esac   # project-specific keepers, colon-separated
    # BSD find: -mmin +1440 = modified more than 24 h ago
    old="$(find "$e" -maxdepth 0 -mmin +1440)" || { echo "tmp-tidy: --check — reading the age of tmp/$name failed (find exit $?)" >&2; return 2; }
    [ -n "$old" ] || continue
    case "$name" in   # the launcher's checkout-wide build lock (and its takeover claim): a run's own, so an old one is a launcher that died — never deleted by hand
      .run-lock) echo "tmp-tidy: an old build lock tmp/$name (older than 24 h: its launcher died) — settle it with drive-stage.sh --wait, --peek, or --abandon; never remove it by hand"; bad=1 ;;
      .run-lock.claim) echo "tmp-tidy: an old takeover claim tmp/$name (older than 24 h: a --wait/--abandon died inside its takeover) — once no launcher runs, remove it by hand (rmdir tmp/$name), then settle the lock"; bad=1 ;;
      *) echo "tmp-tidy: stray in tmp/ (older than 24 h): tmp/$name"; bad=1 ;;
    esac
  done <<< "$entries"
  return "$bad"
}

# ---------- --plan ----------
tidy_plan() {   # $1 = repo root (tmp/), $2 = PLAN-NN, $3 = dry-run|apply, $4 = the records root (the plan, the LOG, the review dir, the archive;
  # the repo root in one repo) → 0 iff no UNRESOLVED (and, under apply, the delete happened)
  local root="$1" plan="$2" mode="$3" rec="${4:-$1}"
  local src="$root/tmp/$plan" rev="$rec/$PLANS_REL/$plan-review" lst="$rec/archive/plans/$plan.list" arc
  arc="$(find_arc "$rec" "$plan" || true)"; [ -n "$arc" ] || arc="$rec/archive/plans/$plan$ARCHIVE_EXT"
  local arext="${arc#$rec/archive/plans/$plan}"
  local work; work="$(mktemp -d)"
  local out="$rev"; [ "$mode" = "dry-run" ] && out="$work/review"
  local planfile="" pf npf=0
  for pf in "$rec/$PLANS_REL/${plan}"-*.md; do [ -f "$pf" ] || continue; npf=$((npf+1)); planfile="$planfile${planfile:+ }$pf"; done   # a glob, counted in bash: no ls | grep -c to lose a status
  [ "$npf" -eq 1 ] || { echo "tmp-tidy: expected exactly one ${REC_LABEL}$PLANS_REL/$plan-*.md, found: ${planfile:-none}" >&2; rm -rf "$work"; return 2; }
  [ -f "$rec/$LOG_REL" ] || { echo "tmp-tidy: no ${REC_LABEL}$LOG_REL (RATCHET_LOG) — its cites can't be read, so nothing is tracked, archived or deleted (a missing LOG is never read as \"no cites\")" >&2; rm -rf "$work"; return 2; }
  bail() { echo "tmp-tidy: $1" >&2; rm -rf "$work"; }   # the refusal for a failed producer: named, the work dir removed, nothing written past it
  local have_src=0; [ -d "$src" ] && have_src=1
  resolve_failed() {   # $1 = the cite, $2 = what state the run leaves → the refusal every resolve caller makes on a non-zero: a tool failed, which is not a verdict on the cite
    echo "tmp-tidy: could not resolve \`$1\` — a tool failed (the line above names it); this is not a verdict on the cite. $2" >&2
    rm -rf "$work"
  }
  if [ "$have_src" -eq 0 ] && [ ! -f "$lst" ]; then
    echo "tmp-tidy: neither tmp/$plan nor archive/plans/$plan.list exists — nothing to tidy" >&2; rm -rf "$work"; return 2
  fi
  if [ -f "$lst" ] && [ ! -f "$arc" ]; then   # a .list is only evidence while its archive exists
    echo "tmp-tidy: archive/plans/$plan.list exists but no archive/plans/$plan.tar.{zst,gz} — the list proves nothing; restore the archive" >&2; rm -rf "$work"; return 2
  fi
  # a git checkout anywhere under tmp/PLAN-NN (a red-proof worktree, a clone, or tmp/PLAN-NN itself) is scratch, never evidence, and it stops
  # both modes before anything is read or written: PLAN-36's 1.2 GB red worktree made the dry run crawl for minutes and would have archived
  # 1.1 GB. One find, its status checked, never a probe per directory. ANY line it prints refuses, so a name holding a newline can't slip by
  if [ "$have_src" -eq 1 ]; then
    ( cd "$src" && find . -mindepth 1 \( -type d \( "${OPAQUE_FIND[@]}" \) -prune \) -o -name .git -prune -print ) > "$work/git.raw" || { bail "scanning tmp/$plan for git checkouts failed (find exit $?)"; return 2; }   # never inside an opaque bundle
    if [ -s "$work/git.raw" ]; then
      local g
      while IFS= read -r g; do
        case "$g" in ./.git) g="tmp/$plan" ;; *) g="tmp/$plan/${g#./}"; g="${g%/.git}" ;; esac
        echo "tmp-tidy: $g holds a git checkout" >&2
      done < "$work/git.raw"
      echo "tmp-tidy: --$mode refused — nothing was read, tracked, archived or deleted. Scratch worktrees belong outside the repo: keep the mutation diff and its log in tmp/$plan/, remove the checkout (git worktree remove, or rm -rf a clone), then run the tidy again" >&2
      rm -rf "$work"; return 1
    fi
  fi
  if [ -f "$arc" ]; then
    verify_ar "$arc" || { echo "tmp-tidy: $arc fails its integrity check" >&2; rm -rf "$work"; return 2; }
    decompress "$arc" > "$work/arc.tar" || { bail "decompressing $arc failed (exit $?)"; return 2; }   # membership comes from the archive, never from a list that could drift;
    tar -tf "$work/arc.tar" > "$work/arc.raw" || { bail "listing $arc failed (tar exit $?)"; return 2; }   # each step captured to a file and checked
    collapse_list "$work/arc.raw" > "$work/arc.col" || { bail "reading the archive's members failed"; return 2; }   # an opaque bundle is its one line, as the .list names it
    sort "$work/arc.col" > "$work/arc.members" || { bail "sort failed (exit $?)"; return 2; }
    if [ -f "$lst" ]; then sort "$lst" > "$work/lst.sorted" || { bail "sort failed (exit $?) reading $lst"; return 2; }; fi
    if [ -f "$lst" ] && ! cmp -s "$work/lst.sorted" "$work/arc.members"; then
      if [ "$mode" = "apply" ]; then
        echo "tmp-tidy: archive/plans/$plan.list disagreed with the archive's members — the archive is the evidence; list rewritten from it" >&2
        cp "$work/arc.members" "$lst"
      else
        echo "tmp-tidy: archive/plans/$plan.list disagrees with the archive's members — resolving against the archive; --apply rewrites the list (a dry run writes nothing)" >&2
      fi
    fi
  fi

  # (a) index + categorize every file under tmp/PLAN-NN: rel<TAB>size<TAB>category
  : > "$work/index.tsv"; : > "$work/files"; : > "$work/dirs"; : > "$work/bundles"
  if [ "$have_src" -eq 1 ]; then   # each listing captured to a file and checked, then read in THIS shell (a `find | sed | while` lost find's status)
    # an opaque bundle (OPAQUE) is pruned from every walk: it is one item, listed in bundles as `<rel>/`, never its members
    ( cd "$src" && find . \( -type d \( "${OPAQUE_FIND[@]}" \) -prune \) -o -type f -print ) > "$work/files.raw" || { bail "listing tmp/$plan failed (find exit $?)"; return 2; }
    sed 's|^\./||' "$work/files.raw" > "$work/files.rel" || { bail "sed failed (exit $?)"; return 2; }
    sort "$work/files.rel" > "$work/files" || { bail "sort failed (exit $?)"; return 2; }
    ( cd "$src" && find . -mindepth 1 -type d \( "${OPAQUE_FIND[@]}" \) -prune -print ) > "$work/bundles.raw" || { bail "listing tmp/$plan's opaque bundles failed (find exit $?)"; return 2; }
    sed -e 's|^\./||' -e 's|$|/|' "$work/bundles.raw" > "$work/bundles.rel" || { bail "sed failed (exit $?)"; return 2; }
    sort "$work/bundles.rel" > "$work/bundles" || { bail "sort failed (exit $?)"; return 2; }
    ( cd "$src" && find . -mindepth 1 \( -type d \( "${OPAQUE_FIND[@]}" \) -prune \) -o -type d -print ) > "$work/dirs.raw" || { bail "listing tmp/$plan's directories failed (find exit $?)"; return 2; }
    sed -e 's|^\./||' -e 's|$|/|' "$work/dirs.raw" > "$work/dirs" || { bail "sed failed (exit $?)"; return 2; }
    while IFS= read -r rel; do
      [ -n "$rel" ] || continue
      size="$(fsize "$src/$rel")" || { bail "reading the size of tmp/$plan/$rel failed"; return 2; }
      cat="$(categorize "$rel" "$size")" || { bail "categorizing tmp/$plan/$rel failed"; return 2; }
      printf '%s\t%s\t%s\n' "$rel" "$size" "$cat"
    done < "$work/files" > "$work/index.tsv"
  fi
  # the member universe a citation may resolve against: on-disk rels, the archive's members (read from the verified archive;
  # the .list only when no archive exists — which the checks above already refused) minus the PLAN-NN/ prefix, and
  # already-tracked rels from a previous run
  cat "$work/files" "$work/dirs" "$work/bundles" > "$work/members" || { bail "cat failed (exit $?)"; return 2; }
  if [ -f "$work/arc.members" ] || [ -f "$lst" ]; then
    ml="$work/arc.members"; [ -f "$ml" ] || ml="$lst"
    sed -n "s|^$plan/||p" "$ml" > "$work/arc.rel" || { bail "sed failed (exit $?) reading the archive's members"; return 2; }
    g -v '^$' "$work/arc.rel" >> "$work/members" || { bail "reading the archive's members failed"; return 2; }
  fi
  if [ -d "$rev" ]; then
    for cat in prompts reviews notes probes shots; do
      [ -d "$rev/$cat" ] || continue
      ( cd "$rev/$cat" && find . -type f ) > "$work/rev.raw" || { bail "listing $PLANS_REL/$plan-review/$cat failed (find exit $?)"; return 2; }
      sed 's|^\./||' "$work/rev.raw" >> "$work/members" || { bail "sed failed (exit $?)"; return 2; }
    done
  fi
  sort -u -o "$work/members" "$work/members" || { bail "sort failed (exit $?)"; return 2; }

  # (b) citations: cited<TAB>rest  (rest = path relative to tmp/PLAN-NN; a legacy bare `tmp/x` is read as tmp/PLAN-NN/x)
  : > "$work/cites.raw"
  for f in "$planfile" "$rec/$LOG_REL" "$rec/$LOGDIR_REL"/*.md; do   # each source's cites captured and checked (a failed read is a refusal, never "no cites"; the LOG's presence was checked above)
    [ -f "$f" ] || continue
    srcname=log; [ "$f" = "$planfile" ] && srcname=plan
    c="$(cites_in "$f")" || { bail "reading the cites in ${REC_LABEL}${f#$rec/} failed (the line above names why) — nothing was tracked, archived, or deleted"; return 2; }
    [ -z "$c" ] || while IFS= read -r x; do [ -n "$x" ] && printf '%s\t%s\n' "$srcname" "$x"; done <<< "$c" >> "$work/cites.raw"
  done
  sort -u -o "$work/cites.raw" "$work/cites.raw" || { bail "sort failed (exit $?)"; return 2; }   # one decision (and one message) per cite and source
  : > "$work/cites.tsv"
  while IFS="$(printf '\t')" read -r srcname cited; do
    [ -n "$cited" ] || continue
    rest="${cited#tmp/}"; rest="$(opaque_cut "$rest")"   # a cite into an opaque bundle is a cite of the bundle
    case "$rest" in
      "$plan"/*) rest="${rest#$plan/}"
                 if wildcard_only "$rest"; then echo "tmp-tidy: \`$cited\` names no file (wildcards only) — not a cite" >&2; continue; fi ;;
      "$plan") continue ;;                       # a bare `tmp/PLAN-NN` cite is the dir itself
      PLAN-[0-9]*/*|PLAN-[0-9]*) continue ;;     # another plan's evidence — its own tidy resolves it
      PLAN-NN/*|PLAN-NN) continue ;;             # the convention's own placeholder, a lesson quoting the playbook — prose, never a cite (the ratchet's cite leg passes it too)
      *) # legacy bare form: from the plan file it must resolve here; from the LOG only if it does. A wildcard-only cite (`tmp/**`) is
         # prose about tmp/, never a cite (a rotated LOG's `"tmp/**"` made every file of every later plan trackable)
         if wildcard_only "$rest"; then echo "tmp-tidy: \`$cited\` names no file (wildcards only) — not a cite" >&2; continue; fi
         if [ "$srcname" = "log" ]; then   # resolved ONCE, its status checked, its fields read by expansion (a `resolve | cut` inside `[ ]` had no status to read)
           lr="$(resolve "$rest" "$work/members")" || { resolve_failed "$cited" "Nothing was tracked, archived, or deleted."; return 2; }
           k="${lr%%"$TAB"*}"; kn="${lr#*"$TAB"}"; kn="${kn%%"$TAB"*}"
           case "$k" in missing) continue ;; pattern) [ "$kn" -gt 0 ] || continue ;; esac
         fi ;;
    esac
    printf '%s\t%s\n' "$cited" "$rest" >> "$work/cites.tsv"
  done < "$work/cites.raw"
  sort -u -o "$work/cites.tsv" "$work/cites.tsv" || { bail "sort failed (exit $?)"; return 2; }

  # (c) what gets tracked: rel<TAB>category — structural categories, then cited shots within the shot cap (wherever they live) + cited small non-log files outside a gate dir.
  # "Cited" is by exact path, by directory, or by PATTERN: each match gets the same per-file decision (a capture cited as `gate/panel-{dark,light}.png` once stayed archive-only)
  # A cited DIRECTORY whose would-be-tracked members (its structural ones included) total more than DIR_CAP is archived whole: its rows go
  # to overcap (dir, count, bytes), never tracked; a member cited on its own keeps its own decision (PLAN-42's cited dir held 1,970 binaries)
  awk -F'\t' '$3=="probes"||$3=="prompts"||$3=="reviews"||$3=="notes" {print $1"\t"$3}' "$work/index.tsv" > "$work/structural.tsv" || { bail "awk failed (exit $?)"; return 2; }
  : > "$work/cited.tsv"; : > "$work/overcap"; local sel
  while IFS="$(printf '\t')" read -r cited rest; do
    [ -n "$rest" ] || continue
    r="$(resolve "$rest" "$work/members")" || { resolve_failed "$cited" "Nothing was tracked, archived, or deleted."; return 2; }   # never "0 tracked": a selection that skipped this cite's files would let the archive-and-delete run without them
    kind="${r%%"$TAB"*}"; x="${r#*"$TAB"}"   # fields by expansion: a `printf | cut | tr` once lost a producer's status
    case "$kind" in
      exact)   hits="$x" ;;
      prefix|pattern) x="${x#*"$TAB"}"; [ "$x" != "$r" ] || x=""; hits="${x//$TAB/$'\n'}" ;;   # a directory's members, a pattern's matches (none → nothing to decide; the check below reads it MISSING)
      *) continue ;;                             # missing → the check
    esac
    printf '%s\n' "$hits" > "$work/hits" || { bail "writing the cite's matches failed (exit $?)"; return 2; }   # a checked file, never a here-string: bash 3.2 backs one
    # with a temp file, and a loop whose redirect fails is skipped with no error — an empty selection the dir cap would weigh as nothing (EVO-92).
    # The loop writes nothing: its rows collect in `sel` (an assignment can't fail) and go to cite.rows in ONE checked write after it, because
    # the loop's own `||` turns errexit off inside it, where a row printf that failed would drop the row unseen (a short selection the cap
    # underweighs, or cited evidence left archive-only). The self-test lints this loop for any printf
    sel=""
    while IFS= read -r rel; do                   # selection-loop: every producer below is checked; rows go to sel, never to a stream
      [ -n "$rel" ] || continue
      row="$(awk -F'\t' -v r="$rel" '$1==r' "$work/index.tsv")" || { bail "awk failed (exit $?)"; return 2; }
      [ -n "$row" ] || continue                  # not on disk this run (an archive-only or already-tracked member)
      size="${row#*"$TAB"}"; cat="${size#*"$TAB"}"; size="${size%%"$TAB"*}"
      l="$(lower "${rel##*/}")" || { bail "tr failed"; return 2; }
      if [ "$cat" = archive ] && is_gate_path "$rel"; then   # CITED under a gate dir: the decision a file gets anywhere else — a cited note is tracked like any note
        if [ "$size" -lt "$SIZE_CAP" ]; then cat="$(base_category "$l" "$size")" || { bail "categorizing tmp/$plan/$rel failed"; return 2; }; fi
        case "$cat" in probes|prompts|reviews|notes) sel="$sel$rel$TAB$cat"$'\n'; continue ;; esac
      fi
      case "$cat" in
        probes|prompts|reviews|notes) sel="$sel$rel$TAB$cat"$'\n' ;;   # tracked by its category already: listed so a dir cite weighs it, and an exact cite keeps it past its dir's cap
        shots) if [ "$size" -le "$SHOT_CAP" ]; then sel="$sel$rel${TAB}shots"$'\n'; fi ;;   # a cited shot within the cap is tracked wherever it lives (a gate dir included); over the cap it stays archive-only and the cite resolves through the archive's members
        archive)
          case "$l" in *.log|*.err|*rollout*.jsonl) continue ;; esac   # a transcript — a run log, or the launcher's copy of Codex's session record — is archive-only even when cited
          if [ "$size" -lt "$SIZE_CAP" ]; then sel="$sel$rel${TAB}reviews"$'\n'; fi ;;
      esac
    done < "$work/hits" || { bail "selecting the rows for tmp/$plan/$rest failed"; return 2; }   # selection-loop end
    printf '%s' "$sel" > "$work/cite.rows" || { bail "writing the selection for tmp/$plan/$rest failed (exit $?)"; return 2; }
    if [ "$kind" = prefix ] && [ -s "$work/cite.rows" ]; then   # a directory cite: weigh what it would track
      sum="$(awk -F'\t' 'FILENAME == ARGV[1] { sz[$1] = $2; next } !seen[$1]++ { t += sz[$1]; n++ } END { printf "%d %d\n", n, t }' "$work/index.tsv" "$work/cite.rows")" \
        || { bail "awk failed (exit $?) weighing the cited directory tmp/$plan/${rest%/}"; return 2; }
      case "$sum" in [0-9]*" "[0-9]*) ;; *) bail "weighing the cited directory tmp/$plan/${rest%/} gave '$sum'"; return 2 ;; esac
      if [ "${sum#* }" -gt "$DIR_CAP" ]; then printf '%s\t%s\t%s\n' "${rest%/}" "${sum%% *}" "${sum#* }" >> "$work/overcap"; continue; fi
    fi
    cat "$work/cite.rows" >> "$work/cited.tsv" || { bail "cat failed (exit $?)"; return 2; }
  done < "$work/cites.tsv"
  # the structural rows less every one under an over-cap directory, then the cited rows (an exact cite, an under-cap subdirectory's)
  awk -F'\t' 'FILENAME == ARGV[1] { p[++n] = $1 "/"; next } { for (i = 1; i <= n; i++) if (index($1, p[i]) == 1) next; print }' "$work/overcap" "$work/structural.tsv" > "$work/tracked.tsv" \
    || { bail "awk failed (exit $?) applying the dir cap"; return 2; }
  cat "$work/cited.tsv" >> "$work/tracked.tsv" || { bail "cat failed (exit $?)"; return 2; }
  sort -u -o "$work/tracked.tsv" "$work/tracked.tsv" || { bail "sort failed (exit $?)"; return 2; }
  # before ANY copy: a same-path file whose bytes differ from an archived member or an already-tracked review file would
  # replace evidence — refuse first, copy never (apply only; a dry run reports but writes nothing into the repo)
  if [ "$mode" = "apply" ] && [ "$have_src" -eq 1 ]; then
    differs() {   # $1 $2 → 0 when the bytes differ OR cmp cannot tell (an error is never "the same": evidence is not replaced on a guess), 1 when identical
      local rc=0; cmp -s "$1" "$2" || rc=$?; [ "$rc" -ne 0 ]
    }
    collide=""
    if [ -f "$arc" ]; then   # extract the verified archive from the file decompressed above — a `decompress | tar -x` could stop short and the merge below would drop members
      mkdir -p "$work/merge" && tar -C "$work/merge" -xf "$work/arc.tar" || { bail "extracting $arc failed (tar exit $?)"; return 2; }
      while IFS= read -r m; do
        [ -n "$m" ] || continue
        if [ -f "$work/merge/$plan/$m" ] && differs "$src/$m" "$work/merge/$plan/$m"; then collide="$collide${collide:+$'\n'}archive: $m"; fi
      done < "$work/files"
      while IFS= read -r m; do   # an opaque bundle already archived under the same name: the same only when diff -r finds no difference (an error is never "the same")
        [ -n "$m" ] || continue
        [ -d "$work/merge/$plan/$m" ] || continue
        rc=0; diff -rq "$src/$m" "$work/merge/$plan/$m" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 0 ] || collide="$collide${collide:+$'\n'}archive: $m"
      done < "$work/bundles"
    fi
    while IFS="$(printf '\t')" read -r rel cat; do
      [ -n "$rel" ] || continue
      if [ -f "$rev/$cat/$rel" ] && differs "$src/$rel" "$rev/$cat/$rel"; then collide="$collide${collide:+$'\n'}tracked: $cat/$rel"; fi
    done < "$work/tracked.tsv"
    if [ -n "$collide" ]; then
      echo "tmp-tidy: tmp/$plan holds files that differ from evidence of the same name already archived or tracked — rename the new one (-rN) rather than replace evidence:" >&2
      while IFS= read -r x; do echo "  $x" >&2; done <<< "$collide"; rm -rf "$work"; return 1
    fi
  fi
  # copy, preserving sub-paths under the category dir (a cited `shots/a.png` lands at shots/shots/a.png — deliberate: a
  # re-run lists the tracked rel as `shots/a.png` again and the same cite resolves exact)
  while IFS="$(printf '\t')" read -r rel cat; do
    [ -n "$rel" ] || continue
    dir="$out/$cat/$rel"; dir="${dir%/*}"
    mkdir -p "$dir" && cp -p "$src/$rel" "$out/$cat/$rel" || { bail "copying tmp/$plan/$rel into the review dir failed"; return 2; }
  done < "$work/tracked.tsv"

  # (d) archive (apply only) — built beside the target, verified, then moved into place
  if [ "$mode" = "apply" ] && [ "$have_src" -eq 1 ]; then
    local tarroot="$root/tmp"
    if [ -f "$arc" ]; then   # a re-run after new scratch appeared: MERGE the old members under the new ones (collisions were refused above; the merge dir was extracted there)
      mkdir -p "$work/merge/$plan" && cp -Rp "$src/." "$work/merge/$plan/" || { bail "staging the merged archive failed"; return 2; }
      tarroot="$work/merge"
    fi
    mkdir -p "$rec/archive/plans" || { bail "mkdir ${REC_LABEL}archive/plans failed"; return 2; }
    tar -C "$tarroot" -cf "$work/$plan.tar" "$plan" || { bail "tar failed (exit $?) building the archive"; return 2; }   # built to a file, then compressed: a `tar | compress` hid tar's status
    compress "$work/$plan$arext" < "$work/$plan.tar" || { bail "compressing the archive failed (exit $?)"; return 2; }
    verify_ar "$work/$plan$arext" || { bail "the new archive fails its integrity check"; return 2; }
    decompress "$work/$plan$arext" > "$work/$plan.check.tar" || { bail "decompressing the new archive failed (exit $?)"; return 2; }
    tar -tf "$work/$plan.check.tar" > "$work/$plan.raw.list" || { bail "listing the new archive failed (tar exit $?)"; return 2; }
    collapse_list "$work/$plan.raw.list" > "$work/$plan.list" || { bail "writing the new .list failed"; return 2; }   # an opaque bundle is named once
    mv -f "$work/$plan$arext" "$arc" && mv -f "$work/$plan.list" "$lst" || { bail "moving the archive into place failed"; return 2; }
    # the .list now mirrors the archive just written
    sed -n "s|^$plan/||p" "$lst" > "$work/arc.rel" || { bail "sed failed (exit $?)"; return 2; }
    g -v '^$' "$work/arc.rel" >> "$work/members" || { bail "reading the new list failed"; return 2; }
    sort -u -o "$work/members" "$work/members" || { bail "sort failed (exit $?)"; return 2; }
  fi

  # manifest: cited path → tracked path | archive member | pattern citation | MISSING
  local today; today="$(date -u +%Y-%m-%d)" || { bail "date failed"; return 2; }
  mkdir -p "$out" || { bail "mkdir $out failed"; return 2; }
  {
    printf '# %s — evidence manifest\n\n' "$plan"
    printf 'Written %s by `script/tmp-tidy.sh` (playbook `protocol/context-discipline.md` § Workspace). Small cited evidence — a cited shot at or under %s KB included, wherever it lived — and every prompt/verdict/note/probe source is tracked here; transcripts, uncited or larger shots, and large artifacts live in `archive/plans/%s%s` (gitignored, on-disk archive; member list in `archive/plans/%s.list`). Paths below are as cited in this plan'"'"'s file, `%s`, and `%s/*.md`.\n\n' "$today" "$SHOT_CAP_KB" "$plan" "$arext" "$plan" "$LOG_REL" "$LOGDIR_REL"
    printf '| cited `tmp/` path | now |\n|---|---|\n'
  } > "$out/MANIFEST.md"
  : > "$work/unresolved"
  loc_of() {   # $1 = rel → tracked: … | archive: … ; 2 when a lookup fails (a failed lookup is never "archive")
    local rel="$1" cat
    cat="$(awk -F'\t' -v r="$rel" '$1==r {print $2; exit}' "$work/tracked.tsv")" || { echo "tmp-tidy: awk failed looking up $rel" >&2; return 2; }
    if [ -z "$cat" ] && [ -d "$rev" ]; then
      for c in prompts reviews notes probes shots; do [ -f "$rev/$c/$rel" ] && { cat="$c"; break; }; done
    fi
    if [ -n "$cat" ]; then printf 'tracked: %s/%s-review/%s/%s' "$PLANS_REL" "$plan" "$cat" "$rel"
    else printf 'archive: archive/plans/%s%s → %s/%s' "$plan" "$arext" "$plan" "$rel"; fi
  }
  while IFS="$(printf '\t')" read -r cited rest; do
    [ -n "$rest" ] || continue
    r="$(resolve "$rest" "$work/members")" || { resolve_failed "$cited" "tmp/$plan is KEPT (the delete gate was not reached); the MANIFEST is incomplete — re-run."; return 2; }
    kind="${r%%"$TAB"*}"; x="${r#*"$TAB"}"   # fields by expansion, as the selection reads them
    case "$kind" in
      exact)
        case "$x" in
          */) printf '| `%s` | dir → archive: archive/plans/%s%s → %s/%s/ |\n' "$cited" "$plan" "$arext" "$plan" "${rest%/}" ;;
          *)  loc="$(loc_of "${rest%/}")" || { bail "the manifest's lookup failed"; return 2; }; printf '| `%s` | %s |\n' "$cited" "$loc" ;;
        esac ;;
      prefix)
        oc="$(awk -F'\t' -v d="${rest%/}" '$1 == d { print $2 " " $3; exit }' "$work/overcap")" || { bail "awk failed (exit $?) reading the dir cap's list"; return 2; }
        if [ -n "$oc" ]; then
          printf '| `%s` | archived (dir over cap) — %s members to track, %s KB, over the %s KB cap → archive: archive/plans/%s%s → %s/%s/ |\n' "$cited" "${oc%% *}" "$(( (${oc#* } + 999) / 1000 ))" "$DIR_CAP_KB" "$plan" "$arext" "$plan" "${rest%/}"
          continue
        fi
        n="${x%%"$TAB"*}"; x="${x#*"$TAB"}"; phits="${x//$TAB/$'\n'}"; locs=""; i=0
        while IFS= read -r h; do [ -n "$h" ] || continue; i=$((i+1)); [ "$i" -le 3 ] || break
          loc="$(loc_of "$h")" || { bail "the manifest's lookup failed"; return 2; }; locs="$locs$loc; "; done <<< "$phits"
        locs="${locs%; }"; more=""; [ "$n" -gt 3 ] && more=" (+$((n-3)) more)"
        printf '| `%s` | dir/prefix → %s%s |\n' "$cited" "$locs" "$more" ;;
      pattern)
        n="${x%%"$TAB"*}"; x="${x#*"$TAB"}"; [ "$n" != "$x" ] || x=""; ex="${x%%"$TAB"*}"
        if [ "$n" -gt 0 ]; then
          nt=0; phits="${x//$TAB/$'\n'}"   # the `case` stays OUTSIDE a command substitution: bash 3.2 cannot parse a case pattern's `)` inside `$( )`
          while IFS= read -r h; do [ -n "$h" ] || continue; loc="$(loc_of "$h")" || { bail "the manifest's lookup failed"; return 2; }; case "$loc" in tracked:*) nt=$((nt+1)) ;; esac; done <<< "$phits"
          trk=""; [ "$nt" -eq 0 ] || trk="; $nt of them also tracked under \`$PLANS_REL/$plan-review/\` (listed below)"
          printf '| `%s` | pattern citation — %s matching members in `archive/plans/%s%s` (e.g. `%s/%s`)%s |\n' "$cited" "$n" "$plan" "$arext" "$plan" "$ex" "$trk"
        else
          printf '| `%s` | **MISSING** — pattern citation with no matching member |\n' "$cited"; echo "$cited" >> "$work/unresolved"
        fi ;;
      *) printf '| `%s` | **MISSING** — not on disk, not tracked, not an archive member |\n' "$cited"; echo "$cited" >> "$work/unresolved" ;;
    esac
  done < "$work/cites.tsv" >> "$out/MANIFEST.md"
  # inventory: EVERY file under the review directory after this run — this run's tracked.tsv plus what earlier runs already
  # promoted. The table above samples a dir/prefix cite (three locations, "+N more"); the close guard checks each `tracked:`
  # path is in the index, so it reads this list, which is complete, never sampled.
  # built into files and checked step by step — the close guard reads this list, so a listing that failed must never shorten it
  while IFS="$(printf '\t')" read -r rel cat; do
    if [ -n "$rel" ]; then printf '%s/%s-review/%s/%s\n' "$PLANS_REL" "$plan" "$cat" "$rel"; fi
  done < "$work/tracked.tsv" > "$work/inv.raw"
  for c in prompts reviews notes probes shots; do
    [ -d "$rev/$c" ] || continue
    ( cd "$rev/$c" && find . -type f ) > "$work/inv.find" || { bail "listing $PLANS_REL/$plan-review/$c failed (find exit $?)"; return 2; }
    sed "s|^\./|$PLANS_REL/$plan-review/$c/|" "$work/inv.find" >> "$work/inv.raw" || { bail "sed failed (exit $?)"; return 2; }
  done
  sort -u "$work/inv.raw" > "$work/inv.sorted" || { bail "sort failed (exit $?)"; return 2; }
  printf '\n## Tracked files\n\nEvery file this and earlier runs promoted into `%s/%s-review/` (the close guard checks each is in the index):\n\n' "$PLANS_REL" "$plan" >> "$out/MANIFEST.md"
  sed 's/^/- tracked: /' "$work/inv.sorted" >> "$out/MANIFEST.md" || { bail "sed failed (exit $?) writing the inventory"; return 2; }

  # report
  local nf ntr nci nunres
  nf="$(fcount "$work/index.tsv")" && ntr="$(fcount "$work/tracked.tsv")" && nci="$(fcount "$work/cites.tsv")" || { bail "counting the run's files failed"; return 2; }
  echo "tmp-tidy: $plan ($mode) — $nf files on disk, $ntr tracked, $nci citations"
  cat "$out/MANIFEST.md" || { bail "cat failed (exit $?)"; return 2; }
  nunres="$(fcount "$work/unresolved")" || { bail "counting the UNRESOLVED cites failed — the delete gate cannot read it"; return 2; }   # the gate's own number: a failed count once read as 0
  # (e) citation check
  if [ "$nunres" -gt 0 ]; then sed 's/^/UNRESOLVED /' "$work/unresolved"; fi
  local rc=0
  # (f) delete gate
  if [ "$mode" = "apply" ] && [ "$have_src" -eq 1 ]; then
    notlisted=""
    while IFS= read -r rel; do   # each lookup three ways: a grep that fails is a refusal, never "listed"
      [ -n "$rel" ] || continue
      rc=0; has_line "$plan/$rel" "$lst" || rc=$?
      case "$rc" in 0) ;; 1) notlisted="$notlisted${notlisted:+$'\n'}$rel" ;; *) bail "reading archive/plans/$plan.list failed — tmp/$plan is KEPT"; return 2 ;; esac
    done < "$work/files"
    while IFS= read -r rel; do   # each opaque bundle by its one line
      [ -n "$rel" ] || continue
      rc=0; has_line "$plan/$rel" "$lst" || rc=$?
      case "$rc" in 0) ;; 1) notlisted="$notlisted${notlisted:+$'\n'}$rel" ;; *) bail "reading archive/plans/$plan.list failed — tmp/$plan is KEPT"; return 2 ;; esac
    done < "$work/bundles"
    if [ "$nunres" -eq 0 ] && [ -z "$notlisted" ]; then
      rm -rf "$src"; echo "tmp-tidy: tmp/$plan archived to archive/plans/$plan$arext and deleted"
    else
      if [ -n "$notlisted" ]; then echo "tmp-tidy: files under tmp/$plan missing from the .list:" >&2; while IFS= read -r x; do echo "  $x" >&2; done <<< "$notlisted"; fi
      echo "tmp-tidy: tmp/$plan KEPT ($nunres unresolved citation(s))"; rc=1
    fi
  elif [ "$nunres" -gt 0 ]; then
    rc=1
  fi
  rm -rf "$work"
  return "$rc"
}

# ---------- self-test ----------
if [ "$do_selftest" -eq 1 ]; then
  d="$(mktemp -d)"; trap 'rm -rf "$d"' EXIT
  fail() { echo "SELF-TEST FAIL: $1"; exit 1; }
  # fixture A: one existing cite, one missing cite → manifest rows + exactly one UNRESOLVED; nothing written into the repo
  mkdir -p "$d/a/docs/plans" "$d/a/docs/log" "$d/a/tmp/PLAN-07/gate" "$d/a/tmp/PLAN-07/sub"
  printf '# PLAN-07\n\n## Artifacts\n\nPrompt at `tmp/PLAN-07/07.1-prompt.md`; verdict at `tmp/PLAN-07/07.1-verdict.md`.\n\nShots `tmp/PLAN-07/gate-*.png`.\n' > "$d/a/docs/plans/PLAN-07-fixture.md"
  printf '## log\n\nSee tmp/PLAN-07/07.1-run.log, tmp/PLAN-07/07.1-rollout.jsonl and tmp/PLAN-08/other.log.\n' > "$d/a/docs/LOG.md"
  printf 'prompt\n' > "$d/a/tmp/PLAN-07/07.1-prompt.md"
  printf 'run transcript\n' > "$d/a/tmp/PLAN-07/07.1-run.log"
  printf '{"type":"session_meta"}\n' > "$d/a/tmp/PLAN-07/07.1-rollout.jsonl"   # the launcher's copy of Codex's session record: a transcript, never tracked (v0.20)
  printf 'fixture\n' > "$d/a/tmp/PLAN-07/gate/big.bin"
  printf 'probe\n' > "$d/a/tmp/PLAN-07/sub/probe-a.swift"
  printf 'clear\n' > "$d/a/tmp/clear-continue.md"
  set +e; outA="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; rcA=$?; set -e
  [ "$rcA" -eq 1 ] || fail "fixture A dry-run should exit 1 (got $rcA): $outA"
  grep -Fq '| `tmp/PLAN-07/07.1-prompt.md` | tracked: docs/plans/PLAN-07-review/prompts/07.1-prompt.md |' <<< "$outA" || fail "fixture A: prompt row missing: $outA"
  grep -Fq '| `tmp/PLAN-07/07.1-verdict.md` | **MISSING**' <<< "$outA" || fail "fixture A: MISSING row missing: $outA"
  grep -Fq "| \`tmp/PLAN-07/07.1-run.log\` | archive: archive/plans/PLAN-07$ARCHIVE_EXT → PLAN-07/07.1-run.log |" <<< "$outA" || fail "fixture A: log→archive row missing: $outA"
  grep -Fq "| \`tmp/PLAN-07/07.1-rollout.jsonl\` | archive: archive/plans/PLAN-07$ARCHIVE_EXT → PLAN-07/07.1-rollout.jsonl |" <<< "$outA" || fail "fixture A: a cited session-record copy must be archive-only, never tracked: $outA"
  [ "$(grep -c '^UNRESOLVED ' <<< "$outA")" -eq 2 ] || fail "fixture A: expected exactly two UNRESOLVED (a missing file, a glob matching nothing): $outA"
  grep -Fq 'UNRESOLVED tmp/PLAN-07/gate-*.png' <<< "$outA" || fail "fixture A: a glob matching nothing should be UNRESOLVED: $outA"
  grep -v 'gate-\*' "$d/a/docs/plans/PLAN-07-fixture.md" > "$d/a/fixture.tmp" && mv "$d/a/fixture.tmp" "$d/a/docs/plans/PLAN-07-fixture.md"   # the glob probe is done; the rest of fixture A keeps one UNRESOLVED
  grep -Fq 'UNRESOLVED tmp/PLAN-07/07.1-verdict.md' <<< "$outA" || fail "fixture A: wrong UNRESOLVED path: $outA"
  grep -Fq 'PLAN-08' <<< "$outA" && fail "fixture A: another plan's cite leaked into PLAN-07's manifest"
  [ ! -e "$d/a/docs/plans/PLAN-07-review" ] || fail "dry-run wrote into docs/plans"
  [ ! -e "$d/a/archive" ] || fail "dry-run wrote into archive/"
  # --apply on fixture A must archive but KEEP the dir (an UNRESOLVED citation blocks the delete)
  set +e; outA2="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply 2>&1)"; rcA2=$?; set -e
  [ "$rcA2" -eq 1 ] || fail "fixture A apply should exit 1 (got $rcA2): $outA2"
  [ -d "$d/a/tmp/PLAN-07" ] || fail "fixture A apply deleted tmp/PLAN-07 despite an UNRESOLVED citation"
  [ -f "$d/a/archive/plans/PLAN-07$ARCHIVE_EXT" ] || fail "fixture A apply wrote no archive"
  grep -Fq 'tmp/PLAN-07 KEPT' <<< "$outA2" || fail "fixture A apply did not say KEPT: $outA2"
  # a FILE cite must not resolve to a prefix match: 07.1-verdict.md.bak exists, the cite still reads MISSING
  printf 'stale\n' > "$d/a/tmp/PLAN-07/07.1-verdict.md.bak"
  set +e; outA3="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; set -e
  grep -Fq '| `tmp/PLAN-07/07.1-verdict.md` | **MISSING**' <<< "$outA3" || fail "a file cite resolved to a prefix match (.bak): $outA3"
  # a trailing-slash cite backed only by a regular FILE of that name is MISSING too
  printf 'Also `tmp/PLAN-07/07.1-prompt.md/`.\n' >> "$d/a/docs/plans/PLAN-07-fixture.md"
  set +e; outA3c="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; set -e
  grep -Fq 'UNRESOLVED tmp/PLAN-07/07.1-prompt.md/' <<< "$outA3c" || fail "a trailing-slash cite resolved to a regular file: $outA3c"
  grep -v '07.1-prompt.md/' "$d/a/docs/plans/PLAN-07-fixture.md" > "$d/a/fixture.tmp" && mv "$d/a/fixture.tmp" "$d/a/docs/plans/PLAN-07-fixture.md"
  # a trailing-slash cite of a directory that never existed is MISSING, not an empty dir
  printf 'Also `tmp/PLAN-07/no-such/`.\n' >> "$d/a/docs/plans/PLAN-07-fixture.md"
  set +e; outA3b="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; set -e
  grep -Fq 'UNRESOLVED tmp/PLAN-07/no-such/' <<< "$outA3b" || fail "a trailing-slash cite of a nonexistent dir resolved: $outA3b"
  grep -v 'no-such' "$d/a/docs/plans/PLAN-07-fixture.md" > "$d/a/fixture.tmp" && mv "$d/a/fixture.tmp" "$d/a/docs/plans/PLAN-07-fixture.md"
  # re-apply after new scratch appeared MERGES the archive (never refuses, never loses the earlier members)
  printf 'verdict\n' > "$d/a/tmp/PLAN-07/07.1-verdict.md"
  rm -f "$d/a/tmp/PLAN-07/07.1-run.log"                       # the earlier member is gone from disk; only the archive has it
  set +e; outA4="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply 2>&1)"; rcA4=$?; set -e
  [ "$rcA4" -eq 0 ] || fail "re-apply with the earlier member only in the archive should merge and exit 0 (got $rcA4): $outA4"
  grep -Fxq 'PLAN-07/07.1-run.log' "$d/a/archive/plans/PLAN-07.list" || fail "merge lost the earlier archive member"
  grep -Fxq 'PLAN-07/07.1-verdict.md' "$d/a/archive/plans/PLAN-07.list" || fail "merge did not add the new member"
  [ ! -d "$d/a/tmp/PLAN-07" ] || fail "re-apply with zero UNRESOLVED did not delete tmp/PLAN-07"
  # a same-path file with DIFFERENT bytes than the archived member is refused (never replaces evidence); identical bytes merge —
  # and a differing TRACKED file (the verdict) is refused BEFORE anything is copied: the tracked bytes survive
  mkdir -p "$d/a/tmp/PLAN-07" && printf 'a different verdict\n' > "$d/a/tmp/PLAN-07/07.1-verdict.md"
  set +e; outA4a="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply 2>&1)"; rcA4a=$?; set -e
  [ "$rcA4a" -eq 1 ] || fail "a differing tracked verdict should be refused (got $rcA4a): $outA4a"
  grep -Fq 'tracked: reviews/07.1-verdict.md' <<< "$outA4a" || fail "tracked collision not named: $outA4a"
  [ "$(cat "$d/a/docs/plans/PLAN-07-review/reviews/07.1-verdict.md")" = "verdict" ] || fail "a refused merge overwrote the tracked verdict"
  rm -f "$d/a/tmp/PLAN-07/07.1-verdict.md"
  printf 'a different transcript\n' > "$d/a/tmp/PLAN-07/07.1-run.log"
  set +e; outA4b="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply 2>&1)"; rcA4b=$?; set -e
  [ "$rcA4b" -eq 1 ] || fail "a differing same-path member should be refused (got $rcA4b): $outA4b"
  grep -Fq 'archive: 07.1-run.log' <<< "$outA4b" || fail "archive collision not named: $outA4b"
  [ -d "$d/a/tmp/PLAN-07" ] || fail "a refused merge deleted the scratch"
  printf 'run transcript\n' > "$d/a/tmp/PLAN-07/07.1-run.log"      # identical to the archived bytes → merges
  "$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply >/dev/null 2>&1 || fail "an identical same-path member should merge"
  [ ! -d "$d/a/tmp/PLAN-07" ] || fail "identical-merge did not delete the scratch"
  # a .list that disagrees with its archive is rewritten from the archive (a stale list cannot certify a missing member)
  printf 'PLAN-07/ghost.log\n' >> "$d/a/archive/plans/PLAN-07.list"
  printf 'Also `tmp/PLAN-07/ghost.log`.\n' >> "$d/a/docs/plans/PLAN-07-fixture.md"
  set +e; outA4c="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; set -e
  grep -Fxq 'PLAN-07/ghost.log' "$d/a/archive/plans/PLAN-07.list" || fail "a dry run rewrote the .list (writes only under mktemp)"
  grep -Fq 'disagrees with the archive' <<< "$outA4c" || fail "stale .list not reported: $outA4c"
  grep -Fq 'UNRESOLVED tmp/PLAN-07/ghost.log' <<< "$outA4c" || fail "a cite backed only by a stale .list entry resolved: $outA4c"
  grep -v 'ghost.log' "$d/a/docs/plans/PLAN-07-fixture.md" > "$d/a/fixture.tmp" && mv "$d/a/fixture.tmp" "$d/a/docs/plans/PLAN-07-fixture.md"
  "$BASH" "$0" --root "$d/a" --plan PLAN-07 --apply >/dev/null 2>&1 || fail "apply over a stale .list failed"
  grep -Fxq 'PLAN-07/ghost.log' "$d/a/archive/plans/PLAN-07.list" && fail "--apply did not rewrite the stale .list from the archive"
  # a .list without its archive proves nothing → refused
  mv "$d/a/archive/plans/PLAN-07$ARCHIVE_EXT" "$d/a/archive/plans/hidden"
  set +e; outA5="$("$BASH" "$0" --root "$d/a" --plan PLAN-07 --dry-run 2>&1)"; rcA5=$?; set -e
  [ "$rcA5" -eq 2 ] || fail "a .list with no archive should exit 2 (got $rcA5): $outA5"
  grep -Fq 'the list proves nothing' <<< "$outA5" || fail "missing-archive refusal not reported: $outA5"
  mv "$d/a/archive/plans/hidden" "$d/a/archive/plans/PLAN-07$ARCHIVE_EXT"
  # fixture B: clean — new-form, legacy bare (from the LOG), dir/prefix, pattern, and cited-shot citations all resolve
  mkdir -p "$d/b/docs/plans" "$d/b/docs/log" "$d/b/tmp/PLAN-07/shots" "$d/b/archive"
  printf '# PLAN-07\n\nSee `tmp/PLAN-07/07.1-prompt.md`, `tmp/PLAN-07/07.X-run.log`, `tmp/PLAN-07/shots/`, `tmp/PLAN-07/shots/shot-*.png`, tmp/PLAN-07/shots/shot-{a,b}.png, and `tmp/PLAN-07/shots/shot-a.png`.\n' > "$d/b/docs/plans/PLAN-07-fixture.md"
  printf '## log\n\nlegacy cite tmp/07.2-run.log; also tmp/clear-continue.md.\n' > "$d/b/docs/LOG.md"
  printf '## old log\n\nanother: `tmp/PLAN-07/probe-a.swift`.\n' > "$d/b/docs/log/2026-01.md"
  printf 'p\n' > "$d/b/tmp/PLAN-07/07.1-prompt.md"; printf 'r\n' > "$d/b/tmp/PLAN-07/07.1-run.log"; printf 'r\n' > "$d/b/tmp/PLAN-07/07.2-run.log"
  printf 'probe\n' > "$d/b/tmp/PLAN-07/probe-a.swift"; printf 'png\n' > "$d/b/tmp/PLAN-07/shots/shot-a.png"; printf 'png\n' > "$d/b/tmp/PLAN-07/shot-uncited.png"
  for n in b c d; do printf 'png\n' > "$d/b/tmp/PLAN-07/shots/shot-$n.png"; done   # four members behind one dir cite: the table shows three
  printf 'v\n' > "$d/b/tmp/PLAN-07/07.1-verdict.md"; printf 'c\n' > "$d/b/tmp/clear-continue.md"
  set +e; outB="$("$BASH" "$0" --root "$d/b" --plan PLAN-07 --dry-run 2>&1)"; rcB=$?; set -e
  [ "$rcB" -eq 0 ] || fail "fixture B dry-run should exit 0 (got $rcB): $outB"
  grep -q '^UNRESOLVED ' <<< "$outB" && fail "fixture B: unexpected UNRESOLVED: $outB"
  grep -Fq "| \`tmp/07.2-run.log\` | archive: archive/plans/PLAN-07$ARCHIVE_EXT → PLAN-07/07.2-run.log |" <<< "$outB" || fail "fixture B: legacy LOG cite row missing: $outB"
  grep -Fq '| `tmp/PLAN-07/07.X-run.log` | pattern citation — 2 matching members' <<< "$outB" || fail "fixture B: pattern row missing: $outB"
  grep -Fq '| `tmp/PLAN-07/shots/shot-*.png` | pattern citation — 4 matching members' <<< "$outB" || fail "fixture B: glob row missing (a `*` glob is a pattern cite): $outB"
  grep -Fq '| `tmp/PLAN-07/shots/shot-{a,b}.png` | pattern citation — 2 matching members' <<< "$outB" || fail "fixture B: brace row missing (a {a,b} set is a pattern cite): $outB"
  grep -Fq '| `tmp/PLAN-07/shots/shot-a.png` | tracked: docs/plans/PLAN-07-review/shots/shots/shot-a.png |' <<< "$outB" || fail "fixture B: cited shot not tracked: $outB"
  grep -Fq '| `tmp/PLAN-07/shots/` | dir/prefix → ' <<< "$outB" || fail "fixture B: dir/prefix row missing: $outB"
  grep -Fq '(+1 more)' <<< "$outB" || fail "fixture B: dir/prefix row should sample three of four: $outB"
  grep -Fq -- '- tracked: docs/plans/PLAN-07-review/shots/shots/shot-d.png' <<< "$outB" || fail "fixture B: the fourth member is missing from the tracked inventory: $outB"
  grep -Fq -- '- tracked: docs/plans/PLAN-07-review/prompts/07.1-prompt.md' <<< "$outB" || fail "fixture B: structural (uncited) tracked file missing from the inventory: $outB"
  set +e; outB2="$("$BASH" "$0" --root "$d/b" --plan PLAN-07 --apply 2>&1)"; rcB2=$?; set -e
  [ "$rcB2" -eq 0 ] || fail "fixture B apply should exit 0 (got $rcB2): $outB2"
  [ ! -e "$d/b/tmp/PLAN-07" ] || fail "fixture B apply left tmp/PLAN-07 in place"
  [ -f "$d/b/tmp/clear-continue.md" ] || fail "fixture B apply touched clear-continue.md"
  [ -f "$d/b/archive/plans/PLAN-07$ARCHIVE_EXT" ] && [ -f "$d/b/archive/plans/PLAN-07.list" ] || fail "fixture B apply left no tarball/list"
  verify_ar "$d/b/archive/plans/PLAN-07$ARCHIVE_EXT" || fail "fixture B tarball fails the compressor's integrity test"
  grep -Fxq 'PLAN-07/07.2-run.log' "$d/b/archive/plans/PLAN-07.list" || fail "fixture B .list lacks the run log"
  grep -Fxq 'PLAN-07/shot-uncited.png' "$d/b/archive/plans/PLAN-07.list" || fail "fixture B .list lacks the uncited shot"
  for p in prompts/07.1-prompt.md probes/probe-a.swift shots/shots/shot-a.png reviews/07.1-verdict.md MANIFEST.md; do
    [ -f "$d/b/docs/plans/PLAN-07-review/$p" ] || fail "fixture B apply did not track $p"
  done
  [ ! -e "$d/b/docs/plans/PLAN-07-review/shots/shot-uncited.png" ] || fail "fixture B tracked an uncited shot"
  # every path the manifest marks tracked: exists on disk, and every tracked file is in the manifest's inventory (both directions)
  mt="$(grep -o 'tracked: docs/plans/[^ |;`]*' "$d/b/docs/plans/PLAN-07-review/MANIFEST.md")" || fail "fixture B: the manifest marks nothing tracked (or grep failed)"   # captured, then read in this shell: a failed producer is a failure, never an empty (vacuous) check
  while IFS= read -r t; do t="${t#tracked: }"; [ -f "$d/b/$t" ] || fail "manifest marks $t tracked but it is not on disk"; done <<< "$mt"
  ft="$(cd "$d/b" && find docs/plans/PLAN-07-review -type f ! -name MANIFEST.md)" && [ -n "$ft" ] || fail "fixture B: listing the review dir failed or found nothing"
  while IFS= read -r t; do grep -Fq -- "- tracked: $t" "$d/b/docs/plans/PLAN-07-review/MANIFEST.md" || fail "tracked file $t absent from the manifest inventory"; done <<< "$ft"
  # after apply the dir is gone: a re-run resolves everything against the verified archive's members + the tracked dir
  set +e; outB3="$("$BASH" "$0" --root "$d/b" --plan PLAN-07 --dry-run 2>&1)"; rcB3=$?; set -e
  [ "$rcB3" -eq 0 ] || fail "fixture B post-apply re-check should exit 0 (got $rcB3): $outB3"
  # --check both ways
  mkdir -p "$d/c/tmp/PLAN-09"; printf 'x\n' > "$d/c/tmp/clear-continue.md"; printf 'x\n' > "$d/c/tmp/fresh.log"
  printf 'note\n' > "$d/c/tmp/resume-note.md"; touch -t 202001010000 "$d/c/tmp/resume-note.md"   # an old resume note is a keeper
  mkdir -p "$d/c/tmp/bounded" && printf 'fresh\n' > "$d/c/tmp/bounded/x-run.log"                 # fresh bounded scratch is fine
  "$BASH" "$0" --root "$d/c" --check >/dev/null 2>&1 || fail "--check tripped on a clean tmp/ (or on the resume note)"
  printf 'x\n' > "$d/c/tmp/stale.log"; touch -t 202001010000 "$d/c/tmp/stale.log"
  set +e; outC="$("$BASH" "$0" --root "$d/c" --check 2>&1)"; rcC=$?; set -e
  [ "$rcC" -eq 1 ] || fail "--check should exit 1 on a stale file (got $rcC)"
  grep -Fq 'tmp/stale.log' <<< "$outC" || fail "--check did not name the stale file: $outC"
  grep -Fq 'fresh.log' <<< "$outC" && fail "--check named the fresh file"
  # an old file INSIDE tmp/bounded/ is a stray even when the directory itself was just touched
  printf 'old\n' > "$d/c/tmp/bounded/old-run.log"; touch -t 202001010000 "$d/c/tmp/bounded/old-run.log"; touch "$d/c/tmp/bounded"
  set +e; outD="$("$BASH" "$0" --root "$d/c" --check 2>&1)"; rcD=$?; set -e
  [ "$rcD" -eq 1 ] || fail "--check should exit 1 on an old bounded file (got $rcD): $outD"
  grep -Fq 'tmp/bounded/old-run.log' <<< "$outD" || fail "--check did not name the old bounded file: $outD"
  # the checkout's build lock tmp/.run-lock: a fresh one is a run in flight; an old one is named as a lock to settle, never a stray to delete
  mkdir -p "$d/c2/tmp/.run-lock"; "$BASH" "$0" --root "$d/c2" --check >/dev/null 2>&1 || fail "--check tripped on a fresh build lock"
  touch -t 202001010000 "$d/c2/tmp/.run-lock"
  set +e; outL="$("$BASH" "$0" --root "$d/c2" --check 2>&1)"; rcL=$?; set -e
  [ "$rcL" -eq 1 ] && grep -Fq 'an old build lock tmp/.run-lock' <<< "$outL" && grep -Fq -e '--wait' <<< "$outL" || fail "--check should name an old build lock as one to settle with --wait (rc=$rcL): $outL"
  mkdir -p "$d/c2/tmp/.run-lock.claim"; touch -t 202001010000 "$d/c2/tmp/.run-lock.claim"   # a takeover claim: removed by hand, as the launcher says — never "never remove it"
  set +e; outL="$("$BASH" "$0" --root "$d/c2" --check 2>&1)"; rcL=$?; set -e
  [ "$rcL" -eq 1 ] && grep -Fq 'an old takeover claim tmp/.run-lock.claim' <<< "$outL" && grep -Fq 'rmdir tmp/.run-lock.claim' <<< "$outL" || fail "--check should tell a leftover takeover claim to be removed by hand (rc=$rcL): $outL"
  # fixture G: the gzip path, forced (the fallback when zstd is absent), proven end to end
  mkdir -p "$d/g/docs/plans" "$d/g/tmp/PLAN-09"
  printf '# PLAN-09\n\nSee `tmp/PLAN-09/09.1-run.log`.\n' > "$d/g/docs/plans/PLAN-09-fixture.md"
  printf '## log\n' > "$d/g/docs/LOG.md"; printf 'run\n' > "$d/g/tmp/PLAN-09/09.1-run.log"
  TMP_TIDY_COMPRESSOR=gzip "$BASH" "$0" --root "$d/g" --plan PLAN-09 --apply >/dev/null 2>&1 || fail "gzip-path apply failed"
  [ -f "$d/g/archive/plans/PLAN-09.tar.gz" ] || fail "gzip path wrote no .tar.gz"
  gzip -t "$d/g/archive/plans/PLAN-09.tar.gz" || fail "gzip archive fails gzip -t"
  grep -Fxq 'PLAN-09/09.1-run.log' "$d/g/archive/plans/PLAN-09.list" || fail "gzip .list missing the member"
  grep -Fq 'archive/plans/PLAN-09.tar.gz' "$d/g/docs/plans/PLAN-09-review/MANIFEST.md" || fail "manifest names the wrong suffix on the gzip path"
  # a later run with zstd available must keep using the EXISTING .tar.gz, not advertise a .tar.zst that does not exist
  outG="$("$BASH" "$0" --root "$d/g" --plan PLAN-09 --dry-run 2>&1)" || fail "re-run over the gzip archive failed: $outG"
  grep -Fq 'archive/plans/PLAN-09.tar.gz' <<< "$outG" || fail "re-run switched the manifest to a nonexistent suffix: $outG"
  # fixture P: a brace set with an EMPTY alternative — leading {,a}, trailing {a,}, middle {a,,b} — resolves every choice, the empty one
  # included (BSD grep -E refused the old `(|-r2)` and the cite read UNRESOLVED with both files on disk); a plain {dark,light} set gains
  # no optional (the `panel-.txt` beside it is not a member); a set that matches nothing is still UNRESOLVED
  [ "$(pattern_to_ere 'x{,-r2}.log')" = 'x(-r2)?\.log' ] || fail "a leading empty alternative should make the group optional: $(pattern_to_ere 'x{,-r2}.log')"
  [ "$(pattern_to_ere 'x{a,}.log')" = 'x(a)?\.log' ] || fail "a trailing empty alternative should make the group optional: $(pattern_to_ere 'x{a,}.log')"
  [ "$(pattern_to_ere 'x{a,,b}.log')" = 'x(a|b)?\.log' ] || fail "a middle empty alternative should make the group optional: $(pattern_to_ere 'x{a,,b}.log')"
  [ "$(pattern_to_ere 'x{,}.log')" = 'x\.log' ] || fail "a set of nothing but empties should be dropped whole: $(pattern_to_ere 'x{,}.log')"
  [ "$(pattern_to_ere 'panel-{dark,light}.png')" = 'panel-(dark|light)\.png' ] || fail "a plain brace set must stay a plain group: $(pattern_to_ere 'panel-{dark,light}.png')"
  mkdir -p "$d/p/docs/plans" "$d/p/tmp/PLAN-11"
  printf '# PLAN-11\n\nSee `tmp/PLAN-11/11.3-L1{,-r2}.log`, `tmp/PLAN-11/11.4-cap{-dark,}.log`, `tmp/PLAN-11/11.5-out{-a,,-b}.log`, `tmp/PLAN-11/panel-{dark,light}.txt`, and `tmp/PLAN-11/11.9-none{,-r2}.log`.\n' > "$d/p/docs/plans/PLAN-11-fixture.md"
  printf '## log\n' > "$d/p/docs/LOG.md"
  for f in 11.3-L1.log 11.3-L1-r2.log 11.4-cap-dark.log 11.4-cap.log 11.5-out-a.log 11.5-out.log 11.5-out-b.log panel-dark.txt panel-light.txt panel-.txt; do printf 'x\n' > "$d/p/tmp/PLAN-11/$f"; done
  set +e; outP="$("$BASH" "$0" --root "$d/p" --plan PLAN-11 --dry-run 2>&1)"; rcP=$?; set -e
  [ "$rcP" -eq 1 ] || fail "fixture P dry-run should exit 1 — one brace cite matches nothing (got $rcP): $outP"
  grep -q '^grep: ' <<< "$outP" && fail "fixture P: grep refused an ERE a brace cite built: $outP"
  grep -Fq '| `tmp/PLAN-11/11.3-L1{,-r2}.log` | pattern citation — 2 matching members' <<< "$outP" || fail "fixture P: {,-r2} should resolve x.log and x-r2.log: $outP"
  grep -Fq '| `tmp/PLAN-11/11.4-cap{-dark,}.log` | pattern citation — 2 matching members' <<< "$outP" || fail "fixture P: a trailing empty alternative should resolve both files: $outP"
  grep -Fq '| `tmp/PLAN-11/11.5-out{-a,,-b}.log` | pattern citation — 3 matching members' <<< "$outP" || fail "fixture P: a middle empty alternative should resolve all three files: $outP"
  grep -Fq '| `tmp/PLAN-11/panel-{dark,light}.txt` | pattern citation — 2 matching members' <<< "$outP" || fail "fixture P: a plain brace set should match its two members and not the empty choice: $outP"
  [ "$(grep -c '^UNRESOLVED ' <<< "$outP")" -eq 1 ] || fail "fixture P: expected exactly one UNRESOLVED (the set matching nothing): $outP"
  grep -Fq 'UNRESOLVED tmp/PLAN-11/11.9-none{,-r2}.log' <<< "$outP" || fail "fixture P: a brace cite matching nothing should be UNRESOLVED: $outP"
  # a pattern matches a WHOLE name, never a prefix: `x{,a}.log` with only `x.log.bak` on disk is UNRESOLVED (anchored at `^` alone it resolved against
  # the .bak); with `x.log` it resolves to that one file. The .X / .N / .. / `*` forms still resolve their whole-name members beside a longer-named
  # sibling, and a pattern naming a DIRECTORY still reaches what is beneath it (the second reading a plain cite gets)
  printf '%s\n' x.log.bak 07.1-run.log 07.2-run.log 07.1-run.log.bak shots/ shots/shot-a.png shots/shot-a.png.orig gate-07.1/ gate-07.1/cap.png gate-07.10/ gate-07.10/cap.png > "$d/members-w"
  [ "$(resolve 'x{,a}.log' "$d/members-w")" = "pattern${TAB}0${TAB}" ] || fail "x{,a}.log resolved against x.log.bak: $(resolve 'x{,a}.log' "$d/members-w")"
  printf 'x.log\n' >> "$d/members-w"
  [ "$(resolve 'x{,a}.log' "$d/members-w")" = "pattern${TAB}1${TAB}x.log" ] || fail "x{,a}.log should resolve to x.log alone: $(resolve 'x{,a}.log' "$d/members-w")"
  for pat in 07.X-run.log 07.N-run.log 07..-run.log '07.*-run.log'; do
    [ "$(resolve "$pat" "$d/members-w")" = "pattern${TAB}2${TAB}07.1-run.log${TAB}07.2-run.log" ] || fail "$pat should resolve the two run logs and not the .bak: $(resolve "$pat" "$d/members-w")"
  done
  [ "$(resolve 'shots/shot-*.png' "$d/members-w")" = "pattern${TAB}1${TAB}shots/shot-a.png" ] || fail "a glob should not resolve to a longer name (.png.orig): $(resolve 'shots/shot-*.png' "$d/members-w")"
  [ "$(resolve 'gate-07.X' "$d/members-w")" = "pattern${TAB}2${TAB}gate-07.1/cap.png${TAB}gate-07.10/cap.png" ] || fail "a pattern naming a directory should reach what is beneath it: $(resolve 'gate-07.X' "$d/members-w")"
  [ "$(resolve 'gate-07.1{,0}' "$d/members-w" | cut -f2)" = 2 ] && [ "$(resolve 'gate-07.{1,2}' "$d/members-w")" = "pattern${TAB}1${TAB}gate-07.1/cap.png" ] || fail "a brace set naming a directory should match the whole directory name (gate-07.1 is not gate-07.10): $(resolve 'gate-07.{1,2}' "$d/members-w")"
  printf 'And `tmp/PLAN-11/x{,a}.log`.\n' >> "$d/p/docs/plans/PLAN-11-fixture.md"; printf 'stale\n' > "$d/p/tmp/PLAN-11/x.log.bak"
  set +e; outP2="$("$BASH" "$0" --root "$d/p" --plan PLAN-11 --dry-run 2>&1)"; set -e
  grep -Fq 'UNRESOLVED tmp/PLAN-11/x{,a}.log' <<< "$outP2" || fail "fixture P: x{,a}.log with only x.log.bak on disk should be UNRESOLVED: $outP2"
  printf 'log\n' > "$d/p/tmp/PLAN-11/x.log"
  set +e; outP3="$("$BASH" "$0" --root "$d/p" --plan PLAN-11 --dry-run 2>&1)"; set -e
  grep -Fq '| `tmp/PLAN-11/x{,a}.log` | pattern citation — 1 matching members' <<< "$outP3" || fail "fixture P: x{,a}.log should resolve to x.log alone once it exists: $outP3"
  grep -Fq 'UNRESOLVED tmp/PLAN-11/x{,a}.log' <<< "$outP3" && fail "fixture P: x{,a}.log still UNRESOLVED with x.log on disk: $outP3"
  # fixture S: the shot rule, both ways — a CITED shot at or under the cap is tracked WHEREVER it lives (gate/, gate-12.2/); a cited shot
  # over the cap and every uncited shot is archive-only, the cite still resolving; anything else UNCITED under a gate dir is archive-only (a
  # review-named log, a note); a CITED file there gets the decision it gets anywhere else — a cited note is tracked like any note (PLAN-35's
  # drive note under gate/ was copied out by hand), a cited small text file under reviews/; a shot named *prompt* is a shot, not a prompt
  mkdir -p "$d/s/docs/plans" "$d/s/tmp/PLAN-12/gate" "$d/s/tmp/PLAN-12/gate-12.2"
  printf '# PLAN-12\n\nGate captures `tmp/PLAN-12/gate/window-dark.png`, `tmp/PLAN-12/gate/window-full.png`, `tmp/PLAN-12/gate/at-cap.png`, `tmp/PLAN-12/gate/over-cap.png`, `tmp/PLAN-12/gate-12.2/capture.jpg`; summary `tmp/PLAN-12/gate-12.2/summary.txt`; drive note `tmp/PLAN-12/gate/12.1-drive-note.md`.\n' > "$d/s/docs/plans/PLAN-12-fixture.md"
  printf '## log\n' > "$d/s/docs/LOG.md"
  head -c 300000 /dev/zero > "$d/s/tmp/PLAN-12/gate/window-dark.png"; head -c 500000 /dev/zero > "$d/s/tmp/PLAN-12/gate/window-full.png"
  head -c 400000 /dev/zero > "$d/s/tmp/PLAN-12/gate/at-cap.png"; head -c 400001 /dev/zero > "$d/s/tmp/PLAN-12/gate/over-cap.png"
  head -c 300000 /dev/zero > "$d/s/tmp/PLAN-12/gate-12.2/capture.jpg"
  printf 'png\n' > "$d/s/tmp/PLAN-12/gate/window-uncited.png"; printf 'png\n' > "$d/s/tmp/PLAN-12/permission-prompt.png"
  printf 'summary\n' > "$d/s/tmp/PLAN-12/gate-12.2/summary.txt"; printf 'driver\n' > "$d/s/tmp/PLAN-12/gate-12.2/12.2-last.log"
  printf '# drive note\n' > "$d/s/tmp/PLAN-12/gate/12.1-drive-note.md"; printf '# not cited\n' > "$d/s/tmp/PLAN-12/gate/uncited-note.md"
  [ "$(fsize "$d/s/tmp/PLAN-12/gate/window-dark.png")" -eq 300000 ] && [ "$(fsize "$d/s/tmp/PLAN-12/gate/over-cap.png")" -eq 400001 ] || fail "fixture S: head -c did not write the sizes the cap probes need"
  s_row() { printf '| `tmp/PLAN-12/%s` | %s' "$1" "$2"; }   # $1 rel, $2 the row's right-hand start
  s_tracked="tracked: docs/plans/PLAN-12-review/shots"; s_arch="archive: archive/plans/PLAN-12$ARCHIVE_EXT → PLAN-12"
  set +e; outS="$("$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)"; rcS=$?; set -e
  [ "$rcS" -eq 0 ] || fail "fixture S dry-run should exit 0 — an archived cited shot still resolves (got $rcS): $outS"
  grep -Fq "$(s_row gate/window-dark.png "$s_tracked/gate/window-dark.png |")" <<< "$outS" || fail "fixture S: a cited 300 KB shot under gate/ should be tracked as a shot: $outS"
  grep -Fq "$(s_row gate/window-full.png "$s_arch/gate/window-full.png |")" <<< "$outS" || fail "fixture S: a cited 500 KB shot should be archive-only: $outS"
  grep -Fq "$(s_row gate/at-cap.png "$s_tracked/gate/at-cap.png |")" <<< "$outS" || fail "fixture S: a cited shot of exactly the cap should be tracked: $outS"
  grep -Fq "$(s_row gate/over-cap.png "$s_arch/gate/over-cap.png |")" <<< "$outS" || fail "fixture S: a cited shot one byte over the cap should be archive-only: $outS"
  grep -Fq "$(s_row gate-12.2/capture.jpg "$s_tracked/gate-12.2/capture.jpg |")" <<< "$outS" || fail "fixture S: a cited shot within the cap under gate-12.2/ should be tracked: $outS"
  grep -Fq "$(s_row gate-12.2/summary.txt "tracked: docs/plans/PLAN-12-review/reviews/gate-12.2/summary.txt |")" <<< "$outS" || fail "fixture S: a cited small text file under gate-12.2/ should be tracked under reviews/, as anywhere else: $outS"
  grep -Fq "$(s_row gate/12.1-drive-note.md "tracked: docs/plans/PLAN-12-review/reviews/gate/12.1-drive-note.md |")" <<< "$outS" || fail "fixture S: a cited note under gate/ should be tracked like any note: $outS"
  grep -Fq 'at or under 400 KB' <<< "$outS" || fail "fixture S: the manifest should name the default shot cap: $outS"
  invS="$(grep -F -- '- tracked: ' <<< "$outS" || true)"   # captured first: no `grep -q` at the end of a pipeline (pipefail + SIGPIPE would read a hit as a miss)
  [ "$(grep -c . <<< "$invS")" -eq 5 ] || fail "fixture S: the inventory should list exactly the three within-cap cited shots, the cited note, and the cited text file: $invS"
  for p in window-uncited.png permission-prompt.png 12.2-last.log uncited-note.md; do
    grep -Fq "$p" <<< "$invS" && fail "fixture S: $p is uncited (a shot) or under a gate dir (the log) and must not be tracked: $outS"
  done
  # the cap is $TMP_TIDY_SHOT_CAP_KB: raised, the 500 KB shot is tracked; lowered, the 300 KB one is archived; a leading zero is decimal; a value that is not a whole number is refused, never read as the default
  outS2="$(TMP_TIDY_SHOT_CAP_KB=600 "$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)" || fail "fixture S dry-run under a raised cap failed: $outS2"
  grep -Fq "$(s_row gate/window-full.png "$s_tracked/gate/window-full.png |")" <<< "$outS2" || fail "TMP_TIDY_SHOT_CAP_KB=600 should track the 500 KB shot: $outS2"
  outS3="$(TMP_TIDY_SHOT_CAP_KB=200 "$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)" || fail "fixture S dry-run under a lowered cap failed: $outS3"
  grep -Fq "$(s_row gate/window-dark.png "$s_arch/gate/window-dark.png |")" <<< "$outS3" || fail "TMP_TIDY_SHOT_CAP_KB=200 should archive the 300 KB shot: $outS3"
  outS4="$(TMP_TIDY_SHOT_CAP_KB=0400 "$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)" || fail "fixture S dry-run under a zero-led cap failed: $outS4"
  grep -Fq "$(s_row gate/window-dark.png "$s_tracked/gate/window-dark.png |")" <<< "$outS4" || fail "TMP_TIDY_SHOT_CAP_KB=0400 should read as 400, not octal: $outS4"
  for bad in 4oo 400KB -1 12345678; do
    set +e; outS5="$(TMP_TIDY_SHOT_CAP_KB="$bad" "$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)"; rcS5=$?; set -e
    [ "$rcS5" -eq 64 ] && grep -Fq "TMP_TIDY_SHOT_CAP_KB must be a whole number of KB" <<< "$outS5" || fail "TMP_TIDY_SHOT_CAP_KB=$bad should be refused with 64 (got $rcS5): $outS5"
  done
  # --apply at the default cap: the within-cap shots land under shots/, the rest only in the archive, and the archived cites still resolve after the dir is gone
  outS6="$("$BASH" "$0" --root "$d/s" --plan PLAN-12 --apply 2>&1)" || fail "fixture S apply failed: $outS6"
  for p in shots/gate/window-dark.png shots/gate/at-cap.png shots/gate-12.2/capture.jpg reviews/gate/12.1-drive-note.md reviews/gate-12.2/summary.txt; do
    [ -f "$d/s/docs/plans/PLAN-12-review/$p" ] || fail "fixture S apply did not track $p"
  done
  [ "$(cd "$d/s/docs/plans/PLAN-12-review" && find . -type f ! -name MANIFEST.md | grep -c .)" -eq 5 ] || fail "fixture S apply tracked more than the three within-cap cited shots, the note, and the text file: $(cd "$d/s/docs/plans/PLAN-12-review" && find . -type f)"
  for p in gate/window-full.png gate/over-cap.png gate/window-uncited.png permission-prompt.png gate/uncited-note.md gate-12.2/12.2-last.log; do
    grep -Fxq "PLAN-12/$p" "$d/s/archive/plans/PLAN-12.list" || fail "fixture S .list lacks the archive-only $p"
  done
  [ ! -e "$d/s/tmp/PLAN-12" ] || fail "fixture S apply left tmp/PLAN-12 in place"
  outS7="$("$BASH" "$0" --root "$d/s" --plan PLAN-12 --dry-run 2>&1)" || fail "fixture S post-apply re-check should exit 0 (an archived cited shot resolves through the archive): $outS7"
  grep -Fq "$(s_row gate/window-full.png "$s_arch/gate/window-full.png |")" <<< "$outS7" || fail "fixture S: the archived shot's cite should resolve to its archive member after apply: $outS7"
  # fixture T: a PATTERN cite tracks its matches by the same per-file decision an exact or a directory cite gets — a brace set and a `*` glob under
  # gate/ each track their within-cap match and archive their over-cap match (the old selection skipped pattern cites: a capture cited as
  # `gate/panel-{dark,light}.png` stayed archive-only); a shot no pattern matches stays uncited; a pattern's log matches are still never tracked
  mkdir -p "$d/t/docs/plans" "$d/t/tmp/PLAN-13/gate"
  printf '# PLAN-13\n\nPanels `tmp/PLAN-13/gate/panel-{dark,light}.png`, shots `tmp/PLAN-13/gate/shot-*.png`, logs `tmp/PLAN-13/13.X-run.log`.\n' > "$d/t/docs/plans/PLAN-13-fixture.md"
  printf '## log\n' > "$d/t/docs/LOG.md"
  head -c 300000 /dev/zero > "$d/t/tmp/PLAN-13/gate/panel-dark.png"; head -c 500000 /dev/zero > "$d/t/tmp/PLAN-13/gate/panel-light.png"
  printf 'png\n' > "$d/t/tmp/PLAN-13/gate/shot-1.png"; head -c 400001 /dev/zero > "$d/t/tmp/PLAN-13/gate/shot-2.png"
  printf 'png\n' > "$d/t/tmp/PLAN-13/gate/other.png"; printf 'run\n' > "$d/t/tmp/PLAN-13/13.1-run.log"; printf 'run\n' > "$d/t/tmp/PLAN-13/13.2-run.log"
  outT="$("$BASH" "$0" --root "$d/t" --plan PLAN-13 --dry-run 2>&1)" || fail "fixture T dry-run should exit 0: $outT"
  invT="$(grep -F -- '- tracked: ' <<< "$outT" || true)"
  [ "$invT" = "$(printf -- '- tracked: docs/plans/PLAN-13-review/shots/gate/panel-dark.png\n- tracked: docs/plans/PLAN-13-review/shots/gate/shot-1.png')" ] \
    || fail "fixture T: the brace cite and the glob should each track their within-cap match and nothing else: $outT"
  grep -Fq '| `tmp/PLAN-13/gate/panel-{dark,light}.png` | pattern citation — 2 matching members' <<< "$outT" && grep -Fq '| `tmp/PLAN-13/gate/shot-*.png` | pattern citation — 2 matching members' <<< "$outT" || fail "fixture T: each pattern should still resolve both its members: $outT"
  [ "$(grep -c '1 of them also tracked under `docs/plans/PLAN-13-review/`' <<< "$outT")" -eq 2 ] || fail "fixture T: each shot pattern's row should say one match is tracked: $outT"
  rowT="$(grep -F '13.X-run.log' <<< "$outT" || true)"   # captured first: no `grep -q` at the end of a pipeline
  grep -Fq 'pattern citation — 2 matching members' <<< "$rowT" || fail "fixture T: the .X log pattern should resolve both run logs: $outT"
  grep -Fq 'also tracked' <<< "$rowT" && fail "fixture T: a pattern's log matches must not be tracked: $outT"
  # fault injection: a tool failing while a PATTERN cite resolves must never yield a resolved cite with no paths, nor "0 tracked" at exit 0 (the old
  # pattern branch joined its matches with `tr | sed` inside a printf argument: a `tr` exiting 73 printed `pattern<TAB>2<TAB>`, the selection tracked
  # nothing, the run exited 0 — and after an archive-and-delete the close guard could not recover the omitted files). PATH-shadowed tools, each failing
  # only on ONE call: tr on the old join (`\n` → `\t`) and on the callers' split (`\t` → `\n`); sed and awk inside pattern_to_ere; grep on the pattern's ERE
  mkdir -p "$d/fake"
  printf '#!/bin/sh\ncase "${FAKE_TR_FAIL:-}:${1:-}:${2:-}" in "join:\\n:\\t"|"split:\\t:\\n") echo "tr: injected failure" >&2; exit 73 ;; esac\nexec "%s" "$@"\n' "$(command -v tr)" > "$d/fake/tr"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "${FAKE_SED_FAIL:-<never>}" ] && { echo "sed: injected failure" >&2; exit 73; }; done\nexec "%s" "$@"\n' "$(command -v sed)" > "$d/fake/sed"
  printf '#!/bin/sh\ncase "${FAKE_AWK_FAIL:-}:${1:-}" in 1:*ingrp*) echo "awk: injected failure" >&2; exit 73 ;; esac\nexec "%s" "$@"\n' "$(command -v awk)" > "$d/fake/awk"
  printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "${FAKE_GREP_FAIL:-<never>}" ] && { echo "grep: injected failure" >&2; exit 2; }; done\nexec "%s" "$@"\n' "$(command -v grep)" > "$d/fake/grep"
  chmod +x "$d/fake/tr" "$d/fake/sed" "$d/fake/awk" "$d/fake/grep"
  outF="$(PATH="$d/fake:$PATH" "$BASH" "$0" --root "$d/t" --plan PLAN-13 --dry-run 2>&1)" || fail "fixture T: the shadowed tools with no fault set should change nothing: $outF"
  [ "$(grep -F -- '- tracked: ' <<< "$outF" || true)" = "$invT" ] || fail "fixture T: the shadowed tools with no fault set changed the inventory: $outF"
  # the old join's and split's faults (both now parameter expansion — no tr on the path): the run either refuses or tracks exactly what the
  # unfaulted run tracks — and a pattern row always carries a path
  for tf in join split; do
    set +e; outF="$(PATH="$d/fake:$PATH" FAKE_TR_FAIL=$tf "$BASH" "$0" --root "$d/t" --plan PLAN-13 --dry-run 2>&1)"; rcF=$?; set -e
    if [ "$rcF" -eq 0 ]; then
      [ "$(grep -F -- '- tracked: ' <<< "$outF" || true)" = "$invT" ] || fail "fixture T: a failing tr (the match $tf) tracked the wrong set at exit 0: $outF"
      grep -Fq '(e.g. `PLAN-13/`)' <<< "$outF" && fail "fixture T: a failing tr (the match $tf) left a resolved pattern cite with no paths: $outF"
    fi
  done
  loud() {   # $1 what, $2 mode, $3… env assignments → the faulted run must refuse: non-zero, no report line, no manifest row, nothing written, the scratch kept
    local what="$1" m="$2" o r; shift 2
    set +e; o="$(env PATH="$d/fake:$PATH" "$@" "$BASH" "$0" --root "$d/t" --plan PLAN-13 "$m" 2>&1)"; r=$?; set -e
    [ "$r" -ne 0 ] || fail "fixture T: $what ($m) should fail the run, not exit 0: $o"
    grep -Eq '^tmp-tidy: PLAN-13 \(|pattern citation|^- tracked: ' <<< "$o" && fail "fixture T: $what ($m) still printed a report, a resolved pattern row, or an inventory: $o"
    [ ! -e "$d/t/docs/plans/PLAN-13-review" ] && [ ! -e "$d/t/archive" ] && [ -f "$d/t/tmp/PLAN-13/gate/panel-dark.png" ] || fail "fixture T: $what ($m) wrote evidence, archived, or deleted the scratch"
    loud_out="$o"; loud_rc="$r"
  }
  for m in --dry-run --apply; do
    loud "a failing sed inside pattern_to_ere" "$m" 'FAKE_SED_FAIL=s/\\\.X/\\.[0-9]+/g'
    [ "$loud_rc" -eq 2 ] && grep -Fq 'pattern_to_ere — sed failed (exit 73)' <<< "$loud_out" && grep -Fq 'could not resolve `tmp/PLAN-13/' <<< "$loud_out" || fail "fixture T: a failing sed should exit 2 naming the tool and the cite (rc=$loud_rc): $loud_out"
    loud "a failing awk inside pattern_to_ere" "$m" FAKE_AWK_FAIL=1
    [ "$loud_rc" -eq 2 ] && grep -Fq 'pattern_to_ere — awk failed (exit 73)' <<< "$loud_out" || fail "fixture T: a failing awk should exit 2 naming the tool (rc=$loud_rc): $loud_out"
    loud "a failing grep on the pattern's ERE" "$m" 'FAKE_GREP_FAIL=^gate/panel-(dark|light)\.png(/.*)?$'
    [ "$loud_rc" -eq 2 ] && grep -Fq 'resolve — grep failed (exit 2) matching the pattern cite' <<< "$loud_out" && grep -Fq 'could not resolve `tmp/PLAN-13/gate/panel-{dark,light}.png`' <<< "$loud_out" || fail "fixture T: a failing grep should exit 2 naming grep and the cite, never read as no match (rc=$loud_rc): $loud_out"
    grep -Fq 'UNRESOLVED' <<< "$loud_out" && fail "fixture T: a grep failure was reported as an UNRESOLVED cite: $loud_out"
  done
  # … and resolve itself returns 2 with nothing on stdout (never a count with no paths); serialize_hits counts files, drops `dir/` lines, joins by tabs
  set +e; outF="$(PATH="$d/fake:$PATH"; export FAKE_AWK_FAIL=1; resolve 'x{,a}.log' "$d/members-w" 2>/dev/null)"; rcF=$?; set -e
  [ "$rcF" -eq 2 ] && [ -z "$outF" ] || fail "resolve should return 2 and print nothing when a producer fails (rc=$rcF): $outF"
  [ "$(serialize_hits "$(printf 'a/\na/x.png\nb.log\n')")" = "2${TAB}a/x.png${TAB}b.log" ] && [ "$(serialize_hits "")" = "0${TAB}" ] || fail "serialize_hits should count and join the files and drop dir/ lines: $(serialize_hits "$(printf 'a/\na/x.png\nb.log\n')")"
  outT2="$("$BASH" "$0" --root "$d/t" --plan PLAN-13 --apply 2>&1)" || fail "fixture T apply failed: $outT2"
  [ -f "$d/t/docs/plans/PLAN-13-review/shots/gate/panel-dark.png" ] && [ -f "$d/t/docs/plans/PLAN-13-review/shots/gate/shot-1.png" ] || fail "fixture T apply did not track the within-cap pattern matches"
  [ "$(cd "$d/t/docs/plans/PLAN-13-review" && find . -type f ! -name MANIFEST.md | grep -c .)" -eq 2 ] || fail "fixture T apply tracked more than the two within-cap pattern matches: $(cd "$d/t/docs/plans/PLAN-13-review" && find . -type f)"
  for p in gate/panel-light.png gate/shot-2.png gate/other.png 13.1-run.log; do
    grep -Fxq "PLAN-13/$p" "$d/t/archive/plans/PLAN-13.list" || fail "fixture T .list lacks the archive-only $p"
  done
  outT3="$("$BASH" "$0" --root "$d/t" --plan PLAN-13 --dry-run 2>&1)" || fail "fixture T post-apply re-check should exit 0 (an over-cap pattern match resolves through the archive): $outT3"
  grep -Fq '| `tmp/PLAN-13/gate/panel-{dark,light}.png` | pattern citation — 2 matching members' <<< "$outT3" || fail "fixture T: the brace cite should still resolve both members after apply: $outT3"
  # fixture K (v0.19): (b) a rotated LOG's quoted `"tmp/**"` and a bare `tmp/*` name no file — never a cite (the field's docs/log/2026-07.md
  # made nine .bak files trackable and turned off archive-only at every later close), a plan-local `tmp/PLAN-15/*` likewise; a literal-bearing
  # glob still resolves. (a) a CITED note under gate/ is tracked like any note; an uncited one stays archive-only
  [ "$(wildcard_only '**' && echo y)" = y ] && [ "$(wildcard_only '*/*' && echo y)" = y ] && [ "$(wildcard_only '{,}' && echo y)" = y ] \
    && [ -z "$(wildcard_only '*.log' && echo y)" ] && [ -z "$(wildcard_only 'gate/*.png' && echo y)" ] || fail "wildcard_only: ** */* {,} name nothing; *.log and gate/*.png do"
  mkdir -p "$d/k/docs/plans" "$d/k/docs/log" "$d/k/tmp/PLAN-15/gate"
  printf '# PLAN-15\n\nVerdict `tmp/PLAN-15/15.1-verdict.md`; drive note `tmp/PLAN-15/gate/15.1-note.md`; everything `tmp/PLAN-15/*`; see tmp/PLAN-15/15.1-run.log, then the rest.\n' > "$d/k/docs/plans/PLAN-15-x.md"
  printf '## log\n\nClean up with `rm -rf "tmp/**"` and tmp/* later.\n' > "$d/k/docs/log/2026-07.md"; printf '## log\n' > "$d/k/docs/LOG.md"
  printf 'v\n' > "$d/k/tmp/PLAN-15/15.1-verdict.md"; printf 'run\n' > "$d/k/tmp/PLAN-15/15.1-run.log"; printf 'old\n' > "$d/k/tmp/PLAN-15/old.bak"
  printf '# note\n' > "$d/k/tmp/PLAN-15/gate/15.1-note.md"; printf '# bulk\n' > "$d/k/tmp/PLAN-15/gate/bulk-note.md"
  # the launcher's file names (--read, --review, --fix): every `*-verdict.md` files under reviews/, every prompt under prompts/, the logs archive-only
  for f in premise-prompt.md premise-read-verdict.md premise-read.log prefreeze-read-r2-verdict.md 15.1-L1-verdict.md 15.1-L1.log fix-prompt.md fix-run.log; do printf 'x\n' > "$d/k/tmp/PLAN-15/$f"; done
  set +e; outK="$("$BASH" "$0" --root "$d/k" --plan PLAN-15 --dry-run 2>&1)"; rcK=$?; set -e
  [ "$rcK" -eq 0 ] || fail "fixture K dry-run should exit 0 (got $rcK): $outK"
  invK="$(grep -F -- '- tracked: ' <<< "$outK" || true)"
  for want in reviews/15.1-verdict.md reviews/gate/15.1-note.md prompts/premise-prompt.md prompts/fix-prompt.md reviews/premise-read-verdict.md reviews/prefreeze-read-r2-verdict.md reviews/15.1-L1-verdict.md; do
    grep -Fxq -- "- tracked: docs/plans/PLAN-15-review/$want" <<< "$invK" || fail "fixture K: $want should be tracked: $outK"
  done
  [ "$(grep -c . <<< "$invK")" -eq 7 ] || fail "fixture K: exactly seven files should be tracked — never old.bak (a wildcard-only glob is not a cite), the uncited gate note, or a log: $outK"
  grep -Fq 'names no file (wildcards only) — not a cite' <<< "$outK" && ! grep -Fq '| `tmp/**`' <<< "$outK" && ! grep -Fq '| `tmp/PLAN-15/*`' <<< "$outK" || fail "fixture K: a wildcard-only cite should be named as not a cite and get no manifest row: $outK"
  # (c) a comma OUTSIDE braces inside a cite is refused (exit 2, named), nothing written — the converter would cut the path at the comma; a
  # comma after a cite (prose) is not one
  cp "$d/k/docs/plans/PLAN-15-x.md" "$d/k/plan.keep"; printf 'Split `tmp/PLAN-15/a,b.log`.\n' >> "$d/k/docs/plans/PLAN-15-x.md"
  set +e; outK2="$("$BASH" "$0" --root "$d/k" --plan PLAN-15 --apply 2>&1)"; rcK2=$?; set -e
  [ "$rcK2" -eq 2 ] && grep -Fq 'a comma outside braces cannot be read as one path' <<< "$outK2" && grep -Fq 'tmp/PLAN-15/a' <<< "$outK2" || fail "fixture K: a comma outside braces should refuse with exit 2, naming it (rc=$rcK2): $outK2"
  [ ! -e "$d/k/docs/plans/PLAN-15-review" ] && [ ! -e "$d/k/archive" ] && [ -d "$d/k/tmp/PLAN-15" ] || fail "fixture K: the comma refusal wrote evidence, archived, or deleted the scratch"
  mv "$d/k/plan.keep" "$d/k/docs/plans/PLAN-15-x.md"
  # fault injection over the tidy's own producers (--apply): the scratch listings (find: the git-checkout scan, the files, the directories), the
  # archive build (tar -cf), its listing (tar -tf), and the counts the delete gate reads (wc -l) — each a refusal at exit 2 naming it, the
  # scratch kept, no archive in place
  mkdir -p "$d/fk"
  for t in find tar wc; do   # the harsher fault: the real tool runs and writes its output, THEN the status is 73 — only a checked status catches it
    printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase " $* " in *"${FAKE_%s_FAIL:-<never>}"*) echo "%s: injected failure" >&2; exit 73 ;; esac\nexit $rc\n' "$(command -v "$t")" "$(tr a-z A-Z <<< "$t")" "$t" > "$d/fk/$t"; chmod +x "$d/fk/$t"
  done
  for f in 'FAKE_FIND_FAIL= -name .git -prune ' 'FAKE_FIND_FAIL= -o -type f -print ' 'FAKE_FIND_FAIL= -o -type d -print ' 'FAKE_FIND_FAIL= ) -prune -print ' 'FAKE_TAR_FAIL= -cf ' 'FAKE_TAR_FAIL= -tf ' 'FAKE_WC_FAIL= -l '; do
    set +e; o="$(env PATH="$d/fk:$PATH" "$f" "$BASH" "$0" --root "$d/k" --plan PLAN-15 --apply 2>&1)"; r=$?; set -e
    [ "$r" -eq 2 ] && grep -q 'injected failure' <<< "$o" && ! grep -Fq 'archived to' <<< "$o" || fail "fixture K: $f should refuse at exit 2, never archive-and-delete (rc=$r): $o"
    [ -d "$d/k/tmp/PLAN-15" ] || fail "fixture K: $f deleted the scratch"
    case "$f" in FAKE_WC_FAIL*) ;; *) [ ! -e "$d/k/archive/plans/PLAN-15.list" ] || fail "fixture K: $f left an archive list in place (the archive step must not complete on a failed producer)" ;; esac   # a failed count comes after the archive: kept scratch + a complete archive is recoverable
    rm -rf "$d/k/docs/plans/PLAN-15-review" "$d/k/archive"
  done
  outK3="$("$BASH" "$0" --root "$d/k" --plan PLAN-15 --apply 2>&1)" || fail "fixture K apply (no fault) failed: $outK3"
  [ -f "$d/k/docs/plans/PLAN-15-review/reviews/gate/15.1-note.md" ] && [ ! -e "$d/k/docs/plans/PLAN-15-review/reviews/old.bak" ] && [ ! -e "$d/k/tmp/PLAN-15" ] || fail "fixture K apply: the cited gate note tracked, old.bak not, the scratch deleted"
  # fixture N (v0.19.1): the placeholder quoted from the playbook — `tmp/PLAN-NN/prefreeze-code-review.md`, the bare dir, a `.X` form — is prose,
  # never a cite, from the plan file and the LOG alike (PLAN-37's Surprises read UNRESOLVED at the freeze and forced a reword commit); a real
  # numeric cite that resolves nowhere is still UNRESOLVED beside it
  mkdir -p "$d/n/docs/plans" "$d/n/tmp/PLAN-16"
  printf '# PLAN-16\n\n## Surprises\n\nThe playbook names `tmp/PLAN-NN/prefreeze-code-review.md`, the dir `tmp/PLAN-NN`, and `tmp/PLAN-NN/NN.X-prompt.md`; ours: `tmp/PLAN-16/16.1-run.log`, `tmp/PLAN-16/16.1-verdict.md`.\n' > "$d/n/docs/plans/PLAN-16-x.md"
  printf '## log\n\nPer the playbook, tmp/PLAN-NN/prefreeze-code-review.md.\n' > "$d/n/docs/LOG.md"; printf 'run\n' > "$d/n/tmp/PLAN-16/16.1-run.log"
  set +e; outN="$("$BASH" "$0" --root "$d/n" --plan PLAN-16 --dry-run 2>&1)"; rcN=$?; set -e
  nN="$(grep -c '^UNRESOLVED ' <<< "$outN")" || [ $? -eq 1 ] || fail "fixture N: counting the UNRESOLVED lines failed"   # 1 = no line (the count prints 0); 2 = an error, never a pass
  [ "$rcN" -eq 1 ] && [ "$nN" -eq 1 ] && grep -Fq 'UNRESOLVED tmp/PLAN-16/16.1-verdict.md' <<< "$outN" || fail "fixture N: exactly one UNRESOLVED — the real missing cite, never the placeholder (rc=$rcN): $outN"
  if grep -Fq 'PLAN-NN' <<< "$outN"; then fail "fixture N: the placeholder tmp/PLAN-NN/… was read as a cite: $outN"; else rcg=$?; [ "$rcg" -eq 1 ] || fail "fixture N: the placeholder check failed (grep exit $rcg)"; fi
  # --check: each scan captured — a failing find (the listing, the bounded scan, an entry's age) is exit 2, never "tmp/ clean"
  mkdir -p "$d/ck/tmp/PLAN-01" "$d/ck/tmp/bounded"; printf 'x\n' > "$d/ck/tmp/bounded/a.log"; printf 'x\n' > "$d/ck/tmp/young.log"
  "$BASH" "$0" --root "$d/ck" --check >/dev/null 2>&1 || fail "--check fixture should be clean with no fault"
  for f in 'FAKE_FIND_FAIL= -mindepth 1 -maxdepth 1 ' 'FAKE_FIND_FAIL= -type f -mmin ' 'FAKE_FIND_FAIL= -maxdepth 0 -mmin '; do
    set +e; o="$(env PATH="$d/fk:$PATH" "$f" "$BASH" "$0" --root "$d/ck" --check 2>&1)"; r=$?; set -e
    [ "$r" -eq 2 ] && ! grep -Fq 'tmp/ clean' <<< "$o" || fail "--check with $f should exit 2, never read as clean (rc=$r): $o"
  done
  # … and its sort: the listing's order is a producer too — a sort that prints the listing and THEN fails is exit 2, never "tmp/ clean"
  printf '#!/bin/sh\n"%s" "$@"; rc=$?\ncase "${FAKE_SORT_FAIL:-}" in 1) echo "sort: injected failure" >&2; exit 73 ;; esac\nexit $rc\n' "$(command -v sort)" > "$d/fk/sort"; chmod +x "$d/fk/sort"
  set +e; o="$(env PATH="$d/fk:$PATH" FAKE_SORT_FAIL=1 "$BASH" "$0" --root "$d/ck" --check 2>&1)"; r=$?; set -e
  [ "$r" -eq 2 ] && grep -Fq -- '--check — sort failed' <<< "$o" && ! grep -Fq 'tmp/ clean' <<< "$o" || fail "--check with sort failing after printing should exit 2, never read as clean (rc=$r): $o"
  # the verdict rule outranks the prompt rule: the launcher's verdict names keep a prompt file's name, and a verdict is a review
  for vn in prompt-review-read-verdict.md prefreeze-prompt-r2-read-verdict.md premise-read-verdict.md 07.1-L1-verdict.md; do
    [ "$(categorize "$vn" 100)" = reviews ] || fail "categorize: $vn should file under reviews/, got $(categorize "$vn" 100)"
  done
  [ "$(categorize prefreeze-prompt.md 100)" = prompts ] && [ "$(categorize big-verdict.md 300000)" = archive ] || fail "categorize: a prompt stays under prompts/, a verdict over the cap is archive-only"
  # resolve: a failing lookup is exit 2 with nothing printed — never "missing", never an empty directory
  for fc in '-Fxq x.log' '-Fxq shots/' '^shots/ shots/'; do   # <the grep argument that fails> <the cite>
    set +e; o="$(PATH="$d/fake:$PATH"; export FAKE_GREP_FAIL="${fc%% *}"; resolve "${fc#* }" "$d/members-w" 2>/dev/null)"; r=$?; set -e
    [ "$r" -eq 2 ] && [ -z "$o" ] || fail "resolve '${fc#* }' with grep failing on '${fc%% *}' should return 2 and print nothing (rc=$r): $o"
  done
  # … and ere_escape's sed, on both paths that build an ERE from a cite (a directory cite, a pattern cite): exit 2, nothing printed
  for cite in shots/ 'x{,a}.log'; do
    set +e; o="$(PATH="$d/fake:$PATH"; export FAKE_SED_FAIL='s/[]*.^$+?(){}|[]/\\&/g'; resolve "$cite" "$d/members-w" 2>/dev/null)"; r=$?; set -e
    [ "$r" -eq 2 ] && [ -z "$o" ] || fail "resolve '$cite' with ere_escape's sed failing should return 2 and print nothing (rc=$r): $o"
  done
  # fixture W (v0.23): a git checkout anywhere under tmp/PLAN-NN stops both modes before anything is read (PLAN-36's 1.2 GB red worktree made
  # the dry run crawl and would have archived 1.1 GB). Each shape: exit 1, named, the refusal line, nothing indexed, no archive, no review dir,
  # nothing deleted. Shapes: a .git dir and a real `git worktree add` (.git file) at tmp/PLAN-NN itself, a nested worktree, a nested clone,
  # a symlink .git (live and broken), and a name holding a newline. Then a scan that fails with a checkout present is exit 2, never 1 or an
  # archive, and once the checkouts are gone the close runs clean
  mkdir -p "$d/w/docs/plans" "$d/w/Sources" "$d/w/tmp/PLAN-21"
  printf 'let x = 1\n' > "$d/w/Sources/x.swift"
  git -C "$d/w" init -q && git -C "$d/w" add Sources/x.swift \
    && git -C "$d/w" -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q -m base || fail "fixture W: building the repo failed"
  printf 'prompt\n' > "$d/w/tmp/PLAN-21/21.1-prompt.md"
  printf '# PLAN-21\n\nPrompt `tmp/PLAN-21/21.1-prompt.md`.\n' > "$d/w/docs/plans/PLAN-21-fixture.md"
  printf '# PLAN-22\n\nNothing cited.\n' > "$d/w/docs/plans/PLAN-22-fixture.md"; printf '## log\n' > "$d/w/docs/LOG.md"
  w_refuses() {   # $1 = PLAN-NN, $2 = the path the refusal must name, $3 = a file that must survive, $4 = the case's name
    local m o r
    for m in dry-run apply; do
      set +e; o="$("$BASH" "$0" --root "$d/w" --plan "$1" --"$m" 2>&1)"; r=$?; set -e
      [ "$r" -eq 1 ] || fail "fixture W ($4): --$m should refuse with exit 1 (got $r): $o"
      grep -Fq "tmp-tidy: $2 holds a git checkout" <<< "$o" || fail "fixture W ($4): --$m did not name $2: $o"
      grep -Fq -- "--$m refused — nothing was read, tracked, archived or deleted" <<< "$o" || fail "fixture W ($4): --$m printed no refusal: $o"
      grep -Fq 'files on disk' <<< "$o" && fail "fixture W ($4): --$m indexed the scratch before refusing: $o"
      [ ! -e "$d/w/archive" ] && [ ! -e "$d/w/docs/plans/$1-review" ] || fail "fixture W ($4): --$m wrote an archive or a review dir"
      [ -e "$3" ] || fail "fixture W ($4): --$m deleted $3"
    done
  }
  mkdir "$d/w/tmp/PLAN-21/.git"
  w_refuses PLAN-21 tmp/PLAN-21 "$d/w/tmp/PLAN-21/21.1-prompt.md" "a .git dir at tmp/PLAN-NN itself"
  rmdir "$d/w/tmp/PLAN-21/.git"
  git -C "$d/w" worktree add -q --detach tmp/PLAN-22 >/dev/null 2>&1 && [ -f "$d/w/tmp/PLAN-22/.git" ] || fail "fixture W: the worktree at tmp/PLAN-22 has no .git file"
  w_refuses PLAN-22 tmp/PLAN-22 "$d/w/tmp/PLAN-22/Sources/x.swift" "a git worktree at tmp/PLAN-NN itself"
  git -C "$d/w" worktree remove --force tmp/PLAN-22 >/dev/null 2>&1 || fail "fixture W: removing the tmp/PLAN-22 worktree failed"
  git -C "$d/w" worktree add -q --detach tmp/PLAN-21/red-worktree >/dev/null 2>&1 && [ -f "$d/w/tmp/PLAN-21/red-worktree/.git" ] || fail "fixture W: the nested worktree has no .git file"
  w_refuses PLAN-21 tmp/PLAN-21/red-worktree "$d/w/tmp/PLAN-21/red-worktree/Sources/x.swift" "a nested worktree"
  mkdir -p "$d/w/tmp/PLAN-21/clone/.git" "$d/w/tmp/PLAN-21/clone/Build"; printf 'bulk\n' > "$d/w/tmp/PLAN-21/clone/Build/big.bin"
  w_refuses PLAN-21 tmp/PLAN-21/clone "$d/w/tmp/PLAN-21/clone/Build/big.bin" "a nested clone beside a worktree"
  git -C "$d/w" worktree remove --force tmp/PLAN-21/red-worktree >/dev/null 2>&1 && rm -rf "$d/w/tmp/PLAN-21/clone" || fail "fixture W: removing the nested checkouts failed"
  mkdir -p "$d/w/tmp/PLAN-21/lnk"; ln -s "$d/w/.git" "$d/w/tmp/PLAN-21/lnk/.git"
  w_refuses PLAN-21 tmp/PLAN-21/lnk "$d/w/tmp/PLAN-21/lnk/.git" "a live .git symlink"
  rm -rf "$d/w/tmp/PLAN-21/lnk"; mkdir -p "$d/w/tmp/PLAN-21/brk"; ln -s "$d/w/no-such-dir" "$d/w/tmp/PLAN-21/brk/.git"
  w_refuses PLAN-21 tmp/PLAN-21/brk "$d/w/tmp/PLAN-21/21.1-prompt.md" "a broken .git symlink"
  rm -rf "$d/w/tmp/PLAN-21/brk"
  nl="$(printf 'red\nwt')"; mkdir -p "$d/w/tmp/PLAN-21/$nl/.git"   # find prints `./red` and `wt/.git` on two lines: any line refuses
  w_refuses PLAN-21 tmp/PLAN-21/wt "$d/w/tmp/PLAN-21/$nl/.git" "a checkout name holding a newline"
  # the harsher scan fault: the real find runs, prints the checkout, THEN exits 73 — exit 2, never the exit-1 refusal, never an archive
  set +e; o="$(env PATH="$d/fk:$PATH" 'FAKE_FIND_FAIL= -name .git -prune ' "$BASH" "$0" --root "$d/w" --plan PLAN-21 --apply 2>&1)"; r=$?; set -e
  [ "$r" -eq 2 ] && grep -Fq "scanning tmp/PLAN-21 for git checkouts failed" <<< "$o" && [ ! -e "$d/w/archive" ] && [ -d "$d/w/tmp/PLAN-21/$nl/.git" ] \
    || fail "fixture W: a failed checkout scan should refuse at exit 2 before any archive (rc=$r): $o"
  rm -rf "$d/w/tmp/PLAN-21/$nl"
  set +e; o="$("$BASH" "$0" --root "$d/w" --plan PLAN-21 --apply 2>&1)"; r=$?; set -e
  [ "$r" -eq 0 ] && [ ! -d "$d/w/tmp/PLAN-21" ] && [ -f "$d/w/docs/plans/PLAN-21-review/prompts/21.1-prompt.md" ] || fail "fixture W: with the checkouts gone, --apply should track, archive and delete (rc=$r): $o"
  # fixture X (v0.25) split-repo mode: RATCHET_RECORDS in <root>/script/ratchet.conf names a nested records repo. The plan, the LOG, the review
  # dir and the archive are under it; tmp/ stays under the root; nothing lands in the root's docs/ or archive/. --records names one outright;
  # the environment's empty value wins over the conf (one repo); a records root that can't be used is exit 2, never one repo; --check reads
  # tmp/ only. Then a missing LOG is exit 2 in both layouts (it was once skipped, so its cites went unread)
  mkdir -p "$d/x/script" "$d/x/tmp/PLAN-30" "$d/x/private/docs/plans" && git -C "$d/x" init -q && git -C "$d/x/private" init -q || fail "fixture X: building the code and records repos failed"
  printf 'RATCHET_RECORDS=private\n' > "$d/x/script/ratchet.conf"
  printf '# PLAN-30\n\nPrompt `tmp/PLAN-30/30.1-prompt.md`.\n' > "$d/x/private/docs/plans/PLAN-30-x.md"
  printf '## log\n\nRun `tmp/PLAN-30/30.1-run.log`.\n' > "$d/x/private/docs/LOG.md"
  printf 'prompt\n' > "$d/x/tmp/PLAN-30/30.1-prompt.md"; printf 'run\n' > "$d/x/tmp/PLAN-30/30.1-run.log"
  outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)" || fail "fixture X: the split dry-run should exit 0: $outX"
  grep -Fq '| `tmp/PLAN-30/30.1-prompt.md` | tracked: docs/plans/PLAN-30-review/prompts/30.1-prompt.md |' <<< "$outX" && grep -Fq '| `tmp/PLAN-30/30.1-run.log` | archive: archive/plans/PLAN-30' <<< "$outX" \
    || fail "fixture X: the split dry-run should read the plan and the LOG under private/: $outX"
  [ ! -e "$d/x/docs" ] && [ ! -e "$d/x/archive" ] && [ ! -e "$d/x/private/archive" ] && [ ! -e "$d/x/private/docs/plans/PLAN-30-review" ] || fail "fixture X: a dry run wrote into a repo"
  outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --apply 2>&1)" || fail "fixture X: the split apply should exit 0: $outX"
  [ -f "$d/x/private/docs/plans/PLAN-30-review/prompts/30.1-prompt.md" ] && [ -f "$d/x/private/docs/plans/PLAN-30-review/MANIFEST.md" ] && [ -s "$d/x/private/archive/plans/PLAN-30.list" ] \
    && [ ! -e "$d/x/tmp/PLAN-30" ] && [ ! -e "$d/x/docs" ] && [ ! -e "$d/x/archive" ] || fail "fixture X: the split apply should write the review dir and the archive under private/, delete tmp/PLAN-30, and write nothing in the root: $outX"
  grep -Fxq -- '- tracked: docs/plans/PLAN-30-review/prompts/30.1-prompt.md' "$d/x/private/docs/plans/PLAN-30-review/MANIFEST.md" || fail "fixture X: the MANIFEST's tracked paths must stay relative to the records root"
  outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)" || fail "fixture X: the re-check after the apply should exit 0 (the cites resolve through private/'s archive): $outX"
  mkdir -p "$d/x/tmp/PLAN-31" "$d/xr/docs/plans"; printf 'p\n' > "$d/x/tmp/PLAN-31/31.1-prompt.md"
  printf '# PLAN-31\n\n`tmp/PLAN-31/31.1-prompt.md`\n' > "$d/xr/docs/plans/PLAN-31-x.md"; printf '## log\n' > "$d/xr/docs/LOG.md"
  outX="$("$BASH" "$0" --root "$d/x" --records "$d/xr" --plan PLAN-31 --apply 2>&1)" && [ -f "$d/xr/docs/plans/PLAN-31-review/prompts/31.1-prompt.md" ] && [ -s "$d/xr/archive/plans/PLAN-31.list" ] \
    || fail "fixture X: --records should name the records root outright, over the conf: $outX"
  mkdir -p "$d/x/tmp/PLAN-30"; printf 'again\n' > "$d/x/tmp/PLAN-30/30.2-prompt.md"
  set +e; outX="$(RATCHET_RECORDS= "$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)"; rX=$?; set -e
  [ "$rX" -eq 0 ] && ! grep -Fq 'expected exactly one' <<< "$outX" || fail "fixture X: an empty RATCHET_RECORDS in the environment must leave the conf's records root in force, as ratchet.sh and kit/herdr read it (rc=$rX): $outX"
  mkdir -p "$d/x/plain"; ln -s "$d/x/private" "$d/x/lnk"
  for bad in 'RATCHET_RECORDS=nope' 'RATCHET_RECORDS=plain' "RATCHET_RECORDS=$d/x/private" 'false'; do
    printf '%s\n' "$bad" > "$d/x/script/ratchet.conf"
    set +e; outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)"; rX=$?; set -e
    [ "$rX" -eq 2 ] && ! grep -Fq 'files on disk' <<< "$outX" || fail "fixture X: the conf line '$bad' should be exit 2 before anything is read (rc=$rX): $outX"
    case "$bad" in *plain) grep -Fq 'not the top of its own repo' <<< "$outX" || fail "fixture X: a records dir inside the code repo's work tree should be named as not its own repo: $outX" ;; esac
    "$BASH" "$0" --root "$d/x" --check >/dev/null 2>&1 || fail "fixture X: --check reads tmp/ only, whatever the conf says ('$bad')"
  done
  # the records path rule (modules/split-repo.md): a symlink anywhere along it, a '.', '..' or empty component → exit 2, nothing read;
  # trailing slashes stripped; a non-empty environment value wins over the conf
  mkdir -p "$d/x/real" && git -C "$d/x/real" init -q rec 2>/dev/null || git init -q "$d/x/real/rec" || fail "fixture X: building real/rec failed"
  ln -s "$d/x/real" "$d/x/via"
  for bad in lnk via/rec ./private private/./x private/../private 'a//b'; do
    printf 'RATCHET_RECORDS=%s\n' "$bad" > "$d/x/script/ratchet.conf"
    set +e; outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)"; rX=$?; set -e
    [ "$rX" -eq 2 ] && ! grep -Fq 'files on disk' <<< "$outX" || fail "fixture X: RATCHET_RECORDS=$bad should be exit 2 before anything is read (rc=$rX): $outX"
    case "$bad" in lnk|via/rec) grep -Fq 'a symlink along the path' <<< "$outX" || fail "fixture X: RATCHET_RECORDS=$bad should be refused as a symlinked path: $outX" ;;
      *) grep -Fq "a '.', '..' or empty component" <<< "$outX" || fail "fixture X: RATCHET_RECORDS=$bad should be refused for its components: $outX" ;; esac
  done
  printf 'RATCHET_RECORDS=real/rec\n' > "$d/x/script/ratchet.conf"   # control: the same repo with no symlink passes the path rule (it then finds no plan there)
  set +e; outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)"; rX=$?; set -e
  [ "$rX" -eq 2 ] && grep -Fq 'expected exactly one real/rec/docs/plans/PLAN-30-*.md' <<< "$outX" || fail "fixture X: real/rec (no symlink) should pass the path rule and look there for the plan (rc=$rX): $outX"
  printf 'RATCHET_RECORDS=private//\n' > "$d/x/script/ratchet.conf"
  outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)" && grep -Fq 'tracked: docs/plans/PLAN-30-review/prompts/30.2-prompt.md' <<< "$outX" \
    || fail "fixture X: trailing slashes in the conf's RATCHET_RECORDS should be stripped: $outX"
  printf 'RATCHET_RECORDS=nope\n' > "$d/x/script/ratchet.conf"
  outX="$(RATCHET_RECORDS=private/ "$BASH" "$0" --root "$d/x" --plan PLAN-30 --dry-run 2>&1)" && grep -Fq 'tracked: docs/plans/PLAN-30-review/prompts/30.2-prompt.md' <<< "$outX" \
    || fail "fixture X: a non-empty environment RATCHET_RECORDS (trailing slash and all) should win over the conf's: $outX"
  printf 'RATCHET_RECORDS=private\n' > "$d/x/script/ratchet.conf"
  mv "$d/x/private/docs/LOG.md" "$d/x/private/docs/LOG.away"
  set +e; outX="$("$BASH" "$0" --root "$d/x" --plan PLAN-30 --apply 2>&1)"; rX=$?; set -e
  [ "$rX" -eq 2 ] && grep -Fq 'no private/docs/LOG.md' <<< "$outX" && [ -d "$d/x/tmp/PLAN-30" ] && [ ! -e "$d/x/private/docs/plans/PLAN-30-review/prompts/30.2-prompt.md" ] \
    || fail "fixture X: a missing LOG under the records root should be exit 2 with nothing tracked or deleted (rc=$rX): $outX"
  mkdir -p "$d/nl/docs/plans" "$d/nl/tmp/PLAN-33"; printf '# PLAN-33\n' > "$d/nl/docs/plans/PLAN-33-x.md"; printf 'p\n' > "$d/nl/tmp/PLAN-33/33.1-prompt.md"
  set +e; outX="$("$BASH" "$0" --root "$d/nl" --plan PLAN-33 --dry-run 2>&1)"; rX=$?; set -e
  [ "$rX" -eq 2 ] && grep -Fq 'no docs/LOG.md' <<< "$outX" || fail "fixture X: a missing LOG in one repo should be exit 2 too (rc=$rX): $outX"
  # fixture L (v0.25, T7) the configured paths: RATCHET_LOG and RATCHET_PLANS_DIR are read as the ratchet reads them (the conf when it
  # sets them, else the environment, else docs/LOG.md and docs/plans); the rotated months are <LOG's dir>/log/*.md; a missing CONFIGURED
  # LOG is exit 2 even with a docs/LOG.md beside it; the review dir and the MANIFEST's paths follow the plans dir; one repo and split
  mkdir -p "$d/L/script" "$d/L/plans" "$d/L/log" "$d/L/docs" "$d/L/tmp/PLAN-35"
  printf 'RATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=plans\n' > "$d/L/script/ratchet.conf"
  printf '# PLAN-35\n\nPrompt `tmp/PLAN-35/35.1-prompt.md`.\n' > "$d/L/plans/PLAN-35-x.md"
  printf '## log\n\nNote `tmp/PLAN-35/35.1-note.md`.\n' > "$d/L/LOG.md"
  printf '## old\n\nVerdict `tmp/PLAN-35/35.0-verdict.md`.\n' > "$d/L/log/2026-01.md"
  printf '## decoy\n\nNot read: `tmp/PLAN-35/decoy.md`.\n' > "$d/L/docs/LOG.md"
  printf 'p\n' > "$d/L/tmp/PLAN-35/35.1-prompt.md"; printf 'n\n' > "$d/L/tmp/PLAN-35/35.1-note.md"; printf 'v\n' > "$d/L/tmp/PLAN-35/35.0-verdict.md"
  outL="$("$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)" || fail "fixture L: the dry run with a configured LOG and plans dir should exit 0: $outL"
  grep -Fq '| `tmp/PLAN-35/35.1-prompt.md` | tracked: plans/PLAN-35-review/prompts/35.1-prompt.md |' <<< "$outL" || fail "fixture L: the tracked path should follow RATCHET_PLANS_DIR: $outL"
  grep -Fq '`tmp/PLAN-35/35.1-note.md`' <<< "$outL" && grep -Fq '`tmp/PLAN-35/35.0-verdict.md`' <<< "$outL" || fail "fixture L: the configured LOG and its rotated month (log/*.md) should be read for cites: $outL"
  grep -Fq 'decoy' <<< "$outL" && fail "fixture L: docs/LOG.md must not be read when RATCHET_LOG names another LOG: $outL"
  grep -Fq 'this plan'"'"'s file, `LOG.md`, and `log/*.md`' <<< "$outL" || fail "fixture L: the MANIFEST should name the configured LOG and its months: $outL"
  grep -Fxq -- '- tracked: plans/PLAN-35-review/prompts/35.1-prompt.md' <<< "$outL" && ! grep -Fq -- '- tracked: docs/plans/' <<< "$outL" \
    || fail "fixture L: the dry run's inventory should list this run's tracked files under RATCHET_PLANS_DIR: $outL"
  outL="$("$BASH" "$0" --root "$d/L" --plan PLAN-35 --apply 2>&1)" || fail "fixture L: the apply should exit 0: $outL"
  [ -f "$d/L/plans/PLAN-35-review/MANIFEST.md" ] && [ ! -e "$d/L/docs/plans" ] && grep -Fxq -- '- tracked: plans/PLAN-35-review/prompts/35.1-prompt.md' "$d/L/plans/PLAN-35-review/MANIFEST.md" \
    && ! grep -Fq 'docs/plans/' "$d/L/plans/PLAN-35-review/MANIFEST.md" \
    || fail "fixture L: the review dir and the inventory should sit under RATCHET_PLANS_DIR: $outL"
  mkdir -p "$d/L/tmp/PLAN-35"; printf 'q\n' > "$d/L/tmp/PLAN-35/35.2-prompt.md"; mv "$d/L/LOG.md" "$d/L/LOG.away"
  set +e; outL="$("$BASH" "$0" --root "$d/L" --plan PLAN-35 --apply 2>&1)"; rL=$?; set -e
  [ "$rL" -eq 2 ] && grep -Fq 'no LOG.md (RATCHET_LOG)' <<< "$outL" && [ -f "$d/L/tmp/PLAN-35/35.2-prompt.md" ] || fail "fixture L: a missing configured LOG should be exit 2, a docs/LOG.md beside it notwithstanding (rc=$rL): $outL"
  mv "$d/L/LOG.away" "$d/L/LOG.md"
  printf 'RATCHET_PLANS_DIR=plans\n' > "$d/L/script/ratchet.conf"   # the conf leaves RATCHET_LOG unset: the environment's is used
  outL="$(RATCHET_LOG=LOG.md "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)" && ! grep -Fq decoy <<< "$outL" || fail "fixture L: RATCHET_LOG from the environment should be used when the conf doesn't set it: $outL"
  printf 'RATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=plans\n' > "$d/L/script/ratchet.conf"   # the conf sets it: the conf wins, as in the ratchet
  outL="$(RATCHET_LOG=docs/LOG.md "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)" && ! grep -Fq decoy <<< "$outL" || fail "fixture L: the conf's RATCHET_LOG should win over the environment's, as ratchet.sh reads it: $outL"
  # U3: the conf is sourced over the inherited environment, never a cleared one, so a conf that reads the environment agrees with the
  # ratchet: RATCHET_LOG="${RATCHET_LOG:-docs/LOG.md}" with the environment's LOG.md is LOG.md in both; without it, docs/LOG.md in both
  printf 'RATCHET_LOG="${RATCHET_LOG:-docs/LOG.md}"\nRATCHET_PLANS_DIR=plans\n' > "$d/L/script/ratchet.conf"
  outL="$(RATCHET_LOG=LOG.md "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)" && ! grep -Fq decoy <<< "$outL" \
    || fail "fixture L: a conf that defaults RATCHET_LOG from the environment should see the environment's LOG.md, as the ratchet does: $outL"
  set +e; outL="$(env -u RATCHET_LOG "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)"; rL=$?; set -e   # docs/LOG.md's decoy cite is UNRESOLVED: exit 1
  [ "$rL" -eq 1 ] && grep -Fq 'UNRESOLVED tmp/PLAN-35/decoy.md' <<< "$outL" \
    || fail "fixture L: the same conf with no RATCHET_LOG in the environment should read its default, docs/LOG.md (rc=$rL): $outL"
  td="$(cd "$(dirname "$0")" && pwd)" || fail "fixture L: cannot name this script's folder"
  printf 'RATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=plans\nNOTE="$TT_NEVER_SET_ANYWHERE"\n' > "$d/L/script/ratchet.conf"   # the ratchet sources its conf before set -u
  outL="$(env -u TT_NEVER_SET_ANYWHERE "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)" && ! grep -Fq decoy <<< "$outL" \
    || fail "fixture L: a conf naming an unset variable should source as it does for the ratchet (empty), not fail under set -u: $outL"
  if [ -f "$td/ratchet.sh" ]; then   # the ratchet itself, sourced as a library over the same conf and environment, names the same LOG
    cp "$td/ratchet.sh" "$d/L/script/ratchet.sh" || fail "fixture L: copying the ratchet failed"
    rl="$(cd "$d/L" && RATCHET_LOG=LOG.md RATCHET_LIB=1 "$BASH" -c '. script/ratchet.sh; printf %s "$RATCHET_LOG"')" && [ "$rl" = LOG.md ] \
      || fail "fixture L: the ratchet should read LOG.md from the same conf and environment (got '$rl')"
    rm -f "$d/L/script/ratchet.sh"
  fi
  # U7: the selection loop writes nothing (its rows collect in memory), and the one write after it is checked: a cite.rows that can't be
  # written is exit 2 through the script, nothing tracked — the work dir comes from a fake mktemp whose cite.rows is a directory
  printf 'RATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=plans\n' > "$d/L/script/ratchet.conf"
  sl="$(awk '/^    while IFS= read -r rel; do +# selection-loop: / { on = 1; n++; next } /^    done < "\$work\/hits" .*# selection-loop end$/ { on = 0; e++ }
             on && /printf/ { print NR": "$0 } END { if (n != 1 || e != 1) print "markers: " n + 0 " start, " e + 0 " end (want 1 each)" }' "$0")" || fail "the selection-loop lint failed to run"
  [ -z "$sl" ] || fail "the selection loop must not write rows (its own || turns errexit off, so a failed printf would drop a row unseen): $sl"
  mkdir -p "$d/fmk" && printf '#!/bin/sh\nif [ "$1" = -d ]; then mkdir -p "%s/fmkw/cite.rows" && echo "%s/fmkw"; else exec %s "$@"; fi\n' "$d" "$d" "$(command -v mktemp)" > "$d/fmk/mktemp" && chmod +x "$d/fmk/mktemp" \
    || fail "fixture L: the fake mktemp could not be written"
  set +e; outL="$(PATH="$d/fmk:$PATH" "$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)"; rL=$?; set -e
  [ "$rL" -eq 2 ] && grep -Fq 'writing the selection for tmp/PLAN-35/' <<< "$outL" || fail "fixture L: a selection that can't be written should be exit 2, never a short selection (rc=$rL): $outL"
  # each bad value names its own refusal (the paths it names EXIST, so no later "missing" check can stand in for the rule)
  cp "$d/L/LOG.md" "$d/LOG.md"; mkdir -p "$d/L/pl ans" && cp "$d/L/plans/PLAN-35-x.md" "$d/L/pl ans/"
  for bad in 'RATCHET_PLANS_DIR=' 'RATCHET_LOG=../LOG.md' "RATCHET_LOG=$d/L/LOG.md" "RATCHET_PLANS_DIR='pl ans'" 'RATCHET_PLANS_DIR=../L/plans'; do
    printf '%s\n' "$bad" > "$d/L/script/ratchet.conf"
    set +e; outL="$("$BASH" "$0" --root "$d/L" --plan PLAN-35 --dry-run 2>&1)"; rL=$?; set -e
    [ "$rL" -eq 2 ] && ! grep -Fq 'files on disk' <<< "$outL" || fail "fixture L: the conf line '$bad' should be exit 2 before anything is read (rc=$rL): $outL"
    case "$bad" in
      'RATCHET_PLANS_DIR=') want="(Lite's inline plans)" ;;
      *'pl ans'*) want='may hold only letters, digits' ;;
      *=../*) want="names a '.', '..' or empty component" ;;
      *) want='must be a non-empty path from its root' ;;
    esac
    grep -Fq "$want" <<< "$outL" || fail "fixture L: the conf line '$bad' should be refused with '$want': $outL"
  done
  rm -f "$d/LOG.md"; rm -rf "$d/L/pl ans"
  mkdir -p "$d/Ls/script" "$d/Ls/tmp/PLAN-36" "$d/Ls/private/plans" && git -C "$d/Ls/private" init -q || fail "fixture L: building the split pair failed"
  printf 'RATCHET_RECORDS=private\nRATCHET_LOG=LOG.md\nRATCHET_PLANS_DIR=plans\n' > "$d/Ls/script/ratchet.conf"
  printf '# PLAN-36\n' > "$d/Ls/private/plans/PLAN-36-x.md"; printf '## log\n\n`tmp/PLAN-36/36.1-note.md`\n' > "$d/Ls/private/LOG.md"; printf 'n\n' > "$d/Ls/tmp/PLAN-36/36.1-note.md"
  outL="$("$BASH" "$0" --root "$d/Ls" --plan PLAN-36 --apply 2>&1)" && [ -f "$d/Ls/private/plans/PLAN-36-review/reviews/36.1-note.md" ] && [ -s "$d/Ls/private/archive/plans/PLAN-36.list" ] \
    || fail "fixture L: split-repo with a configured LOG and plans dir should read and write under the records root: $outL"
  mkdir -p "$d/Ls/tmp/PLAN-36"; printf 'm\n' > "$d/Ls/tmp/PLAN-36/36.2-note.md"; rm -f "$d/Ls/private/LOG.md"
  set +e; outL="$("$BASH" "$0" --root "$d/Ls" --records "$d/Ls/private" --plan PLAN-36 --apply 2>&1)"; rL=$?; set -e
  [ "$rL" -eq 2 ] && grep -Fq 'LOG.md (RATCHET_LOG)' <<< "$outL" && [ -f "$d/Ls/tmp/PLAN-36/36.2-note.md" ] || fail "fixture L: split-repo's missing configured LOG should be exit 2 through --records too (rc=$rL): $outL"
  # fixture Y (v0.25) opaque bundles: a *.xcresult directory (and a TMP_TIDY_OPAQUE glob's) is one item — never walked (its members are not
  # counted on disk), never tracked, archived whole; the .list names it once; a cite of the bundle, of a path inside it, or a pattern
  # matching it resolves; a checkout inside a bundle is never looked for; a bad glob is a usage error
  mkdir -p "$d/y/docs/plans" "$d/y/tmp/PLAN-34/r/a.xcresult/Data" "$d/y/tmp/PLAN-34/b.app/Contents"
  i=0; while [ "$i" -lt 40 ]; do printf 'x%s\n' "$i" > "$d/y/tmp/PLAN-34/r/a.xcresult/Data/f$i.md"; i=$((i+1)); done
  printf 'plist\n' > "$d/y/tmp/PLAN-34/r/a.xcresult/Info.plist"; printf 'bin\n' > "$d/y/tmp/PLAN-34/b.app/Contents/x.md"; mkdir -p "$d/y/tmp/PLAN-34/r/a.xcresult/.git"
  printf 'note\n' > "$d/y/tmp/PLAN-34/34.1-notes.md"
  printf '# PLAN-34\n\n`tmp/PLAN-34/r/a.xcresult`, `tmp/PLAN-34/r/a.xcresult/Data/f3.md`, `tmp/PLAN-34/r/*.xcresult`, `tmp/PLAN-34/b.app/Contents/x.md`.\n' > "$d/y/docs/plans/PLAN-34-x.md"
  printf '## log\n' > "$d/y/docs/LOG.md"
  outY="$(TMP_TIDY_OPAQUE='*.app' "$BASH" "$0" --root "$d/y" --plan PLAN-34 --dry-run 2>&1)" || fail "fixture Y: the dry run should exit 0 (every bundle cite resolves; no checkout is looked for inside a bundle): $outY"
  grep -Fq 'tmp-tidy: PLAN-34 (dry-run) — 1 files on disk, 1 tracked' <<< "$outY" || fail "fixture Y: a bundle's members must never be walked, counted or tracked: $outY"
  grep -q 'tracked: .*xcresult\|tracked: .*b\.app' <<< "$outY" && fail "fixture Y: a bundle member was tracked: $outY"
  grep -Fq '| `tmp/PLAN-34/r/a.xcresult/Data/f3.md` | dir/prefix → archive: archive/plans/PLAN-34' <<< "$outY" && grep -Fq '| `tmp/PLAN-34/r/*.xcresult` | pattern citation — 1 matching' <<< "$outY" \
    || fail "fixture Y: a cite inside a bundle and a pattern matching one should resolve through the bundle: $outY"
  set +e; outY="$("$BASH" "$0" --root "$d/y" --plan PLAN-34 --dry-run 2>&1)"; rY=$?; set -e   # without the glob, b.app is walked like any dir, and its member resolves as a file
  [ "$rY" -eq 0 ] && grep -Fq '2 files on disk' <<< "$outY" || fail "fixture Y: with no TMP_TIDY_OPAQUE, b.app's member should be an ordinary file (rc=$rY): $outY"
  outY="$(TMP_TIDY_OPAQUE='*.app' "$BASH" "$0" --root "$d/y" --plan PLAN-34 --apply 2>&1)" || fail "fixture Y: the apply should exit 0: $outY"
  [ ! -e "$d/y/tmp/PLAN-34" ] && grep -Fxq 'PLAN-34/r/a.xcresult/' "$d/y/archive/plans/PLAN-34.list" && grep -Fxq 'PLAN-34/b.app/' "$d/y/archive/plans/PLAN-34.list" \
    && ! grep -q 'xcresult/Data\|xcresult/Info\|b\.app/Contents' "$d/y/archive/plans/PLAN-34.list" || fail "fixture Y: the .list should name each bundle once and none of its members: $(cat "$d/y/archive/plans/PLAN-34.list" 2>/dev/null)"
  ya="$(ls "$d/y/archive/plans/"PLAN-34.tar.* | awk 'NR==1')"; case "$ya" in *.zst) zstd -dc "$ya" > "$d/y.tar" ;; *) gzip -dc "$ya" > "$d/y.tar" ;; esac
  tar -tf "$d/y.tar" | grep -Fxq 'PLAN-34/r/a.xcresult/Data/f39.md' || fail "fixture Y: the archive must hold the bundle's members"
  outY="$(TMP_TIDY_OPAQUE='*.app' "$BASH" "$0" --root "$d/y" --plan PLAN-34 --dry-run 2>&1)" || fail "fixture Y: the re-check after the apply should resolve every bundle cite through the .list: $outY"
  grep -Fq 'disagrees with the archive' <<< "$outY" && fail "fixture Y: the archive's members must be read collapsed, as the .list names them (a bundle's members are no drift): $outY"
  mkdir -p "$d/y/tmp/PLAN-34/r/a.xcresult/Data"; printf 'x3\n' > "$d/y/tmp/PLAN-34/r/a.xcresult/Data/f3.md"; printf 'changed\n' > "$d/y/tmp/PLAN-34/r/a.xcresult/Info.plist"
  set +e; outY="$("$BASH" "$0" --root "$d/y" --plan PLAN-34 --apply 2>&1)"; rY=$?; set -e   # a bundle of the same name whose contents differ from the archived one: evidence is never replaced
  [ "$rY" -eq 1 ] && grep -Fq 'archive: r/a.xcresult/' <<< "$outY" && [ -d "$d/y/tmp/PLAN-34/r/a.xcresult" ] || fail "fixture Y: a differing same-name bundle should be refused as a collision (rc=$rY): $outY"
  rm -rf "$d/y/tmp/PLAN-34"
  for bad in 'x/*.app' '[ab].app' '*.app;rm'; do
    set +e; outY="$(TMP_TIDY_OPAQUE="$bad" "$BASH" "$0" --root "$d/y" --check 2>&1)"; rY=$?; set -e
    [ "$rY" -eq 64 ] || fail "fixture Y: TMP_TIDY_OPAQUE='$bad' should be a usage error (rc=$rY): $outY"
  done
  # fixture Z (v0.25) the dir cap: a cited directory whose would-be-tracked members total more than TMP_TIDY_DIR_CAP_KB is archived whole —
  # its structural members included — while a member cited on its own is still tracked; under a raised cap the same directory is tracked
  mkdir -p "$d/z/docs/plans" "$d/z/tmp/PLAN-35/big" "$d/z/tmp/PLAN-35/small"
  big="$(awk 'BEGIN { while (n++ < 100000) printf "a" }')"; i=0
  while [ "$i" -lt 25 ]; do printf '%s' "$big" > "$d/z/tmp/PLAN-35/big/f$i.txt"; i=$((i+1)); done
  printf 'go\n' > "$d/z/tmp/PLAN-35/big/35.1-prompt.md"; printf 's\n' > "$d/z/tmp/PLAN-35/small/s.txt"
  printf '# PLAN-35\n\n`tmp/PLAN-35/big/`, `tmp/PLAN-35/big/f7.txt`, `tmp/PLAN-35/small/`.\n' > "$d/z/docs/plans/PLAN-35-x.md"; printf '## log\n' > "$d/z/docs/LOG.md"
  outZ="$("$BASH" "$0" --root "$d/z" --plan PLAN-35 --dry-run 2>&1)" || fail "fixture Z: the dry run should exit 0: $outZ"
  grep -Fq '| `tmp/PLAN-35/big/` | archived (dir over cap) — 26 members to track, 2501 KB, over the 2000 KB cap → archive: archive/plans/PLAN-35' <<< "$outZ" \
    || fail "fixture Z: the over-cap directory should read 'archived (dir over cap)': $outZ"
  grep -Fxq -- '- tracked: docs/plans/PLAN-35-review/reviews/big/f7.txt' <<< "$outZ" && grep -Fxq -- '- tracked: docs/plans/PLAN-35-review/reviews/small/s.txt' <<< "$outZ" \
    && [ "$(grep -c -- '- tracked: ' <<< "$outZ")" -eq 2 ] || fail "fixture Z: only the member cited on its own and the under-cap directory's file should be tracked (the prompt under big/ too is archived): $outZ"
  outZ="$(TMP_TIDY_DIR_CAP_KB=5000 "$BASH" "$0" --root "$d/z" --plan PLAN-35 --dry-run 2>&1)" || fail "fixture Z: the dry run under a raised cap should exit 0: $outZ"
  grep -Fq 'dir over cap' <<< "$outZ" && fail "fixture Z: under a 5000 KB cap the directory is tracked: $outZ"
  [ "$(grep -c -- '- tracked: ' <<< "$outZ")" -eq 27 ] || fail "fixture Z: under a raised cap all 26 members and small/'s file should be tracked: $outZ"
  for bad in x 12a 12345678; do
    set +e; outZ="$(TMP_TIDY_DIR_CAP_KB="$bad" "$BASH" "$0" --root "$d/z" --plan PLAN-35 --dry-run 2>&1)"; rZ=$?; set -e
    [ "$rZ" -eq 64 ] || fail "fixture Z: TMP_TIDY_DIR_CAP_KB='$bad' should be a usage error (rc=$rZ): $outZ"
  done
  outZ="$("$BASH" "$0" --root "$d/z" --plan PLAN-35 --apply 2>&1)" || fail "fixture Z: the apply should exit 0: $outZ"
  [ ! -e "$d/z/tmp/PLAN-35" ] && [ -f "$d/z/docs/plans/PLAN-35-review/reviews/big/f7.txt" ] && [ ! -e "$d/z/docs/plans/PLAN-35-review/reviews/big/f8.txt" ] \
    && [ ! -e "$d/z/docs/plans/PLAN-35-review/prompts/big/35.1-prompt.md" ] && grep -Fxq 'PLAN-35/big/f8.txt' "$d/z/archive/plans/PLAN-35.list" || fail "fixture Z: the apply should track f7 alone from big/ and archive the rest: $outZ"
  echo "SELF-TEST OK"; exit 0
fi

if [ "$do_check" -eq 1 ]; then
  rc=0; check_tmp "$ROOT" || rc=$?
  [ "$rc" -ne 0 ] || { echo "tmp-tidy: tmp/ clean"; exit 0; }
  exit "$rc"   # 1 = a stray, 2 = a scan failed
fi

case "$plan" in
  PLAN-[0-9]*) ;;
  *) echo 'usage: tmp-tidy.sh --plan PLAN-NN [--dry-run|--apply] | --check | --self-test' >&2; exit 64 ;;
esac
REC=""; REC_LABEL=""; LOG_REL=""; LOGDIR_REL=""; PLANS_REL=""
resolve_records "$ROOT" || exit 2
tidy_plan "$ROOT" "$plan" "$mode" "$REC"
