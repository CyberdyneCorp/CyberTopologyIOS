# Design: painted-region retopo

## D1. The solve domain is CARVED on the live mesh, before serializing

`beginAutoRetopoAsync` sends the Target off-main as `payloadData()` and rebuilds it there, so the
solve never blocks the UI. Face ids CANNOT cross that boundary: `payloadData()` round-trips
through OBJ, which renumbers every element (`Mesh.duplicated` documents this).

So `AutoRetopoSession.prepare(target:region:params:)` runs on the main actor, where the painted
ids are valid, carves the domain, and hands the thread boundary GEOMETRY. Off-main always solves
`.wholeMesh`.

**Found on device.** The first cut passed `.faces(ids)` off-main to be carved there. The painted
extent drew correctly, the artist ran Auto-Retopo, and nothing happened: the ids named arbitrary
faces of the deserialized mesh — or nothing at all, and `solveOffMain`'s `catch { return nil }`
swallowed it silently. The carve failure is now logged, and
`theSolveDomainIsCarvedBeforeSerializing` asserts what crosses is the carve.
`faceIDsDoNotSurviveAPayloadRoundTrip` states the trap once so it is not re-introduced.

## D2. Carving, not teaching the remesher about regions

`EngineRemeshSolver.carved` duplicates the source and deletes every face outside the region. The
existing whole-mesh remesher then produces a cage covering exactly the painted area, with its own
open boundary — and no engine change is needed.

It is also honest about the result: the solver genuinely sees a smaller model, so density,
boundaries, progress and cancellation behave exactly as they do for a whole mesh.

Refusals: an empty region has nothing to solve, and a region naming EVERY live face is a
whole-mesh solve wearing a disguise — refusing surfaces a selection bug instead of hiding it.
Dead ids are ignored, because a Target can be reloaded under a stale selection.

## D3. The quad budget follows the painted share

A budget is a statement about the whole model ("about 1500 quads for this bunny"). Applied
unscaled to a patch it asks for the entire model's topology inside one ear.

Measured: a 12-face carve at the engine's raw 50 000-quad default did NOT finish inside a minute,
and an obsolete refusal test took 156 s once it started really solving. Scaled by the share, the
same solve takes 0.104 s. Without this the feature would have shipped as a hang on any small
selection.

The scaling lives in `prepare`, beside the carve, because off-main only ever sees a whole mesh and
therefore cannot know the region was a tenth of a model.

## D4. Accept MERGES into the existing cage

`Mesh.append` copies the patch's faces in over `buildFace`, preserving the patch's own shared
edges (a vertex map, so a face reusing an earlier face's vertex shares it) and its exact positions
— no snapper, since the solver's result already lies on the Target and re-snapping would move it.

Nothing is welded to the receiving cage. The cage is hand-authored, and a silent weld would move
vertices the artist placed; the patch's border sits coincident until they merge it with the tools
that exist for that. With no cage present, the patch becomes the cage.

## D5. Painting collects Target FACES, and the mask is transient

Each stroke sample raycasts a 9-point ring at `regionPaintRadiusFraction` (3% of the scene radius)
so a stroke paints a band rather than a one-face scratch. `SurfaceSnapper.raycast` already reports
the Target face id, so no new picking is needed.

The region is viewport state: never journaled, never persisted, and cleared when a solve RUNS
rather than when it is accepted. A stale extent silently shaping the next solve is worse than
repainting.

The extent renders as a non-pulsing teal fill on its OWN ghost-pipeline instance, under the cage:
it says where the solver may work, so it must not cover the geometry being judged.
