# scene-pipeline — Delta Spec

## ADDED Requirements

### Requirement: Scene outliner
The app SHALL provide an outliner listing every Target component and EditMesh object with per-item show/hide, solo, and lock controls, grouping, and per-object statistics (vertex/edge/face counts, UV vertex count). Lasso-visibility gestures and outliner visibility SHALL compose (either can hide; show-all restores both).

#### Scenario: Solo a component
- **WHEN** the user solos one Target component in the outliner
- **THEN** only that component SHALL render, and un-solo SHALL restore the previous visibility state

### Requirement: Import formats
The system SHALL import OBJ (with vertex colors from common encodings), FBX, glTF/GLB, and USD(z) — as new Target, replacement Target, or as EditMesh — plus image textures (target color/reference) and 2D image targets for flat snapping. Import SHALL preserve multiple objects/components and existing UVs.

#### Scenario: Import GLB as target
- **WHEN** a multi-mesh GLB with vertex colors is imported as a Target
- **THEN** each mesh SHALL appear as a separate component in the outliner with colors intact

#### Scenario: Import existing low-poly as EditMesh
- **WHEN** the user imports an OBJ as EditMesh into a document with a Target
- **THEN** the mesh SHALL be editable with all RT tools and snap to the Target

### Requirement: Export formats and configurations
The system SHALL export OBJ (+MTL, normals), STL, FBX, glTF/GLB, and USD(z), with per-object or combined multi-object export, optional subdivide+reproject on export, optional triangulation, multiple UV sets, and UDIM-named textures. Exports SHALL be organized in a user-visible Export folder.

#### Scenario: Multi-object USD export
- **WHEN** a document with three EditMesh objects is exported as USD
- **THEN** one file containing all three named objects with their UV sets SHALL be produced

### Requirement: Live-link network protocol
The app SHALL offer an opt-in local-network live-link service supporting at minimum: push/load Target geometry, pull/load EditMesh, clear scene, close document, display message, create/delete remote action buttons that trigger desktop callbacks, query symmetry and EditMesh change state, and stream the viewport camera to the desktop in real time. Beyond parity, the protocol SHALL support bidirectional incremental edit sync (delta-compressed) and USD payloads. The service SHALL be off by default and SHALL never transmit without explicit user activation.

#### Scenario: Push-pull round trip from Blender
- **WHEN** a desktop client pushes a high-poly Target and later pulls the EditMesh
- **THEN** the Target SHALL open in the active document and the pulled EditMesh SHALL match the app's current state exactly

#### Scenario: Live camera stream
- **WHEN** camera streaming is enabled from a connected client
- **THEN** desktop viewport orientation SHALL follow the iPad camera in real time

### Requirement: Desktop clients at launch
A Blender add-on (push/pull, real-time sync) and a pip-installable Python client with CLI SHALL ship at launch, with a documented protocol for third-party integration and a Nomad Sculpt round-trip preset.

#### Scenario: Python client parity
- **WHEN** a script uses the Python client to push a target, add a remote action, and poll callbacks
- **THEN** all protocol operations SHALL succeed against a device running the app on the same network
