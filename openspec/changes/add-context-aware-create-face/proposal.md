# Proposal: add-context-aware-create-face

## Why

Drawing a face by hand should read the surrounding topology. Today it does not:
an OPEN stroke drawn between two existing vertices — the natural way to fill a
missing quad against adjacent geometry — is not recognized. It fails the
"nearly-closed rescue" gate (an L-shape's endpoints sit ~71% of the path length
apart, past the 65% threshold) and falls to `Unknown`, so nothing is created.
That is the exact gap in the reported case: an L drawn around an empty cell
produced no quad.

Two more context gaps compound it: the recognizer never uses the stroke's
ENDPOINTS to anchor a face to existing vertices (welding is incidental to being
near a corner, and only for closed strokes), and there is NO check preventing a
new face from being stacked directly on top of an existing one — a duplicate
vertex-set face is created without complaint.

## What Changes

- **Open stroke between two vertices → a welded face.** When an open stroke's
  start and end both snap to existing EditMesh vertices (A, B), the recognizer
  interprets it by the sharpness of its dominant bend C:
  - a **sharp (~90°) corner** means two sides of a rectangle were traced →
    **QUAD** with corners `[A, C, B, A+B−C]` (the 4th corner completes the
    parallelogram, welding to a vertex there if one exists);
  - a **gentle bend** means two sides of a triangle were traced → **TRIANGLE**
    `[A, C, B]`;
  - a **near-straight** stroke stays an edge/loop gesture — no face.
  The endpoints A and B are the projected positions of the snapped vertices, so
  the existing weld path shares them; nothing floats.
- **Never stack a face on an existing face.** A build-face op rejects a ring
  whose resolved vertex set already bounds a live face (protects every create
  path), and the recognizer suppresses a create candidate whose interior already
  contains a face, rather than offering it at reduced confidence.

## Impact

- Affected specs: `pencil-interaction` (ADDED: context-aware open-stroke face
  creation; no-overlap rule).
- Affected code:
  - Engine (`stroke_interpreter.hpp` + build-face op, delivered as
    `Engine/patches/0004`): the open-stroke create rule in `interpretStroke`
    (endpoint snap + bend classification + corner ring), and a duplicate-face
    guard in `cyber_retopo_build_face`.
  - App: none expected for creation — the existing `createWeldedFace` apply path
    consumes the emitted corner ring and welds it; a guard so a rejected
    (overlapping) build is inert.
- Affected tests: engine interpreter tests (L→quad, gentle→triangle,
  straight→no-face, over-face suppressed, endpoints welded) and app-hosted
  create/weld/overlap tests.

## Non-Goals

- **Full spatial-overlap detection** (a face partially covering another without
  sharing all vertices) — this change guards the exact-duplicate case and
  suppresses create when the ring's interior is already faced; arbitrary
  coplanar-overlap rejection is deferred.
- **Snapping the bend C or the 4th corner to arbitrary nearby edges** — C is the
  drawn bend; the 4th corner welds only if a vertex is within range.
- Changing the closed-stroke quad/triangle behaviour beyond adding the
  no-duplicate guard.

## Notes

Most of the work is the engine interpreter rule; the app's weld-on-create path
(`createWeldedFace`) already shares the endpoints because the emitted corners sit
on the existing vertices' screen positions. The engine rebuild uses limited
parallelism (`CMAKE_BUILD_PARALLEL_LEVEL=2`) to stay within memory.
