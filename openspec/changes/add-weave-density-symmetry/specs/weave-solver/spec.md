# weave-solver — Delta Spec (add-weave-density-symmetry)

Makes the solver honour two of the six constraints — density and symmetry — by
orchestrating existing engine ops. The other four (frozen patches, tagged-loop flow,
guide strokes, pins) and the prescribed-boundary guarantee remain deferred.

## ADDED Requirements

### Requirement: Density constraint controls resolution
The solver SHALL vary the density of the proposed cage with the requested density: a
finer density SHALL produce a cage with more quads over the same region than a coarser
density, and a coarser density fewer. The relationship SHALL be monotonic.

#### Scenario: Finer density, more quads
- **WHEN** the same Target is solved at a fine density and again at a coarse density
- **THEN** the fine-density cage SHALL contain strictly more quads than the coarse one

### Requirement: Symmetry constraint yields a symmetric cage
When the symmetry constraint is enabled with a mirror axis, the proposed cage SHALL be
mirror-symmetric about that axis' plane: every vertex SHALL have a mirrored partner
across the plane within the weld tolerance, and the seam SHALL be welded (manifold, not
two coincident free edges). Solving SHALL NOT mutate the source mesh.

#### Scenario: Mirror-symmetric output
- **WHEN** a Target is solved with an X-mirror symmetry constraint enabled
- **THEN** for every vertex of the resulting cage there SHALL be a vertex at its mirror
  image across the plane within the weld tolerance

#### Scenario: A non-symmetric Target still yields a symmetric cage
- **WHEN** a non-symmetric Target is solved with a mirror symmetry constraint enabled
- **THEN** the resulting cage SHALL still be mirror-symmetric about the plane

#### Scenario: Determinism holds with constraints
- **WHEN** the same Target is solved twice with the same density and symmetry constraints
- **THEN** the two cages SHALL be identical vertex-for-vertex and face-for-face
