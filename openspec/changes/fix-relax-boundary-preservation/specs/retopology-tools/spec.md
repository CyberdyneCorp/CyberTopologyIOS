# retopology-tools — Delta Spec (fix-relax-boundary-preservation)

## ADDED Requirements

### Requirement: Relax preserves the patch boundary
Relax SHALL preserve the boundary silhouette of the patch it smooths: a boundary
vertex (one on an edge bordering a single face) SHALL be moved only along the
boundary curve — toward the midpoint of its two boundary neighbours — and SHALL NOT
be moved toward the interior. Interior vertices SHALL smooth toward their one-ring
centroid for even quads, and auto-pinned corners SHALL stay fixed. Relax SHALL NOT
collapse an open patch inward.

#### Scenario: The boundary stays on the boundary
- **WHEN** Relax is applied to an open quad patch
- **THEN** every boundary vertex SHALL remain a boundary vertex on the patch edge,
  and the patch SHALL NOT collapse into a star

#### Scenario: The interior evens out
- **WHEN** Relax is applied to a patch with unevenly spaced interior vertices
- **THEN** the interior vertices SHALL move toward even spacing while the boundary
  silhouette is preserved
