# scene-pipeline — Delta Spec (add-scene-outliner)

First requirements for this capability. Covers the outliner only; importers, exporters and
live-link are later Phase 8 tasks.

## ADDED Requirements

### Requirement: Objects are listed with their per-object statistics
The system SHALL present every object in the document with its name, role and topology statistics, so an artist can tell a Target from an EditMesh and compare candidate retopologies without opening each one.

Statistics SHALL be read from the manifest rather than computed by deserialising a payload,
and an object whose statistics were never captured SHALL be shown as unknown rather than as
zero — zero is a measurement, absence is not.

#### Scenario: Every object appears with its counts
- **WHEN** a document contains a Target and an EditMesh
- **THEN** the outliner SHALL list both with their roles and their vertex and face counts

#### Scenario: Missing statistics read as unknown
- **WHEN** an object has no captured statistics
- **THEN** the outliner SHALL indicate that they are unknown rather than displaying zero

### Requirement: Object visibility composes with face visibility
An object SHALL be hidable, and hidden objects SHALL contribute no geometry to the viewport. Object visibility SHALL compose with the per-face visibility the lasso controls: geometry is drawn only when its object is visible AND its face is not hidden.

Hiding an object SHALL NOT alter its per-face visibility, so showing it again restores
exactly the face state the artist had.

#### Scenario: A hidden object draws nothing
- **WHEN** an object is hidden
- **THEN** none of its geometry SHALL be drawn, regardless of its per-face visibility

#### Scenario: Showing an object restores its face state
- **WHEN** an object with some faces hidden by the lasso is hidden and then shown again
- **THEN** exactly the previously hidden faces SHALL still be hidden

### Requirement: Solo is a view mode that does not rewrite object state
Soloing an object SHALL cause every other object to be treated as hidden without modifying their stored visibility, and clearing solo SHALL restore exactly the visibility the artist had configured.

#### Scenario: Solo hides the others without altering them
- **WHEN** one object is soloed while another is already hidden
- **THEN** only the soloed object SHALL draw
- **AND** clearing solo SHALL leave the previously hidden object still hidden

### Requirement: Locking an object refuses edits rather than hiding controls
A locked object SHALL NOT be modified by any journaled command that changes its payload, and an attempt SHALL be refused with a stated reason. Locking SHALL NOT prevent viewing, measuring, soloing or renaming.

#### Scenario: An edit to a locked object is refused
- **WHEN** a mesh edit targets a locked object
- **THEN** it SHALL be refused with a stated reason and the payload SHALL be unchanged

#### Scenario: Locking does not restrict viewing
- **WHEN** an object is locked
- **THEN** it SHALL remain visible, soloable and measurable

### Requirement: Objects can be grouped
Objects SHALL be assignable to a named group, and the outliner SHALL present grouped objects together with a per-group show and hide affordance.

Groups SHALL be a flat label rather than a transform hierarchy, and an object SHALL belong
to at most one group.

#### Scenario: Hiding a group hides its members
- **WHEN** a group containing two objects is hidden
- **THEN** neither member SHALL draw

#### Scenario: Group membership survives a save and reload
- **WHEN** objects are grouped, the document is saved and reopened
- **THEN** the same objects SHALL still be in the same group

### Requirement: Outliner state changes are undoable
Every change the outliner makes to the document — visibility, lock, group membership, renaming — SHALL be journaled so a single undo restores the previous state. Solo, being a view mode, SHALL NOT be journaled.

#### Scenario: Hiding an object is one undo step
- **WHEN** an object is hidden and the user undoes once
- **THEN** the object SHALL be visible again

#### Scenario: Solo leaves no undo entry
- **WHEN** an object is soloed
- **THEN** the undo stack SHALL be unchanged
