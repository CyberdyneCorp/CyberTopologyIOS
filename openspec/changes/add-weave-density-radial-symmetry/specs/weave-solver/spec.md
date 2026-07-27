# weave-solver — Delta Spec (add-weave-density-radial-symmetry)

The two constraint kinds 5.2a could not finish. Multi-axis mirror symmetry already landed
there; this covers spatially varying density and radial symmetry.

## ADDED Requirements

### Requirement: Density is authorable per region, not only globally
A solve SHALL accept a spatially varying density field expressed as per-vertex scale multipliers, so an artist can ask for finer quads where detail matters and coarser quads elsewhere within one solve.

The field SHALL be optional: a solve with no authored density SHALL be byte-identical to
today's, so the capability cannot change existing output by merely existing. How an
authored scale composes with the solver's own curvature-derived adaptivity SHALL be
defined and documented rather than left to whichever value is written last.

#### Scenario: A finer painted region yields smaller quads
- **WHEN** a region of the surface is painted finer than the rest and the mesh is solved
- **THEN** the mean edge length inside that region SHALL be smaller than outside it

#### Scenario: No authored density changes nothing
- **WHEN** a solve supplies no density field
- **THEN** the result SHALL be byte-identical to the same solve before this capability existed

#### Scenario: An authored scale and curvature adaptivity compose predictably
- **WHEN** an authored coarse scale covers a region of high curvature
- **THEN** the resulting edge length SHALL follow the documented composition rule
- **AND** the outcome SHALL NOT depend on the order the two were applied

### Requirement: Radial symmetry is honoured by the solver
A solve with radial symmetry enabled SHALL clip its working domain to one angular sector about the radial axis and replicate that sector, so the proposed cage is rotationally symmetric with the authored sector count.

Sector boundaries SHALL be welded so the result is manifold across its seams rather than a
set of abutting shells. Radial symmetry SHALL compose with mirror symmetry when both are
enabled.

#### Scenario: A radial solve repeats its sector
- **WHEN** a mesh is solved with a radial count of N
- **THEN** the result SHALL be invariant under rotation by 360/N degrees about the radial axis

#### Scenario: Radial seams are manifold
- **WHEN** a radially symmetric solve completes
- **THEN** no unwelded duplicate vertices SHALL remain on a sector boundary

#### Scenario: Radial with no sectors is inert
- **WHEN** a solve supplies a radial count of 1
- **THEN** the result SHALL be byte-identical to a solve with radial symmetry disabled
