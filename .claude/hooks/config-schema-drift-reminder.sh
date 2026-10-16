#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when a file that defines or reads the unified FLASHIda config
# schema is about to be modified, inject a reminder to keep the C# model/emitter, the C++ reader
# and the key documentation in lockstep. The single snake_case bridge schema is guarded by: the
# self-generated reference FlashIDA/test-data/config_schema_reference.json (Reference_IsNeverStale),
# the C# strict loader (rejects unknown keys), the C++ Config reader (rejects unknown keys +
# read-proof vs on-disk), and the hand-written key documentation
# FlashIDA/docs/site/method.schema.json (KeyDocumentationParityTests, ADR-0058).
# Adding/renaming/moving/removing a key on one side without the others turns CI red.
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for schema paths.

input=$(cat)

# The match keeps the closing quote, and a Windows path arrives JSON-escaped (C:\\x\\y). Normalise
# both away before matching: until 2026-10-16 the suffix patterns below never matched anything,
# because every extracted path ended in '"'.
path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 \
  | sed -e 's/^"file_path"[[:space:]]*:[[:space:]]*"//' -e 's/"$//' | tr '\\' '/' | tr -s '/')

case "$path" in
  *FLASHIda/Config.cpp|*FLASHIda/Config.h|*MethodConfig.cs|*MethodParameters.cs|*MethodConfigSerializer.cs)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda config-schema drift guard: this file defines or reads the ONE unified snake_case bridge config schema. Keys are case-sensitive; unknown keys are HARD-REJECTED on both sides. If this edit ADDS/RENAMES/MOVES/REMOVES a config key you MUST: (1) update the C# model (MethodConfig.cs) + ToCppJson emission (MethodParameters.cs) + BuildFullReferenceConfig, and add the key to the C# strict-loader allowlist path it lives in; (2) update the C++ read in Config.cpp AND its rejectUnknownKeys allowlist for that object; (3) regenerate the committed reference by running the C# suite with REGEN_CONFIG_REFERENCE=1 (Reference_IsNeverStale then re-passes; the C++ EveryKey_ParsesToOnDiskValue read-proof + both UnknownKey_Throws tests cover it); (4) document the key in FlashIDA/docs/site/method.schema.json -- type, default, enum, description (ADR-0058) -- or KeyDocumentationParityTests fails. If the edit changes what an EXISTING key does, its default, or its allowed values, step (4) still applies: update that key's description/default/enum, because no test can see stale prose. A scan-config (ms_settings) key must be a [JsonKey] on the MS1/MS2/MS3Parameters struct field. Miss one side and CI goes red."}}
EOF
    ;;
  *docs/site/method.schema.json)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda key documentation (ADR-0058): method.schema.json is HAND-WRITTEN documentation that no loader reads. Its key set must equal FlashIDA/test-data/config_schema_reference.json and every key needs a description (KeyDocumentationParityTests); every committed config must validate against it (ajv step of FlashIDA/.github/workflows/pages.yml). Prose is read from MethodConfig.cs, MethodParameters.ToCppJson, Config.cpp and the consuming engine site, never from memory. Before pushing: node --test docs/site/build.test.js; the ajv command in pages.yml; node docs/site/build.js. A push to phase-containers republishes https://t0mdavid-m.github.io/FlashIDA/."}}
EOF
    ;;
esac

exit 0
