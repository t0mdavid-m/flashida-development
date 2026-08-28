#!/bin/sh
#
# docker/ci-lists.sh - the ONLY supported interface to docker/ci-lists.awk.
#
# The C++ build-target list and the ctest -R alternation are sourced from
# .github/workflows/flashida-ci.yml - parsed, never copied. The workflow file is
# frozen (spec D6) and still runs on every push; this script is how both
# containers and the `ci` dispatcher read it.
#
#   ./docker/ci-lists.sh targets       # one CMake build-target name per line
#   ./docker/ci-lists.sh branches      # one ctest -R alternation branch per line
#   ./docker/ci-lists.sh ctest-regex   # the RAW -R string, verbatim, one line
#   ./docker/ci-lists.sh pins          # key=value for every toolchain pin in the yml
#   ./docker/ci-lists.sh selftest      # parse + validate + reconcile + report (default)
#
# `targets`, `branches`, `ctest-regex` and `pins` write MACHINE-READABLE data to
# stdout and every diagnostic to stderr, so they can be consumed with $(...).
# `selftest` writes a human report to stdout ending in one verdict line.
#
# EXIT CODES
#   0   ok
#   2   fail-closed parse/validation failure (missing file, no anchor, empty or
#       delimiter-only -R, fewer than FLCI_MIN_TARGETS targets, more than one
#       ctest step, ...). For the DATA subcommands (targets/branches/
#       ctest-regex/pins) NOTHING is written to stdout in this case - measured
#       0 bytes. `selftest` is a HUMAN report and has already printed its header
#       by then, so never parse selftest stdout; read its exit status.
#
#       >>> CONSUMERS MUST CHECK THE EXIT STATUS. <<<  On failure stdout is
#       EMPTY, so a bare `for t in $(ci-lists.sh targets)` builds nothing and
#       succeeds, and `ctest -R "$(ci-lists.sh ctest-regex)"` runs with an empty
#       filter - the exact silent-green this parser exists to prevent. Write
#           TARGETS=$(docker/ci-lists.sh targets) || exit 1
#       and never `|| true`.
#   3   reconciliation failure (a ctest -R branch that matches no build target, a
#       build target no branch selects, or a target not registered in
#       executables.cmake)
#   64  usage error
#
# ENVIRONMENT (all optional)
#   FLCI_AWK           awk to use (default: awk). Must be POSIX; mawk, busybox
#                      awk and gawk are all verified.
#   FLCI_WORKFLOW      path to the workflow file (default: <repo>/.github/workflows/flashida-ci.yml)
#   FLCI_MIN_TARGETS   floor on the parsed target count (default: 20)
#   FLCI_REPO_ROOT     override the repo root (default: this script's parent dir)
#   FLCI_REQUIRE_CMAKE 1 = a missing OpenMS/.../executables.cmake is a HARD
#                      failure even when the OpenMS submodule is not checked out.
#                      A missing file with the submodule POPULATED is already
#                      fatal without this - that combination is a broken tree,
#                      never a legitimate parent-only clone.
#
# PORTABILITY. POSIX sh (verified under bash, and written for dash/busybox ash).
# No bashisms, no `local`, no arrays, no `set -o pipefail`, no absolute host
# paths: the repo root is resolved from this script's own location. The only
# external commands used are awk, tr and cat.
#
# WHY THIS IS PARANOID. The worktree copy of the yml is CRLF and Git-for-Windows
# gawk/sed/grep strip CR silently, so a naive parser reads 26 targets on the host
# and ZERO under container mawk - with exit 0. That would build nothing, then run
# the 24 ctest branches against an empty build dir, and report full green. Every
# assertion below exists to make that impossible: ci-lists.awk validates, and
# then this script re-validates the awk's own output independently.

set -eu

PROG=ci-lists.sh
CR=$(printf '\r')
NL='
'

TMPD=

cleanup() {
  if [ -n "$TMPD" ] && [ -d "$TMPD" ]; then rm -rf "$TMPD"; fi
  return 0
}
trap 'cleanup' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# ---------------------------------------------------------------------------
# diagnostics
# ---------------------------------------------------------------------------

die() {
  _code=$1
  shift
  printf '%s: ERROR: %s\n' "$PROG" "$*" >&2
  printf 'FAIL: %s\n' "$*" >&2
  exit "$_code"
}

note() { printf '%s: %s\n' "$PROG" "$*" >&2; }

usage() {
  cat <<'USAGE'
usage: docker/ci-lists.sh [targets|branches|ctest-regex|pins|selftest|help]

  targets       one CMake build-target name per line, from the
                `cmake --build OpenMS/build --target \` continuation block
  branches      one ctest -R alternation branch per line
  ctest-regex   the RAW -R string, verbatim, exactly one line
                (pass it to ctest UNCHANGED, so an over-broad branch stays visible)
  pins          key=value for every toolchain pin the yml actually carries;
                pins the yml does NOT carry are reported on stderr, never invented
  selftest      parse + validate + reconcile the two lists + cross-check
                executables.cmake and the prose copies; prints a verdict line.
                This is the default, and it is step 1 of every C++ entry point.
  help          this text

exit: 0 ok | 2 fail-closed parse failure | 3 reconciliation failure | 64 usage
USAGE
}

# ---------------------------------------------------------------------------
# locate ourselves, the repo root, the awk program and the workflow
# ---------------------------------------------------------------------------

case $0 in
  */*) _progdir=${0%/*} ;;
  *)   _progdir=. ;;
esac
SCRIPT_DIR=$(CDPATH='' cd -- "$_progdir" 2>/dev/null && pwd -P) || SCRIPT_DIR=
[ -n "$SCRIPT_DIR" ] || die 2 "cannot resolve the directory of '$0'. Invoke this script by path, e.g. ./docker/ci-lists.sh"

REPO_ROOT=${FLCI_REPO_ROOT:-}
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT=$(CDPATH='' cd -- "$SCRIPT_DIR/.." 2>/dev/null && pwd -P) || REPO_ROOT=
fi
[ -n "$REPO_ROOT" ] || die 2 "cannot resolve the repo root from '$SCRIPT_DIR'. This script must live at <repo>/docker/ci-lists.sh, or set FLCI_REPO_ROOT."

AWK_PROG=$SCRIPT_DIR/ci-lists.awk
[ -f "$AWK_PROG" ] || die 2 "the parser is missing: expected '$AWK_PROG'. docker/ci-lists.awk and docker/ci-lists.sh ship together; do not invoke one without the other."

AWK=${FLCI_AWK:-awk}
command -v "$AWK" >/dev/null 2>&1 || die 2 "no awk on PATH (tried '$AWK'). Set FLCI_AWK, or install mawk/gawk. There is no fallback parser by design - see docker/ci-lists.awk."

WORKFLOW_REL=.github/workflows/flashida-ci.yml
WORKFLOW=${FLCI_WORKFLOW:-$REPO_ROOT/$WORKFLOW_REL}
WORKFLOW_LABEL=$WORKFLOW_REL
if [ -n "${FLCI_WORKFLOW:-}" ]; then
  WORKFLOW_LABEL=$FLCI_WORKFLOW
  case $WORKFLOW_LABEL in
    *\\*) die 2 "FLCI_WORKFLOW contains a backslash ('$WORKFLOW_LABEL'). awk -v processes escape sequences, so the label would be mangled. Use forward slashes." ;;
  esac
fi

[ -f "$WORKFLOW" ] || die 2 "workflow file not found: '$WORKFLOW' (repo root resolved to '$REPO_ROOT'). The test lists are sourced from it and there is no committed copy to fall back on. Fix: run this from a checkout that contains $WORKFLOW_REL, or set FLCI_WORKFLOW."
[ -r "$WORKFLOW" ] || die 2 "workflow file is not readable: '$WORKFLOW'."

MIN_TARGETS=${FLCI_MIN_TARGETS:-20}
case $MIN_TARGETS in
  ''|*[!0-9]*) die 2 "FLCI_MIN_TARGETS must be a non-negative integer, got '$MIN_TARGETS'." ;;
esac

CMAKE_REL=OpenMS/src/tests/class_tests/openms/executables.cmake
CMAKE_LIST=$REPO_ROOT/$CMAKE_REL

# ---------------------------------------------------------------------------
# small helpers (awk-based, so they need no coreutils beyond tr/cat)
# ---------------------------------------------------------------------------

make_tmpd() {
  if [ -n "$TMPD" ]; then return 0; fi
  if command -v mktemp >/dev/null 2>&1; then
    TMPD=$(mktemp -d 2>/dev/null) || TMPD=
  fi
  if [ -z "$TMPD" ]; then
    TMPD=${TMPDIR:-/tmp}/ci-lists.$$
    mkdir -p "$TMPD"
  fi
  [ -d "$TMPD" ] || die 2 "cannot create a temporary directory (tried mktemp -d and \${TMPDIR:-/tmp}/ci-lists.$$)."
}

count_lines() { "$AWK" 'END { print NR + 0 }' "$1"; }

count_cr() { "$AWK" 'BEGIN { c = sprintf("%c", 13); n = 0 } { n += gsub(c, "") } END { print n + 0 }' "$1"; }

# Every count that gates a fail-closed test must actually BE a number. If the
# awk in use produces nothing (a broken FLCI_AWK, a truncated write), then
# `[ "$n" -lt 20 ]` prints "Illegal number" to stderr and takes the FALSE
# branch - the guard passes and `targets` exits 0 with an EMPTY list, which is
# exactly the silent-green this parser exists to prevent. VERIFIED in dash.
# Call this from the PARENT shell, never inside $(...): a die inside a command
# substitution only kills the subshell.
require_num() {
  case ${1:-} in
    ''|*[!0-9]*)
      die 2 "internal: expected a count from ${2:-a counter}, got '${1:-}'. The awk in use ('$AWK') is not producing numeric output, so the fail-closed guards below cannot run. Refusing to emit a list that was never validated." ;;
  esac
}

# one branch per line, splitting on '|' with parameter expansion only
split_pipes() {
  _s=$1
  while :; do
    case $_s in
      *'|'*) printf '%s\n' "${_s%%'|'*}"; _s=${_s#*'|'} ;;
      *)     printf '%s\n' "$_s"; break ;;
    esac
  done
}

# run the parser into a file; any awk failure is fatal and leaves stdout empty
run_parser() {
  _mode=$1
  _out=$2
  set +e
  "$AWK" -f "$AWK_PROG" -v mode="$_mode" -v src="$WORKFLOW_LABEL" -v min_targets="$MIN_TARGETS" "$WORKFLOW" > "$_out"
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    rm -f "$_out"
    die 2 "docker/ci-lists.awk exited $_rc while parsing $WORKFLOW_LABEL (mode=$_mode). The ERROR line(s) above name what it expected. Nothing was emitted - a missing list is a failure here, never an empty list."
  fi
}

# ---------------------------------------------------------------------------
# independent re-validation of the awk's own output (belt and braces)
# ---------------------------------------------------------------------------

assert_targets_file() {
  _f=$1
  _n=$(count_lines "$_f"); require_num "$_n" "the line count of $_f"
  if [ "$_n" -lt "$MIN_TARGETS" ]; then
    die 2 "only $_n build target(s) survived the parse of $WORKFLOW_LABEL (floor FLCI_MIN_TARGETS=$MIN_TARGETS). An empty or short target list means the container builds nothing and then runs ctest against an empty build dir - which reports full green. Refusing."
  fi
  _cr=$(count_cr "$_f"); require_num "$_cr" "the CR count of $_f"
  if [ "$_cr" -ne 0 ]; then
    die 2 "a carriage return survived into the parsed target list. docker/ci-lists.awk's CR strip is broken, or the list was produced by something else. Refusing to use it."
  fi
  while IFS= read -r _t; do
    case $_t in
      '')                    die 2 "empty build-target name in the parsed list from $WORKFLOW_LABEL." ;;
      *[!A-Za-z0-9_.+-]*)    die 2 "implausible build-target name '$_t' parsed from $WORKFLOW_LABEL - a CMake target name cannot contain that character. Refusing to pass it to cmake --build." ;;
    esac
  done < "$_f"
}

assert_regex_file() {
  _f=$1
  _n=$(count_lines "$_f"); require_num "$_n" "the line count of $_f"
  if [ "$_n" -ne 1 ]; then
    die 2 "expected exactly one line for the ctest -R alternation, got $_n from $WORKFLOW_LABEL."
  fi
  _raw=
  IFS= read -r _raw < "$_f" || true
  if [ -z "$_raw" ]; then
    die 2 "the ctest -R alternation parsed EMPTY from $WORKFLOW_LABEL. 'ctest -R \"\"' is version-dependent and catastrophic in BOTH directions: it matches EVERY test on ctest 4.3.3 and NO tests, exit 0, on ctest 3.28.3. An empty regex must never reach ctest."
  fi
  case $_raw in
    *"$CR"*) die 2 "a carriage return survived into the ctest -R alternation. Refusing to pass it to ctest." ;;
  esac
  case $_raw in
    *'"'*) die 2 "the ctest -R alternation contains a double quote; the extraction is wrong. Refusing." ;;
  esac
  _stripped=$(printf '%s' "$_raw" | tr -d '|')
  if [ -z "$_stripped" ]; then
    die 2 "the ctest -R alternation from $WORKFLOW_LABEL consists only of '|' delimiters, which in ERE selects every test. Refusing."
  fi
}

# ---------------------------------------------------------------------------
# subcommands that emit data
# ---------------------------------------------------------------------------

cmd_targets() {
  make_tmpd
  run_parser targets "$TMPD/targets.txt"
  assert_targets_file "$TMPD/targets.txt"
  cat "$TMPD/targets.txt"
}

cmd_branches() {
  make_tmpd
  run_parser branches "$TMPD/branches.txt"
  _n=$(count_lines "$TMPD/branches.txt"); require_num "$_n" "the parsed branch count"
  if [ "$_n" -lt 1 ]; then
    die 2 "zero ctest -R alternation branches parsed from $WORKFLOW_LABEL."
  fi
  cat "$TMPD/branches.txt"
}

cmd_regex() {
  make_tmpd
  run_parser regex "$TMPD/regex.txt"
  assert_regex_file "$TMPD/regex.txt"
  cat "$TMPD/regex.txt"
}

cmd_pins() {
  make_tmpd
  run_parser pins "$TMPD/pins.txt"
  _n=$(count_lines "$TMPD/pins.txt"); require_num "$_n" "the parsed pin count"
  if [ "$_n" -lt 1 ]; then
    die 2 "zero toolchain pins parsed from $WORKFLOW_LABEL - at minimum the install-qt-action version: is expected. The anchor moved."
  fi
  cat "$TMPD/pins.txt"
}

# ---------------------------------------------------------------------------
# selftest: parse, validate, reconcile, cross-check, report
# ---------------------------------------------------------------------------

RECON_FAIL=0

recon_fail() {
  printf 'FAIL  %s\n' "$*"
  RECON_FAIL=$((RECON_FAIL + 1))
}

cmd_selftest() {
  make_tmpd

  # -- 0. our own two files must be LF. A CRLF ci-lists.sh dies with
  #       "bad interpreter: /bin/sh^M" inside the Linux container, and a CRLF
  #       ci-lists.awk is a coin flip per awk implementation.
  for _f in "$AWK_PROG" "$SCRIPT_DIR/ci-lists.sh"; do
    if [ -f "$_f" ]; then
      _cr=$(count_cr "$_f"); require_num "$_cr" "the CR count of $_f"
      if [ "$_cr" -ne 0 ]; then
        die 2 "'$_f' contains carriage returns. These files run inside a Linux container; a CRLF shebang fails with 'bad interpreter'. Fix: a root .gitattributes with '*.sh text eol=lf' and 'docker/** text eol=lf', then re-checkout (core.autocrlf=true is set on this host and there is no root .gitattributes yet)."
      fi
    fi
  done

  printf '=== ci-lists selftest ===\n'
  printf 'repo root   %s\n' "$REPO_ROOT"
  printf 'workflow    %s\n' "$WORKFLOW_LABEL"
  printf 'awk         %s\n' "$(command -v "$AWK")"
  printf 'min targets %s\n\n' "$MIN_TARGETS"

  # -- 1. parse ------------------------------------------------------------
  run_parser all "$TMPD/all.tsv"

  "$AWK" -F '\t' '$1 == "TARGET"    { print $2 }' "$TMPD/all.tsv" > "$TMPD/targets.txt"
  "$AWK" -F '\t' '$1 == "BRANCH"    { print $2 }' "$TMPD/all.tsv" > "$TMPD/branches.txt"
  "$AWK" -F '\t' '$1 == "RAWREGEX"  { print $2 }' "$TMPD/all.tsv" > "$TMPD/regex.txt"

  assert_targets_file "$TMPD/targets.txt"
  assert_regex_file   "$TMPD/regex.txt"

  NTARGETS=$(count_lines "$TMPD/targets.txt"); require_num "$NTARGETS" "the parsed target count"
  NBRANCHES=$(count_lines "$TMPD/branches.txt"); require_num "$NBRANCHES" "the parsed branch count"
  BLOCK_LINE=$("$AWK" -F '\t' '$1 == "LINE" && $2 == "target_block" { print $3 }' "$TMPD/all.tsv")
  CTEST_LINE=$("$AWK" -F '\t' '$1 == "LINE" && $2 == "ctest" { print $3 }' "$TMPD/all.tsv")

  if [ "$NBRANCHES" -lt 1 ]; then
    die 2 "zero ctest -R alternation branches parsed from $WORKFLOW_LABEL."
  fi

  printf -- '--- parsed (the only two authoritative lists) ---\n'
  printf '  %-3s build targets   %s:%s  (cmake --build ... --target block)\n' "$NTARGETS" "$WORKFLOW_LABEL" "$BLOCK_LINE"
  printf '  %-3s ctest branches  %s:%s  (ctest -R alternation)\n\n' "$NBRANCHES" "$WORKFLOW_LABEL" "$CTEST_LINE"

  # -- 2. plausibility -----------------------------------------------------
  if [ "$NBRANCHES" -gt "$NTARGETS" ]; then
    printf 'WARN  %s branches for %s targets - more branches than targets is legal but unusual; check for a stale branch.\n' "$NBRANCHES" "$NTARGETS"
  fi
  _dupes=$("$AWK" '{ n[$0]++ } END { for (k in n) if (n[k] > 1) print k }' "$TMPD/targets.txt")
  if [ -n "$_dupes" ]; then
    printf 'WARN  duplicate build target(s): %s\n' "$(printf '%s' "$_dupes" | tr '\n' ' ')"
  fi

  # -- 3. reconcile: relation, NOT set equality ----------------------------
  # 24 != 26 legitimately: -R branches are UNANCHORED regex searches, so
  # FLASHIda_Logging also selects FLASHIda_LoggingFields_test. A parser that
  # treated branches as names would silently drop 2 of 26 tests.
  printf -- '--- reconciliation (substring relation, not set equality) ---\n'
  while IFS= read -r _b; do
    if [ -z "$_b" ]; then continue; fi
    _hits=0
    _names=
    while IFS= read -r _t; do
      case $_t in
        *"$_b"*) _hits=$((_hits + 1)); _names="$_names $_t" ;;
      esac
    done < "$TMPD/targets.txt"
    if [ "$_hits" -eq 0 ]; then
      recon_fail "dead branch      '$_b' selects NO build target. ctest would either run nothing for it or, worse, the alternation no longer describes what is built. Fix both lists in $WORKFLOW_LABEL."
    elif [ "$_hits" -gt 1 ]; then
      printf 'INFO  1:many branch    %-38s ->%s\n' "'$_b'" "$_names"
    fi
  done < "$TMPD/branches.txt"

  while IFS= read -r _t; do
    if [ -z "$_t" ]; then continue; fi
    _hits=0
    while IFS= read -r _b; do
      if [ -z "$_b" ]; then continue; fi
      case $_t in
        *"$_b"*) _hits=$((_hits + 1)) ;;
      esac
    done < "$TMPD/branches.txt"
    if [ "$_hits" -eq 0 ]; then
      recon_fail "uncovered target '$_t' is BUILT but no ctest -R branch selects it, so it compiles and never runs. Add a branch to the -R alternation at $WORKFLOW_LABEL:$CTEST_LINE."
    fi
  done < "$TMPD/targets.txt"

  while IFS= read -r _a; do
    if [ -z "$_a" ]; then continue; fi
    while IFS= read -r _b; do
      if [ -z "$_b" ]; then continue; fi
      if [ "$_a" = "$_b" ]; then continue; fi
      case $_a in
        *"$_b"*) printf 'INFO  redundant branch %-38s (branch %s already selects everything it does)\n' "'$_a'" "'$_b'" ;;
      esac
    done < "$TMPD/branches.txt"
  done < "$TMPD/branches.txt"
  printf '\n'

  # -- 4. cross-check: every target registered in executables.cmake --------
  printf -- '--- cross-check: %s ---\n' "$CMAKE_REL"
  if [ -f "$CMAKE_LIST" ]; then
    set +e
    "$AWK" -f "$AWK_PROG" -v mode=cmakenames -v src="$CMAKE_REL" "$CMAKE_LIST" > "$TMPD/cmakenames.txt"
    _rc=$?
    set -e
    if [ "$_rc" -ne 0 ]; then
      die 2 "docker/ci-lists.awk exited $_rc reading $CMAKE_REL."
    fi
    _ncmake=$(count_lines "$TMPD/cmakenames.txt")
    _names="$NL$(cat "$TMPD/cmakenames.txt")$NL"
    _missing=0
    while IFS= read -r _t; do
      if [ -z "$_t" ]; then continue; fi
      case $_names in
        *"$NL$_t$NL"*) : ;;
        *) recon_fail "target '$_t' is in the --target block but is NOT registered in $CMAKE_REL, so cmake --build cannot produce it."; _missing=$((_missing + 1)) ;;
      esac
    done < "$TMPD/targets.txt"
    printf '  %s unique registered test name(s); %s/%s parsed targets registered\n\n' \
      "$_ncmake" "$((NTARGETS - _missing))" "$NTARGETS"
  else
    # An UNPOPULATED OpenMS submodule is a legitimate parent-only checkout, so
    # that stays an advisory. A POPULATED submodule whose executables.cmake is
    # gone is a broken tree, and skipping the cross-check there would report
    # "registered" for targets nothing registers - a reassuring message over a
    # missing input. Fail closed on that, and on FLCI_REQUIRE_CMAKE=1.
    if [ "${FLCI_REQUIRE_CMAKE:-0}" = "1" ] || [ -f "$REPO_ROOT/OpenMS/CMakeLists.txt" ]; then
      die 2 "$CMAKE_REL not found, but the OpenMS submodule is populated (or FLCI_REQUIRE_CMAKE=1), so the registration cross-check cannot run and its result would be a guess. Fix: git submodule update --init OpenMS, or restore $CMAKE_REL."
    fi
    printf 'WARN  %s not found - the registration cross-check did NOT run.\n' "$CMAKE_REL"
    printf '      The OpenMS submodule is NOT checked out, so this is an advisory SKIP,\n'
    printf '      not a pass: zero targets were confirmed registered anywhere.\n'
    printf '      Fix: git submodule update --init OpenMS   (or set FLCI_REQUIRE_CMAKE=1 to make this fatal)\n\n'
  fi

  # -- 5. surface the prose copies. They are HISTORY, never authoritative --
  printf -- '--- the other places this list is written down (spec section 5: prose is NOT authoritative) ---\n'
  printf '  authoritative  %-46s %s targets\n'  "$WORKFLOW_LABEL:$BLOCK_LINE (--target block)" "$NTARGETS"
  printf '  authoritative  %-46s %s branches\n' "$WORKFLOW_LABEL:$CTEST_LINE (ctest -R)" "$NBRANCHES"
  "$AWK" -F '\t' -v wf="$WORKFLOW_LABEL" -v n="$NTARGETS" '
    $1 == "YMLCLAIM" {
      tag = ($2 + 0 == n + 0) ? "  (agrees)" : "  (DISAGREES with the parsed " n ")"
      printf "  history        %-46s %s%s\n", wf ":" $3 " (yml comment)", $2, tag
    }' "$TMPD/all.tsv"

  doc_cross_check "$REPO_ROOT/CLAUDE.md" "CLAUDE.md" "$NTARGETS" "$NBRANCHES"
  printf '  Only the --target block and the -R line are authoritative. The comments and the\n'
  printf '  CLAUDE.md copies are history; a disagreement above is a doc to fix, not a parse to fix.\n\n'

  # -- 6. toolchain pins ---------------------------------------------------
  printf -- '--- toolchain pins parsed from the yml (spec section 4: parsed, never copied) ---\n'
  "$AWK" -F '\t' '$1 == "PIN" { printf "  %-16s %s\n", $2, $3 }' "$TMPD/all.tsv"
  "$AWK" -F '\t' '$1 == "PINMISSING" { printf "  %-16s NOT IN THE YML - %s\n", $2, $3 }' "$TMPD/all.tsv"
  printf '\n'

  # -- 7. warnings and info from the parser --------------------------------
  "$AWK" -F '\t' '$1 == "WARN" { printf "WARN  %s\n", $2 }' "$TMPD/all.tsv"
  "$AWK" -F '\t' '$1 == "INFO" { printf "INFO  %s\n", $2 }' "$TMPD/all.tsv"

  # -- 8. verdict ----------------------------------------------------------
  printf '\n'
  if [ "$RECON_FAIL" -ne 0 ]; then
    printf 'FAIL: %s reconciliation failure(s) between the two lists in %s - see the FAIL lines above.\n' \
      "$RECON_FAIL" "$WORKFLOW_LABEL"
    exit 3
  fi
  printf 'PASS: %s build targets and %s ctest -R branches parsed from %s; every branch selects at least one target, every target is selected by at least one branch, and the -R string is non-empty.\n' \
    "$NTARGETS" "$NBRANCHES" "$WORKFLOW_LABEL"
}

# compare a prose file's copy of the ctest alternation against the parsed one
doc_cross_check() {
  _file=$1
  _label=$2
  _ntargets=$3
  _nbranches=$4

  if [ ! -f "$_file" ]; then
    printf '  history        %-46s NOT FOUND (advisory cross-check skipped)\n' "$_label"
    return 0
  fi

  set +e
  "$AWK" -f "$AWK_PROG" -v mode=doccheck -v src="$_label" "$_file" > "$TMPD/doc.tsv"
  _rc=$?
  set -e
  if [ "$_rc" -ne 0 ]; then
    printf '  history        %-46s unreadable (advisory cross-check skipped)\n' "$_label"
    return 0
  fi

  "$AWK" -F '\t' -v lbl="$_label" -v n="$_ntargets" '
    $1 == "DOCCLAIM" {
      tag = ($3 + 0 == n + 0) ? "  (agrees)" : "  (DISAGREES with the parsed " n ")"
      printf "  history        %-46s %s%s\n", lbl ":" $2 " (prose claim)", $3, tag
    }' "$TMPD/doc.tsv"

  _branchset="$NL$(cat "$TMPD/branches.txt")$NL"
  _tab=$(printf '\t')
  "$AWK" -F '\t' '$1 == "DOCREGEX" { print $2 "\t" $3 }' "$TMPD/doc.tsv" > "$TMPD/docregex.tsv"
  while IFS="$_tab" read -r _dline _draw; do
    if [ -z "${_draw:-}" ]; then continue; fi
    split_pipes "$_draw" > "$TMPD/docbranches.txt"
    _dn=$(count_lines "$TMPD/docbranches.txt")
    _docset="$NL$(cat "$TMPD/docbranches.txt")$NL"
    _absent=
    while IFS= read -r _db; do
      if [ -z "$_db" ]; then continue; fi
      case $_branchset in
        *"$NL$_db$NL"*) : ;;
        *) _absent="$_absent $_db" ;;
      esac
    done < "$TMPD/docbranches.txt"
    _lacks=
    while IFS= read -r _yb; do
      if [ -z "$_yb" ]; then continue; fi
      case $_docset in
        *"$NL$_yb$NL"*) : ;;
        *) _lacks="$_lacks $_yb" ;;
      esac
    done < "$TMPD/branches.txt"
    if [ "$_dn" -eq "$_nbranches" ] && [ -z "$_absent" ] && [ -z "$_lacks" ]; then
      printf '  history        %-46s %s branches  (agrees)\n' "$_label:$_dline (ctest -R)" "$_dn"
    else
      printf '  history        %-46s %s branches  (DISAGREES with the parsed %s)\n' \
        "$_label:$_dline (ctest -R)" "$_dn" "$_nbranches"
      if [ -n "$_lacks" ]; then printf '                   missing from the doc:%s\n' "$_lacks"; fi
      if [ -n "$_absent" ]; then printf '                   in the doc but not in CI:%s\n' "$_absent"; fi
    fi
  done < "$TMPD/docregex.tsv"
  return 0
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

SUBCMD=${1:-selftest}
case $SUBCMD in
  targets)                       cmd_targets ;;
  branches)                      cmd_branches ;;
  ctest-regex|regex|ctest_regex) cmd_regex ;;
  pins)                          cmd_pins ;;
  selftest|self-test|--self-test) cmd_selftest ;;
  help|-h|--help)                usage ;;
  *)
    usage >&2
    die 64 "unknown subcommand '$SUBCMD'."
    ;;
esac
