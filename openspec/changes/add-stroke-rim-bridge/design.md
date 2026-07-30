# Design: add-stroke-rim-bridge

## Where the decision is made

Recognition stays in the engine (design D1: both recognizer stages run in C++ so they are
headless-testable and portable). The rim WALK is composed in CyberKit from existing engine
queries and ops, exactly as the grid-continuation fill
(`MeshEditController.continueAdjacentBoundary`) and `WeaveFillDomain` already are — it
needs no new engine algorithm, only `boundaryChain` + `buildFace`.

```
stroke_interpreter.hpp   InterpretedAction::BridgeRims  (+ the loop-insert gate)
        ↓ elements = [vertex A, vertex B]
capi.cpp / cyber_capi.h  CYBER_ACTION_BRIDGE_RIMS
        ↓
StrokeInterpretation     Action.bridgeRims
        ↓
MeshRimBridge.swift      Mesh.bridgeRims(from:to:snapping:)   ← the walk + the quads
        ↓
MeshEditController       one journaled `pencil.bridgeRims` command
```

## Recognizer: telling a gap crossing from a loop cut

Both gestures are near-straight lines between two vertices. The discriminator is
`strokeCoversFace` — does any sample in the MIDDLE of the stroke (the first and last
sixth are ignored) have an existing face under it?

- **covers faces** → the kept LoopCut gesture: `insertLoop`, as before.
- **covers none** → candidate rim bridge, when both endpoints snap to distinct existing
  vertices that each carry at least one boundary edge and are not already adjacent.

The two are complementary by construction, so exactly one of them can fire and there is no
confidence race between them. The endpoint sixths are excluded deliberately: a stroke that
starts ON a rim vertex is a corner of that vertex's faces, and a point-in-polygon test at a
polygon corner is a coin flip.

The near-straight test is the one already in `tryOpenStrokeCreateFace` (max perpendicular
deviation < 12% of the chord) — the branch that returns "no face" today is where the bridge
rule is inserted, so a bent stroke keeps its existing quad/triangle reading untouched.

One more condition is needed, and a test found it: a stroke tracing a RIM passes the
no-faces test too, because a rim lies on the boundary of its faces rather than inside them.
So the stroke's MIDDLE must also clear every existing edge — by a fraction of the stroke's
own length, NOT by the pick radius. Camera distance is the trap here: at tablet zoom a real
gap crossing spans only a few percent of the viewport, so a radius-based test (the first
version used `fractionAlongEdges`) reads a legitimate crossing as running along the rims it
connects and refuses the very gesture the rule exists to accept.

## The walk: which way along each rim, and how far

`bridgeRims(from: A, to: B)` takes ONE corresponding pair and grows the strip:

1. **Rims.** A boundary edge incident to A gives A's boundary chain; likewise B. The two
   may be the same chain (one connected cage has ONE boundary loop, so the pictured case
   is two arcs of a single loop) — nothing in the walk assumes otherwise.
2. **Direction.** Each rim can be walked two ways, so four combinations. A combination is
   admissible when the two first steps run the SAME way in space
   (`dot(stepA, stepB) > 0`); the most parallel admissible one wins. The rejected
   antiparallel combinations are exactly the ones that would emit bow-tie quads, so this
   replaces a fold check with a direction choice.
3. **Stop conditions**, checked per step — the walk ends at the FIRST that trips:
   - a rim ran out (open chain end), or the next vertex is already used by either rim
     (the walk met itself around a closed loop),
   - the steps stopped running parallel (`dot ≤ 0`),
   - either rail stepped ALONG the gap rather than across it (|cos| against the current rung
     over 0.85): a rim that folds back up the corridor has stopped bounding it, and past that
     turn the two rims are just two edges of open surface. Found on device, where the walk
     stitched skewed quads over bare Target because the parallel and divergence tests both
     still passed on the domed cage,
   - the rims diverged: the pair is more than 2.5× the first pair's distance apart,
   - `maximumColumns` (24) — a bound against a runaway walk, matching
     `MeshEditController.maxPatchDimension`.
   - a ring the ENGINE refuses (already bounds a live face, or degenerate) ends the walk
     and keeps the columns already built.

   The ANCHOR span has one extra condition the later steps deliberately do not: it must be
   clear of other vertices, within 0.35 of a rim cell. That is what makes two points of the
   SAME rim stretch unbridgeable — their span runs straight through the vertices between
   them — and it is the op's own copy of the recognizer's rim test, so the public API is
   safe on its own. Measured in rim CELLS, not as a fraction of the span: a span-relative
   tolerance grows past the neighbouring rim vertices on a wide gap and refuses the
   multi-row bridges this op exists for.

   Applying that same test to the LATER steps was a bug, found on device: a corridor closed
   by a SUBDIVIDED wall has a rim vertex sitting right on the span between the rails' next
   pair, so the walk stopped with zero steps and the whole bridge came to nothing. Past the
   anchors a span may legitimately run along existing topology.
4. **Rows.** Where the corridor CLOSES, the cage has already subdivided the wall that
   closes it (`closingArc`): those rim vertices ARE the interior rows, and their count sets
   the row count — the same "continue the neighbour's loops" rule the grid fill uses. Read
   off the rim path rather than interpolated and radius-matched, because a real cage is
   domed: the straight chord between a wall's two ends bows away from the wall's own
   vertices, so a radius search misses them and leaves the wall T-junctioned against the
   bridge. "Short arc" is the qualifier that keeps this safe — on a connected cage ANY two
   rim vertices are joined by SOME boundary arc, so a candidate wall must run roughly
   straight across the gap (1.5x its span) and stay inside the row cap.

   With no closing wall, `rows = clamp(round(meanPairDistance / meanRimCell), 1, 8)` so the
   quads still come out roughly cage-sized instead of stretched, and the interior rows are
   interpolations snapped onto the Target by `buildFace`.

Because every quad is built on a RIM edge (one incident face) or on a previously created
bridge edge, a bridge can never stack a face on an existing one — the "never create over a
face" invariant is topological here, not a geometric test.

## Recovering created vertex ids

`buildFace` reports the committed ring, "which may be the reversed input when winding was
corrected against a neighbour". A shared interior vertex must be created ONCE and then
passed as `.existing` to its three other quads, so the walk has to map ring slots to
committed ids. Every ring the walk builds contains at least two `.existing` slots, and
their offset in the committed ring fixes the mapping (forward or reversed, with rotation
tolerated). A test asserts the mapping directly by rebuilding the grid's shared vertices.

## Deliberate omissions

- **No symmetry.** Mirroring a bridge means resolving the mirrored PAIR, not two
  independent mirrored vertices; a wrong pairing would emit a folded strip on the mirror
  side. The primary bridge only is applied.
- **No Auto Relax.** The spec requires rim vertices not to move, and the relax pass moves
  vertices near the edit. Bridging is therefore the one grammar entry that opts out.
- **No new engine op.** If profiling later shows the Swift walk is hot on a large rim, the
  walk is a self-contained function to lift into `retopo/actions.hpp` behind the same
  signature.
