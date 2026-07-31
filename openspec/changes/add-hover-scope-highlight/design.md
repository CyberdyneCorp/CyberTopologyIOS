# Design: hover scope highlight

## D1. One resolver, two consumers

`MeshEditController.resolveMoveScope(at:in:sceneRadius:)` answers "what is under this point" for
BOTH the drag and the hover preview. `EngineHoverQueries` stops measuring its own windows and
maps the scope instead:

| scope | preview | colour |
|---|---|---|
| `.vertex` | snap-target point | yellow (`hoverColor`, unchanged) |
| `.loop` | the loop's edges, as line segments | red |
| `.surface` | the face ring under the point, filled | pink |
| nothing, over empty Target | ghost quad create hint | amber (unchanged) |

Why not leave hover with its own radii: because the highlight's only job is to predict the
drag. Two rules cannot be kept in agreement by intention — hover's were `0.05`/`0.07 ×
sceneRadius` against Move's `0.25`/`0.15 × cell`, which on a 1-unit cage in a scene of radius 7
is 0.49 against 0.15 for an edge. The highlight would have claimed "loop" across most of a face.

The pure `HoverPreviewState` machine keeps its three-query protocol and its priority order, so
its headless tests are untouched; only the ENGINE implementation of those queries changes.

## D2. `MoveScope.loop` carries its seed edge

Rendering a loop needs EDGE ids (the segment list walks endpoints), while the drag needs vertex
ids. Rather than have hover re-run `nearestEdge` with a second copy of the window rule — the
exact drift D1 exists to prevent — the loop case carries the edge it was picked from:

```
case loop([UInt32], edge: UInt32, seed: UInt32)
```

The drag ignores `edge`; hover walks `edgeLoop(from: edge)` with it.

## D3. The face is a FILL, through the ghost pipeline

A face highlight drawn as an outline would be four short line segments — the same primitive,
weight and shape language as the red loop, distinguished only by hue. Filled, it is
unmistakable at a glance and at any zoom.

The ghost pipeline already renders a translucent, normal-offset surface with a per-style
colour, which is exactly what is needed; it just has to stop pulsing. `GhostStyle.faceHighlight`
sets `pulseFloor = 1` (constant alpha) and a pink tint. The pulse is right for the create hint —
an invitation to draw — and wrong here, where the fill states what is already there.

**Corrected after device testing.** The fill reached the GPU and stayed invisible. The hover
fill is encoded in the proposal slot — UNDER the committed EditMesh fill — which is right for
the create hint (it proposes geometry that does not exist yet) and wrong for a face highlight:
the committed fill covers every face, including the one being highlighted, and paints straight
over it. A vertex and a loop were unaffected, because they are drawn by the overlay's later
line and point passes. The renderer now tracks WHICH element the fill holds
(`hoverGhostElement`) and encodes a face highlight after the committed fill instead. The depth
compare is `lessEqual` with no depth write, so the later draw at equal depth wins with no bias
change. `hoverFillDrawsAboveCommittedFill` makes the decision assertable.

Geometry: the face ring is fan-triangulated about its first corner, with one plane normal on
every vertex, reusing `HoverPreviewGeometry.ghostQuad`'s construction generalised past 4
corners. Rings of fewer than 3 corners, or degenerate (collinear) ones, produce no fill rather
than a malformed one.

## D4. Boundary edges now highlight

`slideLoop` rejected boundary edges because a double-tap cannot SLIDE one. Under D1 the query
answers "what would a drag grab", and Move grabs a boundary edge — degrading to that edge's own
two vertices when the loop cannot be walked. So the highlight shows it.

This is a deliberate semantic shift of the preview from "what a double-tap would slide" to
"what is under the pointer". The double-tap slide keeps its own boundary rule; only the preview
changes. The alternative — staying silent over a boundary edge that a drag would happily
move — would make the highlight lie by omission in exactly the place the artist is aiming
carefully.

## D5. Colours are fixed, and stated once

`OverlayUniformsFactory.hover` takes the colour instead of hardcoding it, and the three
constants live beside the existing `wireColor` / `pinColor` / `tagColor`:

| element | linear RGB | why |
|---|---|---|
| vertex | `1.0, 0.85, 0.25` | unchanged — the artist already reads yellow as "this vertex" |
| loop | `1.0, 0.25, 0.20` | red, far from the cyan wireframe and the amber ghost |
| face | `1.0, 0.45, 0.70` | pink, distinct from red at the low alpha a fill needs |

Red and pink are the two that could collide, which is why the loop is a thin bright line and
the face is a broad low-alpha fill: they differ in FORM first, colour second. Colour-blind
readers get the same separation from form that they get from the wireframe-vs-ghost pair today.

## Alternatives considered

- **Highlight the whole falloff region for surface scope** (every vertex within the geodesic
  radius): rejected. It is honest about what moves, but it repaints a large, soft-edged blob on
  every hover sample — expensive, visually noisy, and it answers a question ("how far does the
  influence reach") the artist is not asking at pick time.
- **Keeping hover's own windows and just adding the face case**: rejected — see D1. It ships a
  highlight that is wrong about a face's interior most of the time.
- **A fourth colour for "nothing grabbable"**: rejected; absence of a highlight already says it.
