#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when a file that defines or reads the unified FLASHIda config
# schema is about to be modified, inject a reminder to keep the C# emitter, the C++ reader, and
# the shared drift-guard reference fixture in lockstep. The single bridge schema is guarded by
# ConfigSchemaParityTests (C#: ToCppJson key-set == reference fixture) and ConfigSchemaParity_test
# (C++: every owned field == its sentinel). Adding/renaming/moving/removing a key on one side
# without the others turns CI red.
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for schema paths.

input=$(cat)

path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)

case "$path" in
  *FLASHIda/Config.cpp|*FLASHIda/Config.h|*MethodConfig.cs|*MethodParameters.cs|*MethodConfigSerializer.cs)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda config-schema drift guard: this file defines or reads the ONE unified bridge config schema. If this edit ADDS, RENAMES, MOVES, or REMOVES a config key you MUST keep three things in lockstep: (1) the shared reference fixture FlashIDA/test-data/config_schema_reference.json — give any new key a UNIQUE sentinel value; (2) the C++ per-field assertion in ConfigSchemaParity_test.cpp (TEST_EQUAL the owned field against its sentinel); (3) ToCppJson emission in MethodParameters.cs (the C# ConfigSchemaParityTests emit-equality auto-fails if C# stops emitting a reference key). C# reads bridge keys, C++ reads bridge keys, one schema. If the key is intentionally C#-only (e.g. global.*), add it to the C# global allowlist, not the C++ side. Move all three or CI goes red."}}
EOF
    ;;
esac

exit 0
