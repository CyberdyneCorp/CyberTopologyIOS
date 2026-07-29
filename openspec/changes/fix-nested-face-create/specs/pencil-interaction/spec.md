# pencil-interaction — Delta Spec (fix-nested-face-create)

## ADDED Requirements

### Requirement: A stroke never creates a face inside another face
A closed stroke drawn entirely within a single existing face, touching none of that face's edges or vertices, SHALL NOT create a face.

A cage may contain a face beside another, sharing an edge, or replacing one. A face nested inside
another shares no topology with it and is disconnected geometry, so the create action SHALL be
withheld rather than offered at reduced confidence: a low-confidence create is still a create.

A stroke that comes within picking range of an existing edge or vertex SHALL still create, because it
shares topology with the existing cage — this is a containment test, not a prohibition on drawing over
faces.

#### Scenario: A loop inside one face creates nothing
- **WHEN** the user draws a small closed loop or circle wholly inside one face, away from its edges
- **THEN** no face SHALL be created and the stroke SHALL report that it did nothing

#### Scenario: A loop over empty surface still creates
- **WHEN** the user draws a closed loop over empty surface
- **THEN** a face SHALL be created

#### Scenario: A loop sharing an edge still creates
- **WHEN** a closed loop passes within picking range of an existing edge
- **THEN** a face SHALL be created
