# Select the region with a box, not only a brush

## Why

Asked on device: *"Besides the paint can we also have a selection mode that select all the
faces on the selection box so we will run the auto-retopology only on these faces?"*

The brush is right for irregular areas and for adjusting an edge. "This whole flank" is a
dozen brush strokes and one drag — and the strokes have to be careful, because the brush is
3% of the scene radius and a miss paints where the artist did not mean.

## What Changes

- **A Select Region Box tool.** Drag a rectangle; every visible Target face inside it joins
  the region.
- **It feeds the SAME region the brush paints**, so the two compose: box a flank, then tidy
  its edge with the brush. Which tool was used never changes what happens next.
- **Erase mode applies**, so a pencil double-tap turns it into a DESELECT box.
- **It shares the paint history**, so one box is one undo step exactly like one stroke.
- **The box is drawn while dragging** — a marquee with no visible rectangle is a drag into
  the void.

- **A see-through mode**, toggled by a pencil double-tap while the box is armed: it takes
  the far wall too, because a thin feature like an ear is one thing to retopologize.

Non-goals: no lasso (a freeform outline is what the brush already is); the region stays
transient and cleared when a solve runs.

## Design decision — visible by default, see-through on request

A box takes faces that are inside it, turned toward the camera, AND first-hit by a ray at
their centroid. Two filters, because they catch different things:

- **Facing** excludes the far wall of a shape: a box over the bunny's flank should take the
  flank, not the flank plus the inside of the other side.
- **First-hit** excludes faces hidden behind other geometry — an ear in front of the body,
  say — which a normal test cannot see.

Taking everything the box covers in depth by DEFAULT would carve a domain wrapping both
walls of a shape, which is usually not what the drag said. But sometimes it is exactly what
it said — asked on device: *"on the bunny ears we want to select both the front and back"* —
so see-through is a mode rather than an absence. It skips both filters, which also makes it
the cheaper path: the raycast is what visible-only pays for, once per drag at stroke end.

The gesture that toggles it is already spoken for: with the brush armed, a double-tap
switches to erase. Making it tool-dependent is the resolution — each region tool has its own
most-wanted switch, and the brush's erase and the box's see-through are both reachable
without a second gesture to learn. The consequence, stated plainly: a DESELECT box now needs
erase mode set from the brush.

## Capabilities

### New Capabilities

- `retopology-tools`: a drag box selects visible Target faces into the auto-retopology region.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirements).
- **Affected code**: a new `App/Sources/RegionBoxSelection.swift` (the pure selection),
  `MeshEditRegionPaint.swift` (the commit path), `MeshEditToolSession.swift` (the tool case),
  `MetalViewport.swift` (the cached Target provider, the live box), `ViewportInputModel.swift`
  + `DocumentEditorView.swift` (the marquee overlay), `ActionCatalog` + `ToolbarConfiguration`.
- **Risk**: the selection walks every Target face. It uses the SAME cached Target the paint
  fill does — reading it from the document would repeat the deserialization that made painting
  lag by seconds — and runs once per drag rather than per sample.
