# Dragging a vertex onto another merges them

## Why

Asked on device: *"when we move a vertex, if we are close to another vertex, can we merge
them?"* The capability exists — but only on one verb, in a window sized by the wrong thing,
and without saying so.

- **Move did not merge.** Tweak merged on release; Move welded the seed's POSITION onto the
  target and left the topology alone. The reasoning was that Move drags a falloff REGION and
  collapsing topology under it would surprise. In practice it leaves two coincident vertices
  where the artist plainly meant one — a crack that reads as a merge until something downstream
  chokes on it.
- **The window was a slice of the SCENE** (`sceneRadius × 0.04`). A cage's cells have nothing
  to do with the scene's size, so the same gesture behaves differently on a coarse cage (the
  window is a fraction of a cell — you must land almost exactly on the target) and on a fine
  one (it spans several cells and can absorb a vertex nobody aimed at). This is the third time
  in this line of work a scene-relative tolerance has been the bug; the cage's own spacing is
  what "close enough to be the same vertex" means.
- **Nothing named the outcome.** The target pre-highlights, which says *this one* — not *and
  it will be absorbed*. A merge that is only knowable after release is not discoverable, and
  its absence is not explainable.

## What Changes

- **Both verbs merge.** Move joins Tweak: releasing within range merges the dragged vertex
  into the target, journalled as `<verb>.mergeSnap`. Only the SEED merges — the vertex under
  the finger, never anything the falloff carried along — so a moved region keeps its structure.
- **The window is the grabbed vertex's own cell**: 45% of the mean length of the edges meeting
  it, measured once at grab time, floored well below the old window so a degenerate cell can
  never make merging impossible.
- **The drag names the outcome.** While a merge is engaged the viewport shows a "Merge" chip in
  the slot the post-stroke chip uses, so the result is visible before the release.

Non-goals: no change to the grab radius, to haptics, or to what Move's falloff does to the
region; and no merge of anything other than the seed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pencil-interaction`: the snap-feedback requirement gains the Move merge, the cell-relative
  window, and the named outcome.

## Impact

- `App/Sources/MeshEditController.swift` — `mergeRange(around:in:sceneRadius:)`, the session's
  per-drag range, and the commit path.
- `App/Sources/ViewportInputModel.swift` + `MetalViewport.swift` + `DocumentEditorView.swift` —
  the "Merge" hint.
- Tests: the Move test now asserts a merge; a new test pins the window to the cell.
