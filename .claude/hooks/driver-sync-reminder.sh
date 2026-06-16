#!/usr/bin/env bash
# PreToolUse hook (Edit|Write): when one half of the ground-truth test-acquisition harness is about to be
# modified, remind the editor to keep the C++/C# mirrors in sync. There is ONE interleaved engine-id-echo drive
# contract (docs/kb/test-harness/README.md), implemented twice:
#   C#  : ContinuityTestHarness.PushScanAndDrainFull        C++ : FLASHIda_TestHelpers.h  runInterleaved
#   C#  : DecodeIonFromScanDescription (FLASHIdaLogGolden)  C++ : decodeTrailingIonKey (FLASHIda_TestHelpers.h)
# Editing one without the other silently breaks parent/child lineage and the cross-language ion-decode parity.
#
# Non-blocking: always exits 0; emits hookSpecificOutput.additionalContext only for the paired driver/decoder files.

input=$(cat)

# Pull the target path out of the tool input JSON (file_path for Edit/Write). Tolerant of Windows backslash
# escaping; we only need a substring match on the harness/decoder file names.
path=$(printf '%s' "$input" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1)

case "$path" in
  *ContinuityTestHarness*|*FLASHIda_TestHelpers*|*FLASHIdaLogGolden_test*)
    cat <<'EOF'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"FLASHIda test-harness sync check: this file is one half of the single ground-truth interleaved engine-id-echo drive contract (docs/kb/test-harness/README.md). Keep the two implementations in lockstep: C# ContinuityTestHarness.PushScanAndDrainFull <-> C++ FLASHIda_TestHelpers.h runInterleaved (idle predicate is_agc||empty-desc||(msn_level<=1 && ms1_fed>=nMs1); terminate idle>=3; feed ONE response per requested command, MS1 by index / MS2 singleton / MS3 manifest-or-skip; echo cmd.scan_description verbatim; never fabricate). If you touch the trailing-ion decoder, change BOTH DecodeIonFromScanDescription (C#) and decodeTrailingIonKey (C++) byte-for-byte and re-run the ion-decode parity test (C++ ctest + C# [Test]). Update docs/kb/test-harness/README.md last_verified and confirm its code_anchors still resolve."}}
EOF
    ;;
esac

exit 0
