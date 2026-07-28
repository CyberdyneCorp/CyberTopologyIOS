# Island UV editing and the 2D island grammar (6.3)

## Why

After unwrapping, the layout needs hand adjustment: nudge a shell, turn it, grow it, straighten a
grid, merge two islands, make one symmetric. 6.6 gave the automatic arrangement; this is the
manual half.

## Everything the engine needed already existed — including "relax"

Checking before scoping, as with 6.2/6.4/6.5/6.6: `transforms.hpp` has translate/rotate/scale,
`layout.hpp` has grid straightening / distribution / seam stitching, `symmetrize.hpp` has partial
symmetrization, `uv_clone.hpp` has the topological clone. So this slice is C API exposure plus the
gesture layer, not new algorithms.

**And one requirement was already satisfied.** The spec asks for "relax an island's UVs by
scrubbing on the 3D surface (corner auto-pinning)". A conformal re-solve with two automatically
chosen pins refitted into the island's footprint IS that operation — which is exactly
`reunwrapIsland`, shipped in 6.2b for the X gesture. Nothing new was needed; the entry point
already exists and is already tested.

## The 2D grammar is positional, and the classification has to be readable

"Stroke on upper part → rotate, lower → scale, middle → move." Implemented as vertical THIRDS of
the island's bounding box, deliberately not a radial centre-and-ring: the box is the only thing
the artist can see, so the zones must be readable off it, and a radial split would put "scale" in
a ring whose width depends on the island's aspect — not something anyone can aim at.

Three details that are not cosmetic:

- **Classified in UV space (v up), not view space.** The panel flips v for drawing, so
  classifying in view coordinates would silently swap rotate and scale.
- **The mode is captured at the drag's START and never recomputed.** Reclassifying mid-drag would
  turn a rotation into a scale as the finger crosses a zone boundary.
- **A drag beginning at the island's centroid yields NOTHING.** The angle about a point you are
  standing on is ill-conditioned, so a sub-pixel wobble would swing the island wildly. Below a
  minimum lever arm the gesture declines rather than lurching.

Scale is derived as the RATIO of distances from the centre, so the same finger travel means the
same multiplication on a small island and a large one, and it is clamped so one stray sample
cannot collapse an island to nothing or throw it off the atlas.

Nothing commits while the finger is down. One completed gesture is one journaled step, matching
the brush verbs; an identity transform journals nothing, so an abandoned drag leaves no undo entry
that does nothing.

## A negative scale is refused rather than accepted as a mirror

`transformIsland` rejects a non-positive scale. Mirroring has its own entry point
(`flipIsland`, 6.6) where the winding change is the intent; letting it in through a negative scale
would make an ordinary transform silently produce a defect that only shows up as inverted detail
after baking.

## Clone stays order-based, and that is the point

`cloneIslandUv` copies by island order, face order and corner index, which is right for islands
that are genuine topological duplicates. It is deliberately NOT reused for mirrored pairs — 6.7's
stacking corresponds by reflected position, because index matching across a mirror scrambles the
shell while leaving its bounding box correct. Keeping the two operations separate keeps that
distinction visible instead of hiding a mirror special case inside a clone.

Cloning an island onto ITSELF is refused rather than succeeding as a no-op, so a mis-aimed gesture
is visible.

## Split out as 6.3b: the UV3D on-surface pinch

"Adjust island position/rotation/scale via multitouch pinch directly on the 3D surface with live
texture feedback" is not deferred for size. It needs INPUT ARBITRATION: the viewport already binds
pinch to the camera, so an on-surface island pinch has to be resolved against it through
`InputArbiter` rather than added beside it. That is a gesture-grammar decision with its own
failure modes (a camera pinch mistaken for an island transform is a silent, hard-to-undo edit),
and it deserves its own change.

Also not included: per-vertex mode in UV2D, and the checker/imported-texture preview the live
feedback is described against — the panel has no texture preview yet, so there is nothing for
"live texture feedback" to update.
