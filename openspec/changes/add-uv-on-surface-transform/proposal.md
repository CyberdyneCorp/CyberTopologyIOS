# On-surface island UV transform (6.3b)

## Why

"In UV3D, users SHALL … move island UVs by dragging on the surface, and adjust island
position/rotation/scale via multitouch pinch directly on the 3D surface." Adjusting a layout while
looking at the model, rather than at the 2D panel.

## The arbitration I said this needed already exists

I recorded 6.3b as blocked on input arbitration: "the viewport already binds pinch to the CAMERA, so
an on-surface island pinch must be resolved against it through `InputArbiter`". **That was wrong.**

`InputArbiter.cameraFeedsArmedTool` exists precisely for this and says so: "the
camera-as-manipulator tools deliberately blur pen-authors/fingers-navigate, so the blurring is
decided HERE, never ad hoc in the UIKit layer". Three tools already use it — Patch Clone, Extend
Boundary, Transform Vertices — and `PlacementMath.pinchScale` already converts a camera-distance
change into a scale factor.

Nor is there a spec conflict with "finger strokes never author": that requirement is about strokes
CREATING GEOMETRY, and camera-as-manipulator is the established, spec-sanctioned exception.

So this is a fourth session-plan case reusing an established pattern, and it reuses the
`UVIslandGesture.Transform` type the 2D grammar already produces.

## Three distinct gestures, not one overloaded drag

- **pinch** (camera distance) → island UV **scale**, via the same `PlacementMath.pinchScale` every
  other camera tool uses, so a pinch means the same thing across tools.
- **two-finger twist** (barrel roll) → **rotation**.
- **orbit** (camera screen-lock displacement) → **translation**.

Keeping them separate means no gesture can be mistaken for another. The orbit delta is projected
onto the camera's own right/up axes and divided by the scene radius, so the mapping is independent
of model scale: the same finger travel moves the island the same UV distance on a large model and a
small one.

## The transform is applied on COMMIT, and that is a decision

Accumulated and applied once, not live. Two reasons, and the first is what makes the second free:

- **A UV change is invisible in the 3D viewport today.** Nothing in the app samples a texture, so
  live application would produce no feedback at all.
- **Repeatedly applying centroid-relative deltas does not compose exactly.** Live application would
  therefore trade a real correctness risk for nothing.

One commit, one exact transform. `runTransformIsland` declines an identity, so a session the artist
armed and never moved leaves no undo entry that does nothing.

## Refused up front, not at commit

Arming requires an existing UV layout. A session that could only ever fail is worse than no session,
so the tool declines to arm rather than accepting a stroke and reporting a refusal later.

## Split out as 6.3c: live texture feedback

The requirement names "live texture feedback" and a checker/imported-image preview. **No textured
render path exists anywhere in the app**: the Target and overlay shaders sample no textures, and
neither render path carries UVs in its vertex stream. That is a new render path — corner-expanded
vertices built from the engine's UV corner stream, a shader pair, and its own offscreen harness —
not a wiring job, so it gets its own change.

Also still open from 6.3's original text: per-vertex mode in UV2D.
