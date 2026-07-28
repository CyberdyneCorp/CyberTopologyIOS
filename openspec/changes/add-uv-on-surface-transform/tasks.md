# Tasks: add-uv-on-surface-transform (6.3b, first slice)

## 0. Check the claimed blocker
- [x] 0.1 Confirm whether new input arbitration is needed. It is NOT:
      `cameraFeedsArmedTool` exists for this and three tools already use it.
- [x] 0.2 Confirm no conflict with "finger strokes never author". None: that requirement is about
      strokes creating geometry.

## 1. Session
- [x] 1.1 `UVIslandTransformPlan`, pure, with the orbit→UV mapping normalized by scene radius.
- [x] 1.2 A fourth camera-tool plan case: arm, feed, commit, cancel, banner.
- [x] 1.3 Arm refuses a mesh with no UV layout.
- [x] 1.4 Address the island by a representative FACE id, as every localized UV op does.
- [x] 1.5 Commit applies the accumulated transform ONCE, as one journaled step.

## 2. Gestures
- [x] 2.1 pinch → scale (shared `PlacementMath.pinchScale`).
- [x] 2.2 twist → rotation.
- [x] 2.3 orbit → translation.
- [x] 2.4 A non-positive scale can never reach the engine.

## 3. Surface
- [x] 3.1 Toolbar action + tool, classified as a camera manipulator.
- [x] 3.2 Action Gallery entry.
- [x] 3.3 Visual-verification probe — which UNWRAPS first, since the tool legitimately refuses a
      mesh with no UVs and a probe that skipped it could only exercise the refusal. The guard test
      caught the placeholder that journalled nothing.

## 4. Close out
- [x] 4.1 validate; simulator, device.
- [x] 4.2 Master 6.3b entry; split live texture feedback out as 6.3c.
