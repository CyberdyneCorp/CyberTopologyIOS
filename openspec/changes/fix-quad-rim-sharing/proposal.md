# A created quad shares the rim it was drawn along

## The report

Device, 2026-07-29, 54v/39f cage. Two L-shaped strokes traced along the cage's own rim and
then across the gap. Both resolved to `createQuad` and both produced a face that does not
share the topology it was drawn against — the artist's question was exactly *"why are the
quads not sharing the same edge?"*

```
unknown 0.30 on emptySurface
1. createQuad 0.85 [vertex:38,vertex:21]
2. bridgeRims  0.24 [vertex:38,vertex:21]
```

## Why

Two independent defects, measured by replaying the recorded strokes through the recognizer's
own resampler and corner scan.

**A multi-cell region becomes ONE face** — this is the whole of it, and the second defect
below is why. Read by its dominant bend, the L builds the ring `[A, bend, B, A+B−bend]`,
which for stroke 28 is a parallelogram across the artist's entire top-right region. That ring
is CORRECT as an outline; what is wrong is that it is committed as a single face rather than
subdivided against the topology it was drawn along.

**Hardening, NOT a proven cause: a rounded bend can be counted twice.** `cornerIndices`
suppresses one window after a detected corner, and a hand-drawn rounded turn can still be
turning after that skip, which would let the U branch (`corners.size() >= 2`) read one bend as
two and build a ring with two nearly coincident corners. An offline replay of stroke 28 showed
exactly that — indices 27 and 31, 0.08 of the chord apart — but that replay assumed a SQUARE
viewport, and the device runs at ~1.33; replaying the recorded stroke through the real
recognizer produces a well-proportioned ring with no collapsed side, before any fix. So the
distinctness condition below is defensible hardening of a branch whose own comment says "two
corners = a U", and it is NOT the explanation for the screenshots. It ships labelled as such,
without a failing-first test.

**A multi-cell side is still ONE edge.** `createWeldedFace` welds the four CORNERS to
existing vertices within a pick radius. A quad SIDE that spans several existing cells stays a
single edge, so every rim vertex it passes is left T-junctioned against it — a crack, not a
shared edge. `continueAdjacentBoundary` (change `add-grid-continuation`) is the mechanism
meant to prevent this by extruding the neighbour's boundary chain instead, and it did not run.

Its seed is what fails. It asked for the edge nearest the drawn side's midpoint and then
tested whether that edge happened to be a boundary — but a side traced along a rim has that
rim's INTERIOR neighbours the same distance away (both touch the midpoint vertex), so which
one the query returns is arbitrary. Land on an interior edge and the whole continuation bails
out, leaving the single stretched face. Measured: `rimRun`'s first version reproduced the bail
exactly, `chain → nil` for a side lying ON the rim.

Its trigger is the second, narrower limitation: it fires only for a side whose TWO CORNERS
both snap to existing vertices. An L-derived ring has two corners hanging in mid-air (the
bend, and the inferred fourth corner) and its two existing vertices sit at ring positions 0
and 2 — diagonal, never a side. When the bend happens to land on a vertex the gate passes
anyway, which is why the seed bug is the one the regression test pins down; the gate is
widened here because a bend in open space is equally legitimate and would fail on its own.

## What Changes

- **A rounded bend is one corner.** The two-corner branch SHALL require the two corners to be
  genuinely separated, in stroke order and in space, before reading a stroke as a U.
  Otherwise the stroke takes the single-bend path it always should have.
- **A quad side that FOLLOWS a rim subdivides against it.** The grid-continuation trigger
  becomes geometric rather than corner-based: a side is continued when an existing boundary
  chain runs ALONG it (its vertices lie on the side and cover most of it), whatever the ring's
  corners happen to be. The chain is extruded across the drawn region as before, so the new
  quads continue the rim's loops at the rim's cell size.
- **A patch that lands on another rim closes onto it.** Vertices created by the extrusion weld
  onto coincident existing vertices, so a patch filling the inside of an L meets the second
  rim instead of duplicating it.

Non-goals:

- **Confidence is untouched.** `createQuad` keeps its fixed 0.85. Scaling it by shape
  confidence would demote every legitimate quad drawn with a sloppy stroke, which is what
  `simplify-gesture-grammar` deliberately tuned against.
- **No new gesture.** This is the existing create path doing what it already claimed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `pencil-interaction`: strengthens the created-face requirements — a rounded bend counts once,
  and a face drawn along existing topology shares it.

## Impact

- `Engine/CyberRemesherAndUV/src/retopo/include/cyber/retopo/stroke_interpreter.hpp` (patch
  0024): the distinct-corner condition.
- `App/Sources/MeshEditController.swift`: `continueAdjacentBoundary` triggers off the rim a
  side follows, and welds the created patch onto whatever rim it lands on.
- Tests: recognizer tests for the L vs U reading, and a controller test asserting the created
  patch shares every vertex of the rim it was drawn along.
