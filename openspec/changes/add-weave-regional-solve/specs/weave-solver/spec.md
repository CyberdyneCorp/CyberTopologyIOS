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

### Requirement: Singularities are interior to the solved region
Every interface vertex SHALL end the solve at its prescribed total valence, so that no
singularity is introduced on the interface. The prescription SHALL default to the valence
implied by the surrounding topology and SHALL be overridable per vertex by the caller, so
that a deliberately authored pole on the interface does not force a rejection. The solver
SHALL report the residual interior index budget.

#### Scenario: No new singularity lands on the interface
- **WHEN** a sub-region is solved
- **THEN** each interface vertex's total incident-face count SHALL equal its prescribed
  valence
- **AND** any irregular vertex in the ghost SHALL be strictly interior to the region

#### Scenario: Curvature does not change the combinatorics
- **WHEN** the same ring combinatorics are solved on a flat region and on a curved region
- **THEN** the reported interface conformance and interior index budget SHALL be identical

### Requirement: A non-conforming solve is refused, never published
Where the solver cannot satisfy the prescribed-boundary guarantee, it SHALL fail with a
reason identifying the offending interface vertices and SHALL emit no ghost. It SHALL NOT
emit a ghost that violates the guarantee, and SHALL NOT silently repair the violation by
moving prescribed geometry. Inputs that cannot be solved safely — a region that is
disconnected, empty, or whose boundary loop has odd parity, or a source containing
coincident duplicate vertices or inconsistent face winding — SHALL be refused up front
with a distinct reason for each case.

#### Scenario: Non-conforming region produces no geometry
- **WHEN** a solve cannot place quads meeting every interface vertex at its prescribed
  valence
- **THEN** the solve SHALL report failure naming the offending vertices
- **AND** no ghost SHALL be produced
- **AND** the source mesh SHALL be unchanged

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
