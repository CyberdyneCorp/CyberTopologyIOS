# weave-solver — Delta Spec (add-weave-solver-pipeline)

This delta adds the solver-session PIPELINE and its contract, with the engine's
existing auto-retopology (`cyber_remesh`) as the first backend. It deliberately does
NOT add the constraint-aware solver, field-constraint honouring, sub-region solve, or
the prescribed-boundary guarantee — those are a later engine change behind the same
API.

## ADDED Requirements

### Requirement: Solver-session API
The system SHALL provide a solver-session API that takes a solve region, a constraint
set, and solver parameters, and produces a ghost mesh (proposed, uncommitted geometry)
without mutating the source mesh. The API SHALL report advisory progress and SHALL be
cancellable. The API's constraint type SHALL accept the full Weave taxonomy — frozen
patches, tagged loops, guide strokes, pins, a density field, and a symmetry
configuration — even where honouring of a given constraint is deferred, so call sites
and the document are forward-compatible. For this change the supported region SHALL be
the whole mesh (a maximal-region "solve all").

#### Scenario: Solve produces a ghost, not committed geometry
- **WHEN** the solver is run over the Target
- **THEN** it SHALL return a ghost mesh distinct from the live EditMesh
- **AND** the live document SHALL be unchanged until the ghost is accepted

#### Scenario: Cancel mid-solve
- **WHEN** a running solve is cancelled
- **THEN** the solve SHALL return no ghost
- **AND** the source mesh SHALL be exactly as it was before the solve started

### Requirement: Source mesh is untouched until accept
A solve SHALL NOT modify the source mesh or the document. Any change to the document
SHALL occur only when the user accepts the ghost.

#### Scenario: Solving does not alter the source
- **WHEN** a solve runs to completion and produces a ghost
- **THEN** the source Target and any existing EditMesh SHALL be bit-identical to before the solve

### Requirement: Determinism
The solver SHALL produce a bit-identical ghost across runs given identical inputs
(source mesh, region, constraints, parameters, and seed). The solver SHALL NOT depend
on wall-clock time or unseeded randomness.

#### Scenario: Repeat solve
- **WHEN** the same source is solved twice with the same constraints and parameters
- **THEN** the two ghost meshes SHALL be identical vertex-for-vertex and face-for-face

### Requirement: Ghost accept/override flow
Solver output SHALL appear as ghost geometry, not committed mesh. Tapping SHALL accept
the ghost into the EditMesh as exactly one undoable journal entry; drawing over the
ghost or cancelling SHALL discard it, leaving the document byte-unchanged. Accepted
topology SHALL be ordinary EditMesh — every existing verb and tool SHALL work on it
with no special-casing.

#### Scenario: Accept journals once and undoes cleanly
- **WHEN** the user accepts an Auto-Retopo ghost
- **THEN** the acceptance SHALL be a single journal entry
- **AND** one undo SHALL restore the document to its exact pre-accept bytes

#### Scenario: Draw-over discards
- **WHEN** a ghost is showing and the user draws their own geometry through it
- **THEN** the ghost SHALL be discarded
- **AND** no journal entry SHALL be recorded for the discarded ghost

#### Scenario: Accepted topology takes further edits
- **WHEN** the user accepts a ghost and then applies an existing verb (e.g. Relax)
- **THEN** the verb SHALL operate on the accepted geometry as it would on hand-built topology

### Requirement: Auto-retopology is strictly opt-in
Solver-generated geometry SHALL appear only in response to an explicit invocation.
With Auto-Retopologize never invoked, no solver geometry SHALL ever be produced or
rendered.

#### Scenario: Never invoked, nothing appears
- **WHEN** the user never invokes Auto-Retopologize
- **THEN** no ghost or solver-generated geometry SHALL appear, and the EditMesh SHALL contain only hand-authored topology
