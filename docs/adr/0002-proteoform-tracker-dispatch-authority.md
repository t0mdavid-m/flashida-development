# 0002. The ProteoformTracker is the dispatch authority; Exploration becomes feeder + executor

Status: Accepted (2026-06-24)

## Context

Today `Exploration` owns MSn dispatch end to end: when an MS2 exploration group
completes, `initiateNextLevel` selects fragments from a *single* MS2 spectrum and
builds the MS3 / follow-up commands directly, then discards the per-variant
identification and parameters after winner selection (`Exploration.cpp:642-645`).
The new model must instead pool evidence across *all* of a Precursor's scans and
choose scans "for maximum information," which no existing component does.

## Decision

Introduce a **`ProteoformTracker`** (C++, owned by the `FLASHIda` instance,
whole-run lifetime) holding one `ProteoformModel` per Precursor. It becomes the
**single planner**: every MS3 and every follow-up MSn is planned *via* the tracker
(`tracker.planNextScans(precursor)`). `Exploration` is inverted into a **feeder**
(it pools each variant result into the model) and an **executor** (it enqueues the
model's planned commands); its single-spectrum fragment selection moves *behind* the
model.

## Considered Options

- *Leave Exploration in charge, model as passive observer* — rejected: per-fragment
  best-parameter provenance and cross-scan pooling need a cross-scan owner, and the
  selection decision must see the pooled model, not one spectrum.
- *Replace Exploration entirely* — rejected: it is a mature, CI-covered state
  machine with an ABI dependency; rewriting it is disproportionate risk.

## Consequences

We redirect `Exploration::initiateNextLevel`'s selection/build to the tracker rather
than rewriting Exploration. The per-variant data Exploration currently discards must
now be captured by the model as variants feed in. The engine gains its first piece
of state that outlives a single `processScan` call.
