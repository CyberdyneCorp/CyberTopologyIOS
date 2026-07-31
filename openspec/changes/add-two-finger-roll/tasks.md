# Tasks: add-two-finger-roll

## 1. Camera state

- [x] 1.1 `CameraState.roll` (radians), folded into `basis` by rotating right/up about forward
      (design D1), so `viewMatrix`, picking and the tool bases all follow.
- [x] 1.2 `roll(byRadians:about:)` — rotates the FOCUS about the axis through the pivot parallel
      to the view direction, leaving distance/azimuth/elevation untouched (D2).
- [x] 1.3 `framing(_:aspect:)` and camera rescue produce `roll = 0` (D5).
- [x] 1.4 `isDegenerate` covers a non-finite roll.

## 2. The gesture

- [x] 2.1 `UIRotationGestureRecognizer` on the viewport, simultaneous with the pinch and
      two-finger pan recognizers (D4).
- [x] 2.2 Pivot captured ONCE at gesture begin: the touch midpoint raycast onto the Target,
      falling back to the focus plane (D3).
- [x] 2.3 Twist threshold ~0.12 rad, subtracted from the first applied delta rather than skipped
      (D4).
- [x] 2.4 `ViewportRenderer.roll(byRadians:about:)` entry point, invalidating like the other
      camera interactions.

## 3. The option

- [x] 3.1 `ViewportSettings.twoFingerRollKey`, default ON.
- [x] 3.2 Toggle in the viewport settings popover, beside orbit/zoom speed.
- [x] 3.3 Disabled = updates ignored, recognizer left installed so the setting works mid-session.

## 4. Tests

- [x] 4.1 Sign AND magnitude: a quarter-turn roll moves a marker from above the pivot to
      exactly its left, aspect-scaled (D6). Caught two real bugs — the handler's negation and a
      basis/focus sense mismatch that slid the pivot 0.21 NDC.
- [x] 4.2 The pivot's screen position is unchanged across a roll.
- [x] 4.3 Distance, azimuth and elevation are untouched by a roll.
- [x] 4.4 `basis` right/up rotate while forward does not; the view matrix stays orthonormal.
- [x] 4.5 A ray through a screen point under a rolled camera hits what is drawn there.
- [x] 4.6 Threshold: below it nothing moves; crossing it applies only the excess.
- [x] 4.7 The setting off leaves the camera bit-identical.
- [x] 4.8 Reframe and rescue both level the horizon.
- [x] 4.9 Roll composes with pan and zoom without drift in the other parameters.

## 5. Device verification

- [x] 5.1 Ran on iPad Air 13-inch (M3): 1147 tests, passed (from a CLEAN build).
- [ ] 5.2 Twist on a real cage: the point under the fingers holds still, pinch/pan/twist together
      feel right, and a straight two-finger pan never tilts the horizon.
