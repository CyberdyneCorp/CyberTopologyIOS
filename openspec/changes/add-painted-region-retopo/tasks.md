# Tasks: add-painted-region-retopo

## 1. The region solve (CyberKit)

- [x] 1.1 `EngineRemeshSolver` honours `SolveRegion.faces`: duplicate the source, delete every
      face outside the region, remesh the remainder. Retires the `.wholeMesh`-only refusal —
      TWO tests pinned it (`WeaveSolverTests`, `RegionSolveOpsTests`), both rewritten.
- [x] 1.1a The quad budget follows the painted SHARE. Found the hard way: a 12-face carve at the
      raw 50 000-quad default did not finish inside a MINUTE, and the second obsolete test took
      156 s once it started really solving. Scaled, the same solve takes 0.104 s — and it is the
      right behaviour anyway, since a budget is a statement about the whole model.
- [x] 1.2 An empty region, or one naming every face, is refused clearly rather than aliasing to
      a whole-mesh solve.
- [x] 1.3 Dead face ids in the region are ignored, not fatal (the Target can be reloaded).

## 2. Merging the patch (CyberKit)

- [x] 2.1 `Mesh.append(_:)` over `buildFace` create-slots, with a vertex map so shared patch
      vertices stay shared. No welding to the receiving mesh.
- [x] 2.2 Positions are copied exactly — no re-snapping, which would move the solver's result.

## 3. Painting (App)

- [x] 3.1 A Paint Region tool session collecting TARGET face ids from `SurfaceSnapper.raycast`
      across the brush footprint.
- [x] 3.2 Painted faces highlighted in the viewport.
- [x] 3.3 Clear on run; not journaled, not persisted.

## 4. Wiring (App)

- [x] 4.1 `requestAutoRetopo` passes `.faces(painted)` when a region exists, `.wholeMesh`
      otherwise.
- [x] 4.2 Accept merges into the existing EditMesh, or creates it when absent; one journal entry.
- [x] 4.3 Action Gallery entry + toolbar slot.

## 5. Tests

- [x] 5.1 A region solve covers the painted faces and not the rest.
- [x] 5.2 Empty / all-faces regions refused.
- [x] 5.3 `append` preserves face and vertex counts and exact positions; the receiver keeps its
      own faces.
- [x] 5.4 Accept merges rather than adding an object; undo restores byte-exactly.
- [x] 5.5 No paint ⇒ whole-mesh solve, unchanged.
- [x] 5.6 The mask clears after a run and is absent after reopen.

## 7. Device fix: nothing happened on run

- [x] 7.1 Face ids were crossing the `payloadData()` boundary, which renumbers every element, so
      the off-main carve matched arbitrary faces or none — and the failure was swallowed as a
      silent nil. The carve now runs on the LIVE mesh in `prepare(target:region:params:)`; only
      geometry crosses, and a carve failure is logged (design D1).
- [x] 7.2 Regression tests: `theSolveDomainIsCarvedBeforeSerializing` (what crosses is the carve,
      budget scaled) and `faceIDsDoNotSurviveAPayloadRoundTrip` (the trap, stated once).

## 6. Device verification

- [x] 6.1 Ran on iPad Air 13-inch (M3): 1185 tests, passed.
- [ ] 6.2 Awaiting a device pass: paint the bunny's haunch, run, accept — the patch covers the
      paint, merges into the cage, and the rest of the Target is untouched. Also worth checking
      the brush footprint (`regionPaintRadiusFraction` 0.03 of the scene radius, a 9-point ring
      per sample) and that the teal extent reads against the Target.
