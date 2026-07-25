# Proposal: add-weave-density-symmetry

## Why

`add-weave-solver-pipeline` shipped Auto-Retopologize behind the `WeaveSolving`
seam, but the backend (`EngineRemeshSolver`) ignores every field constraint — it
always produces the same fixed-density, non-symmetric cage. The full
constraint-aware solver (guide-stroke flow, prescribed-boundary quadrangulation) is
research-grade engine work, but two of the six constraints are honourable NOW by
orchestrating engine ops the app already has: **density** (the remesher takes a quad
budget) and **symmetry** (the app already mirrors and welds a working side).

This change makes those two constraints real, so Auto-Retopo output resolution is
user-controlled and symmetric when the document symmetry is on.

## What Changes

- **Density → resolution.** A density control on the Auto-Retopo flow (Coarse /
  Medium / Fine) sets the solve's quad budget; `EngineRemeshSolver` maps
  `SolverParameters.remesh.targetQuads` (and `WeaveConstraints.density` →
  `edgeScale`) so the proposed cage matches the chosen density.
- **Symmetry → mirrored output.** When `WeaveConstraints.symmetry` is enabled with a
  mirror axis, the solver produces a symmetric cage: remesh the Target, clip to the
  symmetry's working side (delete faces whose centroid is on the far side), snap the
  seam onto the plane, then mirror + weld with the existing `applySymmetry` path. The
  document's active symmetry is passed as the constraint, so a symmetric document
  yields a symmetric retopology.
- The Auto-Retopo trigger passes the document's symmetry and the chosen density as
  constraints/params; with neither set, behaviour is exactly today's.

## Impact

- Affected specs: `weave-solver` (MODIFIED: the solver honours density and symmetry;
  ADDED scenarios for both).
- Affected code:
  - CyberKit: `EngineRemeshSolver` honours `constraints.density` and
    `constraints.symmetry` (clip + mirror via existing `faceCentroid`/`deleteFaces`/
    `snapSymmetryPlane`/`applySymmetry`); a small density→params mapping.
  - App: a density picker on the Auto-Retopo affordance; the trigger threads the
    document symmetry + density through `SolverParameters`/`WeaveConstraints`.
- Affected tests: CyberKit solver tests for density (finer budget → more quads) and
  symmetry (output is mirror-symmetric about the plane; a working-side-only cage is
  completed), shared to the app-hosted target; app-hosted flow test that a symmetric
  document yields a symmetric accepted cage.

## Non-Goals

- The prescribed-boundary guarantee, frozen-patch survival, guide-stroke flow,
  tagged-loop alignment, pins-as-hard, and radial symmetry beyond a single mirror —
  all still require the constraint-aware engine solver (a later change).
- A pressure-driven per-region density BRUSH (this ships a global density level; the
  brush is a follow-up).

## Notes

Both constraints are honoured by orchestrating EXISTING engine ops, not by new
quadrangulation math, so this stays inside design rule D1 (no mesh algorithms in
Swift — the algorithms are the engine's remesh/apply-symmetry; the solver only
sequences them). When the real solver lands it subsumes this by honouring the
constraints natively, behind the same `WeaveSolving` seam.
