# Proposal: add-weave-solver-pipeline

## Why

Weave is the product's differentiator (Phase 5, milestone v0.2 "Weave works"):
a constraint-driven solver that auto-fills clean quad topology from the gestures
the user already draws. The full capability is large — six constraint types, a
prescribed-boundary quadrangulation guarantee, regional live re-solve — and the
constraint-aware solver must be built in the C++ `CyberRemesherAndUV` engine.

But the engine ALREADY ships a working auto-retopology solver — `cyber_remesh`
(three quadrangulation methods, curvature adaptivity, hole-filling, target quad
count, built-in progress + cancellation) — and the app never exposes it: it is
wrapped in CyberKit as `Mesh.remeshed(...)` yet called only from one test. Today
users get only MANUAL retopology (the Phase 4 tools); the one-tap auto path the
engine can already do is invisible.

Crucially, `cyber_remesh`'s signature (`in, params, progress, cancel → out`) is
exactly the shape a Weave solver session needs. So this change does two things at
once: it ships **user-facing Auto-Retopologize** by surfacing the existing engine
remesher, AND it stands up the **solver-session pipeline** (region → solve → ghost
→ accept) with the remesher as its FIRST backend behind a `WeaveSolving` seam. The
constraint-aware Weave solver, when it lands in the engine, swaps in behind that
same seam with no app-side change. Real value now; the Phase 5 architecture in
place; zero new engine code.

## What Changes

- **Expose progress + cancellation on CyberKit's remesh.** `Mesh.remeshed(...)`
  gains `onProgress`/`isCancelled` parameters wired to the engine's
  `CyberProgressCb`/`CyberCancelCb` (currently passed as NULL).
- **A `WeaveSolving` session API in CyberKit.** A solve takes a region + a
  constraint set + parameters and produces a **ghost mesh** (proposed, uncommitted
  geometry) with progress and cancellation. The constraint type carries the full
  Weave taxonomy (frozen patches, tagged loops, guide strokes, pins, density,
  symmetry) so call sites and the document are forward-compatible, even though the
  first backend does not yet honour the field constraints.
- **`EngineRemeshSolver`: the first `WeaveSolving` backend.** Wraps `cyber_remesh`.
  For this slice the region is the whole Target (a maximal-region "solve all"): it
  retopologizes the Target surface into a fresh quad EditMesh and returns it as the
  ghost. It never mutates the source mesh.
- **The Auto-Retopologize action + ghost accept/override flow in the app.** An
  action runs the solver session over the Target, renders the result as an **amber
  Weave ghost** (the `GhostStyle` the renderer already reserves), and resolves it:
  **tap accepts** the ghost as the EditMesh in ONE journal entry; **drawing over it
  or cancelling discards** it, document byte-unchanged. Accepted topology is
  ordinary EditMesh — every existing verb/tool works on it with no special-casing.
  A small parameter affordance (target density / method) drives the remesh; sensible
  defaults make it one-tap.
- **Strict opt-in.** Never invoking Auto-Retopologize / Weave produces no solver
  geometry.

## Impact

- Affected specs: `weave-solver` (ADDED: solver-session API, source-untouched-until-
  accept, determinism, ghost accept flow, opt-in — the subset this slice guarantees).
- Affected code (all Swift, no engine repo change):
  - CyberKit: `Mesh.remeshed` gains progress/cancel; new `WeaveSolving`,
    `SolveRegion`, `WeaveConstraints`, `SolverParameters`, `SolverGhost`,
    `SolverProgress`, and `EngineRemeshSolver`.
  - App: an `autoRetopo` `EditorAction` (batch/roster), a solver session on
    `MeshEditController` mirroring the camera-tool session → ghost → commit shape,
    amber ghost rendering via `GhostRenderPath`, progress + cancel UI, and the
    accept/discard routing through the arbiter.
- Affected tests: CyberKit remesh-with-progress/cancel + `EngineRemeshSolver`
  (determinism verified, cancel leaves source untouched) shared into the app-hosted
  target so they run on device too (Phase 4 pattern); app-hosted ghost accept/discard
  round-trips (accept journals once + undo restores bytes; draw-over discards; opt-in
  produces nothing; accepted mesh takes a follow-up verb).

## Non-Goals (deferred to follow-up changes)

- **The constraint-aware Weave solver** — flow alignment from tagged loops,
  guide-stroke orientation, pins as hard positions, density-brush sizing (5.2), and
  the **prescribed-boundary interface guarantee** (5.3) — all require the new engine
  solver. `EngineRemeshSolver` ignores the field constraints for now.
- **Regional solve** — this slice solves the whole Target; lasso/tap sub-region
  solve and regional live re-solve (5.4) come with the constraint-aware solver.
- Implicit sizing from frozen interfaces (5.5), ambient assist (5.6), benchmark run
  (5.7).

## Notes

The `WeaveSolving` protocol is the seam that makes "change it later" literal: the
app, ghost pipeline, accept flow, and their tests depend only on the protocol.
This change wires `EngineRemeshSolver`; the engine follow-up adds the
constraint-aware backend and swaps the injected instance. Everything above the
protocol — including the Auto-Retopologize UX — is unchanged when the real solver
lands. If `cyber_remesh` turns out not to satisfy the determinism contract (its
determinism is currently unverified), that is surfaced as an engine issue rather
than weakening the spec, since strict determinism is a mandated engine property
(design decision D3).
