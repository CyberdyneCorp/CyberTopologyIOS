# Tasks: add-uv-sets-and-stacking (6.7, first slice)

## 1. Engine — UDIM
- [x] 1.1 Tile index/coordinate conversion in standard numbering (1001 + u + 10·v).
- [x] 1.2 Derive an island's tile from its UV bounds; never store an assignment.
- [x] 1.3 Occupied-tile list, ascending and deduplicated.
- [x] 1.4 Straddle detection, with a flush-to-edge island NOT counted as straddling.
- [x] 1.5 Move an island to a tile by a WHOLE number of tiles.

## 2. Engine — stacking
- [x] 2.1 Mirror-pair finding by reflected face centroids, tolerance relative to island size.
- [x] 2.2 Islands on the plane are not self-paired; each island in at most one pair.
- [x] 2.3 Corner correspondence by reflected VERTEX POSITION, staged so a partial match writes
      nothing.
- [x] 2.4 Tests, including per-corner correspondence (a bounds check would pass a scrambled
      shell) and a mutation check that index-matching fails.

## 3. C API + patch
- [x] 3.1 Tile query, retile, straddle query, stack.
- [x] 3.2 Shared island-partition helper so every localized UV op agrees on what an island is.
- [x] 3.3 Patch-stack entry (0018).

## 4. CyberKit
- [x] 4.1 `udimTiles()`, `assignIsland(containing:toTile:)`, `straddlingIslands()`,
      `stackMirroredIslands(planePoint:planeNormal:)`.
- [x] 4.2 Tests, including that a query returns empty without a layout while a MUTATION refuses.

## 5. App
- [x] 5.1 Stack command, journaled as one step, refusing unless a mirror axis is enabled.
- [x] 5.2 UDIM readout in the panel: tiles shown only when more than one is occupied, straddles
      always called out.
- [x] 5.3 Action Gallery entry.

## 6. Close out
- [x] 6.1 validate; engine, simulator, device.
- [x] 6.2 Master 6.7 entry; split multiple UV SETS out as 6.7a with the OBJ-payload reason.
