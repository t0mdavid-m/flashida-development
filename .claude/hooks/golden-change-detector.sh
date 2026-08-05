#!/usr/bin/env bash
# PostToolUse hook (Edit|Write|Bash): backstop for the golden write gate.
#
# The PreToolUse gate reasons about the tool INPUT, so a sufficiently indirect write (a script
# whose name and arguments mention nothing golden, a generated path, a build step) can slip past
# it. This hook checks REALITY instead: after any Edit/Write/Bash, it asks git whether a committed
# golden actually changed on disk, and if so forces the fact into the transcript.
#
# It cannot undo the write -- PostToolUse runs after the fact -- but it makes a SILENT golden
# change impossible, which is the actual failure mode: on 2026-08-05 goldens were rewritten and
# pushed without the diff ever being shown to the owner.
#
# Always exits 0; emits additionalContext only when a golden is genuinely dirty.

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

# The goldens live in the FlashIDA submodule, so ask git there. -uall so untracked new goldens
# (a promoted capture landing as a new file) are reported too.
changed=$(git -C FlashIDA status --porcelain -uall -- test-data/golden 2>/dev/null | head -20)

[ -z "$changed" ] && exit 0

n=$(printf '%s\n' "$changed" | grep -c .)
files=$(printf '%s\n' "$changed" | sed 's/^/    /')

cat <<EOF
{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"GOLDEN FILES ARE CURRENTLY MODIFIED ($n file(s) dirty under FlashIDA/test-data/golden):\n$(printf '%s' "$files" | sed 's/"/\\"/g; s/$/\\n/' | tr -d '\n')\nA golden is the project's behavioural reference. Before committing or pushing this, you MUST show the owner the actual before/after diff and get explicit sign-off -- a plan-level or conditional approval does not substitute for showing the concrete change. If you did not intend to modify a golden, revert it now with: git -C FlashIDA checkout -- test-data/golden"}}
EOF

exit 0
