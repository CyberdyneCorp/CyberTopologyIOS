# Tasks: fix-target-occlusion

## 1. Depth precision

- [x] 1.1 `clipPlanes` floors the near plane relative to FAR so `far/near` stays bounded
      (1e3), instead of the 1e5 the old floor allowed.
- [x] 1.2 Diving inside the model still renders (the floor is what makes a non-positive
      `d - 2r` safe).

## 2. A scene-relative allowance

- [x] 2.1 `CameraState.depthBias(forWorldOffset:bounds:)` — the NDC bias equivalent to pulling a
      surface toward the camera by a world distance, at the focus depth.
- [x] 2.2 `OverlaySettings.occlusionBias` becomes a FRACTION of the scene radius; the renderer
      converts once per frame and feeds wire, fill, ghosts and guide lines from that one value.
- [x] 2.3 Default and range re-picked in scene-relative terms; the settings label says what it
      now means.

## 3. Tests

- [x] 3.1 MEASUREMENT guard: the allowance is a small fraction of the scene's own NDC depth
      spread, at the default AND at the slider's maximum. (The "49.5x" in the first draft was a
      miscalculation — see the proposal. The real defect was the MAXIMUM, worth ~48% of the
      scene radius at the far surface.)
- [x] 3.2 The near/far ratio is bounded at fitted, inside and far poses.
- [x] 3.3 Front and back of the scene differ measurably in NDC depth when framed.
- [x] 3.4 The converted bias scales with the scene: same fraction, same result on a 2 mm and a
      200 m scene.
- [x] 3.5 A surface-snapped overlay still passes the depth test (the allowance is not zero).
- [x] 3.7 PIXEL tests through the real render path, which the fill never had: a fill behind the
      Target is hidden, a fill in front still draws, a fill behind a THIN feature is hidden
      (fails with the raw-NDC allowance at 311 differing pixels), and a MAXED slider still
      occludes.
- [x] 3.6 Existing overlay/fill tests still pass with the new units, updated where they asserted
      the old NDC number.

## 4. Device verification

- [x] 4.1 Ran on iPad Air 13-inch (M3): 1156 tests, passed.
- [~] 4.2 Awaiting the reporter's device pass: the cage wrapped around the bunny shows no
      far-side faces at any slider position, the near-side cage still reads on the surface, and
      toggling X-ray now visibly changes what is drawn (it appeared inert because the maxed
      allowance was already revealing everything).
