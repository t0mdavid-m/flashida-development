#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when a file that defines or reads the unified FLASHIda config
# schema is about to be modified, inject a reminder to keep the C# model/emitter and the C++ reader
# in lockstep. The single snake_case bridge schema is guarded by: the self-generated reference
# FlashIDA/test-data/config_schema_reference.json (Reference_IsNeverStale), the C# strict loader
# (rejects unknown keys), and the C++ Config reader (rejects unknown keys + read-proof vs on-disk).
# Adding/renaming/moving/removing a key on one side without the other turns CI red.
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for schema paths.

input=$(cat)

path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)

case "$path" in
  *FLASHIda/Config.cpp|*FLASHIda/Config.h|*MethodConfig.cs|*MethodParameters.cs|*MethodConfigSerializer.cs)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda config-schema drift guard: this file defines or reads the ONE unified snake_case bridge config schema. Keys are case-sensitive; unknown keys are HARD-REJECTED on both sides. If this edit ADDS/RENAMES/MOVES/REMOVES a config key you MUST: (1) update the C# model (MethodConfig.cs) + ToCppJson emission (MethodParameters.cs) + BuildFullReferenceConfig, and add the key to the C# strict-loader allowlist path it lives in; (2) update the C++ read in Config.cpp AND its rejectUnknownKeys allowlist for that object; (3) regenerate the committed reference by running the C# suite with REGEN_CONFIG_REFERENCE=1 (Reference_IsNeverStale then re-passes; the C++ EveryKey_ParsesToOnDiskValue read-proof + both UnknownKey_Throws tests cover it). A scan-config (ms_settings) key must be a [JsonKey] on the MS1/MS2/MS3Parameters struct field. Miss one side and CI goes red."}}
EOF
    ;;
esac

exit 0
