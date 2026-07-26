# Tasks: add-weave-region-selection

Selection, session and presentation over the API `add-weave-regional-solve` already
shipped. No solver or engine change — if a task here needs one, it is out of scope
and belongs in 5.4b.

## 1. The armed tool

- [ ] 1.1 `RetopoTool.weaveRegion` + an `EditorAction` case, toolbar-assignable and
      listed in `ActionCatalog` with a help panel that says PAINT over faces, and says
      why it is not a lasso (the retired `visibilityLasso` entry is the precedent for
      recording that honestly).
- [ ] 1.2 `isCameraManipulator = false` — the camera is not the manipulator here; the
      stroke is. It arms like Pin Flip / Guide, not like Patch Clone.
- [ ] 1.3 `commitToolStroke` `.weaveRegion` case: resolve the painted faces via
      `strokeSurfaceHits` (the Patch Clone path, `MeshEditCameraTools.swift:213`), UNION
      into the current selection, journal NOTHING.

## 2. The session

- [ ] 2.1 `WeaveRegionSession` on `MeshEditController`: the selected face ids, the
      chosen density, and the pending `SolverGhost`. Not journaled, not persisted — it
      is a view of an intent, not document state.
- [ ] 2.2 Clearing: a `clearWeaveRegion` action, and automatic teardown when the
      document snapshot changes underneath (the Patch Clone precedent —
      `onDiscardLiveEdits` / external undo must not leave a selection pointing at dead
      face ids).
- [ ] 2.3 The selection must be validated against the LIVE mesh before every solve:
      face ids can die under an undo, and `cyber_mesh_set_solve_region` refuses a dead
      id (correctly). Drop dead ids and report the drop rather than failing the solve.

## 3. Solving

- [ ] 3.1 `beginWeaveRegionSolve`: build `WeaveConstraints`, run
      `CompositeWeaveSolver` with `.faces(selection)` over the EDITMESH (Design
      Decision 1) off the main thread, reusing `solveOffMain`'s payload+report shape.
- [ ] 3.2 Present through the existing amber ghost + Accept/Discard bar. The region
      notice from task 13.3 already surfaces irregular interface vertices and seam
      triangles — verify it appears on this path too.
- [ ] 3.3 Show the derived quad budget (`RegionWeaveSolver.prescribedQuadBudget`) in the
      banner BEFORE solving, so the user sees the density the patch will get.
- [ ] 3.4 Accept commits as ONE journal entry and one undo restores the pre-accept bytes.

## 4. Live re-solve

- [ ] 4.1 Re-solve when the selection or density changes while a session is armed;
      debounce so a multi-stroke selection does not launch a solve per stroke.
- [ ] 4.2 **Generation-token the in-flight solve.** A superseded result must be dropped,
      not presented — the 3.5 interpretation chip already had to solve exactly this and
      its `generation` token is the precedent to copy.
- [ ] 4.3 Re-solving journals nothing, and a re-solve replaces the pending ghost rather
      than stacking a second one.

## 5. Tests

- [ ] 5.1 Selection: painting selects the crossed faces; a second stroke UNIONS; clearing
      empties; none of it journals.
- [ ] 5.2 A dead face id (selection, then undo) is dropped rather than failing the solve.
- [ ] 5.3 Accept journals exactly once and one undo restores byte-exactly; discard
      journals nothing. Assert on the LIVE handle, not a payload round-trip.
- [ ] 5.4 Unselected faces are unchanged across an accepted region solve — same id, same
      ring, bitwise identical positions. This is the user-visible form of the guarantee.
- [ ] 5.5 Density change re-solves and replaces the ghost; the document stays unchanged.
- [ ] 5.6 A superseded in-flight solve never becomes the presented ghost.
- [ ] 5.7 A UI test driving the REAL tool: arm, paint, solve, accept, undo.

## 6. Validation

- [ ] 6.1 `openspec validate --changes --strict`.
- [ ] 6.2 Full app-hosted suite green on the simulator; no golden regenerated.
- [ ] 6.3 Update `add-cybertopology-app/tasks.md`: tick 5.4a's lasso-region clause with
      the painted-selection correction stated, and add **5.4b** for the external
      reference surface (Design Decision 3) so a re-woven patch can follow the Target
      instead of the cage.
