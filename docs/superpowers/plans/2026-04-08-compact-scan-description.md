# Compact Scan Description Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current 20-32 char scan descriptions with a compact 15-char format (16 bytes with null) that fits the Thermo instrument API hard limit.

**Architecture:** Replace base-36 4-char tracking IDs with base-94 3-char IDs using a configurable alphabet. Remove the `|` delimiter — tracking ID is always chars 0-2 (fixed position). Char 3 is a type code (A/S/R/F/C/E). Chars 4-15 carry mass-in-kDa and optional ion annotation. All changes are in `FLASHIda.cpp/.h` and their tests; the bridge API, ScanCommand struct, and C# P/Invoke are unchanged.

**Tech Stack:** C++20 (OpenMS), C# .NET 4.8 (FlashIDA), NUnit

**Spec:** `docs/superpowers/specs/2026-04-08-compact-scan-description-design.md`

---

## File Map

| File | Responsibility | Tasks |
|------|---------------|-------|
| `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h` | Declarations: encode/decode, alphabet, ForTest helpers | 1 |
| `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` | Implementations: encode/decode, all 13 scan_description writes, parsing | 1, 2, 3 |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp` | Encode/decode roundtrip assertions | 4 |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp` | Scan description format assertions | 4 |
| `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp` | Exploration format assertions | 4 |
| `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs` | C# format assertion for scan descriptions | 5 |
| `FlashIDA/test-data/golden/*.json` | 17 golden files with ScanDescription fields | 6 |

---

### Task 1: Replace encode/decode functions and tracking alphabet (C++)

**Files:**
- Modify: `OpenMS/src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h:498,515,807,810,875`
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:3106-3125,3358-3370`

This task replaces the base-36 4-char encoding with base-94 3-char encoding and updates the ID counter wrapping.

- [ ] **Step 1: Update FLASHIda.h — replace declarations and add alphabet**

In `FLASHIda.h`, make these changes:

**a)** Replace the `encodeBase36_` declaration (line 807) and `decodeBase36_` declaration (line 810):

```cpp
// Replace:
static std::string encodeBase36_(int value);
// ...
int decodeBase36_(const std::string& s) const;

// With:
static std::string encodeTracking_(int value);
// ...
int decodeTracking_(const std::string& s) const;
```

**b)** Add the tracking alphabet as a static member near `tracking_id_counter_` (line 875):

```cpp
static const std::string tracking_alphabet_;
int tracking_id_counter_ = 0;
```

**c)** Rename the ForTest helpers (lines 497-518):

```cpp
// Replace:
/// Test-only accessor for encodeBase36_ (static, no state dependency)
static std::string encodeBase36ForTest(int v) { return encodeBase36_(v); }
// ...
/// Test-only accessor: decode base-36 string to int
int decodeBase36ForTest(const std::string& s) const
{
  return decodeBase36_(s);
}

// With:
/// Test-only accessor for encodeTracking_ (static, no state dependency)
static std::string encodeTrackingForTest(int v) { return encodeTracking_(v); }
// ...
/// Test-only accessor: decode tracking string to int
int decodeTrackingForTest(const std::string& s) const
{
  return decodeTracking_(s);
}
```

- [ ] **Step 2: Update FLASHIda.cpp — replace implementations**

**a)** Add the static member definition near the top of the file (after includes, before any function):

```cpp
const std::string FLASHIda::tracking_alphabet_ = "!\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
```

**b)** Replace `encodeBase36_` (lines 3106-3116) with:

```cpp
std::string FLASHIda::encodeTracking_(int value)
{
  const int base = static_cast<int>(tracking_alphabet_.size());
  char buf[4] = {tracking_alphabet_[0], tracking_alphabet_[0], tracking_alphabet_[0], '\0'};
  for (int i = 2; i >= 0; --i)
  {
    buf[i] = tracking_alphabet_[value % base];
    value /= base;
  }
  return std::string(buf);
}
```

**c)** Replace `nextTrackingIdInt_` (lines 3118-3125) with:

```cpp
int FLASHIda::nextTrackingIdInt_()
{
  const int base = static_cast<int>(tracking_alphabet_.size());
  const int max_id = base * base * base - 1;
  int id = tracking_id_counter_++;
  if (tracking_id_counter_ > max_id)
    tracking_id_counter_ = 0;
  return id;
}
```

**d)** Replace `decodeBase36_` (lines 3358-3370) with:

```cpp
int FLASHIda::decodeTracking_(const std::string& s) const
{
  const int base = static_cast<int>(tracking_alphabet_.size());
  int value = 0;
  for (char c : s)
  {
    Size pos = tracking_alphabet_.find(c);
    if (pos == std::string::npos) return -1;
    value = value * base + static_cast<int>(pos);
  }
  return value;
}
```

- [ ] **Step 3: Rename all call sites of encodeBase36_ and decodeBase36_ in FLASHIda.cpp**

Use find-and-replace across the file:
- `encodeBase36_` → `encodeTracking_` (approximately 14 call sites: lines 3199, 3337, 3430, 3500, 3594, 3630, 3742, 3876, 3924, 4063, 4084, 4119, 4134)
- `decodeBase36_` → `decodeTracking_` (approximately 2 call sites: lines 3888, 3947)

- [ ] **Step 4: Build C++ to verify compilation**

```bash
cd OpenMS/build && cmake --build . --target FLASHIdaQueueTracking_test FLASHIda_ProcessScan_test -- -j$(nproc)
```

Expected: Compiles without errors. Tests will FAIL (assertions expect old format) — that's expected and fixed in Task 4.

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/openms/include/OpenMS/ANALYSIS/TOPDOWN/FLASHIda.h \
        src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Replace base-36 encoding with base-94 tracking alphabet (3-char IDs)"
```

---

### Task 2: Update all scan_description format strings (C++)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp` (13 locations)

This task rewrites all scan_description formatting to the compact format: `{3-char ID}{type code}{payload}`, max 15 visible chars.

Type codes: `A` = AGC, `S` = survey MS1, `R` = recording, `F` = followup, `C` = conditional, `E` = exploration.

- [ ] **Step 1: Update `makeMS1Command_` and `makeAGCCommand_` defaults (lines 3158, 3178)**

These are always overwritten by callers, but update for consistency:

```cpp
// Line 3158 (makeMS1Command_):
// Replace:
std::strncpy(cmd.scan_description, "MS1 survey scan", sizeof(cmd.scan_description) - 1);
// With:
std::strncpy(cmd.scan_description, "S", sizeof(cmd.scan_description) - 1);

// Line 3178 (makeAGCCommand_):
// Replace:
std::strncpy(cmd.scan_description, "AGC calibration", sizeof(cmd.scan_description) - 1);
// With:
std::strncpy(cmd.scan_description, "A", sizeof(cmd.scan_description) - 1);
```

- [ ] **Step 2: Update CV transition MS1 (line 3338)**

```cpp
// Replace:
std::snprintf(ms1.scan_description, sizeof(ms1.scan_description),
              "%s|CV transition MS1 CV=%.1f", id_str.c_str(), next_cv);

// With:
std::snprintf(ms1.scan_description, 16, "%sS", id_str.c_str());
```

- [ ] **Step 3: Update `buildMS2Command_` (lines 3430-3434)**

The PeakGroup overload builds standard DDA MS2 commands. Uses `pg.getMonoMass()` and `charge` parameter.

```cpp
// Replace:
std::string id_str = encodeTracking_(id);
char desc_buf[256];
std::snprintf(desc_buf, sizeof(desc_buf), "%s|%.2f@%d", id_str.c_str(), pg.getMonoMass(), charge);
std::strncpy(cmd.scan_description, desc_buf, sizeof(cmd.scan_description) - 1);
cmd.scan_description[sizeof(cmd.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(id);
std::snprintf(cmd.scan_description, 16, "%sR%.1f@%d", id_str.c_str(), pg.getMonoMass() / 1000.0, charge);
```

- [ ] **Step 4: Update `buildMS3Command_` (lines 3500-3509)**

MS3 uses `frag_mz` and `frag_charge`. The mass in kDa is `frag_mz * frag_charge / 1000.0`. Ion annotation is appended directly after charge (no space).

```cpp
// Replace:
std::string id_str = encodeTracking_(id);
char desc_buf[256];
if (ion_type != '\0' && frag_index > 0)
  std::snprintf(desc_buf, sizeof(desc_buf), "%s|MS3 %c%d mz=%.2f z=%d",
                id_str.c_str(), ion_type, frag_index, frag_mz, frag_charge);
else
  std::snprintf(desc_buf, sizeof(desc_buf), "%s|MS3 mz=%.2f z=%d",
                id_str.c_str(), frag_mz, frag_charge);
std::strncpy(cmd.scan_description, desc_buf, sizeof(cmd.scan_description) - 1);
cmd.scan_description[sizeof(cmd.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(id);
double frag_mass_kda = frag_mz * frag_charge / 1000.0;
if (ion_type != '\0' && frag_index > 0)
  std::snprintf(cmd.scan_description, 16, "%sR%.1f@%d%c%d",
                id_str.c_str(), frag_mass_kda, frag_charge, ion_type, frag_index);
else
  std::snprintf(cmd.scan_description, 16, "%sR%.1f@%d",
                id_str.c_str(), frag_mass_kda, frag_charge);
```

- [ ] **Step 5: Update `pushFollowUpMS2_` (lines 3594-3598)**

Followup copies from parent via `cmd = ctx`. `cmd.mono_mass` and `cmd.stages[0].charge_state` are inherited.

```cpp
// Replace:
std::string id_str = encodeTracking_(cmd.scan_id);
char desc_buf[256];
std::snprintf(desc_buf, sizeof(desc_buf), "%s|followup mz=%.2f", id_str.c_str(), cmd.stages[0].precursor_mz);
std::strncpy(cmd.scan_description, desc_buf, sizeof(cmd.scan_description) - 1);
cmd.scan_description[sizeof(cmd.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(cmd.scan_id);
std::snprintf(cmd.scan_description, 16, "%sF%.1f@%d",
              id_str.c_str(), cmd.mono_mass / 1000.0, cmd.stages[0].charge_state);
```

- [ ] **Step 6: Update `pushConditionalFollowUp_` (lines 3630-3634)**

Same pattern as followup — uses inherited `mono_mass` and `stages[0].charge_state`.

```cpp
// Replace:
std::string id_str = encodeTracking_(cmd.scan_id);
char desc_buf[256];
std::snprintf(desc_buf, sizeof(desc_buf), "%s|conditional mz=%.2f", id_str.c_str(), cmd.stages[0].precursor_mz);
std::strncpy(cmd.scan_description, desc_buf, sizeof(cmd.scan_description) - 1);
cmd.scan_description[sizeof(cmd.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(cmd.scan_id);
std::snprintf(cmd.scan_description, 16, "%sC%.1f@%d",
              id_str.c_str(), cmd.mono_mass / 1000.0, cmd.stages[0].charge_state);
```

- [ ] **Step 7: Update exploration variant in `initiateExploration_` (lines 3742-3746)**

Uses `precursor_mass` and `precursor_charge` parameters.

```cpp
// Replace:
std::string id_str = encodeTracking_(id_int);
v.tracking_id = id_str;
std::snprintf(cmd.scan_description, sizeof(cmd.scan_description),
             "%s|EXPL CE=%.1f %.2f@%d", id_str.c_str(),
             ces[i], precursor_mass, precursor_charge);

// With:
std::string id_str = encodeTracking_(id_int);
v.tracking_id = id_str;
std::snprintf(cmd.scan_description, 16, "%sE%.1f@%d",
             id_str.c_str(), precursor_mass / 1000.0, precursor_charge);
```

- [ ] **Step 8: Update exploration production scan in `selectWinner_` (line 3876)**

This is a `[TRACK-CREATE]` log line — it uses `encodeTracking_` but does NOT write `scan_description` (the production command's description is set by `buildMS2Command_`). No format change needed. Just verify the rename from Step 3 of Task 1 was applied.

- [ ] **Step 9: Update exploration `decodeTracking_` call in `selectWinner_` (line 3888)**

```cpp
// Replace:
variant_tracking_to_group_.erase(decodeBase36_(vr.tracking_id));
// With (already done in Task 1 Step 3):
variant_tracking_to_group_.erase(decodeTracking_(vr.tracking_id));
```

Verify the rename was applied.

- [ ] **Step 10: Update `initiateNextLevel_` production scan (line 3924)**

This is a `[TRACK-CREATE]` log line only. The command's `scan_description` is set by `buildMS2Command_`. Just verify the rename was applied.

- [ ] **Step 11: Update `getNextScanCommand` — timer AGC (lines 4063-4067)**

```cpp
// Replace:
std::string id_str = encodeTracking_(out.scan_id);
char desc_buf[128];
std::snprintf(desc_buf, sizeof(desc_buf), "%s|AGC calibration", id_str.c_str());
std::strncpy(out.scan_description, desc_buf, sizeof(out.scan_description) - 1);
out.scan_description[sizeof(out.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(out.scan_id);
std::snprintf(out.scan_description, 16, "%sA", id_str.c_str());
```

- [ ] **Step 12: Update `getNextScanCommand` — cycle-time MS1 (lines 4084-4088)**

```cpp
// Replace:
std::string id_str = encodeTracking_(out.scan_id);
char desc_buf[128];
std::snprintf(desc_buf, sizeof(desc_buf), "%s|MS1 survey", id_str.c_str());
std::strncpy(out.scan_description, desc_buf, sizeof(out.scan_description) - 1);
out.scan_description[sizeof(out.scan_description) - 1] = '\0';

// With:
std::string id_str = encodeTracking_(out.scan_id);
std::snprintf(out.scan_description, 16, "%sS", id_str.c_str());
```

- [ ] **Step 13: Update `getNextScanCommand` — idle AGC (lines 4119-4123)**

```cpp
// Replace:
std::string agc_id_str = encodeTracking_(agc_cmd.scan_id);
char agc_desc_buf[128];
std::snprintf(agc_desc_buf, sizeof(agc_desc_buf), "%s|AGC calibration", agc_id_str.c_str());
std::strncpy(agc_cmd.scan_description, agc_desc_buf, sizeof(agc_cmd.scan_description) - 1);
agc_cmd.scan_description[sizeof(agc_cmd.scan_description) - 1] = '\0';

// With:
std::string agc_id_str = encodeTracking_(agc_cmd.scan_id);
std::snprintf(agc_cmd.scan_description, 16, "%sA", agc_id_str.c_str());
```

- [ ] **Step 14: Update `getNextScanCommand` — idle MS1 (lines 4134-4138)**

```cpp
// Replace:
std::string ms1_id_str = encodeTracking_(ms1_cmd.scan_id);
char ms1_desc_buf[128];
std::snprintf(ms1_desc_buf, sizeof(ms1_desc_buf), "%s|MS1 survey", ms1_id_str.c_str());
std::strncpy(ms1_cmd.scan_description, ms1_desc_buf, sizeof(ms1_cmd.scan_description) - 1);
ms1_cmd.scan_description[sizeof(ms1_cmd.scan_description) - 1] = '\0';

// With:
std::string ms1_id_str = encodeTracking_(ms1_cmd.scan_id);
std::snprintf(ms1_cmd.scan_description, 16, "%sS", ms1_id_str.c_str());
```

- [ ] **Step 15: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Update all scan_description formats to compact 15-char layout"
```

---

### Task 3: Update processMS2Path_ parsing (C++)

**Files:**
- Modify: `OpenMS/src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp:3937-3947`

Replace pipe-delimiter parsing with fixed-position 3-char ID extraction.

- [ ] **Step 1: Replace parsing in processMS2Path_**

```cpp
// Replace (lines 3937-3947):
// Step 1: Decode tracking ID from scan_description format: {base36_id}|{payload}
std::string desc_str = scan_desc ? scan_desc : "";
if (desc_str.empty())
  return 0;

Size pipe_pos = desc_str.find('|');
if (pipe_pos == std::string::npos)
  return 0;

std::string id_str = desc_str.substr(0, pipe_pos);
int tracking_id = decodeBase36_(id_str);

// With:
// Step 1: Decode tracking ID from scan_description — fixed position chars 0-2
std::string desc_str = scan_desc ? scan_desc : "";
if (desc_str.size() < 3)
  return 0;

std::string id_str = desc_str.substr(0, 3);
int tracking_id = decodeTracking_(id_str);
```

- [ ] **Step 2: Verify no other pipe-delimiter parsing exists**

Search for `find('|')` in `FLASHIda.cpp` to confirm this is the only location.

- [ ] **Step 3: Commit**

```bash
cd OpenMS
git add src/openms/source/ANALYSIS/TOPDOWN/FLASHIda.cpp
git commit -m "Update processMS2Path_ to fixed-position 3-char tracking ID parsing"
```

---

### Task 4: Update C++ test assertions

**Files:**
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp:110-115`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp:590,629-634,722-723,767-768,791-803,1155-1157,1168-1170`
- Modify: `OpenMS/src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp:566,621`

- [ ] **Step 1: Update FLASHIdaQueueTracking_test.cpp — encode/decode assertions**

The old assertions (lines 110-115) test 4-char base-36 output. Replace with 3-char base-94:

```cpp
// Replace:
TEST_STRING_EQUAL(FLASHIda::encodeBase36ForTest(0), "0000")
TEST_STRING_EQUAL(FLASHIda::encodeBase36ForTest(35), "000z")
TEST_STRING_EQUAL(FLASHIda::encodeBase36ForTest(36), "0010")
TEST_STRING_EQUAL(FLASHIda::encodeBase36ForTest(1679615), "zzzz")
TEST_STRING_EQUAL(FLASHIda::encodeBase36ForTest(1296), "0100")

// With:
// Base-94: alphabet[0]='!', alphabet[1]='"', ..., alphabet[93]='~'
// encodeTracking_(0)  = "!!!" (all zeros)
// encodeTracking_(1)  = "!!\"" (last char is '"', index 1)
// encodeTracking_(94) = "!\"!" (middle char advances)
// encodeTracking_(94*94-1) = "!~~" (max with first char '!')
// encodeTracking_(830583) = "~~~" (max value: 94^3 - 1)
TEST_STRING_EQUAL(FLASHIda::encodeTrackingForTest(0), "!!!")
TEST_STRING_EQUAL(FLASHIda::encodeTrackingForTest(1), "!!\"")
TEST_STRING_EQUAL(FLASHIda::encodeTrackingForTest(94), "!\"!")
TEST_STRING_EQUAL(FLASHIda::encodeTrackingForTest(830583), "~~~")
TEST_STRING_EQUAL(FLASHIda::encodeTrackingForTest(8836), "\"!!")
```

Also update the `decodeBase36ForTest` roundtrip if present in this file — replace all occurrences of `encodeBase36ForTest` → `encodeTrackingForTest` and `decodeBase36ForTest` → `decodeTrackingForTest`.

- [ ] **Step 2: Update FLASHIda_ProcessScan_test.cpp — format assertions**

**a)** Line 590 — scan_description minimum length: change from 4 to 3:

```cpp
// Replace:
TEST_EQUAL(std::strlen(cmd.scan_description) >= 4, true)
// With:
TEST_EQUAL(std::strlen(cmd.scan_description) >= 3, true)
```

**b)** Lines 629-634 — format validation: replace pipe-at-position-4 with type-code-at-position-3:

```cpp
// Replace:
std::string desc(cmd.scan_description);
auto pipe_pos = desc.find('|');
TEST_EQUAL(pipe_pos != std::string::npos, true)
TEST_EQUAL(pipe_pos, 4)  // 4-char base-36 ID
std::string id_part = desc.substr(0, pipe_pos);
TEST_EQUAL(id_part.find_first_not_of("0123456789abcdefghijklmnopqrstuvwxyz") == std::string::npos, true)

// With:
std::string desc(cmd.scan_description);
TEST_EQUAL(desc.size() >= 4, true)  // 3-char ID + type code
std::string id_part = desc.substr(0, 3);
// Verify all chars are in the tracking alphabet (printable ASCII 0x21-0x7E)
for (char c : id_part)
{
  TEST_EQUAL(c >= 0x21 && c <= 0x7E, true)
}
// Type code should be R for recording MS2
TEST_EQUAL(desc[3], 'R')
```

**c)** Lines 722-723 — conditional follow-up: replace `"|conditional"` with type code `C`:

```cpp
// Replace:
std::string cond_desc(out.scan_description);
TEST_EQUAL(cond_desc.find("|conditional") != std::string::npos, true)
TEST_EQUAL(cond_desc.find("|conditional"), 4)  // After 4-char base-36 ID

// With:
std::string cond_desc(out.scan_description);
TEST_EQUAL(cond_desc.size() >= 4, true)
TEST_EQUAL(cond_desc[3], 'C')
```

**d)** Lines 767-768 — MS3 format: replace `"|MS3"` with type code `R` (recording):

```cpp
// Replace:
std::string ms3_desc(out.scan_description);
TEST_EQUAL(ms3_desc.find("|MS3") != std::string::npos, true)
TEST_EQUAL(ms3_desc.find("|MS3"), 4)  // After 4-char base-36 ID

// With:
std::string ms3_desc(out.scan_description);
TEST_EQUAL(ms3_desc.size() >= 4, true)
TEST_EQUAL(ms3_desc[3], 'R')  // MS3 recording
```

**e)** Lines 791-803 — decodeBase36 roundtrip: update to 3-char base-94:

```cpp
// Replace:
std::string desc(cmd.scan_description);
TEST_EQUAL(desc.size() >= 5, true)  // 4 chars + pipe
TEST_EQUAL(desc[4], '|')
std::string id_str = desc.substr(0, 4);
// Verify the ID is valid base-36
for (char c : id_str)
{
  TEST_EQUAL((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z'), true)
}
// Roundtrip: decoding the base-36 ID should give back cmd.scan_id
int decoded_id = ida->decodeBase36ForTest(id_str);
TEST_EQUAL(decoded_id, cmd.scan_id)

// With:
std::string desc(cmd.scan_description);
TEST_EQUAL(desc.size() >= 4, true)  // 3-char ID + type code
std::string id_str = desc.substr(0, 3);
for (char c : id_str)
{
  TEST_EQUAL(c >= 0x21 && c <= 0x7E, true)
}
int decoded_id = ida->decodeTrackingForTest(id_str);
TEST_EQUAL(decoded_id, cmd.scan_id)
```

**f)** Lines 1155-1157 — idle AGC format:

```cpp
// Replace:
std::string agc_desc(cmd.scan_description);
TEST_EQUAL(agc_desc.find("|AGC calibration") != std::string::npos, true)
TEST_EQUAL(agc_desc.find("|AGC calibration"), 4)

// With:
std::string agc_desc(cmd.scan_description);
TEST_EQUAL(agc_desc.size() >= 4, true)
TEST_EQUAL(agc_desc[3], 'A')
```

**g)** Lines 1168-1170 — idle MS1 format:

```cpp
// Replace:
std::string ms1_desc(cmd.scan_description);
TEST_EQUAL(ms1_desc.find("|MS1 survey") != std::string::npos, true)
TEST_EQUAL(ms1_desc.find("|MS1 survey"), 4)

// With:
std::string ms1_desc(cmd.scan_description);
TEST_EQUAL(ms1_desc.size() >= 4, true)
TEST_EQUAL(ms1_desc[3], 'S')
```

- [ ] **Step 3: Update FLASHIda_exploration_test.cpp — exploration format assertions**

**a)** Line 566 and line 621 — exploration variant format:

```cpp
// Replace (both locations):
std::string desc(cmd.scan_description);
TEST_EQUAL(desc.find("|EXPL CE=") != std::string::npos, true)

// With:
std::string desc(cmd.scan_description);
TEST_EQUAL(desc.size() >= 4, true)
TEST_EQUAL(desc[3], 'E')
```

- [ ] **Step 4: Build and run all C++ tests**

```bash
cd OpenMS/build
cmake --build . --target FLASHIdaQueueTracking_test FLASHIda_ProcessScan_test FLASHIdaFAIMS_test FLASHIda_exploration_test ScanCommandLayout_test DeconvolvedSpectrum_OptimizationMetadata_test FLASHIda_LegacyConfig_test -- -j$(nproc)
OPENMS_DATA_PATH=$(pwd)/../../OpenMS/share/OpenMS ctest -R "FLASHIdaQueueTracking|FLASHIda_ProcessScan|FLASHIdaFAIMS|FLASHIda_exploration|ScanCommandLayout|DeconvolvedSpectrum_OptimizationMetadata|FLASHIda_LegacyConfig" --output-on-failure
```

Expected: All 7 test binaries pass.

- [ ] **Step 5: Commit**

```bash
cd OpenMS
git add src/tests/class_tests/openms/source/FLASHIdaQueueTracking_test.cpp \
        src/tests/class_tests/openms/source/FLASHIda_ProcessScan_test.cpp \
        src/tests/class_tests/openms/source/FLASHIda_exploration_test.cpp
git commit -m "Update test assertions for compact 3-char base-94 scan descriptions"
```

---

### Task 5: Push C++ changes and trigger DLL build

**Files:** None (git operations only)

- [ ] **Step 1: Push to flashida-v9-bridge**

```bash
cd OpenMS
git push origin flashida-v9-bridge
```

This triggers the `build-dlls` workflow on the OpenMS repo (~40 min).

- [ ] **Step 2: Monitor build**

```bash
gh run list -R t0mdavid-m/OpenMS --branch flashida-v9-bridge -L 3
```

Wait for the build to complete. Do not poll — proceed to Task 6 in the meantime.

---

### Task 6: Update C# format assertion

**Files:**
- Modify: `FlashIDA/src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs:874-875`

This can be done while waiting for the DLL build.

- [ ] **Step 1: Update scan description format assertion**

```csharp
// Replace (lines 874-875):
Assert.IsTrue(initialResults.All(r => r.ScanDescription.Length >= 5 && r.ScanDescription[4] == '|'),
    "Initial MS2 commands should have base-36 tracking-ID scan descriptions (XXXX|...)");

// With:
Assert.IsTrue(initialResults.All(r => r.ScanDescription.Length >= 4 && "ARFCE".Contains(r.ScanDescription[3])),
    "Initial MS2 commands should have compact tracking-ID scan descriptions (XXXR...)");
```

- [ ] **Step 2: Commit**

```bash
cd FlashIDA
git add src/Flash.Tests/AcquisitionLoop/ContinuityTests.cs
git commit -m "Update scan description format assertion for compact 3-char tracking IDs"
```

---

### Task 7: Download DLLs, re-capture golden files, push everything

**Files:**
- Modify: `FlashIDA/dll/*.dll` (updated OpenMS DLLs)
- Modify: `FlashIDA/test-data/golden/*.json` (17 golden files)

Depends on Task 5 DLL build completing.

- [ ] **Step 1: Download the built DLLs**

```bash
# Find the latest successful run
gh run list -R t0mdavid-m/OpenMS --branch flashida-v9-bridge -L 3 --json databaseId,status,conclusion

# Download (replace <run-id> with the actual run ID)
gh run download <run-id> -R t0mdavid-m/OpenMS -n selected-bin-artifacts -D /tmp/openms-dlls

# Copy to FlashIDA/dll/
cp /tmp/openms-dlls/*.dll FlashIDA/dll/
```

- [ ] **Step 2: Commit updated DLLs**

```bash
cd FlashIDA
git add dll/
git commit -m "Update OpenMS DLLs with compact scan description format"
```

- [ ] **Step 3: Push FlashIDA**

```bash
cd FlashIDA
git push origin phase-8
```

- [ ] **Step 4: Update parent submodule pointers**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add FlashIDA OpenMS
git commit -m "Update submodules: compact scan description format"
git push origin phase-8
```

- [ ] **Step 5: Wait for CI, re-capture golden files if needed**

The CI run will capture new golden files. If golden file comparison tests fail (expected — scan descriptions changed), download the new golden captures from CI artifacts and commit them:

```bash
# Download golden captures from CI artifacts
gh run download <ci-run-id> -n continuity-golden-capture -D /tmp/golden

# Diff and review before overwriting
diff FlashIDA/test-data/golden/ /tmp/golden/

# Copy and commit
cp /tmp/golden/*.json FlashIDA/test-data/golden/
cd FlashIDA
git add test-data/golden/
git commit -m "Re-capture golden files for compact scan description format"
git push origin phase-8
```

- [ ] **Step 6: Update parent submodule pointer for golden file commit**

```bash
cd /home/tom-mueller/kohlbacherlab/FLASHIda/Development
git add FlashIDA
git commit -m "Update FlashIDA submodule: golden files for compact scan descriptions"
git push origin phase-8
```

- [ ] **Step 7: Verify CI green**

```bash
gh run list -L 3 --json databaseId,status,conclusion
```

Expected: Both `cpp-unit-tests` and `windows-tests` jobs pass.
