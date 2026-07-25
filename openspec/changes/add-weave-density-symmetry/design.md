# Design: add-weave-density-symmetry

## Context

`EngineRemeshSolver` (from add-weave-solver-pipeline) wraps `cyber_remesh` and ignores
`WeaveConstraints`. This change makes it honour the two constraints expressible through
existing engine ops — density and symmetry — without the constraint-aware field solver.

## Density → resolution

`cyber_remesh` already takes a quad budget (`RemeshParameters.targetQuads`) and an edge
scale. The solver maps density to those:
- `SolverParameters.remesh.targetQuads` is the primary control; the Auto-Retopo UI
  exposes it as Coarse / Medium / Fine presets (≈600 / 1500 / 4000).
- If `WeaveConstraints.density` is set, its `targetEdgeLength` scales
  `RemeshParameters.edgeScale` (finer edge → smaller scale), so the constraint refines
  the budget locally-in-spirit even though this slice applies it globally.

No new engine work — it is parameter mapping.

## Symmetry → mirrored output (single mirror axis)

`applySymmetry(settings, axis:)` already mirrors every face wholly on the working side
and welds on-plane vertices. So a GUARANTEED-symmetric cage is: remesh, keep only the
working side, then mirror it.

Steps (in `EngineRemeshSolver`, when `constraints.symmetry` is enabled with ≥1 mirror
axis — this slice uses the first):
1. Remesh the Target → cage `M`.
2. **Clip to the working side (whole-face).** Delete every face with ANY vertex on the
   far side of the plane, leaving only faces WHOLLY on the working side. Clipping by
   whole-face (not centroid) is what makes the result symmetric: `applySymmetry` mirrors
   only faces wholly on the working side, so a straddling face left by a centroid clip
   would stay un-mirrored and break symmetry. (Orphan vertices left by the delete are
   dropped by the payload round-trip on accept.)
3. **Snap the seam.** `snapSymmetryPlane(settings)` moves vertices within the weld
   tolerance of the plane exactly onto it, so the mirror welds cleanly.
4. **Mirror + weld.** `applySymmetry(settings, axis:)` reflects the working side, welds
   the seam, and (optionally) re-snaps to the Target.

The result is exactly symmetric about the plane. The clipped boundary is as ragged as
the remesh made it (the remesher is not plane-aware), so the seam is symmetric but not
guaranteed-clean quads — acceptable for this slice; a plane-aware solve is the research
solver's job.

## Key decisions

### D1 — Orchestration only, still inside design rule D1
Both paths call EXISTING engine ops (`cyber_remesh`, `deleteFaces`, `snapSymmetryPlane`,
`apply_symmetry`). The solver only sequences them; no quadrangulation math moves into
Swift.

### D2 — Determinism preserved
`cyber_remesh` is bit-deterministic (verified in the pipeline change), and the clip
(centroid sign), snap, and mirror are deterministic engine ops, so the whole solve stays
deterministic — the same document + density + symmetry yields an identical cage.

### D3 — Single mirror axis this slice
Multi-axis (quadrant) and radial symmetry are non-goals; the solver honours the first
enabled mirror axis and ignores extra axes / radial (documented, not silently wrong).

### D4 — Constraints threaded from the document
The Auto-Retopo trigger reads the document's `SymmetrySettings` into
`constraints.symmetry` and the chosen density into `params`, so "symmetric document →
symmetric retopo" needs no separate toggle.

## Risks / Trade-offs

- **Ragged seam** after clip+mirror → acceptable, noted; the interface is symmetric,
  just not optimally-quaded. Relax/edit tools work on it normally.
- **targetEdgeLength → edgeScale mapping is approximate** (no surface-area term) → the
  primary control is the explicit targetQuads preset; the density-field mapping is a
  secondary refinement.
- **Target not symmetric** → clip+mirror still yields a symmetric CAGE (it mirrors the
  working side regardless), which is the requested behaviour; the far side simply won't
  match the Target there. Documented.
