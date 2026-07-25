# Proposal: add-grid-continuation

## Why

Drawing a quad against the multi-row edge of an existing grid drops ONE big
undivided quad floating against that edge (reported bunny case: the drawn panel
did not pick up the neighbouring 4 rows). CozyBlanket instead fills the drawn
region with rows that CONTINUE the neighbour's edge loops — welded onto the
boundary, matched to its cell size — so the new patch is animation/sculpt-ready
uniform topology, not a lone oversized face.

An earlier attempt subdivided every drawn quad by size alone; that wrongly split
legitimate single quads (a standalone quad, the first quad on an empty mesh, a
one-cell append). The correct trigger is TOPOLOGY, not size: only a quad drawn
against a genuinely subdivided boundary continues loops.

## What Changes

- **A quad drawn against a subdivided existing boundary continues its loops.**
  When a drawn quad's side snaps onto an existing boundary chain of ≥ 2 cells,
  that chain is extruded across the drawn region (`extendBoundary`): the new
  quads WELD onto the boundary and continue its edge loops, one welded column
  per neighbour-cell of drawn depth, at the neighbour's cell size.
- **Everything else stays a single welded face.** A triangle, a standalone quad
  (no neighbour), or a one-cell append (single-edge neighbour, or a shared side
  shorter than ~1.5 neighbour cells) is a single welded face exactly as before.
- Any engine rejection of the extrusion falls back to a single welded face, so
  no stroke is ever lost.

## Impact

- Affected specs: `pencil-interaction` (MODIFIED: create-face continues an
  adjacent subdivided boundary's loops; ADDED scenarios).
- Affected code: app-side `MeshEditController.buildCreatedFace` /
  `continueAdjacentBoundary` / `boundarySubChain`, routing both the live and the
  swap create paths through it. No engine change — it composes the existing
  `boundaryChain`, `extendBoundary`, `nearestVertex`, and `nearestEdge` ops.
- Affected tests: `PatchFillTests` (continuation, multi-column, one-cell append
  stays single, standalone stays single, triangle stays single); the existing
  single-quad create tests remain green.

## Non-Goals

- Respecting a curved / non-parallel drawn far edge — the continuation extrudes
  parallel welded columns (a parallelogram fill snapped to the Target), which
  matches a hand-drawn rectangular patch.
- Continuing loops across more than one shared side at once (e.g. an interior
  hole bounded on multiple sides) — a single shared side per stroke.
- Any explicit "patch fill" tool/mode; this is the plain quad-draw gesture
  becoming topology-aware.

## Notes

`extendBoundary` (engine `cyber_retopo_extend_boundary_grid`) welds each ring
onto the previous and corrects winding against the existing face on the chain's
first edge, so orientation is handled engine-side. The number of continued rows
is inherited from the shared chain; the number of columns is drawn-depth ÷
neighbour cell size, clamped to `maxPatchDimension`.
