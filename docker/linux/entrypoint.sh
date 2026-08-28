#!/usr/bin/env bash
# ===========================================================================
# FLASHIda local CI -- Linux lane entrypoint.
#
#   configure | build | test | shell | all | help
#
# Runs INSIDE the container built from docker/linux/Dockerfile. It never
# creates its own mounts; it asserts the mount contract and fails closed with
# the exact fix when the contract is not met.
#
# ---------------------------------------------------------------------------
# THE VERDICT CONTRACT (design doc section 6)
#
# The LAST line of every run is exactly one of:
#     PASS:    <what was verified>                        exit 0
#     FAIL:    <first failing gate>                       exit non-zero
#     PARTIAL: <what did not run> -- NOT CI-EQUIVALENT    exit non-zero
# A human who reads only the last line is never misled. There is no `|| true`
# on a gate anywhere in this script; a missing input, an empty parse or an
# absent file is an error, never a silent skip.
#
# ---------------------------------------------------------------------------
# THE MOUNT CONTRACT (design doc sections 3 and 6)
#
#   -v <repo>:/work:ro                                    source, read-only
#   -v <vol>:/work/OpenMS/cmake-build-linux-release       build tree
#   -v <vol>:/ccache                                      compiler cache
#   -e CCACHE_DIR=/ccache -e CCACHE_BASEDIR=/work -e CCACHE_MAXSIZE=30G
#   -e OPENMS_DATA_PATH=/work/OpenMS/share/OpenMS
#   --network none                                        required by configure
#
# The build directory MUST sit at /work/OpenMS/cmake-build-linux-<type>:
# ctest runs every class test with its CWD set to the build dir
# (add_test ... WORKING_DIRECTORY ${CMAKE_BINARY_DIR}), and the class tests
# hard-code "../../FlashIDA/test-data/...". Two levels up from the build dir
# has to be the repo root. `OpenMS/build` is deliberately REFUSED: that name
# is reserved for a CI-shaped tree and reusing it lets a container build
# masquerade as a CI one.
#
# The repo bind being read-only is safe: every fixture literal is an input,
# and every test write is relative to the CWD, i.e. into the build volume.
#
# ---------------------------------------------------------------------------
# THE ci-lists.sh CONTRACT -- consumed, not duplicated (design doc section 5)
#
# The build target list and the ctest -R string are NEVER hard-coded here.
# They are read from docker/ci-lists.sh, which parses
# .github/workflows/flashida-ci.yml. If that script is missing, unreadable,
# fails, or returns something that does not validate, this entrypoint FAILS.
# There is no default list to fall back to -- a fallback is precisely how you
# get "build nothing, then ctest an empty build dir, then report green".
#
# Interface, as implemented by docker/ci-lists.sh (verified against it):
#     ci-lists.sh targets      -> one CMake/CTest target name per line, exit 0
#     ci-lists.sh ctest-regex  -> the RAW ctest -R string, one line, exit 0
#     ci-lists.sh --self-test  -> exit 0 when the parser self-check passes
# Diagnostics go to stderr; stdout carries only the answer.
#
# A few alternative spellings are probed after the primary one, so that a
# rename over there becomes a slower probe rather than a silent wrong list.
# Whatever spelling answers, the ANSWER is validated (target names must look
# like target names; the -R string must be one non-empty line that is not just
# delimiters) -- an unrecognised flag that prints a human report and still
# exits 0 can therefore never be mistaken for a list.
# Override the path with FLCI_LISTS_SH.
# ===========================================================================

set -euo pipefail

# --------------------------------------------------------------------------
# Verdict machinery. Registered before anything else can fail.
# --------------------------------------------------------------------------
FINAL_VERDICT=""
FINAL_RC=1
SUBCOMMAND="(none)"
DEGRADED=""

on_exit() {
  local rc=$?
  if [ -z "$FINAL_VERDICT" ]; then
    # Something aborted before a verdict was set (set -e, a trap, a signal).
    # Never let that look like success.
    printf 'FAIL: %s aborted without reaching a verdict (exit %d) -- see the log above\n' \
      "$SUBCOMMAND" "$rc"
    if [ "$rc" -eq 0 ]; then exit 1; fi
    exit "$rc"
  fi
  printf '%s\n' "$FINAL_VERDICT"
  exit "$FINAL_RC"
}
trap on_exit EXIT

pass()    { FINAL_VERDICT="PASS: $*";    FINAL_RC=0; exit 0; }
fail()    { FINAL_VERDICT="FAIL: $*";    FINAL_RC=1; exit 1; }
partial() { FINAL_VERDICT="PARTIAL: $* -- NOT CI-EQUIVALENT"; FINAL_RC=2; exit 2; }

# Accumulates rather than overwrites: two degraded gates must not mask each
# other, and the verdict has to name every gate that did not run.
degrade() {
  if [ -n "$DEGRADED" ]; then DEGRADED="$DEGRADED; $*"; else DEGRADED="$*"; fi
}

log()  { printf '[flci] %s\n' "$*"; }
warn() { printf '[flci] WARN: %s\n' "$*" >&2; }
info() { printf '[flci] INFO: %s\n' "$*"; }
rule() { printf '[flci] ---------------------------------------------------------------\n'; }

# --------------------------------------------------------------------------
# Defaults. Everything is overridable; nothing is a host-specific path.
# --------------------------------------------------------------------------
WORKSPACE="${FLCI_WORKSPACE:-/work}"
BUILD_TYPE="Release"
TIER=""
SLOW_THRESHOLD="${FLCI_SLOW_THRESHOLD:-2}"
CTEST_JOBS="${FLCI_CTEST_JOBS:-6}"
BUILD_DIR=""
MIN_TARGETS="${FLCI_MIN_TARGETS:-20}"
LISTS_SH="${FLCI_LISTS_SH:-}"
SELF_TEST="${FLCI_SELF_TEST:-1}"
ALLOW_NETWORK="${FLCI_ALLOW_NETWORK:-0}"
NAMED_TARGETS=()

# mawk is what the ci-lists parser has to survive, and it is the awk that
# ships in the ubuntu base. Prefer it explicitly: installing gawk takes over
# the /usr/bin/awk alternative and would hide a mawk-only break (mawk has no
# gensub() and no length(array)).
AWK="awk"
if command -v mawk >/dev/null 2>&1; then AWK="mawk"; fi

# ci-lists.sh defaults to `${FLCI_AWK:-awk}`, and this lane is where the design
# doc says the workflow parser gets proven mawk-clean. Hand it the same awk this
# script picked, so the self-test cannot quietly run under gawk -- the one
# implementation that strips CR and therefore cannot see the CRLF-parse bug.
# A caller who set FLCI_AWK deliberately keeps their choice.
export FLCI_AWK="${FLCI_AWK:-$AWK}"

usage() {
  cat <<'USAGE'
Usage: entrypoint.sh <subcommand> [options] [target ...]

Subcommands
  configure   CMake configure into the build directory. Requires --network none.
  build       cmake --build: the OpenMS library, then the CI target list
              (or only the named targets, when target names are given).
  test        ctest. FAST TIER BY DEFAULT -- see --tier.
  all         configure, then build, then test.
  shell       interactive bash with the lane's environment already set.
  help        this text.

Options
  --release              build type Release (default)
  --debug                build type Debug -- a SEPARATE build directory and a
                         separate ccache namespace, so the two configurations
                         never share a configure or a cache state
  --tier fast|full       ctest tier. Default: fast.
                           fast = the CI test set MINUS every test whose last
                                  observed runtime exceeded --slow-threshold.
                                  With no timing data yet it FALLS BACK TO FULL
                                  and says so.
                           full = the whole CI test set.
  --full                 alias for --tier full
  --slow-threshold SEC   fast-tier cutoff in seconds (default 2)
  --jobs N               ctest -j (default 6)
  --build-dir PATH       override the build directory
  --workspace PATH       override the workspace root (default /work)
  -h, --help             this text

Environment
  FLCI_LISTS_SH        path to ci-lists.sh (default <workspace>/docker/ci-lists.sh)
  FLCI_SELF_TEST=0     skip ci-lists.sh --self-test. The parse itself is still
                       validated and still fail-closed, but the run then ends
                       PARTIAL: a skipped gate is never a PASS.
  FLCI_ALLOW_NETWORK=1 configure without --network none. The run then ends
                       PARTIAL, because a vendored yaml-cpp can no longer be
                       ruled out.
  FLCI_MIN_TARGETS     floor on the parsed target count (default 20)
  FLCI_BUILD_JOBS      cmake --build -j
  CCACHE_DIR CCACHE_BASEDIR CCACHE_MAXSIZE OPENMS_DATA_PATH

This lane is authoritative for "does it compile under gcc" and for nothing
else. It can never judge a float value and can never capture or promote a
golden.
USAGE
}

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------
if [ "$#" -eq 0 ]; then
  usage
  fail "no subcommand given -- try 'configure', 'build', 'test', 'all', 'shell' or 'help'"
fi

SUBCOMMAND="$1"; shift
case "$SUBCOMMAND" in
  configure|build|test|all|shell) ;;
  help|-h|--help) usage; FINAL_VERDICT="PASS: printed usage"; FINAL_RC=0; exit 0 ;;
  *) usage; fail "unknown subcommand '$SUBCOMMAND' -- expected configure|build|test|all|shell|help" ;;
esac

while [ "$#" -gt 0 ]; do
  case "$1" in
    --release)          BUILD_TYPE="Release"; shift ;;
    --debug)            BUILD_TYPE="Debug";   shift ;;
    --full)             TIER="full";          shift ;;
    --tier)             [ "$#" -ge 2 ] || fail "--tier needs a value (fast|full)"
                        TIER="$2"; shift 2 ;;
    --tier=*)           TIER="${1#--tier=}";  shift ;;
    --slow-threshold)   [ "$#" -ge 2 ] || fail "--slow-threshold needs a value in seconds"
                        SLOW_THRESHOLD="$2"; shift 2 ;;
    --slow-threshold=*) SLOW_THRESHOLD="${1#--slow-threshold=}"; shift ;;
    --jobs|-j)          [ "$#" -ge 2 ] || fail "--jobs needs a value"
                        CTEST_JOBS="$2"; shift 2 ;;
    --jobs=*)           CTEST_JOBS="${1#--jobs=}"; shift ;;
    --build-dir)        [ "$#" -ge 2 ] || fail "--build-dir needs a path"
                        BUILD_DIR="$2"; shift 2 ;;
    --build-dir=*)      BUILD_DIR="${1#--build-dir=}"; shift ;;
    --workspace)        [ "$#" -ge 2 ] || fail "--workspace needs a path"
                        WORKSPACE="$2"; shift 2 ;;
    --workspace=*)      WORKSPACE="${1#--workspace=}"; shift ;;
    -h|--help)          usage; FINAL_VERDICT="PASS: printed usage"; FINAL_RC=0; exit 0 ;;
    --)                 shift; while [ "$#" -gt 0 ]; do NAMED_TARGETS+=("$1"); shift; done ;;
    -*)                 fail "unknown option '$1' -- run 'help' for the option list" ;;
    *)                  NAMED_TARGETS+=("$1"); shift ;;
  esac
done

case "$TIER" in
  ""|fast) TIER="fast" ;;
  full)    ;;
  *)       fail "unknown --tier '$TIER' -- expected 'fast' or 'full'" ;;
esac

case "$SLOW_THRESHOLD" in
  ''|*[!0-9.]*) fail "--slow-threshold must be a number of seconds, got '$SLOW_THRESHOLD'" ;;
esac
case "$CTEST_JOBS" in
  ''|*[!0-9]*) fail "--jobs must be a positive integer, got '$CTEST_JOBS'" ;;
esac
[ "$CTEST_JOBS" -ge 1 ] || fail "--jobs must be >= 1, got '$CTEST_JOBS'"

if [ "${#NAMED_TARGETS[@]}" -gt 0 ]; then
  case "$SUBCOMMAND" in
    build|test|all) ;;
    *) fail "'$SUBCOMMAND' takes no target names (got '${NAMED_TARGETS[0]}')" ;;
  esac
fi

# --------------------------------------------------------------------------
# Paths derived from the build type. The two build types NEVER share a build
# directory (so never a configure or a CMakeCache), and never share a ccache
# namespace either -- one configuration's budget cannot evict the other's.
# --------------------------------------------------------------------------
case "$BUILD_TYPE" in
  Release) BUILD_SLUG="release" ;;
  Debug)   BUILD_SLUG="debug" ;;
  *)       fail "internal: unexpected build type '$BUILD_TYPE'" ;;
esac

# Strip a trailing slash (but never turn "/" into ""). A --workspace or
# --build-dir given with one made the lexical two-levels-below check compare
# "/work/" against "/work", so an ABSENT build volume was reported as a layout
# error instead of reaching its own "mkdir on the host, then mount" message.
strip_slash() { case "$1" in /) printf '/' ;; */) printf '%s' "${1%/}" ;; *) printf '%s' "$1" ;; esac; }
WORKSPACE="$(strip_slash "$WORKSPACE")"
[ -z "$BUILD_DIR" ] || BUILD_DIR="$(strip_slash "$BUILD_DIR")"

SOURCE_DIR="$WORKSPACE/OpenMS"
[ -n "$BUILD_DIR" ] || BUILD_DIR="$SOURCE_DIR/cmake-build-linux-$BUILD_SLUG"

CCACHE_ROOT="${CCACHE_DIR:-/ccache}"
export CCACHE_DIR="$CCACHE_ROOT/linux-$BUILD_SLUG"
export CCACHE_BASEDIR="${CCACHE_BASEDIR:-$WORKSPACE}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-30G}"
export OPENMS_DATA_PATH="${OPENMS_DATA_PATH:-$SOURCE_DIR/share/OpenMS}"
# 16 `#pragma omp` sites live under TOPDOWN, so ctest -j oversubscribes badly.
# (FLASHIda.cpp calls omp_set_num_threads(4) unconditionally at construction,
# so this only governs tests that never build a FLASHIda -- pin it anyway.)
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-1}"
export HOME="${HOME:-/tmp}"

JUNIT_XML="$BUILD_DIR/flci-ctest.xml"
TIMING_LEDGER="$BUILD_DIR/flci-timings.tsv"
TEST_BIN_DIR="$BUILD_DIR/src/tests/class_tests/bin"

# --------------------------------------------------------------------------
# Preflight: the mount contract, asserted, with the fix named on every failure.
# --------------------------------------------------------------------------
preflight_workspace() {
  [ -d "$WORKSPACE" ] || fail "workspace '$WORKSPACE' is not a directory -- mount the repo with: -v <repo>:$WORKSPACE:ro"
  [ -f "$SOURCE_DIR/CMakeLists.txt" ] || fail "'$SOURCE_DIR/CMakeLists.txt' is missing -- the OpenMS submodule is not checked out, or the repo was mounted at the wrong path (expected -v <repo>:$WORKSPACE:ro)"
  [ -d "$WORKSPACE/FlashIDA/test-data" ] || fail "'$WORKSPACE/FlashIDA/test-data' is missing -- the FlashIDA submodule must be checked out; the C++ class tests read fixtures from it by relative path"
  [ -d "$OPENMS_DATA_PATH" ] || fail "OPENMS_DATA_PATH '$OPENMS_DATA_PATH' is not a directory -- pass -e OPENMS_DATA_PATH=$SOURCE_DIR/share/OpenMS"

  case "$BUILD_DIR" in
    */build|*/build/) fail "refusing build directory '$BUILD_DIR': the name 'build' is reserved for a CI-shaped tree, and reusing it lets a container build masquerade as a CI one. Use cmake-build-linux-$BUILD_SLUG." ;;
  esac

  # The fixture literals resolve as <build>/../../FlashIDA/test-data, so the
  # build directory has to be exactly two levels below the repo root. Resolve
  # lexically when the directory does not exist yet, so that the *absent build
  # volume* case reaches its own message ("mkdir on the host, then mount")
  # instead of being reported as a layout error.
  local two_up ws_real
  if [ -d "$BUILD_DIR" ]; then
    two_up="$(cd "$BUILD_DIR/../.." 2>/dev/null && pwd -P || true)"
  else
    two_up="${BUILD_DIR%/}"; two_up="${two_up%/*}"; two_up="${two_up%/*}"
  fi
  ws_real="$(cd "$WORKSPACE" && pwd -P)"
  if [ "$two_up" != "$ws_real" ]; then
    fail "build directory '$BUILD_DIR' is not two levels below the workspace ('$two_up' != '$ws_real'). The class tests hard-code ../../FlashIDA/test-data and ctest runs them with CWD = the build dir, so the fixtures would not resolve. Mount the build volume at $SOURCE_DIR/cmake-build-linux-$BUILD_SLUG."
  fi
}

preflight_build_dir_writable() {
  [ -d "$BUILD_DIR" ] || fail "build directory '$BUILD_DIR' does not exist. Docker cannot create a mount point inside a read-only bind, so the CALLER must 'mkdir -p <repo>/OpenMS/cmake-build-linux-$BUILD_SLUG' on the host and mount a named volume over it."
  local probe="$BUILD_DIR/.flci-write-probe.$$"
  if ! ( : > "$probe" ) 2>/dev/null; then
    fail "build directory '$BUILD_DIR' is not writable. It must be a named volume mounted OVER the read-only repo bind: -v <vol>:$BUILD_DIR"
  fi
  rm -f "$probe"
  mkdir -p "$CCACHE_DIR" 2>/dev/null || fail "ccache directory '$CCACHE_DIR' is not writable -- mount it with: -v <vol>:$CCACHE_ROOT -e CCACHE_DIR=$CCACHE_ROOT"
}

assert_network_none() {
  local n=0 i
  for i in /sys/class/net/*; do
    [ -e "$i" ] || continue
    case "${i##*/}" in lo) ;; *) n=$((n + 1)) ;; esac
  done
  if [ "$n" -eq 0 ]; then
    log "network: isolated (loopback only) -- yaml-cpp cannot be silently vendored"
    return 0
  fi
  if [ "$ALLOW_NETWORK" = "1" ]; then
    warn "$n non-loopback interface(s) present and FLCI_ALLOW_NETWORK=1: configure may silently FetchContent yaml-cpp from github.com instead of using the apt 0.8.0. This run is degraded."
    degrade "configure ran WITHOUT --network none, so a vendored yaml-cpp cannot be ruled out"
    return 0
  fi
  fail "configure requires network isolation: $n non-loopback interface(s) are present. ENABLE_TDL defaults ON and tdl-config.cmake falls back to a configure-time FetchContent clone of github.com/jbeder/yaml-cpp when it cannot find yaml-cpp >= 0.8.0, which would silently replace the apt package this image is built around. Add '--network none' to docker run (or set FLCI_ALLOW_NETWORK=1 to accept a PARTIAL verdict)."
}

# --------------------------------------------------------------------------
# ci-lists.sh: the ONLY source of the target list and the ctest -R string.
# --------------------------------------------------------------------------
TARGETS=()
CTEST_REGEX=""

lists_exec() {
  if [ -x "$LISTS_SH" ]; then
    "$LISTS_SH" "$@"
  else
    # A bind mount can lose the exec bit; honour the shebang anyway.
    local shebang
    shebang="$(head -n 1 "$LISTS_SH" 2>/dev/null || true)"
    case "$shebang" in
      '#!'*bash*) bash "$LISTS_SH" "$@" ;;
      *)          sh   "$LISTS_SH" "$@" ;;
    esac
  fi
}

# Every line must look like a CMake target name. This is what stops an
# unrecognised flag -- which might make ci-lists.sh print a human report and
# still exit 0 -- from being mistaken for a target list.
validate_target_lines() {
  local text="$1" n total
  n="$(printf '%s\n' "$text" | grep -c '^[A-Za-z][A-Za-z0-9_]*$' || true)"
  total="$(printf '%s\n' "$text" | grep -c '[^[:space:]]' || true)"
  [ "$n" -ge "$MIN_TARGETS" ] || return 1
  [ "$n" -eq "$total" ] || return 1
  return 0
}

validate_regex_line() {
  local text="$1"
  [ -n "$text" ] || return 1
  [ "$(printf '%s\n' "$text" | grep -c '' || true)" -eq 1 ] || return 1
  # Not just delimiters and whitespace: an empty -R selects EVERY test on some
  # ctest versions and none-with-exit-0 on others. Both are silent.
  printf '%s' "$text" | tr -d '|[:space:]' | grep -q '[A-Za-z0-9_]' || return 1
  return 0
}

load_lists() {
  [ -n "$LISTS_SH" ] || LISTS_SH="$WORKSPACE/docker/ci-lists.sh"
  [ -f "$LISTS_SH" ] || fail "ci-lists.sh not found at '$LISTS_SH'. The build target list and the ctest -R string are parsed out of .github/workflows/flashida-ci.yml by that script and are never hard-coded here. Mount the repo at $WORKSPACE, or set FLCI_LISTS_SH."
  if LC_ALL=C grep -q "$(printf '\r')" "$LISTS_SH"; then
    fail "'$LISTS_SH' contains CR characters. It was checked out with CRLF (core.autocrlf=true) and will not run under /bin/sh. Fix: add 'docker/** text eol=lf' to the root .gitattributes and re-checkout that file."
  fi

  if [ "$SELF_TEST" = "1" ]; then
    local st_ok=0 flag st_out
    for flag in --self-test selftest self-test; do
      if st_out="$(lists_exec "$flag" 2>&1)"; then
        st_ok=1
        printf '%s\n' "$st_out" | sed 's/^/[flci] ci-lists| /'
        log "ci-lists.sh $flag: PASS"
        break
      fi
    done
    if [ "$st_ok" -ne 1 ]; then
      # Deliberately fatal. The self-test is what re-validates the parser after
      # a workflow edit, and the parser's own worst failure is a silent
      # zero-target parse. Downgrading a failure here to a warning would
      # reintroduce exactly that.
      lists_exec --self-test || true
      fail "'$LISTS_SH --self-test' did not succeed (nor did 'selftest' or 'self-test'). Either the parser self-check is failing -- fix it before anything reads the lists -- or ci-lists.sh does not implement it, in which case teach it '--self-test' or re-run with FLCI_SELF_TEST=0."
    fi
  else
    # A skipped gate is a PARTIAL, never a PASS (design doc section 6:
    # "PARTIAL ... is used by ... any run that skipped a gate"). Without this
    # a single env var buys a green verdict with the parser self-check off.
    warn "FLCI_SELF_TEST=0: the ci-lists.sh parser self-check was skipped. The parsed lists are still validated below."
    degrade "the ci-lists.sh parser self-check was SKIPPED (FLCI_SELF_TEST=0), so the workflow parse was not re-validated"
  fi

  local out used flag line
  used=""
  for flag in targets --targets --print-targets --list-targets; do
    if out="$(lists_exec "$flag" 2>/dev/null)" && validate_target_lines "$out"; then
      used="$flag"; break
    fi
  done
  [ -n "$used" ] || fail "could not obtain a build target list from '$LISTS_SH'. Expected: '$LISTS_SH targets' prints one CMake target name per line (at least $MIN_TARGETS of them) on stdout and exits 0. There is no built-in fallback list on purpose: an empty or wrong parse must stop the run, not build nothing and then report green."
  log "targets from '$LISTS_SH $used'"
  while IFS= read -r line; do
    [ -n "$line" ] && TARGETS+=("$line")
  done <<< "$(printf '%s\n' "$out" | sed 's/\r$//' | grep '^[A-Za-z][A-Za-z0-9_]*$')"

  used=""
  # Deliberately NOT probed: any spelling of "branches". A branch LIST is not
  # the raw -R string, and running the wrong one would silently change what
  # ctest selects.
  for flag in ctest-regex regex ctest_regex --regex --ctest-regex --raw-regex --print-regex; do
    if out="$(lists_exec "$flag" 2>/dev/null)" && validate_regex_line "$out"; then
      used="$flag"; break
    fi
  done
  [ -n "$used" ] || fail "could not obtain the ctest -R string from '$LISTS_SH'. Expected: '$LISTS_SH ctest-regex' prints the RAW -R alternation from the workflow on one stdout line and exits 0. An empty -R is not usable: on some ctest versions it selects every test, on others it selects none and still exits 0."
  CTEST_REGEX="$(printf '%s' "$out" | sed 's/\r$//')"
  log "ctest -R from '$LISTS_SH $used'"

  [ "${#TARGETS[@]}" -ge "$MIN_TARGETS" ] || fail "parsed only ${#TARGETS[@]} build targets, below the floor of $MIN_TARGETS"
  log "parsed ${#TARGETS[@]} build targets and a $(printf '%s' "$CTEST_REGEX" | tr '|' '\n' | grep -c '')-branch ctest -R string"

  reconcile_lists
}

# Design doc section 5, rule 3: reconcile by matching RELATION, not set
# equality -- a -R branch is an unanchored search, so one branch legitimately
# covers several targets. Reported, not fatal: the hard gate is the JUnit
# count check after the run, which turns both an uncovered target and an
# over-broad branch into a failure.
reconcile_lists() {
  local uncovered dead
  uncovered="$(printf '%s\n' "${TARGETS[@]}" | $AWK -v re="$CTEST_REGEX" '
    BEGIN { nb = split(re, b, "|") }
    { covered = 0
      for (i = 1; i <= nb; i++) if (b[i] != "" && index($0, b[i]) > 0) covered = 1
      if (!covered) print $0 }')"
  dead="$(printf '%s\n' "$CTEST_REGEX" | tr '|' '\n' | $AWK -v tl="$(printf '%s;' "${TARGETS[@]}")" '
    BEGIN { nt = split(tl, t, ";") }
    $0 != "" {
      hit = 0
      for (i = 1; i <= nt; i++) if (t[i] != "" && index(t[i], $0) > 0) hit = 1
      if (!hit) print $0 }')"
  if [ -n "$uncovered" ]; then
    warn "build targets NOT covered by any ctest -R branch (they would be built and never run):"
    printf '%s\n' "$uncovered" | sed 's/^/[flci]        /' >&2
  fi
  if [ -n "$dead" ]; then
    warn "ctest -R branches matching no build target (dead branches):"
    printf '%s\n' "$dead" | sed 's/^/[flci]        /' >&2
  fi
  if [ -z "$uncovered" ] && [ -z "$dead" ]; then
    log "reconciliation: every target is covered by a branch, every branch matches a target"
  fi
  return 0
}

resolve_named_targets() {
  [ "${#NAMED_TARGETS[@]}" -gt 0 ] || return 0
  local n t found
  for n in "${NAMED_TARGETS[@]}"; do
    found=0
    for t in "${TARGETS[@]}"; do
      if [ "$n" = "$t" ]; then found=1; break; fi
    done
    if [ "$found" -ne 1 ]; then
      fail "'$n' is not one of the ${#TARGETS[@]} targets parsed out of the workflow. Valid names: $(printf '%s ' "${TARGETS[@]}")"
    fi
  done
}

# --------------------------------------------------------------------------
# configure
# --------------------------------------------------------------------------
do_configure() {
  preflight_workspace
  preflight_build_dir_writable
  assert_network_none

  rule
  log "configure: $BUILD_TYPE  ->  $BUILD_DIR"
  log "ccache:    $CCACHE_DIR (basedir $CCACHE_BASEDIR, max $CCACHE_MAXSIZE)"
  rule

  # Deliberately NOT passed, each for a reason:
  #   OPENMS_CONTRIB_LIBS  -- the tarball is contrib_build-Windows.tar.gz
  #   CMAKE_PREFIX_PATH / Eigen3_DIR -- chocolatey/aqt specific; on Linux apt
  #                           puts the config files where CMake already looks
  #   WITH_GUI=ON          -- CI needs it only to ship FLASHDeconvWizard.exe
  #   ENABLE_STYLE_TESTING -- NEVER set it: src/tests/CMakeLists.txt makes it
  #                           either/or, so ON would silently drop class_tests
  #                           and with it every FLASH test
  #   ENABLE_CLASS_TESTING -- defaults ON; passing OFF would drop them too
  cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" -G Ninja \
    -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
    -DWITH_GUI=OFF \
    -DPYOPENMS=OFF \
    -DENABLE_DOCS=OFF \
    -DBOOST_USE_STATIC=ON \
    -DGIT_TRACKING=OFF \
    -DCMAKE_CXX_COMPILER_LAUNCHER=ccache \
    || fail "cmake configure failed for $BUILD_TYPE in $BUILD_DIR"

  [ -f "$BUILD_DIR/CMakeCache.txt" ] || fail "configure reported success but $BUILD_DIR/CMakeCache.txt is missing"
  log "configure OK: $BUILD_DIR/CMakeCache.txt written"
}

# --------------------------------------------------------------------------
# build
# --------------------------------------------------------------------------
do_build() {
  preflight_workspace
  preflight_build_dir_writable
  [ -f "$BUILD_DIR/CMakeCache.txt" ] || fail "'$BUILD_DIR' has not been configured (no CMakeCache.txt). Run the 'configure' subcommand first, with --network none."

  local jobs_args=()
  if [ -n "${FLCI_BUILD_JOBS:-}" ]; then jobs_args=(-j "$FLCI_BUILD_JOBS"); fi

  local to_build=()
  if [ "${#NAMED_TARGETS[@]}" -gt 0 ]; then
    to_build=("${NAMED_TARGETS[@]}")
    log "build: $BUILD_TYPE, ${#to_build[@]} named target(s) only"
  else
    to_build=("${TARGETS[@]}")
    log "build: $BUILD_TYPE, the OpenMS library then all ${#to_build[@]} workflow targets"
    # The library first, exactly as the workflow does.
    cmake --build "$BUILD_DIR" ${jobs_args[@]+"${jobs_args[@]}"} --target OpenMS \
      || fail "cmake --build --target OpenMS failed ($BUILD_TYPE)"
  fi

  # No keep-going flag anywhere: a partial build followed by ctest is the
  # silent-green shape this lane exists to avoid.
  cmake --build "$BUILD_DIR" ${jobs_args[@]+"${jobs_args[@]}"} --target "${to_build[@]}" \
    || fail "cmake --build failed for: ${to_build[*]}"

  assert_binaries "${to_build[@]}"
  log "build OK: ${#to_build[@]} target binaries present in $TEST_BIN_DIR"
}

# Existence, never mtime: ccache and ninja legitimately skip a relink.
assert_binaries() {
  local missing=() t
  [ -d "$TEST_BIN_DIR" ] || fail "test binary directory '$TEST_BIN_DIR' does not exist after a successful build -- the class-test RUNTIME_OUTPUT_DIRECTORY override moved, or class_tests was not configured"
  for t in "$@"; do
    if [ ! -f "$TEST_BIN_DIR/$t" ] && [ ! -f "$TEST_BIN_DIR/$t.exe" ]; then
      missing+=("$t")
    fi
  done
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "cmake reported success but these target binaries are absent from $TEST_BIN_DIR: ${missing[*]}"
  fi
}

# --------------------------------------------------------------------------
# Fixture inventory. Derived from the test sources, never a committed list.
# --------------------------------------------------------------------------
assert_fixture_inventory() {
  local srcdir="$SOURCE_DIR/src/tests/class_tests/openms"
  [ -d "$srcdir" ] || fail "class test sources not found at '$srcdir'"
  local literals
  literals="$(grep -rho '\.\./\.\./FlashIDA/test-data/[A-Za-z0-9_./-]*' "$srcdir" 2>/dev/null | sed 's#/*$##' | LC_ALL=C sort -u || true)"
  if [ -z "$literals" ]; then
    fail "found zero '../../FlashIDA/test-data/...' literals under $srcdir. Either the fixture convention changed or this grep is broken -- do not run the suite until that is understood."
  fi
  local count=0 crlf=0 crlf_example="" missing=() lit
  while IFS= read -r lit; do
    [ -n "$lit" ] || continue
    count=$((count + 1))
    # Resolved exactly the way the tests resolve them: relative to the build dir.
    if [ ! -e "$BUILD_DIR/$lit" ]; then
      missing+=("$lit")
    elif [ -f "$BUILD_DIR/$lit" ] && LC_ALL=C grep -q "$(printf '\r')" "$BUILD_DIR/$lit"; then
      crlf=$((crlf + 1))
      [ -n "$crlf_example" ] || crlf_example="$lit"
    fi
  done <<< "$literals"
  if [ "${#missing[@]}" -gt 0 ]; then
    fail "${#missing[@]} of $count fixture paths referenced by the class tests do not resolve from the build directory: ${missing[*]}. The build dir must sit at <repo>/OpenMS/cmake-build-linux-$BUILD_SLUG with <repo>/FlashIDA/ beside it."
  fi
  log "fixtures: all $count '../../FlashIDA/test-data/...' literals resolve from $BUILD_DIR"

  # Informational only, and measured rather than assumed: FlashIDA/.gitattributes
  # says `* text eol=crlf`, so fixtures arrive CRLF in the working tree. A
  # Windows text-mode ifstream strips CR and a Linux one does not, which is a
  # known Linux-only failure mode for the tests that slurp these files whole.
  # NEVER "fix" it by normalising the fixtures -- that would change what CI and
  # the Windows lane see.
  if [ "$crlf" -gt 0 ]; then
    info "$crlf of $count fixture files contain CR (e.g. $crlf_example). On Linux, ifstream does NOT strip CR. If ConfigSchemaParity_test, FLASHIda_ChargeModes_test or FLASHIda_LoggingFields_test fail on a string compare, check that first: it is a Linux-lane artefact, not a regression, and the fixtures must NOT be normalised (FlashIDA/.gitattributes pins them to CRLF for CI and the Windows lane)."
  fi
}

# --------------------------------------------------------------------------
# JUnit parsing (mawk-safe: no gensub, no length(array), no asort)
# --------------------------------------------------------------------------
junit_records() {   # $1 = xml path; prints "SUITE<TAB>N" and "CASE<TAB>name<TAB>status<TAB>time"
  $AWK '
    function attrval(s, k,   pat, p, rest, q) {
      pat = " " k "=\""
      p = index(s, pat)
      if (p == 0) return ""
      rest = substr(s, p + length(pat))
      q = index(rest, "\"")
      if (q == 0) return ""
      return substr(rest, 1, q - 1)
    }
    { sub(/\r$/, ""); buf = buf $0 " " }
    END {
      p = index(buf, "<testsuite")
      if (p > 0) {
        s = substr(buf, p)
        e = index(s, ">")
        if (e > 0) s = substr(s, 1, e - 1)
        printf "SUITE\t%s\n", attrval(s, "tests")
      }
      n = split(buf, parts, "<testcase")
      for (i = 2; i <= n; i++) {
        s = parts[i]
        e = index(s, ">")
        if (e > 0) s = substr(s, 1, e - 1)
        printf "CASE\t%s\t%s\t%s\n", attrval(s, "name"), attrval(s, "status"), attrval(s, "time")
      }
    }
  ' "$1"
}

# The timing ledger is DERIVED state inside the build volume and is never
# committed: a hand-maintained slow-test list is exactly the duplication that
# ci-lists.sh exists to prevent. It is cumulative rather than last-run-only,
# because a fast run's JUnit contains no slow tests at all -- reading only the
# previous run would make the fast tier forget what is slow after one use.
merge_timing_ledger() {
  [ -f "$JUNIT_XML" ] || return 0
  local fresh tmp
  fresh="$(junit_records "$JUNIT_XML" | $AWK -F'\t' '$1 == "CASE" && $2 != "" && $4 != "" { print $2 "\t" $4 }')"
  [ -n "$fresh" ] || return 0
  tmp="$TIMING_LEDGER.$$"
  { if [ -f "$TIMING_LEDGER" ]; then cat "$TIMING_LEDGER"; fi; printf '%s\n' "$fresh"; } \
    | $AWK -F'\t' 'NF == 2 && $1 != "" { t[$1] = $2 } END { for (k in t) printf "%s\t%s\n", k, t[k] }' \
    | LC_ALL=C sort > "$tmp"
  mv "$tmp" "$TIMING_LEDGER"
}

# --------------------------------------------------------------------------
# test
# --------------------------------------------------------------------------
do_test() {
  preflight_workspace
  preflight_build_dir_writable
  [ -f "$BUILD_DIR/CMakeCache.txt" ] || fail "'$BUILD_DIR' has not been configured. Run 'configure' then 'build' first."
  assert_fixture_inventory

  local selected=() excluded=() known_names slow_all
  local mode="suite"
  local effective_tier="$TIER"

  # Fold the previous run's report into the ledger before it is overwritten.
  merge_timing_ledger

  if [ "${#NAMED_TARGETS[@]}" -gt 0 ]; then
    mode="named"
    selected=("${NAMED_TARGETS[@]}")
  else
    if [ "$effective_tier" = "fast" ]; then
      if [ ! -s "$TIMING_LEDGER" ]; then
        effective_tier="full"
        log "TIER: no timing data in $TIMING_LEDGER yet, so the fast tier has nothing to exclude -- FALLING BACK TO --tier full. The next run will have timings."
      fi
    fi
    if [ "$effective_tier" = "fast" ]; then
      slow_all="$($AWK -F'\t' -v thr="$SLOW_THRESHOLD" 'NF == 2 && ($2 + 0) > (thr + 0) { print $1 }' "$TIMING_LEDGER" | LC_ALL=C sort)"
      known_names="$($AWK -F'\t' 'NF == 2 { print $1 }' "$TIMING_LEDGER")"
      local t known=0 unknown=0 is_slow
      for t in "${TARGETS[@]}"; do
        is_slow=0
        if [ -n "$slow_all" ] && printf '%s\n' "$slow_all" | grep -qx -- "$t"; then is_slow=1; fi
        if printf '%s\n' "$known_names" | grep -qx -- "$t"; then
          known=$((known + 1))
        else
          unknown=$((unknown + 1))
        fi
        if [ "$is_slow" -eq 1 ]; then excluded+=("$t"); else selected+=("$t"); fi
      done
      log "TIER: fast (threshold ${SLOW_THRESHOLD}s) -- $known of ${#TARGETS[@]} targets have a recorded runtime; $unknown do not and are INCLUDED"
    else
      selected=("${TARGETS[@]}")
    fi
  fi

  if [ "${#selected[@]}" -eq 0 ]; then
    fail "the $effective_tier tier selected zero tests -- refusing to run. Raise --slow-threshold, or use --tier full."
  fi

  # -R is the RAW workflow string for a suite run, so a future over-broad
  # branch stays visible (the count gate below turns it into a failure). For a
  # named run it is an anchored alternation of exactly the requested names.
  local ctest_args=(--test-dir "$BUILD_DIR" --output-on-failure --no-tests=error
                    --output-junit "$JUNIT_XML" -j "$CTEST_JOBS")
  if [ "$mode" = "named" ]; then
    ctest_args+=(-R "^($(printf '%s|' "${selected[@]}" | sed 's/|$//'))$")
  else
    ctest_args+=(-R "$CTEST_REGEX")
    if [ "${#excluded[@]}" -gt 0 ]; then
      ctest_args+=(-E "^($(printf '%s|' "${excluded[@]}" | sed 's/|$//'))$")
    fi
  fi

  rule
  if [ "$mode" = "named" ]; then
    log "RUNNING: ${#selected[@]} NAMED target(s) -- a SUBSET, not the suite"
  else
    log "RUNNING TIER: $effective_tier -- ${#selected[@]} of ${#TARGETS[@]} workflow tests"
  fi
  if [ "${#excluded[@]}" -gt 0 ]; then
    log "EXCLUDED by the fast tier (${#excluded[@]}), each over ${SLOW_THRESHOLD}s in the recorded timings:"
    printf '[flci]        %s\n' "${excluded[@]}"
  elif [ "$mode" != "named" ] && [ "$effective_tier" = "fast" ]; then
    log "EXCLUDED: none -- no recorded runtime exceeded ${SLOW_THRESHOLD}s, so this fast run is content-identical to --tier full"
  fi
  log "OMP_NUM_THREADS=$OMP_NUM_THREADS   ctest -j $CTEST_JOBS"
  { printf '[flci] $ ctest'; printf ' %q' "${ctest_args[@]}"; printf '\n'; }
  rule

  rm -f "$JUNIT_XML"
  local ctest_rc=0
  ctest "${ctest_args[@]}" || ctest_rc=$?

  # Timings are worth keeping even when the run failed.
  merge_timing_ledger

  if [ "$ctest_rc" -ne 0 ]; then
    gate_junit_report "${selected[@]}" || true
    if [ "$mode" = "named" ]; then
      fail "ctest exited $ctest_rc (${#selected[@]} named target(s): ${selected[*]})"
    fi
    fail "ctest exited $ctest_rc ($effective_tier tier, ${#selected[@]} of ${#TARGETS[@]} tests selected)"
  fi

  gate_junit "${selected[@]}"

  local extra
  if [ "$mode" = "named" ]; then
    # DEGRADED is checked FIRST here, exactly as in the two tier branches
    # below: a named run reached through `all` can carry a degraded configure,
    # and emitting PASS ahead of this check exited 0 on a run that was not
    # CI-equivalent.
    if [ -n "$DEGRADED" ]; then
      partial "$DEGRADED; ctest ${#selected[@]}/${#selected[@]} NAMED targets green -- SUBSET ONLY, not the ${#TARGETS[@]}-test workflow set"
    fi
    pass "ctest ${#selected[@]}/${#selected[@]} NAMED targets green -- SUBSET ONLY, not the ${#TARGETS[@]}-test workflow set (run 'test --tier full' for that)"
  fi
  if [ "$effective_tier" = "fast" ]; then
    extra="FAST TIER, ${#excluded[@]} slow test(s) EXCLUDED"
    if [ "${#excluded[@]}" -gt 0 ]; then
      extra="$extra ($(printf '%s ' "${excluded[@]}" | sed 's/ $//'))"
    fi
    if [ -n "$DEGRADED" ]; then
      partial "$DEGRADED; ctest ${#selected[@]}/${#TARGETS[@]} green, $extra"
    fi
    pass "ctest ${#selected[@]}/${#TARGETS[@]} green on gcc -- $extra, so this is NOT the full suite; run 'test --tier full' or GitHub CI before trusting it"
  fi
  if [ -n "$DEGRADED" ]; then
    partial "$DEGRADED; ctest FULL tier ${#selected[@]}/${#TARGETS[@]} green"
  fi
  pass "ctest FULL tier ${#selected[@]}/${#TARGETS[@]} green on gcc (compilation and logic only -- never float values, never goldens)"
}

# Never gate on the JUnit `failures` attribute: a missing test binary yields
# ctest exit 8 with failures="0" and status="notrun".
gate_junit_report() {
  local expected=("$@")
  if [ ! -s "$JUNIT_XML" ]; then
    warn "no JUnit report at $JUNIT_XML"
    return 1
  fi

  local recs suite_n names ncases bad_status rc=0 e seen
  recs="$(junit_records "$JUNIT_XML")"
  suite_n="$(printf '%s\n' "$recs" | $AWK -F'\t' '$1 == "SUITE" { print $2; exit }')"
  names="$(printf '%s\n' "$recs" | $AWK -F'\t' '$1 == "CASE" { print $2 }')"
  ncases="$(printf '%s\n' "$names" | grep -c '[^[:space:]]' || true)"
  bad_status="$(printf '%s\n' "$recs" | $AWK -F'\t' '$1 == "CASE" && $3 != "run" { printf "%s(status=%s) ", $2, $3 }')"

  if [ "$ncases" -ne "${#expected[@]}" ]; then
    warn "JUnit reports $ncases testcases but ${#expected[@]} were selected -- an uncovered target, an over-broad -R branch, or a test that never registered"
    rc=1
  fi
  if [ -n "$suite_n" ] && [ "$suite_n" != "$ncases" ]; then
    warn "JUnit <testsuite tests=\"$suite_n\"> disagrees with $ncases <testcase> elements"
    rc=1
  fi
  for e in "${expected[@]}"; do
    seen="$(printf '%s\n' "$names" | grep -cx -- "$e" || true)"
    if [ "$seen" -ne 1 ]; then
      warn "expected exactly one JUnit testcase named '$e', found $seen"
      rc=1
    fi
  done
  if [ -n "$bad_status" ]; then
    warn "testcases not marked status=\"run\": $bad_status"
    rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    log "JUnit gate OK: $ncases testcases, all status=run, every expected name present exactly once"
  fi
  return "$rc"
}

gate_junit() {
  if ! gate_junit_report "$@"; then
    fail "the JUnit result gate rejected $JUNIT_XML (see the WARNs above). ctest's own exit code is not sufficient: a missing binary gives exit 8 with failures=\"0\" and status=\"notrun\"."
  fi
}

# --------------------------------------------------------------------------
# shell
# --------------------------------------------------------------------------
do_shell() {
  preflight_workspace
  rule
  log "workspace   $WORKSPACE (read-only bind)"
  log "source      $SOURCE_DIR"
  log "build dir   $BUILD_DIR ($BUILD_TYPE)"
  log "ccache      $CCACHE_DIR"
  log "data path   $OPENMS_DATA_PATH"
  log "awk         $AWK"
  log "this lane is authoritative for gcc compilation and NOTHING else"
  rule
  local rc=0
  cd "$BUILD_DIR" 2>/dev/null || cd "$WORKSPACE"
  bash || rc=$?
  [ "$rc" -eq 0 ] || fail "interactive shell exited $rc"
  pass "interactive shell exited 0 (nothing was verified)"
}

# --------------------------------------------------------------------------
# Dispatch
# --------------------------------------------------------------------------
case "$SUBCOMMAND" in
  shell)
    do_shell
    ;;
  configure)
    do_configure
    if [ -n "$DEGRADED" ]; then partial "$DEGRADED; configure otherwise succeeded"; fi
    pass "cmake configure ($BUILD_TYPE) succeeded in $BUILD_DIR"
    ;;
  build)
    load_lists
    resolve_named_targets
    do_build
    if [ -n "$DEGRADED" ]; then partial "$DEGRADED; build otherwise succeeded"; fi
    if [ "${#NAMED_TARGETS[@]}" -gt 0 ]; then
      pass "built ${#NAMED_TARGETS[@]} named target(s) ($BUILD_TYPE) -- SUBSET ONLY, not the ${#TARGETS[@]}-target workflow set"
    fi
    pass "built libOpenMS and all ${#TARGETS[@]} workflow test targets ($BUILD_TYPE) under gcc"
    ;;
  test)
    load_lists
    resolve_named_targets
    do_test
    ;;
  all)
    load_lists
    resolve_named_targets
    do_configure
    do_build
    do_test
    ;;
esac

fail "internal: subcommand '$SUBCOMMAND' fell through without a verdict"
