# 0015. The log folder is resolved host-side, and `log_dir` means two different things

Status: Accepted (2026-08-09). Amends
[ADR-0006 (single bridge config schema)](0006-single-bridge-config-schema.md), whose
"`ToCppJson` becomes ~identity" direction this deliberately departs from for one key.

## Context

FLASHIda wrote seven log files through two unrelated mechanisms, and used neither well.

The C++ engine's five streams each took their own absolute path in `method.json`'s `runtime`
section — `ida_log_path`, `scan_commands_path`, `scan_results_path`, `identification_log_path`,
`pooled_identification_log_path` — with an empty string meaning "do not open this stream".

Naming five absolute paths per method is enough friction that nobody ever did it.
`grep '"runtime"'` across every committed `*.json` returned exactly one hit, the generated schema
reference, and no production C# code set any of the five either. **The instrument had never
written any of those five files.** The feature existed, was tested, and was unreachable in
practice.

The other two files, `FlashLog_<ts>.log` and `IDALog_<ts>.log`, were named by log4net from two
*independent* `%date{yyyy-MM-dd-HH-mm-ss}` PatternStrings in `App.config`. A run straddling a
second boundary produced two different suffixes. `-r|--rawname` replaced both with a raw-file-derived
name and `CheckLogPath` added a timestamp only *on collision*, by concatenation, so a third
collision produced `name_ts1_ts2_ts3`.

This matters more than a tidy-up because of how the application is actually launched. Xcalibur's
Pre-Acquisition command runs `Flash.exe … -r %R` **once per sample**. A forty-sample sequence is
forty processes: forty correctly-named log4net pairs, and — whenever the five engine paths *were*
set — five files with all forty runs appended into them, each with a fresh header row injected
mid-file, because every stream opens `std::ios::app`.

## Decision

**One authored key, `runtime.log_dir`, names a folder. Every run gets its own timestamped
subfolder inside it, and all seven files land there.** The five per-stream keys are deleted from
both the authored model and the bridge schema; a config carrying one throws a migration error.

**Resolution happens host-side, exactly once, in `LogPathResolver.Compose(log_dir, rawname, now)`,
called only from the two `Main` methods.** C# absolutises the base directory, mints one timestamp,
composes `<log_dir>/<rawname>_<stamp>/` (or `<log_dir>/<stamp>/`), disambiguates a collision with
`_2`/`_3`, creates the directory, and writes the absolute result back into the config before
`ToCppJson` runs. C++ joins its five fixed basenames onto whatever it receives.

**`log_dir` therefore means two different things either side of the bridge, deliberately:**

| Layer | `""` | non-empty |
|---|---|---|
| authored (`method.json`) | `"."` — the process working directory | base directory for run folders |
| emitted (bridge JSON, read by `Config.cpp`) | **open nothing** | the fully-resolved run folder |

## Consequences

**The two meanings must not be collapsed.** Empty-means-off on the wire is what lets a C++ fixture
with no `runtime` section — or with `"runtime": {}` — open no streams at all.
`ProteoformTracker_Localization_test.cpp` passes `"runtime": {}` for precisely that reason, and
three further `ProteoformTracker_*` tests pass no section at all. "Fixing" the asymmetry would
silently switch on five file streams in six tests. That is the single most likely way for a future
reader to break this, which is why this ADR exists.

**Composition must stay out of `ToCppJson` and out of `MethodParameters.Load`.** `ToCppJson` is the
body of `GenerateReferenceConfigJson`, so a clock- or CWD-derived value reaching it makes
`config_schema_reference.json` differ on every run — and `Reference_IsNeverStale` would then fail
*unfixably*, because the regenerated file goes stale the moment it is written. Putting it in `Load`
is worse: every NUnit suite that loads a config would start writing five log files into `bin/`, and
the `Exit(1)` on an uncreatable folder would kill the test host mid-run.
`JsonConfigTests.ToCppJson_EmitsLogDirVerbatim` is the tripwire.

**`MethodParameters.Load` moved to the top of `Flash.Main`.** The folder has to reach the log4net
appenders, and `XmlConfigurator.Configure` opens their files immediately — roughly one async event
and a hundred lines before the old load site inside `InstrumentConnected` ran. The config-error
report moved to `Console.Error` with it, because `log` does not exist that early.

**Engine logging is now always on, with no off switch**, and the streams flush per row from the
instrument event thread. That path had never been exercised in production. `flush()` is a syscall
rather than an fsync, which is why this was judged acceptable.

**An uncreatable log folder is fatal.** C# creates the directory and exits 1 before the instrument
container exists. The alternatives both end with an operator who believes they have logs and does
not: `IdaLogger` never checks `is_open()` before writing, so a bad folder means five streams that
no-op silently, and a warning has nowhere to go because the log file lives in the folder that just
failed.

**The engine still never touches the filesystem beyond opening streams.** It does not create
directories, and it does not throw when an open fails. The host owns the filesystem. The cost is
borne by the C++ test suite: 47 sites must each create their own folder, and one that forgets
writes nothing and passes, because `TSVFile::parse` reports a missing file as zero rows without
error. All 47 route through a single `freshLogDir` helper to keep that to one place.

**Test isolation moved from filename to folder.** The 47 sites previously stayed distinct by using
a unique filename each in the one shared ctest working directory. With fixed basenames, each engine
instance needs its own folder — including the several sections that construct two or three engines
in sequence.

**`buildJsonWithRuntime` was renamed to `buildJsonWithLogDir`.** Under the new parameter list the
second argument is `bool enable_ms3`, so a stale call passing a path there would convert
`const char*` to `true`: compiling clean while silently forcing MS3 on and blanking the activation
string. Six call sites had exactly that shape.

**No golden content moved.** Only locations changed; the basenames C++ joins are
`LogGoldenComparer.FileNames` verbatim. One qualification: `buildJsonWithRuntime` never emitted
`pooled_identification_log_path`, so the pooled writer goes live in the helper-driven C++ sections
for the first time. That adds no engine work — `ProteoformTracker` builds the descriptor
unconditionally and `writePooledModelRow` early-returns on `is_open()`.

## Alternatives considered

**Resolve in C++.** Rejected on the timestamp. Two of the seven files are written by log4net inside
the C# process, so a C++-minted stamp would have to cross back over a bridge with no export for it
— the five exports and the 2048-byte `ScanCommand` are fixed — or be minted twice, which is exactly
the two-independent-`%date`-evaluations bug being removed, reintroduced across a language boundary.

**Keep the five keys as overrides beneath a new `log_dir`.** This is what leaving `Config.cpp`
untouched forces: the bridge would still carry five paths, `config_schema_reference.json` is
generated from the bridge schema and reloaded through the strict authored loader
(`ConfigSchemaParityTests.cs:63`), so all five would have to survive in the authored model. Six
keys where one would do, against a house rule that deletes redundant knobs. Rejected; the cost was
paid in C++ test churn instead.

**A per-run folder named only by the timestamp.** Rejected because the instrument already supplies
a better run identity: `%R` names the `.raw` file the logs describe. The two now compose rather
than competing, and `CheckLogPath` disappears.
