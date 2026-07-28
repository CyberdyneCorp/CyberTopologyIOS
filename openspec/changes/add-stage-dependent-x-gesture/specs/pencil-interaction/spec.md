# pencil-interaction — Delta Spec (add-stage-dependent-x-gesture)

## ADDED Requirements

### Requirement: The X gesture never destroys geometry outside the retopology stage
An X gesture SHALL be interpreted against the document's current stage. It SHALL delete faces ONLY in the retopology stage. In any other stage it SHALL NOT delete geometry, even when no stage-specific interpretation is implemented for that stage.

The default for an unhandled stage SHALL be to do nothing, not to fall back to deletion: a
gesture whose meaning is unimplemented must be inert rather than destructive.

#### Scenario: An X in the UV stage does not delete faces
- **WHEN** the user draws an X over faces while the document is in the UV stage
- **THEN** no face SHALL be deleted

#### Scenario: An X in the retopology stage still deletes
- **WHEN** the user draws an X over faces while the document is in the retopology stage
- **THEN** those faces SHALL be deleted as one undoable step
