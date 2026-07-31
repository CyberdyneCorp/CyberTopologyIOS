# Paint a part of the Target and auto-retopologize only that

## Why

Asked on device: *"Can we have a feature where we paint some parts of the target and do the
auto-retopology (using our library) only on the painted part?"*

Auto-Retopo is all-or-nothing today: it remeshes the entire Target and hands back a whole new
cage. That is the wrong granularity for the actual workflow — an artist hand-authors the parts
that need judgement and wants the solver to fill a specific bare area (a haunch, an ear, the
back), leaving everything else alone.

The pieces are already in place and unused:

- `AutoRetopoSession.run` takes `region: SolveRegion` and forwards it to the solver.
- `SolveRegion.faces([UInt32])` is declared — and `EngineRemeshSolver` REFUSES it
  (`WeaveSolver.swift:250`), so the app can only ever pass `.wholeMesh`.
  `add-weave-region-selection` recorded this exact dormancy: "nothing in the app produces a
  region".
- `SurfaceSnapper.raycast` already reports the **Target face id** under a point, so painting
  produces face ids directly.
- The ghost + Accept/Discard bar, the progress reporting, and off-main solving all exist.

## What Changes

- **A Paint Region tool**: paint over the Target to mark the faces to retopologize. Painted
  faces are highlighted so the extent is visible before committing to a solve.
- **`EngineRemeshSolver` honours `.faces`** by carving a sub-Target — duplicate the source,
  delete everything unpainted, remesh what remains. The existing whole-mesh remesher then
  produces a cage covering exactly the painted area, with its own open boundary. No engine
  change: `duplicated()`, `deleteFaces` and `remeshed` all ship today.
- **Accepting MERGES the patch into the existing cage** rather than adding an object: the
  patch's faces are appended to the current EditMesh, so the artist keeps one cage. The seam is
  NOT welded — border vertices stay coincident until merged deliberately, which the existing
  drag-merge and Merge Pair already do. When there is no cage yet, the patch becomes it.
- **The paint clears after each run**, so a second run never inherits a stale extent.

Non-goals: no welding of the patch seam (a separate, deliberate operation); no per-region
density (the existing density control applies); no persistence of the mask in the document — it
is viewport state, cleared on run.

## Capabilities

### New Capabilities

- `retopology-tools`: painting a region of the Target restricts auto-retopology to it, and the
  result merges into the existing cage.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirements).
- **Affected code**: `CyberKit/Sources/CyberKit/WeaveSolver.swift` (region carve),
  a new `CyberKit/Sources/CyberKit/MeshAppend.swift` (patch merge over `buildFace`),
  `App/Sources/MeshEditToolSession.swift` + a paint session (Target face collection),
  `App/Sources/AutoRetopoSession.swift` (region plumbed to the run, merge on accept),
  `ActionCatalog` + toolbar entry.
- **Risk**: the carve runs on a 69k-face Target, and the paint collects faces by raycasting the
  brush footprint per sample — both are per-gesture costs on the main actor, so they are
  measured rather than assumed.
