# document-model — Delta Spec

## ADDED Requirements

### Requirement: Two-mesh document architecture
A document SHALL contain zero or more immutable high-poly **Targets** (imported sculpts, scans, or 2D image targets) and one or more editable low-poly **EditMeshes**. Targets SHALL never be modified by editing tools; EditMesh vertices SHALL continuously snap to the active Target surface via shrink-wrap projection unless snapping is explicitly disabled for the object.

#### Scenario: EditMesh vertex snapping
- **WHEN** any tool creates or moves an EditMesh vertex while a Target is active
- **THEN** the vertex position SHALL be projected onto the Target surface before the operation commits

#### Scenario: Target immutability
- **WHEN** any editing verb (Pencil, Relax, Move, Tweak, Erase) is applied over a Target with no EditMesh element under the stroke
- **THEN** the Target geometry SHALL remain unchanged

#### Scenario: UV-only document without a Target
- **WHEN** a user creates a UV-only project by importing a low-poly mesh as the EditMesh with no Target
- **THEN** the document SHALL open directly in the UV stage with snapping disabled and all UV and export features functional

### Requirement: Stage state machine
A document SHALL move between three stages — **RT** (retopology), **UV** (unwrap/layout), and **BK** (baking) — selectable at any time. Per-stage state (pins, loop tags, seams, occlusion settings, cage distances, viewport layout) SHALL be persisted in the document and restored when re-entering a stage.

#### Scenario: Stage state round-trip
- **WHEN** a user tags loops in RT, marks seams in UV, edits cage distances in BK, then closes and reopens the document
- **THEN** all stage-specific state SHALL be restored exactly

### Requirement: Multi-object documents
A document SHALL support multiple Targets and multiple EditMesh objects simultaneously, each independently addressable for visibility, editing, linking, and export.

#### Scenario: Two EditMeshes in one document
- **WHEN** a document contains two EditMesh objects and the user edits one
- **THEN** the other EditMesh SHALL be unaffected, and each SHALL be exportable individually or together

### Requirement: Unbounded undo tree
The system SHALL maintain an undo history for the active document bounded only by storage, not by a fixed step count. Undo SHALL be branch-preserving: redoing after divergent edits SHALL NOT silently discard the abandoned branch within the session. Two-finger tap SHALL undo; three-finger tap SHALL redo.

#### Scenario: Deep undo
- **WHEN** a user performs 500 edit operations and then invokes undo 500 times
- **THEN** the document SHALL return to its initial state without loss

#### Scenario: Gesture undo/redo
- **WHEN** the user two-finger taps the viewport
- **THEN** the last operation SHALL be undone; a three-finger tap SHALL redo it

### Requirement: Autosave and session recovery in every tier
The system SHALL autosave documents periodically and on backgrounding, and SHALL recover the in-progress session after a crash or force-quit. Saving and recovery SHALL function in the free tier — saving SHALL NOT be gated by purchase.

#### Scenario: Crash recovery
- **WHEN** the app terminates unexpectedly with unsaved edits
- **THEN** on next launch the document SHALL reopen with at most the last few seconds of work lost

#### Scenario: Free-tier save
- **WHEN** a user with no purchases edits and closes a document
- **THEN** the document SHALL be saved and reopenable with full fidelity

### Requirement: User-visible document storage
Documents SHALL be stored as files in a user-visible folder accessible from the iPadOS/macOS Files app, with support for named versions ("save new version") and iCloud Drive sync. The system SHALL NOT require an account and SHALL NOT transmit document data off-device except via explicit user-initiated export or live-link.

#### Scenario: Files app visibility
- **WHEN** a user saves a document and opens the system Files app
- **THEN** the document file SHALL be visible, copyable, and shareable in the app's folder

#### Scenario: Save new version
- **WHEN** the user invokes "save new version" with a name
- **THEN** a named copy SHALL be created and the original SHALL remain untouched
