# Design: context-aware Move

## D1. The scope is decided ONCE, at grab

`strokeBegan` resolves a `MoveScope` and stores it on the session; every later sample reads it.
It is not re-evaluated per sample.

Why: the drag's meaning must not change under the finger. Re-picking per sample would let a
vertex-scope drag become a loop-scope drag simply by passing near an edge mid-gesture, and the
journal entry (one per drag) could then describe something the artist never started.

```
enum MoveScope {
    case vertex(UInt32)          // that vertex alone
    case loop([UInt32], seed: UInt32)   // loop vertices, rigid
    case surface(seed: UInt32)   // today's geodesic falloff
}
```

## D2. Pick order: vertex, then edge, then face

At the surface hit point, BOTH candidates are gathered with the same generous reach
(`sceneRadius × vertexPickRadiusFraction`, today's grab radius) and only then judged against
the cell-relative windows:

1. a vertex within `vertexWindow` of the hit → `.vertex`
2. else an edge within `edgeWindow` of the hit → walk the loop → `.loop`
3. else a vertex within the reach → `.surface`
4. else inert, exactly as today

Vertex wins ties because it is the more precise intent: every vertex also lies on edges, so an
edge-first order would make single-vertex scope unreachable.

Step 3 keeps today's grab radius so that starting anywhere on a face still finds a seed — the
surface scope must not become harder to reach than it is now.

**Corrected during implementation.** The first cut nested the edge query inside a successful
vertex grab, so a hit had to be near a vertex before an edge was even considered. On a cage
that is coarse relative to its scene that is unsatisfiable: a 2-unit cell in a scene of radius
7 puts the cell's midpoint 1.0 from either vertex against a reach of 0.85, so loop scope was
unreachable and — because the grab failed outright — the whole stroke went inert. The tests
caught it as "no journal entry at all". Gathering both candidates independently fixes it, and
`resolveMoveScope` now returns nil only when NEITHER a vertex nor an edge is within reach.

## D3. The windows are cell-relative, not scene-relative

`vertexWindow` and `edgeWindow` are fractions of the LOCAL cell — the mean length of the edges
meeting the candidate vertex — reusing the measure `mergeRange(around:in:sceneRadius:)`
already establishes, with the same floor so a degenerate cell cannot make a scope unreachable.

Why: a scene-relative window has been the defect four times in this line of work. On a fine
cage `sceneRadius × 0.12` covers many cells, so it cannot express "on this vertex"; on a coarse
cage the same number is a fraction of one cell.

| window | value | reasoning |
|---|---|---|
| `vertexWindow` | 0.25 × cell | inside the half-cell separating a vertex from the edge midpoint, so a touch aimed at a vertex is not competing with the edge |
| `edgeWindow` | 0.15 × cell | a THIN band, because a band runs along every side of a face and eats its interior fast (below) |

**Corrected after device testing.** The first values (0.30 / 0.35) were sized only against each
other, and that is the wrong constraint. The binding one is the FACE INTERIOR: vertex and edge
are targets the artist aims at, while the face is the default they fall back to, so surface has
to be the dominant region of a cell.

For a square cell the surface region is what survives inside all four edge bands, `(1 - 2e)²`:

| `edgeWindow` | surface share of a square cell |
|---|---|
| 0.35 | 9% |
| 0.25 | 25% |
| 0.15 | **49%** (measured on a 9×9 lattice: 60%) |

A TRIANGLE sets the hard ceiling. Its farthest interior point from any edge is the incenter,
and for the right-isoceles triangle a triangulated quad produces that is ~0.26 of the mean
edge — so any `edgeWindow` at or above 0.26 covers the entire triangle and surface scope inside
one is not rare but *impossible*. Device testing reported exactly this: starting a drag on a
face or triangle no longer stretched the patch. Both cases are now regression tests
(`theInteriorOfATriangleResolvesToSurfaceScope`,
`mostOfAQuadsInteriorResolvesToSurfaceScope`), with
`aTouchAimedAtAnEdgeStillResolvesToLoopScope` as the counterweight against over-shrinking.

## D4. Loop motion is rigid, and comes from the engine's own loop walk

The loop is `edgeLoopVertices(from:)` — the same walk that backs per-loop pinning and Loop
Info, so a loop drag moves precisely the set the artist can already pin and inspect.

Each sample applies the FULL drag delta (`hit - anchor`) to every loop vertex and re-snaps,
then advances the anchor, mirroring how surface scope integrates its displacement. The loop
keeps its shape and shifts as a unit.

Fallback: if the walk returns fewer than 3 vertices — a pole, a boundary, a non-quad
neighbourhood where the loop cannot be walked end to end — the scope degrades to the picked
edge's two endpoints rather than doing nothing. A drag that visibly grabbed an edge must move
something; silently inert is the failure mode this line of work keeps removing.

## D5. Pins hold, and a pinned loop shears

Pinned vertices are excluded from the displaced set in every scope, per the existing
requirement that Move SHALL NOT displace a pinned vertex.

Consequence, accepted deliberately: dragging a loop with one pinned vertex shears that loop
rather than moving it rigidly. The alternative — refusing the drag, or moving the pin — either
makes pins a trap or breaks a stated invariant. The chip can say the loop is partly pinned;
the geometry follows the pins.

## D6. The multi-vertex move belongs in CyberKit, not the controller

A new op, `Mesh.moveVertices(_:by:pinned:snapping:)`, applies a displacement to a set of
vertices with snapping and pin exclusion. `MeshRimBridge` and `MeshHalveDensity` set the
precedent: composed ops live in CyberKit, and the controller only decides WHICH vertices and
WHY (design rule D1 — no mesh algorithms in the app layer).

VERTEX scope goes through this op too, rather than through `tweakVertex` as first planned, for
two reasons: `tweakVertex` "ignores pins by design" (correct for Tweak, wrong for Move, which
is specced never to displace a pinned vertex), and a displacement keeps the grabbed vertex's
offset from the finger instead of teleporting it to the touch on the first sample.

No engine patch is required: the loop walk and snapped per-vertex placement already exist
across the C API.

## D7. One journal entry per drag, named by scope

Journalled verbs: `move.vertex`, `move.loop`, and `move` for surface scope (unchanged, so
existing history and tests keep their meaning). The merge suffix composes as today:
`move.vertex.mergeSnap`. Loop scope never merges, so `move.loop.mergeSnap` cannot occur.

## Alternatives considered

- **Falloff along the loop** (grabbed end moves fully, fading along the loop): rejected in
  review — a loop is a structural line in a cage, and bending it from a single grab is a
  sculpting gesture, not a retopology one. Rigid keeps the loop's shape, which is the property
  that makes loops worth having.
- **Merging on loop release**: rejected. A loop dropped near its neighbour would collapse a
  whole ring of topology from one gesture, and the artist cannot see every vertex's merge
  candidate at once.
- **Re-picking scope per sample**: rejected, see D1.
- **A modifier (long-press, second finger) to choose scope**: rejected — it adds a mode to a
  gesture the artist already aims precisely. What is under the finger IS the modifier.
