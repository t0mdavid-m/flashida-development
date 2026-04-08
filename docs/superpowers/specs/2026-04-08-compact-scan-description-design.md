# Compact Scan Description Format

**Date:** 2026-04-08
**Status:** Approved

## Problem

The Thermo instrument API imposes a hard 16-character limit on scan descriptions (15 visible characters + null terminator). Exceeding this limit breaks acquisition. The current format (`{4-char base36}|{payload}`) produces descriptions of 15-32 characters, all of which exceed or are at the limit. Every MS2, MS3, exploration, followup, and conditional scan description is broken on real instruments.

## Goal

Redesign scan descriptions to fit within 15 visible characters (+ null terminator = 16 bytes) while preserving: (1) a tracking ID for the C++ engine to correlate requests with results, and (2) a human-readable payload so scientists can understand why each scan was acquired.

## Design

### Layout

```
[TTT][X][payload...]
 ^    ^   ^
 |    |   +-- 0-11 chars: mode-specific content
 |    +------ 1 char: scan type code
 +----------- 3 chars: tracking ID (base-94, fixed position)
```

Maximum: 15 visible characters + null terminator (16 bytes total). No separator between tracking ID and type code.

### Tracking ID (chars 0-2)

Base-94 encoding using all printable ASCII (0x21-0x7E):

```
!"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\]^_`abcdefghijklmnopqrstuvwxyz{|}~
```

- 3 characters = 94^3 = 830,584 unique IDs
- Wraps at 830,583 back to 0
- Stored as a `const std::string` class member so characters can be added or removed if the instrument rejects any
- Parsing on the return path: always `substr(0, 3)` (fixed position, no delimiter search)

### Type codes (char 3)

| Code | Meaning | Description |
|------|---------|-------------|
| `A` | AGC | AGC calibration scan (timer-based or idle) |
| `S` | Survey | MS1 survey scan (timer-based, idle, or CV transition) |
| `R` | Recording | Standard DDA MS2 or MS3 target from deconvolution |
| `F` | Followup | MS2 tagging follow-up scan (MS2 or MS3) |
| `C` | Conditional | Conditional MS2 scan (MS2 only) |
| `E` | Exploration | CE sweep variant (MS2 or MS3) |

### Payload formats (chars 4-15)

Mass is displayed in kDa with 1 decimal place. Charge is the integer charge state. Ion annotation (for MS3 targets) is the fragment ion type letter and residue index, appended directly without a space separator.

**No payload (AGC, Survey):**

| Type | Example | Length |
|------|---------|--------|
| AGC | `!!!A` | 4 |
| Survey | `!!!S` | 4 |

**MS2 targets (Recording, Followup, Conditional, Exploration):** `{kDa:.1f}@{charge}`

| Type | Example | Length |
|------|---------|--------|
| R MS2 | `!!!R29.5@12` | 12 |
| F MS2 | `!!!F29.5@12` | 12 |
| C MS2 | `!!!C29.5@12` | 12 |
| E MS2 | `!!!E29.5@12` | 12 |

**MS3 targets (Recording, Followup, Exploration):** `{kDa:.1f}@{charge}{ion}{index}`

Ion annotation is appended directly after the charge (no space). The charge is always a decimal integer and the ion type is always a letter, so the boundary is unambiguous.

| Type | Example | Length |
|------|---------|--------|
| R MS3 | `!!!R3.1@3b12` | 13 |
| F MS3 | `!!!F3.1@3b12` | 13 |
| E MS3 | `!!!E3.1@3y123` | 14 |

**Worst case:** `!!!R70.0@50y123` = 15 characters (fits exactly with null terminator at byte 16).

### Encoding/decoding functions

Replace `encodeBase36_` / `decodeBase36_` with `encodeTracking_` / `decodeTracking_`:

```cpp
// Single source of truth for the tracking alphabet.
// Remove characters here if the instrument rejects them.
const std::string tracking_alphabet_ = "!\"#$%&'()*+,-./0123456789:;<=>?@"
                                        "ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`"
                                        "abcdefghijklmnopqrstuvwxyz{|}~";

std::string encodeTracking_(int value)
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

int decodeTracking_(const std::string& s)
{
    const int base = static_cast<int>(tracking_alphabet_.size());
    int value = 0;
    for (char c : s)
    {
        Size pos = tracking_alphabet_.find(c);
        if (pos == std::string::npos) return -1; // invalid character
        value = value * base + static_cast<int>(pos);
    }
    return value;
}
```

### Tracking ID counter wrapping

`nextTrackingIdInt_()` wraps at `tracking_alphabet_.size()^3 - 1` instead of the current hardcoded `36^4 - 1`:

```cpp
int nextTrackingIdInt_()
{
    int base = static_cast<int>(tracking_alphabet_.size());
    int max_id = base * base * base - 1;
    int id = tracking_id_counter_++;
    if (tracking_id_counter_ > max_id)
        tracking_id_counter_ = 0;
    return id;
}
```

### Scan description formatting

Each `snprintf` call that currently writes `{base36}|{payload}` changes to `{base94}{type}{payload}`. The `scan_description` buffer is 256 bytes in `ScanCommand` (unchanged) but output is capped at 15 visible characters by format design.

**Examples of format strings:**

```cpp
// AGC
std::snprintf(buf, 16, "%sA", id.c_str());

// MS1 survey
std::snprintf(buf, 16, "%sS", id.c_str());

// MS2 recording
std::snprintf(buf, 16, "%sR%.1f@%d", id.c_str(), mono_mass / 1000.0, charge);

// MS3 recording with ion annotation
std::snprintf(buf, 16, "%sR%.1f@%d%c%d", id.c_str(), mono_mass / 1000.0, charge, ion_type, frag_index);

// MS3 recording without ion annotation
std::snprintf(buf, 16, "%sR%.1f@%d", id.c_str(), mono_mass / 1000.0, charge);

// Followup MS2 (mono_mass inherited from parent command)
std::snprintf(buf, 16, "%sF%.1f@%d", id.c_str(), cmd.mono_mass / 1000.0, charge);

// Followup MS3 with ion annotation (mono_mass inherited from parent command)
std::snprintf(buf, 16, "%sF%.1f@%d%c%d", id.c_str(), cmd.mono_mass / 1000.0, charge, ion_type, frag_index);

// Conditional MS2 (mono_mass inherited from parent command)
std::snprintf(buf, 16, "%sC%.1f@%d", id.c_str(), cmd.mono_mass / 1000.0, charge);

// Exploration MS2
std::snprintf(buf, 16, "%sE%.1f@%d", id.c_str(), precursor_mass / 1000.0, charge);

// Exploration MS3 with ion annotation
std::snprintf(buf, 16, "%sE%.1f@%d%c%d", id.c_str(), precursor_mass / 1000.0, charge, ion_type, frag_index);
```

Note: `snprintf(buf, 16, ...)` writes at most 15 characters + null terminator, enforcing the 16-byte instrument limit.

### Return-path parsing change

In `processMS2Path_()`, replace delimiter-based parsing with fixed-position:

```cpp
// Before:
Size pipe_pos = desc_str.find('|');
if (pipe_pos == std::string::npos) return 0;
std::string id_str = desc_str.substr(0, pipe_pos);
int tracking_id = decodeBase36_(id_str);

// After:
if (desc_str.size() < 3) return 0;
std::string id_str = desc_str.substr(0, 3);
int tracking_id = decodeTracking_(id_str);
```

### `[TRACK-CREATE]` log lines

Console log format is unchanged. These are not scan descriptions and have no length limit. They continue to log full-precision mass in Da, CE, FAIMS CV, etc.

### Golden files

All golden files containing `ScanDescription` fields will need re-capture after this change. The tracking ID encoding changes (base-36 4-char to base-94 3-char) and the payload format changes (pipe-separated verbose to compact).

## Files to modify

| File | Change |
|------|--------|
| `OpenMS/.../FLASHIda.h` | Replace `encodeBase36_`/`decodeBase36_` declarations with `encodeTracking_`/`decodeTracking_`. Add `tracking_alphabet_` member. |
| `OpenMS/.../FLASHIda.cpp` | Replace encode/decode implementations. Update all `snprintf` calls for scan descriptions. Update `processMS2Path_` parsing. Update `nextTrackingIdInt_` wrapping. |
| `OpenMS/.../FLASHIdaQueueTracking_test.cpp` | Update tracking ID assertions for base-94 3-char format. |
| `OpenMS/.../FLASHIda_ProcessScan_test.cpp` | Update scan description assertions. |
| `OpenMS/.../FLASHIdaFAIMS_test.cpp` | Update scan description assertions. |
| `OpenMS/.../FLASHIda_exploration_test.cpp` | Update scan description assertions. |
| `FlashIDA/.../ContinuityTestHarness.cs` | Update any scan description parsing. |
| `FlashIDA/test-data/golden/*.json` | Re-capture all golden files. |

## Files unchanged

- `ScanCommand` struct (256-byte `scan_description` field unchanged)
- `FLASHIdaBridgeFunctions.cpp/.h` (bridge API unchanged)
- `FLASHIdaWrapper.cs` (P/Invoke unchanged, `ScanDescription` field unchanged)
- `ScanFactory.cs` (passes description string through, no parsing)
- `Flash.cs` (no scan description logic)
