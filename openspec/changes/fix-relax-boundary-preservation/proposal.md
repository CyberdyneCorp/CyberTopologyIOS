# Proposal: fix-relax-boundary-preservation

## Why

Relax is meant to even out the quads of a patch (uniform topology for animation /
sculpting), keeping the patch shape. Instead it collapses the patch into a
four-pointed star: the four corners are auto-pinned (valence ≤ 2) and stay put,
but the boundary EDGE vertices (valence 3) are relaxed toward their one-ring
centroid — which for a boundary vertex is the interior — so they pull inward
while the corners hold, spiking the silhouette. This is the reported bunny case
(a clean grid became a star after Relax). CozyBlanket's Relax preserves the
silhouette and only redistributes vertices for even spacing.

## What Changes

- **Relax is boundary-aware.** A boundary vertex (one on an edge bordering a
  single face) smooths ONLY along the boundary curve — toward the midpoint of its
  two boundary neighbours — so it evens its spacing without moving inward, keeping
  the silhouette. Interior vertices smooth toward their full one-ring centroid
  (uniform quads), as before. Corners (auto-pinned, valence ≤ 2) stay fixed. The
  move stays tangential and re-snaps to the Target.
- This applies to Relax, Relax-All, and Auto Relax (all call the same op).

## Impact

- Affected specs: `retopology-tools` (MODIFIED: Relax preserves the boundary).
- Affected code: engine `relax.hpp` (boundary-vs-interior smoothing target) +
  `neighbors.hpp` (`isBoundaryVertex` / `boundaryNeighbors`), delivered as
  `Engine/patches/0005`.
- Affected tests: a relax on an open patch keeps its boundary vertices on the
  boundary (silhouette preserved, no inward collapse) while the interior evens out.

## Non-Goals

- Full angle-based / area-weighted smoothing (cotangent weights) — this is uniform
  Laplacian with boundary preservation, matching the current interior behaviour.
- Smoothing the boundary curve toward a target shape; it only redistributes
  vertices along the existing boundary.

## Notes

Header-only engine change; rebuilt with limited parallelism. The interior
behaviour is unchanged, so existing relax tests (interior smoothing, pin honouring)
still hold; the new behaviour is that boundary vertices no longer migrate inward.
