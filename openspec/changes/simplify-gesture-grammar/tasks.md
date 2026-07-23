# Tasks: simplify-gesture-grammar

Ordered by dependency. Step 1 is a prerequisite for step 3 — re-tuning
against synthesized strokes has already failed twice.

## 1. Real-stroke corpus (prerequisite)

- [x] 1.1 Capture 3-5 real failing quad strokes on device with the task-1.1b
      fixture recorder. Committed under
      `CyberKit/Tests/CyberKitTests/Fixtures/DeviceStrokes/` — NOT
      `Fixtures/Strokes/`, which is a synthetic corpus whose every file must
      match a code generator (`corpusMatchesGenerators`) and replay to its
      expected outcome; captured strokes satisfy neither. Four strokes, one
      per side of a central quad, each an open "U" adjacent to the shared
      edge; all recorded `shape=unknown; none:0.20` on device. Provenance
      (device, Target, intent, what the recognizer answered) is embedded in
      each fixture and summarized in `DeviceStrokes/PROVENANCE.md`.
      (Deferred: overshoot / stop-short / curved-surface variants — the four
      adjacent-quad captures already reproduce the bug; add the others if the
      re-tune needs more geometry.)
- [x] 1.2 `DeviceStrokeCorpusTests` asserts each capture resolves to
      `createQuad` through the real engine recognizer. Failing by design
      today, wrapped per-fixture in `withKnownIssue` so the suite stays green
      while the bug is documented; when the re-tune lands, each known issue
      resolves and Swift Testing flags it as unexpectedly passing. This is
      the acceptance criterion for task 3.

## 2. Curate the grammar

Revised target (device feedback): the kept GESTURES are **CreateQuad,
CreateTriangle, DeleteFaces (X), and InsertLoop (line crossing a face ring)**
— not the proposal's original strict three. Everything else (tagLoop,
mergeVertices, toggleVisibility, dissolveEdge, rotateEdge, hideRegion,
createGrid) leaves the stroke path and stays as an armed tool.

- [x] 2.1a **CreateTriangle added** (engine patch 0024): a closed stroke
      whose corner estimate is a non-degenerate THREE-corner ring resolves to
      `createTriangle`; four stays `createQuad`. Detection is conservative —
      `polygonCorners` rejects near-collinear "triangles" (area/perimeter²),
      so a flat lasso started at a tip is NOT a triangle, and the rescue path
      (open strokes) always estimates a quad, since an open stroke's ends
      make the seam-corner test meaningless. Full stack wired: engine enum,
      `CYBER_ACTION_CREATE_TRIANGLE` (appended, values stable), Swift
      `Action.createTriangle`, welded apply + alternative-swap, chip label.
      Corner-to-corner and mid-edge triangles both detected; validated by
      `closedTriangleResolvesToCreateTriangle` with the square/lasso/device
      corpus held unchanged. On-device corpus validation of real triangle
      strokes is the next step, mirroring the quad flow.
- [x] 2.1b Engine (patch 0029): `interpretStroke` restricted to the four
      kept gestures — Line emits only InsertLoop (a line crossing edges),
      Circle emits only CreateQuad, Grid falls through to None, and
      tagLoop/mergeVertices/toggleVisibility/dissolveEdge/rotateEdge/
      hideRegion/createGrid are no longer emitted. The quad/triangle rescue
      runs before grid/scribble so the wigglier U no longer trips grid
      detection. Corpus + device-stroke tests assert the new resolutions and
      pass through a clean engine rebuild.
- [x] 2.2 App (`ActionCatalog`): the removed gestures' gallery help text no
      longer calls them Pencil gestures. mergeLine/scribbleDissolve point at
      the Merge pair TOOL (real coverage); gridStroke/loopTag/edgeRotate/
      visibilityLasso/visibilityLines are marked retired-from-grammar with the
      capability returning as an armed tool (see Deferred). The enum cases stay
      (persisted toolbars + tests reference them) but describe reality; the
      `.pencil` and `loopInsert` notes drop the stale grid/tag-swap language.
- [x] 2.3 Interpretation chip: alternatives are limited by what the engine
      emits — only the four kept actions — and the swap path
      (`performReplacingLast`) is unchanged. The action-agnostic state-machine
      tests were re-based off the retired tagLoop/toggleVisibility fixtures
      onto the one plausible curated ambiguity (quad vs triangle).
- [x] 2.4 Gesture-level tests/goldens for the removed actions retired
      (StrokeInterpreter, MeshEditController, App swap tests, corpus goldens);
      the underlying mesh OPS keep tool-level coverage in `GrammarMeshOpsTests`
      (dissolve/merge/rotate/grid/hide/tag), since only the gesture bindings
      were removed. No capability lost its op coverage.
- [x] 2.5 `tests/traceability.yaml` pencil-interaction + gesture-regression
      lists rewritten to the four-gesture reality; proposal and the
      pencil-interaction spec delta reconciled from the original strict-three
      to the shipped four (InsertLoop kept). `check_traceability.py` green.

## 3. Re-tune closed-vs-open

- [x] 3.1 Seam-tolerant self-intersection counting (engine patch 0026):
      `countSelfIntersections(pts, seamWindow)` ignores crossings between a
      leading and a trailing segment — closing a hand-drawn quad overshoots
      the start, and that seam crossing must not demote the loop to Lasso.
      An interior crossing (an X, a scribble) still counts. Driven by two
      real device captures (`quad_closed_smooth_a/b`) that were misread as
      lasso until this landed.
- [x] 3.2 Nearly-closed rescue: landed as engine patch
      `0023-stroke-nearly-closed-quad-rescue`. An open stroke that bounds a
      recoverable quad ring (no self-crossings, not straight, endpoints
      within `nearlyClosedFraction`=0.65 of the perimeter) classifies as a
      ClosedLoop. Placed LAST in `classifyShape`, so it only ever upgrades a
      would-be Unknown and cannot steal a grid/scribble/cross — which is why
      it works WITHOUT the task-2 grammar cut and breaks no synthetic
      fixture. Gated on geometry, not a corner-count threshold: two of the
      four device strokes are drawn smoothly and register < 2 sharp corners.
- [x] 3.3 Driven by the task-1.1 device corpus. `DeviceStrokeCorpusTests`
      now asserts (plainly, no longer `withKnownIssue`) that all four real
      quad strokes resolve to `createQuad`. The X fixture still resolves to
      `deleteFaces` (the rescue does not touch self-intersecting strokes).
- [x] 3.4 Full suite green: 560 app + 268 CyberKit, zero regressions.

## 4. Weld created faces onto existing topology

- [x] 4.1 `Mesh.createWeldedFace(at:mergeRadius:snapping:)` (CyberKit): each
      corner within `mergeRadius` (the tool's `mergeSnapRadiusFraction` of the
      scene) of an existing vertex resolves to `.existing` UP FRONT, so
      `buildFace` corrects the new face's winding against the reused boundary
      edge, then a safety-net merge folds any leftover new vertex onto a
      coincident existing one. Follows the Build Quad tool's release-merge
      semantics (app-side resolution via `buildFace`) rather than a new C API.
      Corner-on-edge splitting is deferred: vertex reuse already yields the
      reference counts for the adjacent-quad case; edge-splitting is a
      refinement for corners landing mid-edge.
- [x] 4.2 `MeshEditController` gesture `createQuad` (and the alternative-swap
      rebuild) route through it. The weld's `buildFace` + merges run inside
      the closure `applyCreate` executes within the stroke's one
      `MeshEditTransaction`, so a single undo removes the whole welded face.
- [x] 4.3 `BuildToolsOpsTests/weldedFaceSharesEdgeWithAdjacentQuad`: one quad
      (4v/4e/1f) + an adjacent quad sharing an edge yields exactly 6v/7e/2f,
      and the shared edge borders both faces.
- [x] 4.4 `weldedFaceFarFromTopologyIsStandalone` (a far quad still adds 4
      new vertices, stays disconnected) plus `weldedFaceOnEmptyMeshCreates-
      Standalone` (first stroke of a retopo). Full suite green: 560 app +
      271 CyberKit.

## 5. Deferred / explicitly out of scope

- **Tool-ifying the gesture-only capabilities without an existing tool.**
  The design keeps grid fill, loop tag, edge rotate and region hide/show as
  armed tools, but only merge/dissolve currently have one (the Merge pair
  tool). Building dedicated arm-a-tool paths for createGrid, tagLoop,
  rotateEdge and hideRegion/toggleVisibility is a follow-up; until then their
  underlying ops keep coverage in `GrammarMeshOpsTests` and their gallery
  tiles say so. Their `EditorAction` cases remain so persisted toolbars and
  the batch panel keep resolving.
- Auto Relax after welded creation (task 4.5a of the parent change already
  tracks the missing create paths).
- Restoring any removed gesture as a MODIFIED gesture (e.g. delete-faces via
  a different stroke) — if the four-gesture set proves too small, that is a
  new proposal with its own device evidence.
