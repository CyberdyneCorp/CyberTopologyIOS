# Tasks: add-halve-density

## 1. The op (CyberKit)

- [x] 1.1 `MeshHalveDensity.swift`: `Mesh.halveDensity()` with typed refusals
      (`notQuadOnly`, `loopMeetsPole`, `oddLoopCount`, `tooFewLoops`).
- [x] 1.2 Loop enumeration: partition the edges into loops via `edgeLoop(from:)`; order each
      family by walking a boundary side, which visits the perpendicular loops in sequence.
- [x] 1.3 Alternation keeps the BOUNDARY loops and dissolves the interior ones, so the
      silhouette survives.
- [x] 1.4 Per family, in order: `dissolveEdges(loop)` then remove the valence-2 vertices it
      leaves mid-side by `mergeVertices(keep: collinearNeighbour, remove: midVertex)` — the
      dissolve alone yields SIX-sided faces, not quads.
- [x] 1.5 Families are processed ONE AT A TIME. Dissolving both first strands each 2x2 block's
      centre vertex inside the merged face with no edges, which no `mergeVertices` cleanup can
      reach.
- [x] 1.6 Refuse BEFORE mutating: validate quad-only, loop walkability, and parity up front, so
      a refusal cannot leave a half-halved cage.

## 2. The command (App)

- [x] 2.1 `BatchCommand.halve` — title "Halve", notes naming the annotation clear,
      `requiresTarget: false`, `annotationPolicy: .rebuilt`.
- [x] 2.2 Wired into the batch-command run path as one journal entry.
- [x] 2.3 `halveRefusal(_:)` puts the reason in the status line, in the artist's terms, and
      rethrows so the transaction is discarded byte-clean.

## 3. Tests

- [x] 3.1 A 4x4 grid halves to 2x2: face count, quad-only, and vertex count all as predicted.
- [x] 3.2 Silhouette: every surviving vertex position existed before, and the boundary loop
      passes through the same points.
- [x] 3.3 The result is a valid quad grid — no valence-2 vertices and no n-gons left behind
      (the assertion that pins step 1.4; without the cleanup this fails with six-sided faces).
- [x] 3.4 One undo restores the payload bytes (controller test).
- [x] 3.5 Each refusal, with the mesh unchanged: a triangle in the cage, a pole, an odd loop
      count, a single-loop cage.
- [ ] 3.6 (not done) Round trip: subdivide then halve returns the original face count (positions need not
      match — subdivision moves vertices, halving does not put them back).
- [x] 3.7 Suite mirrored into the app-hosted target so it runs on device.
- [ ] 3.8 Every fix verified to FAIL without it — the discipline this session settled on after
      two tests that passed for the wrong reason.

## 4. Close out

- [ ] 4.1 `openspec validate --all --strict`.
- [ ] 4.2 Simulator + device counts.

## 5. The repeated-halving bug: not in this algorithm

Halving an already-halved cage stranded a vertex. The cause was in NEITHER the halving nor the
engine primitives it composes — both were verified directly (`dissolveEdges` leaves exactly the
six-sided face and two live valence-2 vertices the design assumes; face winding stays
consistent; the dissolved loops are straight; the ring length is right; an offline replay of the
walk on the real dumped mesh produced perfect rings).

It was every scan that enumerates elements by PROBING IDS, all bounded by `live * 2 + 64`.
Stable ids are SPARSE, so that bound is unsound: as edits remove elements the live count falls
while the ids stay high, and the ceiling drops below them. Measured on the failing mesh — 40
live edges with live ids up to 143; the pass's own dissolve then dropped it to 32 live, putting
the ceiling at 128 and hiding every edge above it, including BOTH remaining edges of the vertex
that stranded, which is why it looked like a vertex with no neighbours.

- [x] 5.1 Engine: `cyber_mesh_vertex_capacity` / `cyber_mesh_edge_capacity` (patch 0025) —
      the C++ `Mesh` already had `vertexCapacity()`/`edgeCapacity()`; only the C ABI lacked them.
- [x] 5.2 CyberKit: `Mesh.vertexCapacity` / `Mesh.edgeCapacity`.
- [x] 5.3 Every id-probing scan now runs to the capacity. SIX sites, three of them shipped
      earlier TODAY and carrying the same latent bug:
      `MeshHalveDensity` (2), `MeshRimBridge` (1 — the rim bridge would have failed on a
      heavily edited cage, exactly the workflow it is for), `MeshEditController` (2 — the
      cell-relative merge range and the rim-following seed search), `WeaveFillDomain` (1,
      pre-existing).
- [x] 5.4 `repeatedHalvingSteppsDown` re-enabled, and `capacityBoundsTheIdSpace` pins the
      invariant directly.
- [x] 5.5 The three throwaway probes (mesh dump, dissolve semantics, id sparsity) retired once
      they had answered their questions; `strandedMidVertex` stays as a real refusal, since a
      silent skip there is what let the corruption through in the first place.

## 6. Close out

- [x] 6.1 `openspec validate --all --strict`: 34/34.
- [x] 6.2 Simulator 1106/1106 + 475/475; device (iPad, 6 suites incl. the mirrored halve suite,
      the rim bridge, patch fill and the batch commands) 114/114 — the device run deliberately
      spans all four of today's features, since the id-capacity fix touched three of them.
- [x] 6.3 Batch command + device mirror done; controller tests cover the button end to end and
      the refused case journaling nothing.
