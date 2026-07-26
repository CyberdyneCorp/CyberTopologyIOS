# Tasks: add-weave-region-selection

Selection, domain construction, session and presentation over the API
`add-weave-regional-solve` already shipped. **No engine change** — every primitive
this needs already ships (`cyber_mesh_boundary_loop`,
`cyber_retopo_extend_boundary_grid` with a Target snapper, `cyber_mesh_set_solve_region`).
If a task here turns out to need one, it is out of scope and belongs in 5.4b.

## 0. Feasibility spike — RUN 2026-07-26. **GROWING WORKS. The falsifier did not fire.**

- [x] 0.1 `WeaveFillSpikeTests`: a 4x2 quad cage covering the lower band of a domed
      24x24 triangle Target; walk its free edge; `extendBoundary` 2 rows with the
      Target snapper; region-solve exactly those 8 seed faces with the cage frozen.
- [x] 0.2 Measured, after the density fix below:

      (a) cage vertices moved 0/15, cage face rings changed 0/8
      (b) orphaned interface vertices 0 — manifold across the seam
      (c) irregular interface vertices 0/5, seam triangles 1
      (d) seed deviation from Target 7.5e-09; SOLVED deviation 0.0126 = 0.031 quads

- [x] 0.3 **(d) does not fire.** The solved band sits 3% of a quad off the Target, so
      building the `ReferenceSurface` from cage+seed rather than from the Target is a
      quality detail, not a blocker. **5.4b stays a follow-up** — and that downgrade is
      now measured rather than assumed, which was the point of asking.
- [x] 0.4 **The spike found a real bug, and it was load-bearing.** `validate()` floored
      `targetQuadCount` at 100 — a whole-mesh assumption. The prescribed budget for the
      seed band was 7 quads, silently clamped to 100, and the solve produced **77 faces,
      11x too fine**, with **4 of 5 interface vertices irregular**. That floor defeated
      `prescribedQuadBudget` outright, i.e. the spec's "auto-filled regions match manual
      scale with no dials". Fixed in patch 0006: the floor is 4 when a region is present,
      100 otherwise. After the fix the same solve produces 5 faces and **0/5 irregular**.
      A 6x-too-dense patch welded onto a coarse cage is wrong output however clean its
      seam, so this is the right trade — but it is a trade: the coarser solve leaves
      residual SEAM TRIANGLES the quadrangulator cannot pair (4 on the 6x6 proof
      fixture, 1 here). They are reported via `interfaceTriangles`; reducing them belongs
      with 5.3a. The `add-weave-regional-solve` interface goldens were regenerated —
      they had been recorded at the clamped density.

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
