# acceptance-extract.awk: prints the body of a plan's `## Validation and Acceptance` section (the heading line itself is
# not included). ratchet.sh (the hash check), refreeze.sh (the stamp) and ci-replay.sh all call it, so what gets
# stamped and what gets checked can't drift. Rule: protocol/verification.md § Enforce the freeze.
#
# Kit copy: install as script/acceptance-extract.awk, and commit it before the first stamp. Usage: awk -f
# acceptance-extract.awk <plan.md>. Its tests live in ratchet.sh --self-test.
#
# The section runs to the next real `## ` heading. Three kinds of `## ` line are content, not a boundary:
#   1. inside a fenced code block: opened by three or more backticks or tildes at up to three spaces of indent, and
#      closed only by a fence of the same character that is at least as long;
#   2. inside a shell here-doc opened on an indented line (a Verify: block): <<WORD, <<'WORD', <<"WORD", <<-WORD, and
#      every here-doc on that line in order, until the line that is exactly the pending WORD (leading tabs allowed
#      after <<-);
#   3. a line indented four or more spaces (a Markdown code line).
# Fence state is tracked from the top of the file, so a `## Validation and Acceptance` line inside a fence never opens
# the section. Each rule only extends the extracted region, so a plan with none of these lines keeps its stamp byte for
# byte.
function fence_open(line,    m) {                       # → the fence string (```` ``` ```` / `~~~~`) when the line opens one, else ""
  if (match(line, /^ {0,3}(`{3,}|~{3,})/)) { m = substr(line, RSTART, RLENGTH); sub(/^ */, "", m); return m }
  return ""
}
function fence_closes(line, open,    m, c) {             # → 1 when the line is a closing fence for `open`: same char, at least as long
  if (!match(line, /^ {0,3}(`{3,}|~{3,})[ \t]*$/)) return 0
  m = substr(line, RSTART, RLENGTH); sub(/^ */, "", m); sub(/[ \t]*$/, "", m)
  c = substr(open, 1, 1)
  return (substr(m, 1, 1) == c && length(m) >= length(open))
}
function push_heredocs(line,    rest, m, w, d) {          # every `<<WORD` on the line, left to right, queued in order
  rest = line
  while (match(rest, /<<-?[ \t]*['"]?[A-Za-z_][A-Za-z0-9_]*['"]?/)) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    d = (substr(m, 3, 1) == "-") ? 1 : 0
    gsub(/^<<-?[ \t]*['"]?/, "", m); gsub(/['"]$/, "", m)
    nhd++; hdw[nhd] = m; hdd[nhd] = d
  }
}
{
  if (fence != "") {                                     # inside a fence (before or inside the section): content until it closes
    if (f) print
    if (fence_closes($0, fence)) fence = ""
    next
  }
  if (f && hdi <= nhd) {                                 # inside a here-doc body: content until the pending terminator
    print
    line = $0; if (hdd[hdi]) sub(/^\t+/, "", line)
    if (line == hdw[hdi]) hdi++
    next
  }
  if (!f && $0 ~ /^## Validation and Acceptance/) { f = 1; nhd = 0; hdi = 1; next }   # the section starts (heading not hashed)
  if (f && $0 ~ /^## /) { f = 0 }                        # a real top-level heading ends the section
  if (f) {
    print                                                # every line in between, verbatim
    if ($0 ~ /^[ \t]/) push_heredocs($0)                 # here-docs are recognized only on indented (Verify block) lines
  }
  m = fence_open($0); if (m != "") fence = m             # a fence opens anywhere in the file
}
