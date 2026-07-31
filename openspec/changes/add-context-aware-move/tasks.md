# Tasks: add-context-aware-move

## 1. The scope decision

- [x] 1.1 `MoveScope` on the session — `.vertex(UInt32)`, `.loop([UInt32], seed:)`,
      `.surface(seed:)` — resolved once in `strokeBegan`, read by every sample (design D1).
- [x] 1.2 Pick order vertex → edge → face. Both candidates are gathered with the existing
      grab radius FIRST and then judged against the cell windows — nesting the edge query
      inside a successful vertex grab made loop scope unreachable on a coarse cage and left
      the stroke inert (design D2, "Corrected during implementation").
- [x] 1.3 `vertexWindow` / `edgeWindow` as fractions of the local cell, reusing the measure
      behind `mergeRange(around:in:sceneRadius:)`, both < 0.5 cell (D3). NO scene-derived
      floor: a floor wins on any cage smaller than the scene, reinstating the bug. An
      unmeasurable cell resolves to vertex scope instead, which is the guarantee the floor
      was meant to provide.
- [x] 1.4 Loop from `edgeLoopVertices(from:)`; fewer than 3 vertices degrades to the picked
      edge's two endpoints (D4).

## 2. The move itself

- [x] 2.1 `Mesh.moveVertices(_:by:pinned:snapping:)` in CyberKit: one displacement applied to a
      set, each vertex re-snapped, pinned vertices excluded (D6).
- [x] 2.2 `applyBrush` dispatches on scope — `moveVertices` for vertex AND loop scope (not
      `tweakVertex`, which ignores pins by design), `moveWithGeodesicFalloff` unchanged for
      surface scope.
- [x] 2.3 Anchor advances per sample in every scope, so displacement integrates the same way.
- [x] 2.4 Journal verbs `move.vertex` / `move.loop` / `move`, merge suffix composing as today
      (D7).

## 3. Merge, narrowed by scope

- [x] 3.1 Merge-on-release runs for vertex and surface scope only.
- [x] 3.2 Loop scope never registers a merge candidate, so no "Merge" hint appears for it.

## 4. Naming the scope

- [x] 4.1 `ViewportInputModel` carries the scope name ("Vertex" / "Loop" / "Surface") while a
      Move drag is live; cleared on end and on cancel.
- [x] 4.2 Shown in the chip slot the "Merge" hint uses. Decide precedence when a vertex drag
      also holds a merge — proposal: the merge wins, being the outcome-bearing statement.
- [x] 4.3 Action Gallery help text for Move updated to describe the three scopes.

## 5. Tests

- [x] 5.1 Vertex scope moves ONE vertex: neighbours' positions unchanged (the assertion that
      fails today, since the falloff carries them).
- [x] 5.2 Loop scope displaces every `edgeLoopVertices` member and nothing else.
- [x] 5.3 Loop rigidity: adjacent-vertex spacing preserved within snap tolerance.
- [x] 5.4 Moved vertices reproject onto the Target — asserted at the CyberKit level against a
      TILTED plane (z = 0.5x), where a vertex that failed to reproject is trivially visible.
- [x] 5.5 Unwalkable loop (pole / boundary) moves the picked edge's two vertices, not zero.
- [x] 5.6 Scope survives the drag: begin on a vertex, pass over an edge, still one vertex moved.
- [x] 5.7 Density independence: same touch offset on a coarse and a fine cage resolves to the
      same scope (the regression guard for the scene-relative window).
- [x] 5.8 Vertex scope still merges on release; loop scope releases over a neighbour WITHOUT
      merging and keeps its vertex count.
- [x] 5.9 Pins: a pinned vertex inside a dragged loop does not move.
- [x] 5.10 Surface scope unchanged — `moveDragsWithGeodesicFalloffIgnoringDisconnectedComponent`
      re-anchored from the vertex at (0,1) to the face interior at (0.6,0.55), with a note
      saying why; the merge test's verb is now `move.vertex.mergeSnap`.
- [x] 5.11 Mirror the CyberKit op tests into the device target in `project.yml`.

## 6. Device verification

- [x] 6.1 Ran on iPad Air 13-inch (M3): 1126 tests, including the mirrored
      "Move vertices ops" suite. Passed.
- [~] 6.2 Device: vertex and edge-loop drags confirmed working on the iPad. The face/patch
      stretch was BROKEN and is fixed (6.3); needs one more device pass to confirm, along with
      the chip naming each scope and a loop holding its shape over a curved Target.
- [x] 6.3 Device testing found the windows wrong: vertex and loop scope worked, but starting
      on a face/triangle no longer stretched the patch. The edge window was sized against the
      vertex window instead of against the FACE INTERIOR — at 0.35 only 9% of a square cell
      (measured: 11%) was surface scope, and a triangle, whose incenter is ~0.26 of its mean
      edge from any side, had NO surface region at all. Now 0.25 / 0.15, with the face
      interior back to ~60% of a cell (design D3).
