# plans/development/ — Active Development Plans

This directory contains per-phase implementation plans and read-only reference documents.

## Editable files (working documents)

- **Phase_0/ through Phase_8/implementation-plan.md** — Detailed per-phase implementation plans. All edits during implementation go in these files.

## Read-only reference documents (do NOT edit)

- **baseline-plan.md** — Parameter optimization plan v9. Architecture design and issue specifications.
- **testing-strategy.md** — Test tiers, CI infrastructure, and per-phase test matrices.
- **acquisition-loop-testing-strategy.md** — Extends testing-strategy.md to cover the C# acquisition loop (DataPipe, IScanProcessor, ScanScheduler) via mock-based tests.
- **implementation-roadmap.md** — High-level phase overview, build batching, CI environment requirements.
- **verification-report.md** — Cross-document consistency verification results.
- **test-file-specification.md** — Test file formats, directory layout, and golden file catalog.
- **environment-and-workflows.md** — CI environment, GitHub Actions workflows, and build infrastructure.

Do NOT reference any files in the parent `plans/` directory (v2-v9 archived iterations) for implementation guidance.
