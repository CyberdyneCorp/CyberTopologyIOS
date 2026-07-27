# weave-solver — Delta Spec (add-interface-singularity-guarantee)

Turns the second half of the prescribed-boundary guarantee from a measurement into a
promise. Replaces the reporting requirement `add-weave-regional-solve` shipped.

## MODIFIED Requirements

### Requirement: Interface irregularity is measured and reported
The solver SHALL compute, for each interface vertex, the total valence implied by the
surrounding topology and the valence the solve actually produced, and SHALL report every
vertex where they differ together with the residual interior index budget. The
prescription SHALL be overridable per vertex by the caller, so that a deliberately
authored pole on the interface is not counted as a defect.

Reporting SHALL remain available even once the guarantee below holds, because a caller
needs to distinguish "no singularity on the interface" from "the solver declined to
answer", and because a caller-overridden prescription is reported against the override
rather than the cage.

#### Scenario: Interface irregularities are surfaced, not hidden
- **WHEN** a sub-region solve produces an interface vertex whose valence differs from its
  prescription
- **THEN** the solve SHALL report that vertex and the count of such vertices
- **AND** the report SHALL be available to the caller alongside the ghost

#### Scenario: An authored pole is not a defect
- **WHEN** the caller overrides the prescribed valence at an interface vertex and the solve
  matches that override
- **THEN** the vertex SHALL NOT be reported as irregular

## ADDED Requirements

### Requirement: No singularity is placed on a prescribed interface
The solver SHALL NOT publish a ghost in which an interface vertex carries a valence other
than its prescription. Where it cannot place the region's topology without doing so, it
SHALL refuse and name the offending vertices, so that a published proposal always carries
the guarantee rather than a caveat. Singularities the region's topology requires SHALL be
placed strictly interior to the solved region.

This is the claim that distinguishes a prescribed-boundary solve from remeshing a sub-mesh
and stitching it, so a published proposal that merely *usually* honours it is not the
capability.

#### Scenario: A published proposal has a regular interface
- **WHEN** a region solve produces a ghost
- **THEN** every interface vertex SHALL carry exactly its prescribed valence
- **AND** any irregular vertex SHALL be strictly interior to the region

#### Scenario: An unachievable interface is refused, not published with a caveat
- **WHEN** the solver cannot give every interface vertex its prescribed valence
- **THEN** no ghost SHALL be produced
- **AND** the offending interface vertices SHALL be named
- **AND** the source mesh SHALL be unchanged

#### Scenario: A reflex ring is solved, not merely reported on
- **WHEN** a region whose interface ring contains a reflex corner is solved
- **THEN** the proposal SHALL either honour the guarantee or be refused
- **AND** it SHALL NOT be published with irregular interface vertices
