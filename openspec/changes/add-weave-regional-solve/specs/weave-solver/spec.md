# weave-solver — Delta Spec (add-weave-regional-solve)

This delta lifts the whole-mesh-only restriction on the solver-session API and adds the
prescribed-boundary interface guarantee (task 5.3).

The guarantee is stated as **enforce-or-fail**, not construct-correct: a ghost that
violates it cannot exist, at the cost that some regions produce no ghost at all. That
trade is deliberate and is written into the requirements rather than left to the
implementation.

## MODIFIED Requirements

### Requirement: Solver-session API
The system SHALL provide a solver-session API that takes a solve region, a constraint
set, and solver parameters, and produces a ghost mesh (proposed, uncommitted geometry)
without mutating the source mesh. The API SHALL report advisory progress and SHALL be
cancellable. The API's constraint type SHALL accept the full Weave taxonomy — frozen
patches, tagged loops, guide strokes, pins, a density field, and a symmetry
configuration — even where honouring of a given constraint is deferred, so call sites
and the document are forward-compatible. The supported regions SHALL be the whole mesh
(a maximal-region "solve all") and a connected sub-region given as a set of face ids.
A sub-region solve SHALL exclude any face named as a frozen patch by the constraint set.
A sub-region solve SHALL NOT be treated as equivalent to a whole-mesh solve even when the
region names every live face, because the two paths differ in id stability and in which
repair stages run.

#### Scenario: Solve produces a ghost, not committed geometry
- **WHEN** the solver is run over the Target
- **THEN** it SHALL return a ghost mesh distinct from the live EditMesh
- **AND** the live document SHALL be unchanged until the ghost is accepted

#### Scenario: Cancel mid-solve
- **WHEN** a running solve is cancelled
- **THEN** the solve SHALL return no ghost
- **AND** the source mesh SHALL be exactly as it was before the solve started

#### Scenario: Sub-region solve rewrites only the region
- **WHEN** a solve is run over a connected sub-region of a mesh
- **THEN** only faces inside the region SHALL be replaced
- **AND** every face outside the region SHALL be present in the ghost with the same face
  id and the same vertex ring in the same order

#### Scenario: Frozen patches are excluded from the region
- **WHEN** a sub-region solve is given a constraint set naming frozen faces that overlap
  the region
- **THEN** those faces SHALL be excluded from the solved region and treated as prescribed
  surrounding topology

## ADDED Requirements

### Requirement: Prescribed-boundary landing is exact
The solver SHALL land a prescribed boundary exactly. Every vertex on the interface
between a solved sub-region and its surrounding topology SHALL appear in the ghost with
the same vertex id and a bitwise-identical position. Conformance SHALL NOT be assessed
by a distance
tolerance: a positional comparison cannot distinguish a vertex that was never touched
from one that was moved and snapped back, and the distinction is the guarantee.
The interface EDGE set SHALL also be preserved — no stage may insert a vertex into a
prescribed boundary polyline, even where the resulting geometry still lies on that
polyline.

#### Scenario: Interface vertices are untouched
- **WHEN** a sub-region is solved
- **THEN** every interface vertex SHALL be alive in the ghost under its original id
- **AND** each component of its position SHALL be bitwise identical to the input

#### Scenario: Interface edges are not resampled
- **WHEN** a sub-region is solved at a target density several times finer than the
  interface edge spacing
- **THEN** the set of vertex pairs forming the interface SHALL be unchanged

### Requirement: Interface irregularity is measured and reported
The solver SHALL compute, for each interface vertex, the total valence implied by the
surrounding topology and the valence the solve actually produced, and SHALL report every
vertex where they differ together with the residual interior index budget. The prescription
SHALL be overridable per vertex by the caller, so that a deliberately authored pole on the
interface is not counted as a defect.

This change reports the measure; it does not guarantee the measure is zero. Forcing it to
zero is a coupled degree-constrained matching over the interface ring (see design.md
ADDENDUM 2) and is deferred to its own change — the guarantee must not be claimed until a
solver for it exists.

#### Scenario: Interface irregularities are surfaced, not hidden
- **WHEN** a sub-region solve produces an interface vertex whose valence differs from its
  prescription
- **THEN** the solve SHALL report that vertex and the count of such vertices
- **AND** the report SHALL be available to the caller alongside the ghost

#### Scenario: An authored pole is not a defect
- **WHEN** the caller overrides the prescribed valence at an interface vertex and the solve
  matches that override
- **THEN** the vertex SHALL NOT be reported as irregular

### Requirement: A solve that would violate exact landing is refused, never published
The solver SHALL refuse, emitting no ghost, where it cannot preserve prescribed vertex
identity, prescribed positions, or the prescribed interface edge set. It SHALL NOT silently
repair such a violation by moving prescribed geometry. Inputs that cannot be solved safely —
a region that is disconnected or empty, or a source containing coincident duplicate vertices
or inconsistent face winding — SHALL be refused up front with a distinct reason for each
case.

Interface IRREGULARITY is deliberately excluded from this requirement: it is reported, not
refused. Refusing on it was measured to reject every test fixture (design.md ADDENDUM 1-2),
which would make regional solve unusable while guaranteeing nothing extra.

#### Scenario: A solve that would move prescribed geometry produces nothing
- **WHEN** a solve cannot preserve the prescribed positions or interface edge set
- **THEN** the solve SHALL report failure naming the offending elements
- **AND** no ghost SHALL be produced
- **AND** the source mesh SHALL be unchanged

#### Scenario: An irregular interface does not block the ghost
- **WHEN** a solve lands the interface exactly but leaves an interface vertex irregular
- **THEN** a ghost SHALL still be produced
- **AND** the irregularity SHALL appear in the report

#### Scenario: Unweldable source is refused before solving
- **WHEN** a sub-region solve is requested on a mesh containing coincident duplicate
  vertices
- **THEN** the solve SHALL refuse with a reason naming that condition rather than
  proceeding

### Requirement: Whole-mesh solves are unaffected
Introducing region support SHALL NOT change the result of any whole-mesh solve. A
whole-mesh solve SHALL remain bit-identical to its result before this change, and an
empty region SHALL be equivalent to a whole-mesh solve.

#### Scenario: Existing whole-mesh output is unchanged
- **WHEN** a whole-mesh solve is run with the same source, constraints and parameters as
  before this change
- **THEN** the resulting ghost SHALL be byte-identical to the previously recorded result

### Requirement: Region solves are deterministic under region reordering
A sub-region solve SHALL be deterministic in the same sense as a whole-mesh solve, and
SHALL additionally be invariant to the ORDER in which the region's face ids are supplied.

#### Scenario: Shuffled region ids produce the same ghost
- **WHEN** the same region is solved twice, once with its face ids shuffled
- **THEN** the two ghosts SHALL be identical vertex-for-vertex and face-for-face
