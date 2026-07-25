# Tasks: add-context-aware-create-face

## 1. Engine: open-stroke create rule (patch 0004)

- [ ] 1.1 In `interpretStroke`, add an open-stroke create path (fires on `Line` /
      `Unknown` when `proj` is present): snap `stroke.front()`/`stroke.back()` to
      existing vertices A, B (`nearestVertex`, `vertexRadius`); require both and A≠B.
- [ ] 1.2 Find the dominant bend C (max perpendicular deviation from the A–B chord);
      classify by the angle at C: sharp → QUAD `[A, C, B, A+B−C]`; gentle → TRIANGLE
      `[A, C, B]`; near-straight → no face.
- [ ] 1.3 Suppress when the ring centroid is over a live face (`faceContaining`).
- [ ] 1.4 Set `out.shape.corners` = ring; `addCandidate(CreateQuad|CreateTriangle,
      conf, {Vertex A, Vertex B})`. Do not disturb the Line→insert-loop path.

## 2. Engine: duplicate-face guard

- [ ] 2.1 In `cyber_retopo_build_face`, after resolving the ring's vertex ids,
      reject (error, mesh unchanged) when a live face already has that exact vertex
      set (order-independent), via faces-around-first-vertex.

## 3. Build

- [ ] 3.1 Generate `Engine/patches/0004-*.patch` (isolated from 0001-0003 via a temp
      base tree); verify the full stack applies; rebuild the engine (limited
      parallelism); update build_engine.sh docs.

## 4. App

- [ ] 4.1 Confirm the create apply path consumes the emitted ring and welds (no
      change expected); a rejected duplicate build stays inert (no journal entry).

## 5. Tests (device + simulator)

- [ ] 5.1 Engine interpreter (CyberKit `StrokeInterpretation`): an L-shaped stroke
      between two vertices → CreateQuad with a 4-corner ring welding the endpoints;
      a gently-bent stroke → CreateTriangle; a straight stroke → no create.
- [ ] 5.2 Over-face suppression: a create stroke whose interior is over an existing
      face offers no create.
- [ ] 5.3 Duplicate-face guard: building a face with an existing face's vertex set
      is rejected and the mesh is unchanged.
- [ ] 5.4 App-hosted: drawing an L between two cage vertices creates one welded quad
      (vertex count grows by the new corners only, endpoints shared); undo restores.

## 6. Validation

- [ ] 6.1 `openspec validate add-context-aware-create-face --strict`.
- [ ] 6.2 Full suite green on simulator AND device.
