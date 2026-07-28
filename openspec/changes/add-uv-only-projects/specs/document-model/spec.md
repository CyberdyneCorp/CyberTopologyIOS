# document-model — Delta Spec (add-uv-only-projects)

## ADDED Requirements

### Requirement: A UV-only project is derived, not a document type
A UV-only project SHALL be defined as a document containing an EditMesh and no Target. This SHALL be derived from the document's objects rather than stored as state, so that removing a document's Target makes it behave as UV-only and adding one stops it.

Importing a mesh as a UV-only project SHALL add the EditMesh and switch to the UV stage as a
SINGLE undoable step, so one undo cannot leave the document in the UV stage with nothing to
unwrap.

Importing into a document already in the UV stage SHALL NOT journal a redundant stage change.

#### Scenario: One undo restores the pre-import state
- **WHEN** a low-poly mesh is imported as a UV-only project and the user undoes once
- **THEN** the object SHALL be gone AND the stage SHALL be what it was before the import

#### Scenario: The project type follows the objects
- **WHEN** a Target is added to a UV-only project
- **THEN** the document SHALL no longer be a UV-only project

#### Scenario: UV and export features need no Target
- **WHEN** a UV-only project is unwrapped and exported
- **THEN** both SHALL succeed with no Target present
