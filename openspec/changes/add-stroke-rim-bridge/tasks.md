# Tasks: add-stroke-rim-bridge

## 1. Engine recognizer (C++)

- [x] 1.1 `InterpretedAction::BridgeRims` in `stroke_interpreter.hpp`.
- [x] 1.2 `strokeCoversFace(proj, stroke)` helper — any sample in the middle 4/6 of the
      stroke over an existing face.
- [x] 1.3 `tryOpenStrokeBridgeRims`: near-straight stroke, endpoints snap to two distinct
      vertices, each on an open boundary, not already adjacent, and `!strokeCoversFace`
      → candidate `BridgeRims` with elements `[vertex A, vertex B]`.
- [x] 1.3a Also refuse a stroke that mostly runs ALONG existing edges
      (`fractionAlongEdges > 0.6`): tracing a rim passes the no-faces test too, and
      bridging two points of one rim stretch would throw a quad over the topology between
      them. Found by a test, not by reasoning.
- [x] 1.4 Gate the Line branch's `insertLoop` on `strokeCoversFace`.
- [x] 1.5 C ABI: `CYBER_ACTION_BRIDGE_RIMS` in `cyber_capi.h` + `toCAction` in `capi.cpp`.
- [x] 1.6 Patch-stack entry (0023).

## 2. CyberKit

- [x] 2.1 `StrokeInterpretation.Action.bridgeRims` + decode case.
- [x] 2.2 `MeshRimBridge.swift`: `Mesh.bridgeRims(from:to:maximumColumns:maximumRows:snapping:)`
      — rim resolution, direction choice, stop conditions, row count, quad emission,
      committed-ring id recovery. Typed failures, mesh unchanged on refusal.
- [x] 2.2a The rails fan out BOTH ways from the anchor pair — the pair is a
      correspondence, not the extent of the fill, so an anchor mid-rim still fills the
      whole corridor.
- [x] 2.2b Rung clearance is measured in RIM CELLS, not as a fraction of the rung: a
      rung-relative tolerance grows past the neighbouring rim vertices on a wide gap and
      refuses the multi-row bridges this op exists for. Caught by the divergence test.

## 3. App

- [x] 3.1 Apply `.bridgeRims` as one journaled `pencil.bridgeRims` element edit, with NO
      auto-relax (rim vertices must not move).
- [x] 3.2 Swap support: `canBuildReplacement` + `meshReplacement` cases.
- [x] 3.3 Chip label ("Bridge quads").

## 4. Tests

- [x] 4.1 Grammar: stroke across a gap between two rims → `bridgeRims` with both endpoint
      vertices as elements.
- [x] 4.2 Grammar REGRESSION GUARD: a line across a group of faces still → `insertLoop`
      with the full ring (`lineAcrossRingResolvesFullLoopInsert` stays green).
- [x] 4.3 Grammar: a gap-crossing stroke offers NO `insertLoop` candidate at all.
- [x] 4.4 Grammar REGRESSION GUARD: a bent stroke between two vertices still creates a
      quad/triangle; a straight stroke with no rim under an endpoint still creates
      nothing; a stroke ALONG a rim is not a bridge.
- [x] 4.5 Op: two facing rims bridge into a quad per paired step, extending past the
      anchors both ways; every rim vertex reused and unmoved.
- [x] 4.6 Op: a multi-cell-wide gap subdivides into rows; interior vertices are new,
      interpolated and created ONCE (the id-recovery proof).
- [x] 4.7 Op: diverging rims stop the walk; the column/row bounds hold; a vertex with no
      open rim, an adjacent pair, and two points of one rim stretch all throw and leave
      the mesh unchanged.
- [x] 4.8 Controller: applying the candidate journals exactly one entry and one undo
      restores the pre-stroke payload bytes.
- [x] 4.9 Mirror the new op suite into the app-hosted target in `project.yml` so it runs
      on DEVICE.
- [x] 4.10 Goldens: NO regeneration needed — the golden corpus is interpreted with no
      EditMesh (stage 1 only), and every rule this change touches needs a projection.

## 4a. Device report: the bridge was recognized and then refused

Manual device run (2026-07-29, 49v/34f cage, `quad_adjacent_pencil.stroke 25.json`): the HUD
read `line 0.93 on emptySurface; bridgeRims 0.75 [vertex:27,vertex:18]` and the EditMesh did
NOT change. The recognizer was right; `Mesh.bridgeRims` refused with `rimsDoNotFace`.

- [x] 4a.1 Cause: the notch the stroke crossed is closed on one side by a SUBDIVIDED wall,
      so a rim vertex sits at the wall's mid-height. Both rails step onto the wall's two
      ends, the span between them runs through that mid vertex, and the walk's clearance
      test read it as occupied topology — stopping with ZERO steps, so no pair survived and
      nothing could be built.
- [x] 4a.2 Fix: the clearance test belongs to the ANCHOR span only (where it still stops two
      points of one rim stretch). Past the anchors a span may legitimately run along
      existing topology.
- [x] 4a.3 Fix: a row point that lands ON an existing vertex REUSES it (bounded by both the
      cell and the row spacing), so the subdivided wall becomes a corner of both bridge
      quads instead of being left T-junctioned against a new edge.
- [x] 4a.4 Fix: a ring the engine refuses now ENDS the walk and keeps the columns already
      built, instead of failing the whole bridge; with nothing built the refusal still
      propagates.
- [x] 4a.5 Regression test `notchWithSubdividedWallBridges` reconstructs the device topology
      (one-cell-wide notch, two cells tall, subdivided left wall) and asserts 1 column x 2
      rows, ONE new vertex, and the wall vertex being a corner of BOTH quads. Verified it
      fails without the fix — `Caught error: rimsDoNotFace`, the exact device symptom.

## 4b. Second device report: it built, and built too much

Manual device run (2026-07-29, same cage, `quad_adjacent_pencil.stroke 26.json`): the notch
DID fill, but `49v/34f -> 55v/40f` — `+6 f` where the notch is 3, and `+6 v` where 2 were
needed. Two distinct defects behind one stroke.

- [x] 4b.1 THREE SKEWED QUADS over open Target. Past the anchors the upper rim turns UP the
      gap while the lower one still runs across it, and the walk kept pairing them: the
      parallel test passed (the two steps still had a positive dot on the domed surface) and
      the divergence bound passed (1.4x the first gap). Fix: neither rail may step ALONG the
      gap — |cos| against the current rung above `maximumStepAlongGap` (0.85) means the rim
      folded back up the corridor and has stopped bounding it. Measured 0.997 on the device
      case; a rim tapering at 45 degrees sits at 0.707.
      Test: `rimsFoldingAwayStopTheWalk`.
- [x] 4b.2 NO WELD ANYWHERE (`+6 v` = 3 rungs x 2 interior rows, all new), so the wall was
      left T-junctioned — a crack. Cause: a real cage is DOMED, so the straight chord
      between a wall's two ends bows away from the wall's own vertices, past any sane weld
      radius. Fix: read a closing wall's interior rows off the RIM PATH
      (`closingArc`) instead of interpolating and searching a radius — exact, and
      curvature-proof. A wall the cage already subdivided also DEFINES the row count, the
      same "continue the neighbour's loops" rule the grid fill uses.
      Test: `bowedWallVertexIsReused` (wall bowed 0.6 off the chord — a radius search cannot
      find it).
- [x] 4b.3 "Short arc" is the qualifier that makes 4b.2 safe: on a connected cage ANY two rim
      vertices are joined by SOME boundary arc, so a candidate wall must run roughly straight
      across the gap (`closingArcSlack` 1.5x) and stay within the row cap. The anchors' own
      arc detours around the notch (4x its span) and is correctly not read as a wall.

## 5. Close out

- [x] 5.1 `openspec validate add-stroke-rim-bridge --strict`.
- [x] 5.2 Engine C++ 358/358 (134794 assertions), unit suites 1083/1083 in 102 suites,
      device (iPad, `RimBridgeOpsTests` + `ContextAwareCreateFaceTests` +
      `MeshEditControllerTests`) 66/66 — the bridge walk and the recognizer's stage 2 both
      verified on hardware.
- [x] 5.2a PRE-EXISTING failures, NOT from this change: `CyberTopologyUITests`
      `testDrawQuadOnSeededTargetJournalsAndUndoes` (532/534) and
      `testRingStrokeInsertsLoopDirectlyWithoutAmbiguity` (594/595/598) both fail at the
      MULTI-FINGER undo/redo gesture assertions — the edits themselves succeed (the quad
      appears as `4 v · 1 f`; the ring stroke's chip reads "Insert loop" and the strip
      splits to `8 v · 3 f`), then the three-finger undo does not revert. Verified by
      parking this change (patch reversed, engine rebuilt, Swift stashed) and re-running:
      identical 5 failures at identical lines on main.
- [x] 5.3 Docs: the grammar's only prose surface is the pencil-interaction spec (README
      and docs/ carry no gesture table), and the delta covers it.
