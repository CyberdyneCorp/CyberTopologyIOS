# Design: two-finger roll

## D1. Roll is camera STATE, folded into the basis

`CameraState` gains `roll: Float` (radians), and `basis` rotates its derived right/up about the
forward axis by it:

```
right_r = right * cos(roll) - up * sin(roll)
up_r    = up * cos(roll) + right * sin(roll)
```

Not applied in the view matrix alone, and not in the renderer. `basis` is what the picking rays,
the pan direction and the camera-as-manipulator tools (Transform Vertices, Patch Clone) all read.
A roll applied only where the image is produced would leave every one of those computing against
an up vector the artist can plainly see is wrong — a tap would pick the wrong place, a pan would
slide diagonally, and a screen-space vertex transform would shear.

`viewMatrix()` already builds from `basis`, so it follows for free.

## D2. The pivot stays put

Rolling about the camera's own axis spins the scene about the screen CENTRE, which slides
whatever the artist is working on out from under their fingers — the opposite of what the
gesture promises. The roll is therefore about the axis through the pivot P (world), parallel to
the view direction:

```
focus' = P + R(forward, θ) · (focus - P)
roll'  = roll + θ
```

`distance`, `azimuth` and `elevation` are untouched, and the eye follows automatically: the eye
is `focus + distance · direction`, and `direction` IS the rotation axis, so the eye-to-focus
offset is invariant under R. One rotation of one point is the whole implementation.

## D3. Where the pivot comes from

The midpoint between the two touches, raycast onto the Target; on a miss (empty space beyond the
model), the point on the focus PLANE under that midpoint. Never the focus point itself, which
would silently degrade to a centre-spin.

The pivot is captured once, when the gesture begins, and held for its duration. Re-raycasting per
frame would let the pivot crawl across the surface as the scene turns beneath it, feeding its own
motion.

## D4. Arbitration with pinch and pan

`UIRotationGestureRecognizer`, delegated to recognize simultaneously with the existing pinch and
two-finger pan — one physical gesture routinely carries all three, and forcing exclusivity would
make the winner arbitrary.

A twist threshold (~0.12 rad, about 7°) must be exceeded before any roll is applied, then the
gesture tracks continuously from that point. Without it, the small rotational noise in a straight
two-finger drag accumulates into a visibly tilted horizon over a long pan — the failure the
threshold exists to prevent is not a false start, it is drift.

The threshold is subtracted from the first applied delta rather than skipped, so the scene does
not jump by 7° the moment it engages.

## D5. The option, and getting back to level

`ViewportSettings.twoFingerRollKey`, default ON. Off means the recognizer's updates are ignored
outright, rather than the recognizer being removed — the setting can then change mid-session
without rebuilding the gesture stack.

`CameraState.framing(_:aspect:)` and camera rescue both produce `roll = 0`. Someone who has
tumbled the horizon and wants out reaches for double-tap reframe; a reframe that preserved the
tilt would fail the "always returns to a valid framing" promise in the letter and the spirit.

Undoing a roll by hand is also always possible — the gesture is symmetric.

## D6. Sign convention

UIKit's `UIRotationGestureRecognizer.rotation` is positive CLOCKWISE on screen (y points down).
A positive `CameraState.roll` turns the scene COUNTER-clockwise, so the handler negates the
gesture's rotation; the scene then follows the fingers instead of fighting them. The tests pin
this by projecting a known world point and asserting which way it travels — and by how far,
scaled by the aspect ratio — because a sign error here is invisible in any assertion about the
roll ANGLE alone and instantly obvious on device.

**Found while implementing:** the basis rotation and the focus rotation must use the SAME sense
about the forward axis, or they do not cancel and the pivot slides across the screen as the view
rolls (measured: 0.21 NDC for a 0.6 rad twist). `forward × right = -up` is where the signs come
from. `thePivotKeepsItsScreenPosition` is the guard.

## Alternatives considered

- **Twist drives azimuth** (turntable spin): rejected. One-finger horizontal drag already does
  that, and it would not rotate "around the place where my fingers are" in any meaningful sense.
- **Roll about the screen centre**: rejected — see D2. It is one line simpler and it moves the
  work out from under the hand.
- **Springing back to level on release**: rejected. The point is to hold a comfortable drawing
  angle for a stroke; springing back would undo it before the stroke starts.
- **Storing roll in the document**: rejected, consistent with the rest of the camera.
