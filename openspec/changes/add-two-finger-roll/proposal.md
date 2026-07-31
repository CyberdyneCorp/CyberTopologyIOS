# Two-finger twist rolls the view around the fingers

## Why

Asked on device: *"Can I have the option to rotate when I use 2 fingers and rotate? It will
rotate around the place where my 2 fingers are."*

The camera is a turntable — focus, distance, azimuth, elevation — and its up vector is DERIVED
from world +Y, so the horizon is permanently level and there is no way to tilt it. Retopology is
stroke work: quads follow the direction the hand can comfortably draw, and on a fixed horizon
the artist has to contort the wrist, or orbit the model into an awkward pose, to draw a line
that runs across the screen diagonally.

The twist gesture is free — two fingers currently drive pinch-zoom and pan, and rotation is a
distinct recognizer that runs alongside both. Every 3D tool with tablet muscle memory (Nomad,
Shapr3D, Procreate for its canvas) maps it to exactly this.

## What Changes

- **Two-finger twist rolls the view**, and the point BETWEEN the fingers stays where it is: the
  scene turns under the fingers like a sheet of paper, rather than spinning about the screen
  centre and sliding the thing being worked on out from under them.
- **The roll is real camera state**, not a display trick. `CameraState` gains a `roll` folded
  into its basis, so the picking rays, the pan directions, the camera-driven tools and the
  rendered image all agree about which way is up.
- **It is an option** (`viewportTwoFingerRoll`, default ON) in the viewport settings, beside the
  orbit and zoom speeds. A rolled horizon is disorienting for anyone who does not want it, and
  a twist is easy to trigger by accident while pinching.
- **Reframing levels the horizon.** Double-tap reframe and camera rescue already promise a valid
  framing; a rolled camera is exactly the state someone reaches for that promise from.
- **Rotation coexists with pinch and pan** in a single two-finger gesture, and needs a small
  threshold so a straight two-finger drag does not roll the scene a degree at a time.

Non-goals: no roll from any other input (no one-finger, no Pencil barrel roll — the Pencil's
barrel roll already means something else here); no roll limit or snap-to-angle; no persistence
of roll in the document (it is viewport state, like the rest of the camera).

## Capabilities

### New Capabilities

- `viewport-rendering`: a two-finger twist rolls the camera about the point between the
  fingers, as an option, with reframing restoring a level horizon.

## Impact

- **Affected specs**: `viewport-rendering` (ADDED requirements; the camera gesture mapping gains
  a fourth gesture).
- **Affected code**: `App/Sources/CameraState.swift` (roll state, basis, the roll-about-pivot
  operation, framing/rescue reset), `App/Sources/MetalViewport.swift`
  (`UIRotationGestureRecognizer`, arbitration, the setting), `App/Sources/ViewportRenderer.swift`
  (the roll entry point), `App/Sources/DocumentEditorView.swift` (the settings toggle).
- **Risk**: `basis` is read by the camera-as-manipulator tools (Transform Vertices, Patch
  Clone) and by every picking ray. Folding roll into it is the CORRECT seam — those consumers
  must agree with the screen — but it means the change reaches further than the gesture itself,
  so the tests cover picking and tool bases under a rolled camera, not just the rendered matrix.
