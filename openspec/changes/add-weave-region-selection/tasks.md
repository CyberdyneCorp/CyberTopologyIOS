# Tasks: add-weave-region-selection

Selection, domain construction, session and presentation over the API
`add-weave-regional-solve` already shipped. **No engine change** — every primitive
this needs already ships (`cyber_mesh_boundary_loop`,
`cyber_retopo_extend_boundary_grid` with a Target snapper, `cyber_mesh_set_solve_region`).
If a task here turns out to need one, it is out of scope and belongs in 5.4b.

## 0. Feasibility spike (FIRST — this project's pattern, and it has paid twice)

- [ ] 0.1 Headless, in `CyberKitTests`: take a cage that partially covers a domed
      Target, walk its open boundary, `extendBoundary` two rows with the Target
      snapper, then region-solve exactly those new faces with the cage frozen.
- [ ] 0.2 Report: (a) do the cage's boundary vertices survive bitwise, (b) is the
      result manifold across the seam, (c) how many interface vertices come out
      irregular, (d) does the filled band actually lie on the Target (max deviation).
- [ ] 0.3 **(d) is the falsifier.** The seed is snapped, but the region solve
      reprojects onto a ReferenceSurface built from cage+seed, not the Target — if
      deviation is large at a coarse seed, 5.4b stops being a quality improvement and
      becomes a prerequisite, and the rest of this change waits on it.

## 1. Domain construction (CyberKit)

- [ ] 1.1 `WeaveFillDomain.seed(cage:target:rows:)` — find the open boundary chain,
      grow `rows` snapped quad rows, return the new face ids. Refuse with a distinct
      reason when there is no open boundary.
- [ ] 1.2 Row count from the painted extent: grow until the extent is covered, capped
      (`extendBoundary` already floors the step at 1% of scene radius and caps rows —
      reuse that cap rather than inventing a second one).
- [ ] 1.3 The seed is scratch: it exists only inside the solve. A discarded proposal
      must leave NO seed rows behind — the document never sees them.

## 2. The armed tool

- [ ] 2.1 `RetopoTool.weaveFill` + an `EditorAction`, toolbar-assignable, with an
      `ActionCatalog` entry whose help says PAINT or TAP and says why it is not a
      lasso (the retired `visibilityLasso` entry is the precedent for recording that).
- [ ] 2.2 `isCameraManipulator = false`. Tap and paint are distinguished by
      `CameraToolStrokes.isTap`, the same test the camera tools already use.
- [ ] 2.3 Paint resolves the covered Target area via `strokeSurfaceHits` against the
      TARGET (Patch Clone resolves against the EditMesh — same helper, other mesh).

## 3. Session and solve

- [ ] 3.1 `WeaveFillSession` on `MeshEditController`: painted extent, row count,
      density, pending ghost. Not journaled, not persisted.
- [ ] 3.2 Solve off the main thread reusing `solveOffMain`'s payload+report shape,
      through `CompositeWeaveSolver` with `.faces(seedFaces)`.
- [ ] 3.3 Present through the amber ghost + Accept/Discard bar; verify task 13.3's
      region notice appears on this path.
- [ ] 3.4 Accept commits ONE journal entry; one undo restores the pre-accept bytes.
- [ ] 3.5 Teardown on external snapshot change (the Patch Clone precedent): an undo
      underneath must not leave a session pointing at dead ids.

## 4. Live re-solve

- [ ] 4.1 Re-solve when the extent or density changes; debounce so a multi-stroke
      paint does not launch a solve per stroke.
- [ ] 4.2 **Generation-token the in-flight solve** so a superseded result is dropped,
      not presented — the 3.5 interpretation chip's `generation` token is the precedent.
- [ ] 4.3 Re-solving journals nothing and replaces the pending ghost rather than
      stacking a second one.

## 5. Tests

- [ ] 5.1 Seeding: rows are welded to the cage boundary and lie on the Target; no
      open boundary refuses with its own reason.
- [ ] 5.2 Cage faces and boundary vertices are unchanged across an accepted fill —
      same id, same ring, bitwise identical positions, asserted on the LIVE handle.
- [ ] 5.3 The Target is byte-unchanged by a fill.
- [ ] 5.4 Accept journals exactly once and undoes byte-exactly; discard journals
      nothing AND leaves no seed rows in the document.
- [ ] 5.5 Painting further re-solves and replaces the ghost; document unchanged.
- [ ] 5.6 A superseded in-flight solve never becomes the presented ghost.
- [ ] 5.7 Bare Target disconnected from the cage is refused, not mis-filled.
- [ ] 5.8 A UI test driving the REAL tool: arm, tap, accept, undo.

## 6. Validation

- [ ] 6.1 `openspec validate --changes --strict`.
- [ ] 6.2 Full app-hosted suite green on the simulator; no golden regenerated.
- [ ] 6.3 Update `add-cybertopology-app/tasks.md`: tick 5.4a's region-UX clause with
      the painted/tap correction stated; add **5.4b** (external reference surface);
      record on **5.6** what tap-to-fill already delivers and what remains (deciding
      whether to solve speculatively on hover).
