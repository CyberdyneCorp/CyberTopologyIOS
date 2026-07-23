# Delta: document-model

## ADDED Requirements

### Requirement: Object removal

A document object (Target or EditMesh) SHALL be removable through a single
undoable command. Removal SHALL delete the object's manifest entry and its
payload bytes, and undo SHALL restore both verbatim (the removal command
carries the object and its payload so redo needs no source file).

Removing one object SHALL NOT affect any other object: deleting a Target
SHALL leave every EditMesh intact, and deleting an EditMesh SHALL leave the
Target intact.

The object list SHALL present a delete affordance per object.

#### Scenario: Delete a Target
- **GIVEN** a document with one Target and one EditMesh
- **WHEN** the user deletes the Target
- **THEN** the document SHALL contain only the EditMesh
- **AND** a single undo SHALL restore the Target exactly (same payload bytes)

#### Scenario: Delete an EditMesh
- **GIVEN** a document with one Target and one EditMesh
- **WHEN** the user deletes the EditMesh
- **THEN** the document SHALL contain only the Target
- **AND** a single undo SHALL restore the EditMesh exactly

### Requirement: Single-instance import replacement

Importing an object SHALL be single-instance per role: when an object of the
imported role already exists, the import SHALL REPLACE it — removing the
existing same-role object and adding the imported one as ONE undoable step —
rather than adding a second object of that role. Importing into an empty
slot (no existing object of that role) SHALL simply add the object.

Replacement SHALL be exact under undo: a single undo SHALL restore the
previous object (manifest entry and payload) and remove the imported one,
returning the document to its exact pre-import state.

#### Scenario: Re-importing a Target replaces the current one
- **GIVEN** a document whose Target is model A
- **WHEN** the user imports Target model B
- **THEN** the document SHALL contain exactly one Target, model B
- **AND** a single undo SHALL restore model A as the only Target

#### Scenario: Importing into an empty slot adds
- **GIVEN** a document with no Target
- **WHEN** the user imports a Target
- **THEN** the document SHALL contain that one Target
- **AND** a single undo SHALL remove it, leaving no Target
