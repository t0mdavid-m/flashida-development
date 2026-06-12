#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when a FLASHIda TOPDOWN engine file is about to be modified,
# inject a reminder to analyze whether the change alters any logged field. The four log streams
# (ida_log, scan_commands.tsv, scan_results.tsv, identification.tsv) are validated by
# FLASHIda_LoggingFields_test (C++ plausibility) and FLASHIdaLogGolden_test (C# golden); a change
# that adds/renames/reorders an emit, alters a decision value, or touches the ScanCommand ABI must
# be reflected there, keeping "value logged == value the engine actually used".
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for TOPDOWN paths.

input=$(cat)

# Pull the target path out of the tool input JSON (file_path for Edit/Write). Tolerant of the
# Windows backslash escaping in the JSON; we only need a substring match on TOPDOWN.
path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)

case "$path" in
  *TOPDOWN*)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda log-stream impact check: this TOPDOWN engine file feeds the four logged streams (ida_log, scan_commands.tsv, scan_results.tsv, identification.tsv). Before finalizing, analyze whether this edit alters any logged field, even as a side effect — a new/renamed/reordered column emit, a changed decision value, or a ScanCommand ABI/struct change. If it does: keep the value logged equal to the value the engine actually used for that scan; update FLASHIda_LoggingFields_test.cpp (C++ plausibility ranges) and FLASHIdaLogGolden_test.cs (C# golden — recapture with LOG_GOLDEN_CAPTURE=1); and re-check the pinned N/A defaults. If the column count changed, update the schema_column_counts asserts and the ScanCommandLayout tests."}}
EOF
    ;;
esac

exit 0
