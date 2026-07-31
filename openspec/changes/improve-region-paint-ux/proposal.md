# Painting a region tells you what it will do

## Why

Asked on device after the painted-region feature landed:

- *"bring the number of faces available on the custom Face Count"* — the prompt says only
  what the number means, and pre-fills the TARGET's face count (69 451). For a painted
  region the solve clamps to four quads per source triangle, so the artist types a number
  that cannot happen and gets something else. Nothing on screen says what is reachable.
- *"some brush circle when we hover with the pencil"* — the brush is 3% of the scene radius
  and covers a band per stroke, but nothing shows its size until faces turn teal. Painting a
  region is aiming, and the tool gives no cursor.
- *"painting mode to be on erase mode if we double tap the pencil"* — painting is additive
  only. Over-painting means clearing the whole region and starting again.

## What Changes

- **A brush cursor.** While Paint Region is armed, hovering draws a ring of the brush's
  actual radius on the Target. It outranks every element highlight, because "what would a
  Move drag grab" is not the question being asked with a paint tool in hand.
- **Pencil double-tap toggles erase**, and back. The same gesture other apps use to reach an
  eraser, so it needs no on-screen control. The cursor turns red and the chip names the mode
  — the mode is otherwise invisible, since the tool is armed either way.
- **Erasing unpaints faces** instead of clearing everything. What remains keeps its
  first-touched order, so a paint-erase-paint sequence still solves deterministically.
- **The face-count prompt states what is available**: the painted region's size, the ceiling
  it will be clamped to, and that an all-quad cage cannot go arbitrarily coarse. It
  pre-fills a reachable number rather than the whole Target's count.

Non-goals: no brush-size control yet (the radius is fixed at 3% of the scene radius); no
erase for any other paint tool (Freeze and Weave Fill keep their own semantics); the mask
stays transient, cleared when a solve runs.

## Capabilities

### New Capabilities

- `retopology-tools`: the region brush shows its footprint, erases on a pencil double-tap,
  and the face-count prompt states the reachable budget.

## Impact

- **Affected specs**: `retopology-tools` (ADDED requirements).
- **Affected code**: `App/Sources/HoverPreview.swift` (a `brushRing` query and preview case,
  ring geometry), `App/Sources/MeshEditRegionPaint.swift` (erase mode, `PaintedRegion.remove`),
  `App/Sources/MetalViewport.swift` (`pencilInteractionDidTap`, the brush provider),
  `App/Sources/ViewportInputModel.swift` (the mode hint), `App/Sources/EditMeshOverlay.swift`
  + `ViewportRenderer.swift` (cursor colour), `App/Sources/DocumentEditorView.swift` (the
  prompt).
- **Risk**: the double-tap is hardware-dependent (Pencil 2 and later) and cannot be verified
  in the simulator, so the toggle's logic is tested at the model level and the gesture itself
  needs a device pass.
