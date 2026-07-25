# weave-solver Specification

## Purpose
TBD - created by archiving change add-weave-solver-pipeline. Update Purpose after archive.
## Requirements
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
Solver output SHALL appear as ghost geometry, not committed mesh. While a proposal is
shown the user SHALL be offered an accept and a discard affordance: accepting commits
the ghost into the EditMesh as exactly one undoable journal entry; discarding drops it,
leaving the document byte-unchanged. Accepted topology SHALL be ordinary EditMesh —
every existing verb and tool SHALL work on it with no special-casing.

#### Scenario: Accept journals once and undoes cleanly
- **WHEN** the user accepts an Auto-Retopo ghost
- **THEN** the acceptance SHALL be a single journal entry
- **AND** one undo SHALL restore the document to its exact pre-accept bytes

#### Scenario: Discard changes nothing
- **WHEN** a ghost is showing and the user discards it
- **THEN** the ghost SHALL be removed
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

### Requirement: Guide-stroke orientation steering
The solver SHALL accept directional orientation guides (a set of world-space
directions attached to surface locations) and bias the proposed cage's edge flow to
follow them: in the neighbourhood of a guide, the dominant edge direction SHALL align
with the guide direction more closely than it does in an unguided solve of the same
input. The solve SHALL remain deterministic given identical inputs and guides.

#### Scenario: Flow follows the guide
- **WHEN** a Target is solved with an orientation guide along a chosen direction
- **THEN** near the guide the cage's edges SHALL run more nearly parallel to that
  direction than the same region does when solved with no guide

#### Scenario: No guide, unchanged behaviour
- **WHEN** a Target is solved with an empty guide set
- **THEN** the result SHALL be identical to the unguided solve of that Target

#### Scenario: Determinism with guides
- **WHEN** the same Target is solved twice with the same guides
- **THEN** the two cages SHALL be identical vertex-for-vertex and face-for-face

### Requirement: Tagged loops steer flow
A colour-tagged edge loop supplied as a flow constraint SHALL bias the cross field so
the proposed cage's edges run along the loop's direction in its neighbourhood, using
the same orientation-guide channel as guide strokes.

#### Scenario: Loop tag aligns flow
- **WHEN** a Target is solved with a tagged loop supplied as a flow constraint
- **THEN** near the loop the cage's edges SHALL align with the loop's tangent direction
  more closely than in an unguided solve

### Requirement: Guide strokes are authored on the Target surface
The system SHALL let the user draw guide strokes on the Target: while guide authoring
is active, a stroke over the Target SHALL be captured as a world-space polyline lying
on the Target surface, and a stroke that does not hit the Target SHALL add no guide.
Authored guides SHALL be clearable in one action.

#### Scenario: A stroke over the Target becomes a guide on its surface
- **WHEN** guide authoring is active and the user draws a stroke across the Target
- **THEN** a guide polyline SHALL be stored whose points lie on the Target surface

#### Scenario: A stroke that misses the Target adds nothing
- **WHEN** guide authoring is active and the user draws a stroke over empty space
- **THEN** no guide SHALL be stored

#### Scenario: Clear removes all guides
- **WHEN** guides exist and the user clears them
- **THEN** no authored guides SHALL remain

### Requirement: Authored guides are shown as a surface overlay
Authored guide strokes SHALL be rendered as a world-space overlay on the Target that
tracks the camera, so the user can see the active guides from any viewpoint.

#### Scenario: Guides remain visible as the camera moves
- **WHEN** guides exist and the camera orbits
- **THEN** the guide overlay SHALL remain registered to the Target surface

### Requirement: Auto-Retopo follows authored guides
When guides are authored, an Auto-Retopo solve SHALL supply them to the solver as
orientation guides, so the proposed cage's edge flow follows them. With no authored
guides, the solve SHALL be unchanged.

#### Scenario: Authored guides steer the retopo
- **WHEN** guides are authored on the Target and Auto-Retopo is run
- **THEN** the solve SHALL receive those guides as orientation constraints

#### Scenario: No guides, unchanged solve
- **WHEN** no guides are authored and Auto-Retopo is run
- **THEN** the solve SHALL behave exactly as it does without the guide feature

