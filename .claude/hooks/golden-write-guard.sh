#!/usr/bin/env bash
# PreToolUse hook (Edit|Write|Bash): HARD GATE on writes to committed golden files.
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
# It matches Bash as well as Edit|Write on purpose: the incident used `cp` via Bash, which an
# Edit/Write-only hook would not have seen. Covers cp/mv/redirects, python/uv scripts, tee,
# rsync, install -- anything whose command text mentions a golden path.
#
# Deliberately NOT dependent on jq (not installed on this machine); matches the raw stdin JSON.

input=$(cat)

# Match the golden directory across every path spelling that reaches the JSON:
#   test-data/golden      posix / forward-slash
#   test-data\golden      windows, single backslash
#   test-data\\golden     windows, JSON-escaped backslash
# Restricted to the golden tree so ordinary test-data edits (configs, spectra) stay unblocked.
hit=0
printf '%s' "$input" | grep -Eq 'test-data[/\\]+golden' && hit=1

# A script can write goldens without naming the directory on its command line -- the 2026-08-05
# patch ran as `uv run python patch_goldens.py`, whose text contains no golden path at all. So a
# Bash command that merely MENTIONS "golden" and could execute code is gated too.
if [ "$hit" = "0" ]; then
  c=$(printf '%s' "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
  case "$c" in
    *[Gg]olden*)
      case "$c" in
        *python*|*uv\ run*|*bash\ *|*sh\ *|*pwsh*|*powershell*|*node\ *|*./*) hit=1 ;;
      esac
      ;;
  esac
fi

if [ "$hit" = "1" ]; then
  # Distinguish a read from a write where we cheaply can: a Bash command that only inspects a
  # golden (git diff, cat, head, grep, awk, python semdiff) should not prompt. Any command that
  # could write gets the gate. When in doubt, gate.
  cmd=$(printf '%s' "$input" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)
  if [ -n "$cmd" ]; then
    case "$cmd" in
      # Writing verbs, a shell redirect into the tree, or an in-place edit -> gate.
      *cp\ *|*mv\ *|*tee\ *|*rsync\ *|*install\ *|*\>*|*sed\ -i*|*python*|*uv\ run*|*checkout*|*restore*) ;;
      # Everything else touching a golden path is a read (git diff/status, cat, grep, wc, ls) -> allow.
      *) exit 0 ;;
    esac
  fi

  cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"GOLDEN WRITE GATE — this touches a committed golden file under test-data/golden.\n\nA golden may only be recaptured after the owner has seen the ACTUAL DIFF and signed off. An approval given earlier for a plan, or a conditional 'then recapture', is NOT sufficient on its own — show the concrete before/after first.\n\nBefore approving, confirm:\n  1. The diff has been shown to the owner in this conversation.\n  2. The change is understood and intended, not merely 'makes the build green'.\n  3. Scope is minimal: patch only the cells that genuinely moved. Do NOT promote a whole capture artifact unless a full-file replacement is the reviewed intent — promotion also rewrites column order and bakes in that run's float jitter.\n  4. An independent diff review has run where the change is non-trivial."}}
EOF
fi

exit 0
