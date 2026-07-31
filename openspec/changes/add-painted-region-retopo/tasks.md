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
- [x] 4.4 The Accept/Discard banner says which it will do — "merge into" for a region
      patch, "replace" for a whole-Target solve. It said "replace" for both, which told the
      artist their hand-authored topology was about to be discarded when it is appended to.

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

## 8. Device fix: output was quad-DOMINANT, not quads

- [x] 8.1 `EngineRemeshSolver` asks for pure quads. The engine defaults
      `pureQuads = false` and the app inherited it: measured on a carved bunny patch,
      242 of 441 faces were TRIANGLES and 35 were n-gons — the slivers reported as bad
      quality. Set on the whole-mesh remesh path, NOT on `SolverParameters`, because the
      engine refuses pureQuads for a prescribed-boundary region solve and those solves
      share the presets.
- [x] 8.2 Measured trade-off, recorded so the density presets are understood: pure mode
      cannot go as coarse as a low target asks (125 -> 1372 quads), because removing a
      triangle means splitting. The overshoot shrinks as the target rises (1500 -> 3130)
      and it was no slower (1.15 s vs 3.85 s for quad-dominant).
- [x] 8.3 `regionSolveReturnsPureQuads` guards it: zero triangles, zero n-gons.

## 9. Device fix: the patch was uneven, and the count did not mean what it says

Measured on a 440-face painted region of the bunny, quad areas as p90/p10:

- [x] 9.1 `adaptivity = 0` for a patch. The engine default is fully curvature-adaptive,
      right for a whole model and wrong for a painted region: **31.8x** size spread
      versus 2.9x at 0. A painted region is a statement that this area is an even grid.
- [x] 9.2 `holeFillMaxBoundary = 0` for a patch. The region's boundary IS the hole, so
      filling it returned a SEALED bubble — zero boundary edges — which merges into a
      cage as a closed shell instead of an open patch.
- [x] 9.3 The requested count applies to the PATCH. Scaling by the painted share starved
      the solve (500 asked over a 9% patch became 44), and starvation is what makes a
      cage uneven: 44 -> 15.4x, 250 -> 5.4x, 400 -> 3.6x, 600 -> 2.9x. Capped at four
      quads per source triangle so a whole-model budget on one ear cannot starve the
      machine.
- [x] 9.4 One policy, two callers: `EngineRemeshSolver.regionParameters` is applied both
      by the solver (a direct `.faces` request) and by `prepare` (which carves on the
      main actor and hands the boundary a whole mesh, so the solver can no longer tell).
- [x] 9.5 `regionPatchIsEvenAndOpen` guards spread < 6x, an open boundary, and a
      patch-sized face count; `aTinyRegionCapsTheRequestedCount` guards the cap.
## 10. OPEN: the patch BORDER is still spiky

Device verdict after 9: the interior grid is good, the perimeter is a ring of long thin
faces. The painted set's border zigzags at the TARGET's triangle scale and the remesher
honours it.

- [x] 10.1 Reproduced. It needs a DENSE Target: on the 4 968-face fixture the metric reads
      0 slivers, and the defect only appears once subdivided to 14 904 f (device: 69 451).
      The earlier dismissal of boundary smoothing was measured with an INTERIOR metric
      (quad-area spread), which cannot see this.
- [x] 10.2 Metric that sees it: per-face aspect ratio (longest over shortest edge). As
      shipped: worst 25:1, 38 of ~590 faces over 4:1.
- [x] 10.3 Measured in isolation, dilating the painted set by one ring halves the spikes
      (38 -> 14) and cuts the worst to 12:1; a closing (dilate 2, erode 2) gives 10.8:1
      with 19 spikes.
- [x] 10.4 The discrepancy is EXPLAINED, and it was a real bug: the region solve was
      NON-DETERMINISTIC. Three solves of one painted region returned 649, 631 and 603
      faces, one containing a 434 996:1 degenerate face. The remesher is deterministic —
      the CARVE was not. `deleteFaces` is order-sensitive (it compacts ids and prunes
      isolated vertices as it goes) and was handed `Array(Set)`, whose iteration order is
      arbitrary. Sorting the deletion list fixes it: three runs now agree exactly
      (611 f, worst 20.5, 16 spikes).
- [x] 10.5 Every quality number measured against this path BEFORE the sort was therefore a
      single sample of a distribution, not a measurement — including 10.2's 25:1 / 38 spikes
      and 10.3's "dilation halves the spikes". Guarded now by `regionSolveIsDeterministic`
      (byte-identical payloads) and `carveIsDeterministic`.
- [x] 10.6 FIXED with the reliable metric. The painted region grows by up to two face
      rings before the carve, so the remesher follows a fuller outline instead of a
      triangle-scale sawtooth. Measured across THREE patches of a 14 904-face Target
      (means): worst face aspect 24.5 -> 11.9, faces over 4:1 1.9% -> 1.4%, boundary edge
      count 157 -> 126. Two rings beat one on all three metrics.
- [x] 10.7 A morphological CLOSING was measured and rejected: erosion produced degenerate
      faces (277 294:1), presumably by pinching the region into slivers.
- [x] 10.8 Dilation is SELF-LIMITING (`regionDilationGrowthLimit` 1.5x). A ring is a fixed
      number of triangles, not a fixed distance: two rings grew a dense Target's patch by
      1.40x but took the coarse fixture's 400-face patch to 3220 — 65% of the model. It now
      keeps the last ring that stays inside the limit, so dense Targets get the full margin
      and coarse ones get little or none, which is right since their border already zigzags
      at quad scale.
- [x] 10.9 `regionDilationSmoothsTheBorder` guards it RELATIVELY — dilated versus raw on the
      same patch, fewer boundary edges and a better worst face — because the absolute
      numbers depend on the patch and the Target's density. Plus a hard ceiling (< 100:1) so
      a degenerate face like the closing's cannot slip back in.

## 6. Device verification

- [x] 6.1 Ran on iPad Air 13-inch (M3): 1185 tests, passed.
- [x] 6.2 CONFIRMED on device (iPad, 69 451-face bunny Target). Painted the shoulder, asked
      for 40 faces, accepted: the cage went 334 -> 419 faces as ONE EditMesh object, the patch
      covers the paint, the rest of the Target is untouched, and the teal extent read clearly
      while painting. The grid is near-uniform and the border is a smooth polygonal outline —
      the sawtooth and the spikes are gone.
- [x] 6.2a Observed and expected: 40 asked, 85 delivered. Pure-quad mode cannot go as coarse as
      a low target asks, since removing a triangle means splitting (measured 125 -> 1372 at a
      finer scale). The count is a request, not a contract, at the coarse end — the Action
      Gallery copy should say so.
- [ ] 6.2b Remaining, minor: a few step NOTCHES survive at concave corners of the mask. These
      are mask shape, not slivers — the dilation fills teeth but not notches. A closing would,
      and was rejected for producing degenerate faces (10.7), so any fix needs a different
      construction.
