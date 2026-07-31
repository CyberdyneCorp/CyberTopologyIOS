# Tasks: add-hover-scope-highlight

## 1. One resolver

- [x] 1.1 `MoveScope.loop` carries its seed edge — `loop([UInt32], edge: UInt32, seed: UInt32)`
      — so hover can walk the loop without a second copy of the window rule (design D2).
- [x] 1.2 `EngineHoverQueries.snapTargetVertex` / `slideLoop` answer from `resolveMoveScope`
      instead of their own scene-relative radii (D1).
- [x] 1.3 Boundary edges preview like any other edge; the double-tap slide keeps its own rule
      (D4).

## 2. The face preview

- [x] 2.1 `HoverPreviewState.Preview.faceHighlight(corners:)`, resolved after vertex and loop
      and before the empty-surface ghost quad.
- [x] 2.2 `HoverPreviewQuerying.faceUnderPoint(at:)`, engine-backed by the face under the hit.
- [x] 2.3 `HoverPreviewGeometry` fan-triangulates a ring of 3+ corners into the fill; degenerate
      or too-short rings produce no fill.

## 3. Colour and form

- [x] 3.1 `HoverRenderState` carries which element it describes, so the renderer can colour it.
- [x] 3.2 `OverlayUniformsFactory.hover` takes a colour; loop red, vertex yellow (unchanged).
- [x] 3.3 `GhostStyle.faceHighlight` — pink, `pulseFloor = 1` so the fill does not pulse (D3).
- [x] 3.4 `ViewportRenderer.setHoverPreview` picks the style and colour from the element, and
      the encode order follows it: the create hint stays UNDER the committed EditMesh fill, a
      face highlight goes OVER it (design D3, "Corrected after device testing").

## 4. Tests

- [x] 4.1 Priority: vertex beats loop beats face beats ghost quad.
- [x] 4.2 A hovered face resolves to `.faceHighlight` with that face's ring.
- [x] 4.3 The fill is built for 3- and 4-corner rings; a degenerate ring produces none.
- [x] 4.4 AGREEMENT: for a set of points across a cell, the hover preview and
      `resolveMoveScope` name the same element — the regression guard for the two rules
      drifting apart.
- [x] 4.5 A boundary edge previews its loop rather than nothing (the old test asserted the
      opposite; update it with a note saying why).
- [x] 4.6 Render state carries the right colour per element, and the face style does not pulse.
- [x] 4.7 Existing hover tests still pass. `hoverOverBoundaryEdgeShowsNoPreview` became
      `hoverOverBoundaryEdgeHighlightsWhatADragWouldGrab` (D4). The agreement sweep samples
      OFF the lattice: a point exactly on a window boundary is a tie that hover's screen
      round-trip decides by float error either way — inherent to a threshold, not a
      divergence.

## 5. Device verification

- [x] 5.1 Ran on iPad Air 13-inch (M3): 1137 tests, passed (re-run after the fix).
- [~] 5.2 Device: vertex and loop confirmed. The FACE highlight was invisible — the committed
      EditMesh fill was painted over it — now fixed and awaiting one more device pass.
