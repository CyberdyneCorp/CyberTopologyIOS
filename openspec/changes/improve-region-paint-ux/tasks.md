# Tasks: improve-region-paint-ux

## 1. The brush cursor

- [x] 1.1 `HoverPreviewQuerying.brushRing(at:)` + `Preview.brushRing(centre:radius:)`,
      resolved BEFORE every element preview.
- [x] 1.2 `HoverPreviewGeometry.brushRing` — a closed circle facing the camera. Screen-facing
      rather than surface-tangent: a ring laid on a curved surface foreshortens into
      something narrower than the brush actually covers.
- [x] 1.3 Engine-backed query returns a radius only while the paint tool is armed, via a
      provider closure so arming needs no notification.
- [x] 1.4 Its own render element and colour, matching the painted extent's teal.

## 2. Erase mode

- [x] 2.1 `PaintedRegion.remove(_:)` — unpaints, preserving the order of what remains so a
      paint-erase-paint sequence still solves deterministically.
- [x] 2.2 `MeshEditController.paintErases`, announced on change only.
- [x] 2.3 `pencilInteractionDidTap` toggles it, and ONLY while the paint tool is armed —
      otherwise there is nothing to erase and the tap is left for whatever else wants it.
- [x] 2.4 The cursor turns red and the chip names the mode.

## 3. The face-count prompt

- [x] 3.1 States the painted region's size and its ceiling, or the Target's face count.
- [x] 3.2 Pre-fills a reachable number instead of the Target's count.
- [x] 3.3 Says that a very low count comes back higher, since the cage is all quads.

## 3a. The keypad and Half / Double

- [x] 3a.1 `RetopoFaceCountModel` — a pure entry model: append/backspace/clear, halve,
      double, and a runnable test. No SwiftUI, so every rule is unit-tested.
- [x] 3a.2 `RetopoFaceCountView` — the value, Half / Double, a 3x4 keypad, Cancel /
      Retopologize. Presented as a SHEET: an alert can host a TextField and buttons and
      nothing else, and the system number pad floats OVER the dialog, covering the line that
      says what is reachable (the reporter's screenshot showed exactly that).
- [x] 3a.3 Halving floors at the solver's minimum; doubling caps at the ceiling; a digit that
      would exceed the ceiling is IGNORED rather than accepted and rewritten.
- [x] 3a.4 Retopologize is disabled below the solver's minimum.

## 4. Tests

- [x] 4.1 Erase removes faces and preserves the remaining order; erasing an unpainted face
      is harmless.
- [x] 4.2 The mode announces only on change.
- [x] 4.3 The ring is closed, every vertex is on the circle, and a degenerate brush draws
      nothing.
- [x] 4.4 The cursor outranks snap/loop/face/ghost previews when all are available.
- [x] 4.5 The cursor carries its own render element and is lines rather than a fill.
- [x] 4.6 Keypad: typing builds the count and stops at the ceiling; backspace and clear;
      halve/double bounds; the initial value is clamped into range; running needs the floor.

## 5. Device verification

- [x] 5.1 Run the mirrored suites on the iPad.
- [ ] 5.2 HARDWARE-ONLY: the pencil double-tap cannot be exercised in the simulator. Confirm
      on device that it toggles erase and back, that the cursor colour changes with it, and
      that the ring tracks the pen at the brush's true width.
