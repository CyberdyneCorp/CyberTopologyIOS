# Tasks: add-grid-continuation

## 1. App-side create path (no engine change)

- [x] 1.1 `continueAdjacentBoundary`: snap the drawn quad's corners to existing
      vertices (radius capped to the quad's own scale); find a side whose two
      corners snap to distinct existing vertices.
- [x] 1.2 `boundarySubChain`: from the shared side, take the boundary loop
      through the nearest boundary edge and return the arc between the two
      snapped vertices (shorter arc for a closed loop, linear slice otherwise).
- [x] 1.3 Fire only when the chain spans ≥ 2 cells AND the shared side spans
      ≥ ~1.5 neighbour cells (so a one-cell append stays a single quad);
      extrude with `extendBoundary` (rings = drawn depth ÷ cell, clamped to
      `maxPatchDimension`) and fall back to a single welded face on any
      rejection.
- [x] 1.4 Route both the live create path and the swap/alternative create path
      through `buildCreatedFace`.

## 2. Tests (device + simulator, app-hosted)

- [x] 2.1 A quad against a subdivided boundary continues its loops (rows match
      the neighbour, boundary vertices reused not duplicated).
- [x] 2.2 A deeper region continues into several welded columns.
- [x] 2.3 A one-cell append against a single edge stays a single quad.
- [x] 2.4 A standalone quad, and a triangle, stay a single face.
- [x] 2.5 The existing single-quad create tests (`MeshEditControllerTests`
      journaled / append / tall-thin) still pass.

## 3. Validation

- [x] 3.1 `openspec validate add-grid-continuation --strict`.
- [x] 3.2 Full app-hosted suite green on simulator (759 tests). Device pending.
