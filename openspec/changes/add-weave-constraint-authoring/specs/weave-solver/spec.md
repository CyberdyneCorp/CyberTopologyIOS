# weave-solver — Delta Spec (add-weave-constraint-authoring)

Makes the stored constraint taxonomy real: authored pins and tagged loops reach the solver,
and frozen faces become authorable. The existing "Tagged loops steer flow" requirement
already covers what the solver does WHEN a loop is supplied — what was missing is anything
supplying one.

## ADDED Requirements

### Requirement: Authored annotations reach a region solve
A region solve SHALL read the EditMesh's authored annotations and supply them to the solver as constraints, so that pins and colour-tagged loops the artist has already placed steer the solve without being re-authored.

The mapping SHALL be total and explicit: every pinned vertex inside the solved region SHALL
be supplied as a pin, and every tagged edge SHALL be supplied within a loop carrying its
colour. Annotations OUTSIDE the solved region SHALL NOT be supplied, since they constrain
geometry the solve does not touch.

#### Scenario: An authored pin constrains the solve
- **WHEN** a vertex in the region interior is pinned and the region is solved
- **THEN** the pin SHALL be supplied to the solver as a pinned vertex
- **AND** the solve SHALL NOT be byte-identical to the same solve with no pins, since a pin
  that changes nothing is indistinguishable from a pin that was dropped

#### Scenario: An authored tag steers flow
- **WHEN** an edge loop is colour-tagged inside the region and the region is solved
- **THEN** the loop SHALL be supplied as a flow constraint carrying that colour

#### Scenario: Annotations outside the region are not supplied
- **WHEN** pins exist on the EditMesh but outside the solved region
- **THEN** they SHALL NOT appear among the supplied constraints

### Requirement: A pin on a prescribed interface is defined, not arbitrary
A pin authored on a vertex that a region solve already holds fixed SHALL be honoured as a valence prescription rather than as a position constraint, because the interface vertex's POSITION is already guaranteed bitwise by the prescribed-boundary requirement and a redundant position pin would carry no information.

An authored pin in the region INTERIOR SHALL constrain position. The two cases SHALL be
distinguished by whether the vertex lies on the region interface, and the distinction SHALL
be observable to the caller rather than implicit.

#### Scenario: An interior pin holds position
- **WHEN** a pinned vertex lies strictly inside the solved region
- **THEN** the solve SHALL preserve that vertex's position

#### Scenario: An interface pin does not weaken exact landing
- **WHEN** a pinned vertex lies on the region interface
- **THEN** the interface SHALL still land bitwise as the prescribed-boundary requirement
  demands
- **AND** the pin SHALL be reported as a valence prescription for that vertex

### Requirement: Frozen faces are authorable
Faces SHALL be markable as frozen on the EditMesh, and a solve SHALL exclude frozen faces from the region it rewrites, so that an artist can protect hand-built topology from being re-solved.

Frozen state SHALL persist with the document and SHALL survive id compaction, using the
same annotation mechanism as pins rather than a parallel one. Freezing every face of a
region SHALL be an explicit refusal, never a silent whole-region solve.

#### Scenario: A frozen face is not rewritten
- **WHEN** a face inside the solved region is frozen and the region is solved
- **THEN** that face SHALL survive the solve unchanged

#### Scenario: Freezing the whole region refuses
- **WHEN** every face of the selected region is frozen
- **THEN** the solve SHALL refuse with a stated reason and publish nothing

#### Scenario: Frozen state survives a save and reload
- **WHEN** faces are frozen, the document is saved, and it is reloaded
- **THEN** the same faces SHALL still be frozen
