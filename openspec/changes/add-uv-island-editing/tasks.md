# Tasks: add-uv-island-editing (6.3, first slice)

## 0. Check the engine first
- [x] 0.1 Survey `transforms.hpp`, `layout.hpp`, `symmetrize.hpp`, `uv_clone.hpp`.
- [x] 0.2 Record that "relax with corner auto-pinning" is already shipped as `reunwrapIsland`
      (6.2b), so no new engine work is needed for it.

## 1. C API
- [x] 1.1 Combined island transform (move + rotate + scale in ONE atomic call, because a pinch
      produces all three and three calls would journal three steps for one gesture).
- [x] 1.2 Refuse a non-positive scale, so a transform cannot smuggle in a mirror.
- [x] 1.3 Grid straighten, partial symmetrize, clone, stitch.
- [x] 1.4 Shared `withIsland` helper, so no entry point can forget the cache invalidation.
- [x] 1.5 Refuse cloning an island onto itself; validate stitch edge ids as a whole.
- [x] 1.6 Patch-stack entry (0019).
- [x] 1.7 Tests, including that four quarter turns restore the island (the pivot does not drift).

## 2. CyberKit
- [x] 2.1 `transformIsland`, `gridStraightenIsland`, `symmetrizeIsland`, `cloneIsland`,
      `stitchIslands`.
- [x] 2.2 Tests, including the non-positive-scale refusal and all-or-nothing stitching.

## 3. App — the 2D grammar
- [x] 3.1 `UVIslandGesture`: pure zone classification and transform derivation.
- [x] 3.2 Classify in UV space (v up), not view space.
- [x] 3.3 Capture the mode at drag START; never reclassify mid-drag.
- [x] 3.4 Decline below a minimum lever arm instead of lurching.
- [x] 3.5 Ring hit-testing with a nearest-island fallback, so a near-miss still grabs an island.
- [x] 3.6 Drag gesture on the panel; commit on RELEASE as one journaled step.
- [x] 3.7 An identity transform journals nothing.
- [x] 3.8 Grid-straighten command.
- [x] 3.9 Tests for all of the above.

## 4. Close out
- [x] 4.1 validate; engine, simulator, device.
- [x] 4.2 Master 6.3 entry; split the UV3D on-surface pinch out as 6.3b with the
      input-arbitration reason.
