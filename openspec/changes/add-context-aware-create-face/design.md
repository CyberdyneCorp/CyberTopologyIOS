# Design: add-context-aware-create-face

## Context

The recognizer is two-stage: `classifyShape` (pure screen-space shape) then
`interpretStroke` (mesh-context resolver with a `ScreenProjection`). Only stage 2
can see the mesh, so endpoint-to-vertex snapping and over-face checks live there.
The app's `createWeldedFace` already welds an emitted corner ring to nearby
vertices in world space, so once stage 2 emits the right corners at the vertices'
screen positions, the endpoints are shared automatically.

## Engine: open-stroke create rule (`interpretStroke`)

Runs when `classifyShape` returned `Line` or `Unknown` (open strokes that today
make no face), before falling through:

1. **Snap endpoints.** `A = proj->nearestVertex(stroke.front(), vertexRadius)`,
   `B = proj->nearestVertex(stroke.back(), vertexRadius)`. Require both present and
   `A != B`. `Ascreen = proj->screen(A)`, `Bscreen = proj->screen(B)`.
2. **Find the dominant bend C** — the stroke sample of maximum perpendicular
   distance from the chord `Ascreen–Bscreen` (robust for an L). If the max
   deviation is tiny (near-straight), stop — no face.
3. **Classify by the angle at C** between `Ascreen−C` and `Bscreen−C`
   (`cos = dot(normalize…)`):
   - sharp corner (`|cos| < ~0.5`, ≈60–120°) → **QUAD**, ring
     `[Ascreen, C, Bscreen, Ascreen + Bscreen − C]` (parallelogram completion);
   - gentle (`-0.94 < cos ≤ ~-0.5`, ≈120–160°) → **TRIANGLE**, ring `[Ascreen, C, Bscreen]`;
   - near-straight (`cos ≤ -0.94`, >160°) → no face.
4. **Suppress over an existing face.** Compute the ring centroid; if
   `proj->faceContaining(centroid)` is a live face, do not offer the create.
5. Set `out.shape.corners = ring` and `addCandidate(CreateQuad|CreateTriangle,
   conf, {Vertex A, Vertex B})`. The app reads `out.shape.corners` and welds.

`out.shape.shape` stays as classified; only `corners` and the candidate change.
This does not disturb the `Line`→insert-loop path: the open-create rule only fires
when both endpoints snap to vertices AND a real bend exists, which a loop-cut line
across a face ring does not satisfy (its endpoints are off in empty space).

## Engine: duplicate-face guard (`cyber_retopo_build_face`)

After the ring's vertices are resolved (existing + newly created), reject the build
if a live face already has exactly that vertex set (order-independent). Uses the
mesh's faces-around-a-vertex adjacency on the first ring vertex — O(faces touching
one vertex). This protects EVERY create path (open, closed, tool), so the app needs
no new overlap query. A rejected build throws; the app's `journalOrDiscard` already
turns a throw into an inert (non-journaled) stroke.

## App

No change expected for creation: `applyBestCandidate` already applies
`createWeldedFace(at: interpretation.quadCorners, …)` for `CreateQuad`/`CreateTriangle`,
and `quadCorners` is `out.shape.corners`. The duplicate-face rejection surfaces as a
thrown error the existing discard path swallows. A test confirms the inert behaviour.

## Key decisions

### D1 — Endpoint anchoring by emitting corners at the vertex screen positions
Rather than plumb weld-vertex refs through to the app, the engine emits the ring's
A/B corners exactly at the snapped vertices' screen positions; the app's existing
world-space weld re-snaps them onto those vertices. Minimal surface, reuses the
proven weld path. (Candidate `elements` still carry the vertex refs for provenance.)

### D2 — Bend classification, not corner counting
Per the chosen rule: one bend whose sharpness decides quad vs triangle (a sharp
corner traces a rectangle → complete it; a gentle bend traces a triangle). Matches
the drawn intent better than counting corners (a single L-bend would otherwise be a
triangle).

### D3 — Overlap: exact-duplicate guard + interior-face suppression
The universal, well-defined cases. Exact-duplicate is caught at build time (all
paths); "interior already faced" is caught at interpret time for the create gesture.
Arbitrary partial coplanar overlap is a named non-goal.

## Risks / Trade-offs

- **Bend thresholds need tuning** — the sharp/gentle/straight cutoffs are cosine
  bands; the tests assert the three regimes and the thresholds can be adjusted from
  the device corpus later.
- **Interior-face suppression could block a legitimately-intended overdraw** — but
  the user's explicit intent is "no face on top of an existing face", so suppression
  is correct here.
- **Engine rebuild** — patch 0004; built with `CMAKE_BUILD_PARALLEL_LEVEL=2`.
