#!/usr/bin/awk -f
#
# docker/ci-lists.awk - the SINGLE reader of .github/workflows/flashida-ci.yml.
#
# The C++ build-target list and the ctest -R alternation live in exactly one
# place: the workflow file, which is frozen (spec D6) and still runs on every
# push. Nothing else may copy them. This parser extracts them; docker/ci-lists.sh
# wraps it, validates it, and reconciles the two lists against each other.
#
# ---------------------------------------------------------------------------
# INVOCATION.  Always `awk -f docker/ci-lists.awk ...`, NEVER as an inline
# shell string, and NEVER via grep.  A BRE grep for the continuation shape
#     grep 'cmake --build OpenMS/build --target *\\$'
# returns ZERO matches on the real file; ERE and awk return one.
#
# ---------------------------------------------------------------------------
# THE CR TRAP - the single most dangerous bug this file exists to prevent.
# The worktree copy of the yml is CRLF (core.autocrlf=true, no root
# .gitattributes): `git ls-files --eol` reports "i/lf w/crlf" and the file
# carries 608 CR bytes.  On a Git-for-Windows host gawk, GNU sed and GNU grep
# all SILENTLY strip that CR, so a naive parser reads 26 targets there and
# ZERO under container mawk - with exit 0.  The ctest alternation still parses
# (the CR sits outside the -R "..." match), so the failure mode is: build
# nothing, then run 24 ctest branches against an empty build dir, and report
# full green.  Hence: strip \r+$ from EVERY record before anything else, twice,
# by two independent mechanisms (a regex AND an explicit chr(13) loop), and let
# ci-lists.sh re-assert non-emptiness afterwards.
#
# ---------------------------------------------------------------------------
# PORTABILITY CONTRACT.  POSIX awk only.  Verified under mawk 1.3.4 20240123
# (ubuntu:24.04), busybox awk 1.37.0 (alpine) and GNU awk 5.4.0 (Git for
# Windows).  Therefore NO gensub(), NO length(array), NO asort()/asorti(),
# NO ENVIRON, NO \s / \w, NO gawk-only regex.  Every "does this separator get
# treated as a regex" ambiguity is sidestepped with index()/substr().
#
# ---------------------------------------------------------------------------
# OPTIONS (all via -v):
#   mode=all|targets|branches|regex|pins|cmakenames|doccheck   default: all
#   src=<label used in diagnostics>                            default: FILENAME
#   min_targets=<int>                                          default: 20
#
# OUTPUT:
#   mode=all         keyed TSV on stdout - SRC / COUNT / LINE / RAWREGEX /
#                    TARGET / BRANCH / PIN / PINMISSING / YMLCLAIM / WARN / INFO
#   mode=targets     one build-target name per line
#   mode=branches    one ctest -R alternation branch per line
#   mode=regex       the RAW -R string, verbatim, exactly one line
#   mode=pins        key=value per line for every toolchain pin the yml carries
#   mode=cmakenames  unique registered test names from executables.cmake
#   mode=doccheck    DOCREGEX / DOCCLAIM records from a prose file (CLAUDE.md)
#
# EXIT: 0 = ok.  2 = fail-closed parse/validation failure; every message goes
#       to stderr prefixed "ci-lists.awk: ERROR:" and NOTHING is written to
#       stdout, so a caller can never mistake a failure for an empty list.

BEGIN {
  TAB = sprintf("%c", 9)
  CR  = sprintf("%c", 13)

  if (mode == "") mode = "all"
  if (min_targets == "") min_targets = 20
  min_targets = min_targets + 0

  nerr = 0; nwarn = 0; ninfo = 0
  ntargets = 0; nbranches = 0; ncnames = 0
  npins = 0; nmissing = 0
  ndocregex = 0; ndocclaim = 0; nymlclaim = 0
  n_anchor = 0; n_ctest = 0
  in_block = 0; block_line = 0
  raw_regex = ""; ctest_line = 0; contrib_line = 0
  qt_window = 0; runs_on = ""
  src_set = 0

  if (mode != "all" && mode != "targets" && mode != "branches" && mode != "regex" && mode != "pins" && mode != "cmakenames" && mode != "doccheck")
    err("unknown mode '" mode "' (expected one of: all targets branches regex pins cmakenames doccheck)")
}

{
  if (!src_set) {
    if (src == "") src = (FILENAME == "" ? "(stdin)" : FILENAME)
    src_set = 1
  }
  line = rtrim(strip_cr($0))

  if (mode == "cmakenames") { cmake_name(line); next }
  if (mode == "doccheck")   { doc_scan(line);   next }
  yml_scan(line)
}

END {
  if (src == "") src = (FILENAME == "" ? "(stdin)" : FILENAME)

  if (mode == "cmakenames") { validate_cmakenames(); if (nerr == 0) emit_cmakenames(); finish() }
  if (mode == "doccheck")   { if (nerr == 0) emit_doc(); finish() }

  validate_yml()
  if (nerr > 0) finish()

  if (mode == "all")           emit_all()
  else if (mode == "targets")  { emit_list(targets, ntargets);  emit_diag_stderr() }
  else if (mode == "branches") { emit_list(branches, nbranches); emit_diag_stderr() }
  else if (mode == "regex")    { print raw_regex;                emit_diag_stderr() }
  else if (mode == "pins")     { emit_pins();                    emit_diag_stderr() }
  finish()
}

# ===========================================================================
#  scanning
# ===========================================================================

function yml_scan(line,   had_cont, payload, after, c, rest, m, q, inner, v) {
  had_cont = ends_bs(line)
  if (had_cont) payload = rtrim(substr(line, 1, length(line) - 1))
  else          payload = line

  # --- inside the --target continuation block: every line is targets ---
  if (in_block) {
    collect_targets(payload, FNR)
    if (!had_cont) in_block = 0
    return
  }

  # --- the build --target anchor --------------------------------------
  # Matched as an ERE (a BRE grep finds nothing here), then guarded on the
  # NEXT character so `--targetfoo` can never be mistaken for `--target`.
  if (match(line, /cmake[ \t]+--build[ \t]+OpenMS\/build[ \t]+--target/)) {
    after = substr(line, RSTART + RLENGTH)
    c = substr(after, 1, 1)
    if (after == "" || c == " " || c == TAB) {
      if (had_cont) {
        n_anchor++
        if (n_anchor == 1) {
          block_line = FNR
          in_block = 1
          rest = rtrim(after)
          if (ends_bs(rest)) rest = rtrim(substr(rest, 1, length(rest) - 1))
          rest = ltrim(rest)
          if (rest != "") collect_targets(rest, FNR)
        } else {
          err("found more than one `cmake --build OpenMS/build --target \\` continuation block in " src " (first at line " block_line ", another at line " FNR "). CI grew a second build block; refusing to guess which one governs. Fix: keep one block, or teach docker/ci-lists.awk which is authoritative.")
        }
      } else {
        info("other `cmake --build OpenMS/build --target` line at " src ":" FNR " (no continuation, so not the test-exe block): " ltrim(after))
      }
      return
    }
  }

  # --- the ctest -R alternation ---------------------------------------
  # Every -R "..." on the line is counted, not just the first: a second
  # invocation chained onto the SAME line (`ctest ... && ctest ... -R "..."`)
  # must be as fatal as one on its own line, or the parser silently picks the
  # first and the second CI step is never reproduced locally.
  if (index(line, "ctest") > 0 && match(line, /-R[ \t]+"[^"]*"/)) {
    rest = line
    while (match(rest, /-R[ \t]+"[^"]*"/)) {
      n_ctest++
      m = substr(rest, RSTART, RLENGTH)
      rest = substr(rest, RSTART + RLENGTH)
      q = index(m, "\"")
      inner = substr(m, q + 1, length(m) - q - 1)
      if (n_ctest == 1) { raw_regex = inner; ctest_line = FNR }
      else err("found " n_ctest " `ctest ... -R \"...\"` invocations in " src " (first at line " ctest_line ", another at line " FNR "). CI grew a second ctest step; refusing to pick one. Fix: keep one, or teach docker/ci-lists.awk which is authoritative.")
    }
    return
  }

  # --- the yml's OWN prose counts (history, never authoritative) -------
  if (index(line, "#") > 0 && match(line, /[0-9]+[ \t]+(named[ \t]+)?FLASH[ \t]+(C\+\+[ \t]+)?test/)) {
    v = substr(line, RSTART, RLENGTH)
    if (match(v, /^[0-9]+/)) {
      nymlclaim++
      claim_n[nymlclaim] = substr(v, 1, RLENGTH)
      claim_line[nymlclaim] = FNR
      claim_txt[nymlclaim] = ltrim(line)
    }
  }

  # --- toolchain pins (spec section 4: parsed, never copied) -----------
  if (index(line, "install-qt-action") > 0) { qt_window = 12; return }
  if (qt_window > 0) {
    qt_window--
    if (match(line, /^[ \t]*version:[ \t]*/))  setpin("qt_version",  unquote(substr(line, RSTART + RLENGTH)), FNR)
    if (match(line, /^[ \t]*arch:[ \t]*/))     setpin("qt_arch",     unquote(substr(line, RSTART + RLENGTH)), FNR)
    if (match(line, /^[ \t]*archives:[ \t]*/)) setpin("qt_archives", unquote(substr(line, RSTART + RLENGTH)), FNR)
  }
  if (match(line, /^[ \t]*runs-on:[ \t]*/)) {
    v = unquote(substr(line, RSTART + RLENGTH))
    if (v != "" && index(TAB runs_on TAB, TAB v TAB) == 0) {
      if (runs_on == "") runs_on = v
      else runs_on = runs_on TAB v
    }
  }
  if (match(line, /^[ \t]*CCACHE_MAXSIZE:[ \t]*/)) setpin("ccache_maxsize", unquote(substr(line, RSTART + RLENGTH)), FNR)
  if (index(line, "gh release download") > 0 && index(line, "OpenMS/contrib") > 0) {
    contrib_line = FNR
    if (match(line, /--tag[ \t]+[^ \t]+/)) {
      v = substr(line, RSTART, RLENGTH)
      sub(/^--tag[ \t]+/, "", v)
      setpin("contrib_tag", unquote(v), FNR)
    }
  }
}

function collect_targets(s, ln,   n, a, i, t) {
  s = ltrim(rtrim(s))
  if (s == "") {
    err("empty line inside the `--target` continuation block at " src ":" ln " (block starts at line " block_line "). A blank or comment-only continuation line is not a target; refusing to guess.")
    return
  }
  n = split(s, a, " ")
  for (i = 1; i <= n; i++) {
    t = a[i]
    if (t == "") continue
    if (t !~ /^[A-Za-z_][A-Za-z0-9_.+-]*$/) {
      err("unexpected token '" t "' inside the `--target` continuation block at " src ":" ln " - expected a bare CMake target name. Refusing to emit a list built from something the parser does not understand.")
      continue
    }
    if (t in target_seen)
      warn("build target '" t "' is listed twice in the `--target` block (" src ":" target_seen[t] " and :" ln ")")
    else
      target_seen[t] = ln
    ntargets++
    targets[ntargets] = t
    target_line[ntargets] = ln
  }
}

function cmake_name(line,   t) {
  if (line !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_.+-]*[ \t]*$/) return
  t = ltrim(rtrim(line))
  if (t == "") return
  if (t in cname_seen) { cname_seen[t] = cname_seen[t] + 1; return }
  cname_seen[t] = 1
  ncnames++
  cnames[ncnames] = t
}

function doc_scan(line,   m, q, inner, v) {
  if (match(line, /-R[ \t]+"[^"]*"/)) {
    m = substr(line, RSTART, RLENGTH)
    q = index(m, "\"")
    inner = substr(m, q + 1, length(m) - q - 1)
    # A prose placeholder such as `ctest ... -R "..."` is NOT a copy of the
    # list: it names no test. A real alternation always carries ASCII
    # letters, an ellipsis does not. Without this guard doccheck reports
    # every branch as "missing from the doc" against a doc that has
    # correctly stopped duplicating the list at all.
    if (inner ~ /[A-Za-z]/) {
      ndocregex++
      docregex[ndocregex] = inner
      docregex_line[ndocregex] = FNR
    }
  }
  if (match(line, /[0-9]+[ \t]+(named[ \t]+)?FLASH[ \t]+(C\+\+[ \t]+)?test/)) {
    v = substr(line, RSTART, RLENGTH)
    if (match(v, /^[0-9]+/)) {
      ndocclaim++
      docclaim_n[ndocclaim] = substr(v, 1, RLENGTH)
      docclaim_line[ndocclaim] = FNR
    }
  }
}

# ===========================================================================
#  validation - fail-closed, and this is the point of the file
# ===========================================================================

function validate_yml(   i, nonempty, why) {
  if (NR == 0)
    err("read zero records from " src ". The file is empty, unreadable, or was never passed. Fix: pass .github/workflows/flashida-ci.yml as the file argument.")

  if (in_block)
    err("the `--target` continuation block that starts at " src ":" block_line " never terminated - the file ends on a backslash continuation. Refusing to emit a truncated target list.")

  # --- the target list ---
  if (n_anchor == 0)
    err("no `cmake --build OpenMS/build --target \\` continuation block found in " src ". Either the anchor moved, the command was reflowed, or - the classic - every record still carries a trailing CR and nothing matched. Fix: confirm the literal `cmake --build OpenMS/build --target \\` is still present, then re-run.")
  if (ntargets < min_targets)
    err("parsed only " ntargets " build target(s) from " src " (floor is min_targets=" min_targets "). A short or empty target list means the container builds nothing and then runs ctest against an empty build dir - full silent green. Refusing to emit it.")

  # --- exactly one ctest -R invocation ---
  if (n_ctest == 0)
    err("no `ctest ... -R \"...\"` invocation found in " src ". The anchor moved or the quoting changed (single-quoted and unquoted -R are deliberately NOT matched). Refusing to run ctest with no filter.")

  # --- the alternation must be real ---
  if (n_ctest >= 1) {
    if (index(raw_regex, TAB) > 0)
      err("the ctest -R alternation at " src ":" ctest_line " contains a tab, so it cannot be emitted as one TSV record. Refusing.")
    if (raw_regex == "") {
      err("the ctest -R alternation at " src ":" ctest_line " is EMPTY. `ctest -R \"\"` is version-dependent and catastrophic in BOTH directions: it matches EVERY test on ctest 4.3.3, and NO tests with exit 0 on ctest 3.28.3. An empty regex must never reach ctest. Refusing to emit it.")
    } else {
      split_branches(raw_regex)
      nonempty = 0
      for (i = 1; i <= nbranches; i++) if (branches[i] != "") nonempty++
      if (nonempty == 0)
        err("the ctest -R alternation at " src ":" ctest_line " consists only of '|' delimiters. Refusing to emit it (see the empty-regex note above).")
      for (i = 1; i <= nbranches; i++)
        if (branches[i] == "")
          err("empty branch #" i " in the ctest -R alternation at " src ":" ctest_line " - a leading '|', a trailing '|', or '||'. In ERE that branch matches EVERYTHING, so ctest would select every test in the project. Refusing to emit it.")
      for (i = 1; i <= nbranches; i++)
        if (branches[i] != "" && branches[i] !~ /^[A-Za-z0-9_]+$/)
          warn("ctest -R branch '" branches[i] "' is not a plain literal (it carries regex metacharacters). It is still passed to ctest verbatim, but reconciliation against the build-target list is literal substring matching and will be approximate for this branch.")
    }
  }

  # --- pins the yml genuinely does NOT carry: say so, never invent one ---
  why = "the yml runs `gh release download -R OpenMS/contrib` with no tag"
  if (contrib_line > 0) why = why " (" src ":" contrib_line ")"
  why = why ", so CI resolves whatever release is LATEST at run time. There is nothing here to parse - a Dockerfile that pins a contrib tag is pinning something CI does not."
  addmissing("contrib_tag", why)
  addmissing("vc_toolset",      "not in the yml: CI gets MSVC from the windows-2022 runner image via egor-tensin/vs-shell, which resolves a floating channel. Assert cl.exe's version at container run time instead of pinning from here.")
  addmissing("win_sdk",         "not in the yml, same reason as vc_toolset.")
  addmissing("vs_buildversion", "not in the yml, same reason as vc_toolset.")
  addmissing("base_image",      "not in the yml: GitHub-hosted runners are named by label (runs-on), not by image digest.")
  if (runs_on != "") setpin("runs_on", runs_on, 0)
}

function validate_cmakenames() {
  if (ncnames == 0)
    err("parsed zero registered test names from " src ". Expected indented bare names inside the executables.cmake `set(..._executables_list ...)` blocks. Refusing to report an empty registry as agreement.")
}

# ===========================================================================
#  emission
# ===========================================================================

function emit_all(   i) {
  print "SRC" TAB src
  print "COUNT" TAB "targets" TAB ntargets
  print "COUNT" TAB "branches" TAB nbranches
  print "LINE" TAB "target_block" TAB block_line
  print "LINE" TAB "ctest" TAB ctest_line
  print "RAWREGEX" TAB raw_regex
  for (i = 1; i <= ntargets; i++)  print "TARGET" TAB targets[i] TAB target_line[i]
  for (i = 1; i <= nbranches; i++) print "BRANCH" TAB branches[i]
  for (i = 1; i <= npins; i++)     print "PIN" TAB pin_k[i] TAB pin_v[i] TAB pin_l[i]
  for (i = 1; i <= nmissing; i++)  print "PINMISSING" TAB miss_k[i] TAB miss_why[i]
  for (i = 1; i <= nymlclaim; i++) print "YMLCLAIM" TAB claim_n[i] TAB claim_line[i] TAB claim_txt[i]
  for (i = 1; i <= nwarn; i++)     print "WARN" TAB warns[i]
  for (i = 1; i <= ninfo; i++)     print "INFO" TAB infos[i]
}

function emit_list(a, n,   i) { for (i = 1; i <= n; i++) print a[i] }

function emit_pins(   i) {
  for (i = 1; i <= npins; i++) print pin_k[i] "=" pin_v[i]
  for (i = 1; i <= nmissing; i++)
    print "ci-lists.awk: NOTE: pin '" miss_k[i] "' is NOT parseable from " src ": " miss_why[i] > "/dev/stderr"
}

function emit_cmakenames(   i) { for (i = 1; i <= ncnames; i++) print cnames[i] }

function emit_doc(   i) {
  print "SRC" TAB src
  for (i = 1; i <= ndocregex; i++) print "DOCREGEX" TAB docregex_line[i] TAB docregex[i]
  for (i = 1; i <= ndocclaim; i++) print "DOCCLAIM" TAB docclaim_line[i] TAB docclaim_n[i]
}

function emit_diag_stderr(   i) {
  for (i = 1; i <= nwarn; i++) print "ci-lists.awk: WARN: " warns[i] > "/dev/stderr"
  for (i = 1; i <= ninfo; i++) print "ci-lists.awk: INFO: " infos[i] > "/dev/stderr"
}

function finish(   i) {
  if (nerr > 0) {
    for (i = 1; i <= nerr; i++) print "ci-lists.awk: ERROR: " errs[i] > "/dev/stderr"
    exit 2
  }
  exit 0
}

# ===========================================================================
#  helpers - deliberately primitive, so that every awk agrees
# ===========================================================================

# Strip trailing CR twice, by two independent mechanisms. See THE CR TRAP.
function strip_cr(s) {
  sub(/\r+$/, "", s)
  while (length(s) > 0 && substr(s, length(s), 1) == CR) s = substr(s, 1, length(s) - 1)
  return s
}

function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
function rtrim(s) { sub(/[ \t]+$/, "", s); return s }
function ends_bs(s) { return (length(s) > 0 && substr(s, length(s), 1) == "\\") }

function unquote(s,   c) {
  s = ltrim(rtrim(s))
  if (length(s) >= 2) {
    c = substr(s, 1, 1)
    if ((c == "'" || c == "\"") && substr(s, length(s), 1) == c) s = substr(s, 2, length(s) - 2)
  }
  return s
}

# Split on '|' with index()/substr() only. split() with a single-character
# separator is treated literally by every awk we target - but "every awk we
# target agrees" is exactly the assumption that let the CR trap through, so the
# delimiter never touches a regex engine here. Empty branches are PRESERVED,
# because an empty branch is precisely what validate_yml() has to fail on.
function split_branches(s,   rest, p, b) {
  rest = s
  while (1) {
    p = index(rest, "|")
    if (p == 0) { nbranches++; branches[nbranches] = rest; break }
    b = substr(rest, 1, p - 1)
    rest = substr(rest, p + 1)
    nbranches++
    branches[nbranches] = b
  }
}

function setpin(k, v, ln) {
  if (v == "") return
  if (k in pin_have) return
  pin_have[k] = 1
  npins++
  pin_k[npins] = k
  pin_v[npins] = v
  pin_l[npins] = ln
}

function addmissing(k, why) {
  if (k in pin_have) return
  nmissing++
  miss_k[nmissing] = k
  miss_why[nmissing] = why
}

function err(s)  { nerr++;  errs[nerr]   = s }
function warn(s) { nwarn++; warns[nwarn] = s }
function info(s) { ninfo++; infos[ninfo] = s }
