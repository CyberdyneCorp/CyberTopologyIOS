# Tasks: fix-relax-boundary-preservation

## 1. Engine (patch 0005)

- [x] 1.1 `neighbors.hpp`: `isBoundaryVertex` (an incident edge borders one face)
      and `boundaryNeighbors` (neighbours via boundary edges).
- [x] 1.2 `relax.hpp`: a boundary vertex smooths toward the midpoint of its two
      boundary neighbours (along the boundary); non-manifold / single-neighbour
      boundary vertices are left fixed; interior unchanged (one-ring centroid).
- [x] 1.3 Generate `Engine/patches/0005-*.patch`; verify the full stack applies;
      rebuild the engine (limited parallelism); update build_engine.sh docs.

## 2. Tests (device + simulator)

- [x] 2.1 Relax on an open patch keeps every boundary vertex on the boundary and
      does NOT shrink the silhouette (bounding-box / boundary preserved), while a
      perturbed interior vertex moves toward even spacing.
- [x] 2.2 Existing relax tests (interior smoothing, pin honouring) still pass.

## 3. Validation

- [x] 3.1 `openspec validate fix-relax-boundary-preservation --strict`.
- [x] 3.2 Full suite green on simulator (751 app-hosted, 308 tool-hosted). Device pending.
