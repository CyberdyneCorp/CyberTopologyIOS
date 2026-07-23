# Proposal: simplify-gesture-grammar

## Why

Device testing on 2026-07-22 (iPad Air 13-inch M3, real Target: a 4824-vertex
Meshy AI model) showed the Pencil gesture grammar is not usable for its
primary job — drawing quads. Recorded from the debug HUD, the SAME intended
gesture resolved four different ways across consecutive strokes:

```
shape=closedLoop conf=0.85 context=emptySurface; createQuad:0.85   <- intended
shape=lasso      conf=0.60 context=emptySurface; hideRegion:0.36   <- hid faces
shape=scribble   conf=0.80 context=emptySurface; dissolveEdge:0.64 <- "no change"
shape=unknown    conf=0.30 context=emptySurface; none:0.20         <- "not recognized"
```

The cause is structural, not tuning noise. `classifyShape`
(`stroke_interpreter.hpp`) separates NINE shapes with hand-tuned thresholds,
and the branch that produces `createQuad` is the narrowest of them: it
requires the stroke to be closed (endpoint gap < 22% of path length) AND to
have zero self-intersections AND 3-6 corners. Two things a human hand does
routinely fall outside it:

- **Overshooting the join** adds a self-intersection at the seam, demoting a
  closed quad to `Lasso` -> `hideRegion`.
- **Stopping short of the join** leaves an open stroke. Measured gap ratios
  on real device strokes: **0.21** — straddling the 0.22 threshold, so
  identical gestures classify differently run to run. The seam corner never
  registers on an open stroke, giving 3 corners, which falls past every
  open-shape branch to `Unknown`.

An attempt to widen these thresholds directly (engine patch 0023, NOT landed)
demonstrated why the current grammar cannot absorb the fix: raising
`closedFraction` reclassified X strokes and scribbles as closed (both have
near-coincident endpoints), breaking `deleteFaces` and `dissolveEdge`; and a
"nearly closed" rescue branch was claimed first by grid detection, then
broke `scribbleOverEdgeDissolvesItIntoOneQuad`. Every workable loosening of
the quad branch collides with a neighbouring gesture. **The thresholds are
over-constrained because the grammar is too large.**

Separately, the `createQuad` gesture does not weld to existing topology.
Drawing a quad against an existing quad's edge produces a free-floating face
(8 v / 2 f — two disconnected quads) where the reference application
produces a shared edge (10 v / 11 e -> 12 v / 14 e: +2 vertices, +3 edges,
+1 face). The Build Quad TOOL already implements release-merge (task 4.1);
the gesture path does not.

## What Changes

- **Reduce the Pencil gesture grammar to four actions**: create quad face,
  create triangle face, delete faces, and insert an edge loop (a straight
  line drawn ACROSS a quad ring). Remove `hideRegion`, `dissolveEdge`,
  `tagLoop`, `mergeVertices`, `rotateEdge`, `createGrid`, and
  `toggleVisibility` from the stroke grammar.
  - Device feedback (2026-07-22) revised the original strict-three target:
    `insertLoop` is kept because a line ACROSS a ring is geometrically
    distinct from a closed quad outline, a self-crossing X, and a three-corner
    triangle — it never competed for the quad branch — while `tagLoop` (a line
    ALONG a loop) DID collide with it and is removed. A line is now always
    read as an insert loop.
  - The removed capabilities do NOT disappear — they remain available as
    explicit armed TOOLS (the task 4.1/4.2 `RetopoTool` layer) and as batch
    commands. Only the *gesture* bindings are removed. A tool the user arms
    deliberately cannot be triggered by a misread stroke.
- **Collapse the shape classifier accordingly.** With only four actions,
  the classifier separates closed-quad / closed-triangle / X-ish /
  line-across-ring / everything-else instead of nine shapes. `Grid`, `Lasso`
  and `Scribble` leave the grammar's decision path; `Circle` resolves to a
  quad.
- **Re-tune closed-vs-open against the reduced grammar.** With no scribble,
  grid or lasso competing, the nearly-closed rescue can be aggressive: an open
  stroke with quad-like corner structure is a quad. Seam-overshoot
  self-intersections stop disqualifying a closed stroke.
- **Weld created faces onto existing topology.** Corners landing within a
  scale-free radius of an existing vertex reuse it; corners landing on an
  existing edge split/share it. Same semantics as the Build Quad tool's
  release merge, applied to the gesture path, inside the stroke's single
  journal entry.

## Impact

- Affected specs: `pencil-interaction` (gesture grammar table, stroke
  feedback), `retopology-tools` (face creation welding).
- Affected code: `stroke_interpreter.hpp` (engine patch), `ActionCatalog`,
  `MeshEditController`, toolbar/gallery entries, interpretation chip
  alternatives.
- Affected tests: the committed stroke corpus and its goldens shrink with
  the grammar. `dissolve_scribble_pencil`, `hide_lasso_pencil`,
  `grid_pencil`, `x_delete_pencil` and their interpretation goldens either
  retire or move to tool-driven coverage.
  `MeshEditControllerTests/scribbleOverEdgeDissolvesItIntoOneQuad` retires
  with the gesture; edge dissolve keeps tool-level coverage.
- Traceability: grammar scenarios in `tests/traceability.yaml` under
  `pencil-interaction` need rewriting against the four-gesture table.

## Prerequisite: record real strokes first

Two attempts to fix this were driven by SYNTHESIZED strokes and both
misled — a programmatic square is either perfectly closed (never exercising
the rescue) or a perfect square wave (claimed by grid detection). Neither
resembles the device strokes in the HUD log above.

Before re-tuning, capture 3-5 real failing strokes off the device with the
task-1.1b fixture recorder and commit them. The re-tune is then driven by
hand geometry that actually occurs, and the acceptance criterion is
mechanical: every committed real quad stroke resolves to `createQuad`.
