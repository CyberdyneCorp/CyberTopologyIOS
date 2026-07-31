# A leaked touch no longer kills finger navigation

## Why

Reported from device: *"sometimes we lose the navigation (rotation, zoom, pan) with the fingers
on the viewport. All the rest — the buttons, the toolbar, even the pen — works."*

That asymmetry names the mechanism precisely. Three things gate differently:

| input | gate |
|---|---|
| camera gestures | `InputArbiter.allowsCameraTouch` — refused once TWO finger touches are tracked |
| the pen | `penStrokeTouch` only — unaffected by tracked fingers |
| toolbar / buttons | SwiftUI, outside the viewport's recognizers entirely |

Tracked touches were removed in exactly two places — `touchEnded` and `touchCancelled` — both
driven by UIKit callbacks on the observing recognizer. **A touch whose end is never delivered was
therefore tracked forever**, and two of them refuse every finger for the rest of the session,
while the pen and the toolbar carry on working. There was no path back short of relaunching the
app.

`UITouch` objects are also RECYCLED by UIKit, and `register` returned the existing id when it
found the object's address already mapped — so a recycled touch inherited a dead touch's id and
leaked the old entry as well.

## What Changes

- **Dead touches are swept using `UITouch.phase`**, which UIKit updates on the object whether or
  not our callback runs. The sweep runs on every touch event and before every gesture is admitted,
  so a leak costs one gesture instead of the session.
- **A touch that is BEGINNING retires any stale mapping for the same object**, instead of
  inheriting its id — the recycling case.
- **The end of a touch sequence reconciles** (`UIGestureRecognizer.reset`), as a backstop.
- **An authoring stroke whose touch vanished is cancelled**, not left half-open: no end can ever
  arrive for it.
- **Recoveries are counted and logged**, because the TRIGGER is still not reproduced — see below.

Non-goals: no change to palm rejection, to the two-finger limit, or to any gesture's behaviour.

## What is NOT established

The mechanism is certain from the code: two unreleased finger touches disable camera gestures
permanently, and nothing removed them. What is NOT reproduced is WHY a `touchesEnded` goes
missing — the reporter's hunch was "operations at high zoom", and nothing in the touch path is
zoom-dependent, so that remains unexplained. Candidates not yet ruled out: a system gesture or
notification banner interrupting mid-sequence, and the recognizer resets performed when the pen
takes priority over in-flight finger gestures.

This change makes the failure self-healing and observable rather than proving its trigger. The
log line and `recoveredLeakedTouches` counter exist so a recurrence can be confirmed as this bug
rather than guessed at.

## Capabilities

### New Capabilities

- `pencil-interaction`: finger navigation recovers automatically from a touch whose end UIKit
  never delivered.

## Impact

- **Affected specs**: `pencil-interaction` (ADDED requirement).
- **Affected code**: `App/Sources/InputArbiter.swift` (`forget`, `allTouchesFinished`),
  `App/Sources/ViewportInputController.swift` (weak touch tracking, the sweep, recycling-safe
  registration), `App/Sources/MetalViewport.swift` (the twist recognizer joins the set reset when
  the pen takes priority — it was missing).
- **Risk**: the sweep runs on every touch event and in `shouldReceive`, so it must be cheap and
  must never drop a LIVE touch. It keys on `UITouch.phase` being `.ended`/`.cancelled`, which is
  UIKit's own record of a finished touch.
