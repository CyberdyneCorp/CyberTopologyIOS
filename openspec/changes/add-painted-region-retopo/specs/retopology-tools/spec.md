# Delta: retopology-tools (add-painted-region-retopo)

## ADDED Requirements

### Requirement: Auto-retopology can be restricted to a painted region of the Target

The system SHALL let the user paint over the Target to mark a region, and SHALL run
auto-retopology over only that region, producing a cage that covers the painted area and no more.

The painted extent SHALL be visible before the solve runs.

Rationale: an artist hand-authors the topology that needs judgement and wants the solver to fill
a specific bare area. Remeshing the whole Target to fill one haunch discards everything else.

#### Scenario: A painted region is retopologized alone
- **WHEN** the user paints a region of the Target and runs auto-retopology
- **THEN** the proposed cage SHALL cover the painted region
- **AND** SHALL NOT cover unpainted parts of the Target

#### Scenario: Nothing painted
- **WHEN** no region is painted and auto-retopology runs
- **THEN** it SHALL solve the whole Target, as before

#### Scenario: The extent is visible
- **WHEN** the user has painted a region
- **THEN** the painted faces SHALL be highlighted in the viewport

### Requirement: An accepted region patch merges into the existing cage

Accepting a region solve SHALL append the patch's faces to the existing EditMesh, leaving the
artist with ONE cage. Where no EditMesh exists, the patch SHALL become it.

The patch's border vertices SHALL NOT be silently welded to the existing cage.

Rationale: the artist is filling a hole in a cage they are building, not collecting objects.
Welding is a deliberate act with its own tools — doing it implicitly would move hand-placed
vertices without being asked.

#### Scenario: Merging into a cage
- **WHEN** a region patch is accepted while an EditMesh exists
- **THEN** the EditMesh SHALL contain its previous faces plus the patch's
- **AND** the document SHALL still hold exactly one EditMesh object

#### Scenario: The first patch
- **WHEN** a region patch is accepted with no EditMesh present
- **THEN** the patch SHALL become the EditMesh

#### Scenario: Undo
- **WHEN** the user undoes an accepted region patch
- **THEN** the EditMesh SHALL return to exactly its previous state

### Requirement: The painted region is transient

The painted region SHALL be cleared once a solve runs, and SHALL NOT be stored in the document.

Rationale: a stale extent silently shaping the next solve is worse than repainting. The mask is
a statement about what to do next, not a property of the model.

#### Scenario: Cleared after running
- **WHEN** auto-retopology runs over a painted region
- **THEN** the painted region SHALL be empty afterwards

#### Scenario: Not persisted
- **WHEN** a document is saved and reopened
- **THEN** no painted region SHALL be restored
