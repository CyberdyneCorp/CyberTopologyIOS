# Move's scope follows what the drag starts on

## Why

Asked on device: *"I want to be able to move a vertex (and the vertex alone) when I start the
move from a vertex, but if we start the move from a face, keep the same behavior we have
today, and move an edge loop if the move starts from an edge loop."*

Move has exactly one behavior today, whatever is under the finger. `strokeBegan` grabs the
nearest vertex and every sample runs `moveWithGeodesicFalloff`, so:

- **A single vertex cannot be moved with Move.** The falloff always drags its neighbourhood
  along. Adjusting one vertex means switching to Tweak — a different verb, a different
  toolbar trip — for what the artist reads as the same gesture on a smaller target.
- **The loop, the natural unit of a quad cage, has no drag at all.** Loops can be pinned per
  loop and inspected per loop (Loop Info), but the only way to reposition one is to move its
  vertices one at a time and accept the falloff smearing each neighbour on every pass.
- **The grab window is a slice of the SCENE** (`sceneRadius × 0.12`). On a fine cage that
  window spans many cells, so "I started on this vertex" is not a statement the code can
  make. This is the fourth time a scene-relative tolerance has been the defect in this line of
  work (the merge window, the rung clearance, the mid-stroke guard); the cage's own spacing is
  what "on a vertex" means.

## What Changes

The pick at `strokeBegan` decides the drag's SCOPE, and the drag then honors it:

- **Started on a vertex** — that vertex alone moves, snapped to the Target, with the
  merge-on-release behavior it has today. No falloff, no neighbours.
- **Started on an edge** — the edge's whole loop moves RIGIDLY: every loop vertex takes the
  same displacement and re-snaps. No merge, because collapsing a whole loop into its
  neighbours on release is not predictable from the gesture.
- **Started anywhere else on a face** — unchanged: geodesic falloff around the nearest vertex,
  merging the seed on release exactly as today.
- **The chip names the scope** — "Vertex" / "Loop" / "Surface" in the slot the "Merge" hint
  uses, so what the drag grabbed is visible before the artist commits to it.
- **Thresholds are cell-relative**, measured from the local cage spacing at grab time, so the
  same gesture picks the same thing on a coarse cage and a fine one.
- **Pins hold in all three scopes**, per the existing requirement that Move SHALL NOT displace
  a pinned vertex.

Non-goals: Tweak is untouched; no loop SELECTION UI, no partial loops, no rotate/scale of a
loop; no new engine patch (the loop walk and the snapped per-vertex move already exist); and
no change to what the surface-scope falloff does.

## Capabilities

### New Capabilities

- `pencil-interaction`: Move's scope is determined by what the drag starts on — vertex, edge
  loop, or surface — with cell-relative picking and the scope named in the viewport.

## Impact

- **Affected specs**: `pencil-interaction` (ADDED requirements; the merge requirement from
  `improve-vertex-merge` is narrowed by scope, not replaced — vertex and surface scopes keep
  merging their seed, loop scope does not merge).
- **Affected code**: `App/Sources/MeshEditController.swift` (scope decision at grab, dispatch
  per sample), a new `CyberKit` op for the rigid multi-vertex snapped move,
  `App/Sources/ViewportInputModel.swift` + `MetalViewport.swift` (scope hint), and the Move
  entry in the action help text.
- **Risk**: the pick order changes which vertex a drag grabs near an edge, so existing Move
  tests that start a drag close to an edge may now resolve to loop scope. That is the intended
  behavior change and the affected tests are listed in tasks.
