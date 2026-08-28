#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|Bash|PowerShell): HARD GATE on writes to committed golden files.
#
# Unlike the other hooks in this directory, this one is NOT advisory. Golden files are the
# project's behavioural reference; overwriting one silently redefines "correct" for every future
# run. The working agreement is that a golden is recaptured only after the owner has reviewed the
# actual diff and signed off -- and an advisory reminder demonstrably does not enforce that: on
# 2026-08-05 a full-file recapture was written and pushed after a promise to bring the diff for
# review first, on the reasoning that an earlier conditional approval already covered it.
#
# This hook returns permissionDecision "ask", so the write cannot proceed without an explicit
# human click. That approval cannot be self-granted.
#
# It matches Bash and PowerShell as well as Edit|Write on purpose: the incident used `cp` via
# Bash, which an Edit/Write-only hook would not have seen. Covers cp/mv/redirects, python/uv
# scripts, tee, rsync, install, the PowerShell copy and content cmdlets, container invocations,
# the build/test drivers that can rewrite a golden, and the deletion/truncation verbs -- anything
# whose command text names a golden path or a capture switch.
#
# --------------------------------------------------------------------------------------------
# 2026-08-27 -- three PROVEN holes closed (dockerized-local-ci design sec. 7, owner decision D3).
# Each was reproduced against a real hook payload before the fix and re-run after it:
#
#   1. The PowerShell tool matched NO PreToolUse matcher at all. settings.json said
#      "Edit|Write|Bash"; the shell tool on this host is named `PowerShell`. Every
#      `Copy-Item ... test-data\golden\...` was NOT EVALUATED. Fixed in settings.json, and the
#      verb list below had no PowerShell cmdlet either, so it was two independent holes stacked.
#
#   2. The command extractor `"[^"]*"` stopped dead at the first \" escape. For
#      `bash -c "cp a.tsv .../golden/x.golden.tsv"` it handed the read/write classifier the
#      fragment `"command":"bash -c \"` -- which contains no write verb -- so a quoted command
#      fell through to allow. The extractor now reads the whole JSON string, escapes included.
#
#   3. The write-verb list knew nothing about containers, PowerShell or the build drivers, so
#      `docker run -v <repo>/FlashIDA/test-data/golden:/g img capture` was ALLOWED even though
#      it names the golden directory outright.
#
# SCOPE -- stated here so it is not rediscovered the hard way. A PreToolUse hook only ever sees
# THIS AGENT's tool calls. It cannot see the owner's own terminal, and it cannot see a write made
# by a process INSIDE a container through a bind mount. Those two paths are covered by the
# runner's own unconditional `git -C FlashIDA status --porcelain -uall -- test-data` assertion,
# never by this hook. Do not treat a green hook as proof the golden tree was untouched.
#
# FAIL-CLOSED. Every branch that cannot establish "this is a read" gates instead: an empty
# payload, an unparseable command, an unrecognised tool. A false prompt costs one click; a false
# allow costs a silently redefined reference.
#
# Deliberately NOT dependent on jq (not installed on this machine); matches the raw stdin JSON.
# Bash, LF line endings, nothing beyond grep/sed/tr.
# --------------------------------------------------------------------------------------------

input=$(cat)
tool=unknown

# ---------------------------------------------------------------------------------------------
# gate: emit the "ask" decision and stop. $1 is a one-clause reason, and must contain no double
# quote and no backslash -- every caller passes a fixed literal, and $tool is sanitised below.
# ---------------------------------------------------------------------------------------------
gate() {
  _msg="GOLDEN WRITE GATE — $1\n\nTool: ${tool}.\n\nA golden may only be recaptured after the owner has seen the ACTUAL DIFF and signed off. An approval given earlier for a plan, or a conditional 'then recapture', is NOT sufficient on its own — show the concrete before/after first.\n\nBefore approving, confirm:\n  1. The diff has been shown to the owner in this conversation.\n  2. The change is understood and intended, not merely 'makes the build green'.\n  3. Scope is minimal: patch only the cells that genuinely moved. Do NOT promote a whole capture artifact unless a full-file replacement is the reviewed intent — promotion also rewrites column order and bakes in that run's float jitter.\n  4. An independent diff review has run where the change is non-trivial.\n\nNote this hook sees only this agent's tool calls: a capture run from your own terminal, or a container writing through a bind mount, never reaches it — the runner's git-status assertion is what covers those."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"%s"}}\n' "$_msg"
  exit 0
}

# A missing input is an error, not a skip. If this ever fires on every tool call, the hook's
# stdin contract has broken -- that is worth one noisy prompt rather than a silent open door.
if [ -z "$input" ]; then
  gate "the hook received an EMPTY payload and cannot tell what this call does. Fail-closed. If every tool call now prompts, the hook stdin contract has broken -- check .claude/settings.json."
fi

# FAST PATH. This hook runs on EVERY Edit/Write/Bash/PowerShell call, and on Windows each helper
# process costs ~40 ms, so the common case must be one spawn and out. Sound because every trigger
# below needs one of these three tokens somewhere in the payload: both spellings of the golden
# tree contain "golden", so does the log-golden filename pattern, and stage 1(b) greps for
# exactly this alternation. If none is present, nothing downstream can fire.
printf '%s' "$input" | grep -Eqi 'golden|capturemode|regen_config_reference' || exit 0

# ---------------------------------------------------------------------------------------------
# Extractors. Both are tolerant by design: whatever cannot be parsed makes the guard MORE
# conservative, never less.
# ---------------------------------------------------------------------------------------------

# Tool name, sanitised to a safe token because it is echoed back inside the JSON reason.
t=$(printf '%s' "$input" \
      | grep -oE '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | head -1 | sed -e 's/.*:[[:space:]]*"//' -e 's/"$//' | tr -cd 'A-Za-z0-9_.-')
[ -n "$t" ] && tool="$t"

# Is this a tool that RUNS a command string, or one that writes a file directly?
# An allowlist, so an unknown tool is treated as a direct write and gated rather than classified
# by whatever `"command"` key happens to appear inside the bytes it is writing.
case "$(printf '%s' "$tool" | tr '[:upper:]' '[:lower:]')" in
  bash|powershell|pwsh|shell|sh|zsh|cmd) is_cmd_tool=1 ;;
  *)                                     is_cmd_tool=0 ;;
esac

# The command string of a Bash / PowerShell call, INCLUDING any \" escapes.
# `"([^"\\]|\\.)*"` is the JSON string grammar. The old `"[^"]*"` truncated at the first \" and
# handed the classifier a fragment -- hole 2 above.
cmd=$(printf '%s' "$input" | grep -oE '"command"[[:space:]]*:[[:space:]]*"([^"\\]|\\.)*"' | head -1)
lc=$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')

# ---------------------------------------------------------------------------------------------
# is_write: does this command text carry something that can MODIFY a file?
# Matching is done on the lower-cased command, so `Copy-Item`, `copy-item` and `COPY-ITEM` are
# one pattern. Patterns are substring matches on purpose -- over-matching costs a prompt.
# ---------------------------------------------------------------------------------------------
is_write() {
  case "$1" in
    # POSIX write verbs, a shell redirect into the tree, an in-place edit (the original set).
    *cp\ *|*mv\ *|*tee\ *|*rsync\ *|*install\ *|*\>*|*sed\ -i*|*python*|*uv\ run*|*checkout*|*restore*) return 0 ;;
    # Windows / PowerShell copy and content cmdlets plus their aliases.
    # *copy* covers copy / Copy-Item / copy-item / robocopy / xcopy;
    # *move* covers move / Move-Item / Remove-Item.
    *copy*|*move*|*set-content*|*add-content*|*out-file*|*new-item*|*set-item*) return 0 ;;
    # Containers: a write through a bind mount lands in the real tree and is invisible to every
    # other layer of this design. `docker exec`, `docker run -v`, `docker compose run`, podman.
    *docker*|*podman*|*nerdctl*) return 0 ;;
    # Interpreters. The 2026-08-05 incident was `uv run python patch_goldens.py`; a script named
    # for goldens launched by any other interpreter is the same shape.
    *bash\ *|*sh\ *|*pwsh*|*powershell*|*node\ *|*perl\ *|*ruby\ *) return 0 ;;
    # Build and test drivers that can (re)write a golden or the config schema reference.
    *msbuild*|*nunit3-console*|*ctest*|*regression-runner*|*compare_golden*|*dotnet\ *) return 0 ;;
    # Deletion and truncation. A golden that is REMOVED or emptied is redefined just as surely
    # as one that is overwritten, and NONE of the verbs above matches a bare `rm` -- so
    # `rm FlashIDA/test-data/golden/phase4_x.tsv` reached `*) return 1` and was ALLOWED, which
    # contradicts the FAIL-CLOSED contract stated at the top of this file. Covers rm / rmdir /
    # unlink / shred / truncate, cmd's del and erase, PowerShell's Clear-Content, and the
    # [IO.File]:: writers that no cmdlet pattern above reaches.
    *rm\ *|*rmdir*|*unlink\ *|*shred\ *|*truncate\ *|*del\ *|*erase\ *) return 0 ;;
    *clear-content*|*writealltext*|*writealllines*|*writeallbytes*|*appendalltext*|*streamwriter*) return 0 ;;
    # Explicit capture switches, whatever launches them.
    *capturemode*|*log_golden_capture*|*regen_config_reference*) return 0 ;;
  esac
  return 1
}

# can_execute: is_write plus a bare `./script` launch. Used only to decide whether a command that
# MENTIONS a golden is worth looking at; `./` is deliberately NOT in is_write, because a read of
# `../FlashIDA/test-data/golden/x.tsv` contains "./" and must stay allowed.
can_execute() {
  is_write "$1" && return 0
  case "$1" in *./*) return 0 ;; esac
  return 1
}

# ---------------------------------------------------------------------------------------------
# Stage 1 -- does this call reach a golden at all?
# ---------------------------------------------------------------------------------------------
trigger=""

# (a) The golden tree, in every path spelling that reaches the JSON:
#       test-data/golden        posix / forward slash
#       test-data\golden        windows, single backslash
#       test-data\\golden       windows, JSON-escaped backslash (or any deeper nesting)
#     plus any file NAMED like a log golden wherever it sits, which is what a promotion out of
#     bin/log-golden-output/ writes. Case-insensitive: a Windows path may arrive upper-cased.
#     Restricted to the golden tree so ordinary test-data edits (configs, spectra) stay unblocked.
if printf '%s' "$input" | grep -Eqi 'test-data[/\\]+golden|\.golden\.(tsv|json)'; then
  trigger="this touches a committed golden file under test-data/golden."

# (b) A script can write goldens without naming the directory on its command line -- the
#     2026-08-05 patch ran as `uv run python patch_goldens.py`, whose text contains no golden
#     path at all. So a command that merely MENTIONS a golden, or sets a capture switch, and
#     could execute code is examined too. LOG_GOLDEN_CAPTURE matches on "golden"; -captureMode
#     and REGEN_CONFIG_REFERENCE do not, so they are named.
elif [ -n "$cmd" ] \
     && printf '%s' "$lc" | grep -Eq 'golden|capturemode|regen_config_reference' \
     && can_execute "$lc"; then
  trigger="this command names a golden file or a golden-capture switch."
fi

[ -n "$trigger" ] || exit 0

# ---------------------------------------------------------------------------------------------
# Stage 2 -- read or write? Distinguish only where we cheaply can. A command that merely INSPECTS
# a golden (git diff, cat, head, grep, wc, ls) should not prompt. Anything that could write does.
# When in doubt, gate.
# ---------------------------------------------------------------------------------------------
if [ "$is_cmd_tool" = "1" ]; then
  if [ -z "$cmd" ]; then
    gate "this call reaches a golden but the guard could not parse its command, so it cannot tell a read from a write. Fail-closed."
  fi
  is_write "$lc" || exit 0
fi

# Edit / Write / any unrecognised tool: there is no command to classify, so the call IS the write.
gate "$trigger"
