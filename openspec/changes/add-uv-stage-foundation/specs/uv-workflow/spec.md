# uv-workflow — Delta Spec (add-uv-stage-foundation)

First requirements for this capability. The UV stage and the data path it needs; seam
authoring, on-surface manipulation, heatmaps, packing and UV sets are later tasks.

## ADDED Requirements

### Requirement: UV coordinates are readable from a mesh
A mesh's per-corner UV coordinates SHALL be readable, so a view can draw the UV layout and a tool can measure it.

A mesh that has never been unwrapped SHALL be distinguishable from one whose UVs are
degenerate: absence SHALL be reported as absence, not as zeroed coordinates. Reading UVs
SHALL NOT modify the mesh.

#### Scenario: UVs are readable after an unwrap
- **WHEN** a mesh is unwrapped and its UV coordinates are read
- **THEN** one coordinate pair SHALL be returned per face corner

#### Scenario: A mesh that was never unwrapped reports no UVs
- **WHEN** UV coordinates are read from a mesh that has never been unwrapped
- **THEN** the result SHALL indicate that the mesh has no UVs, rather than returning zeros

### Requirement: The UV stage presents a UV workspace
Entering the UV stage SHALL present the UV workspace — the 3D surface alongside a 2D view of the UV layout — rather than the retopology viewport.

The stage SHALL remain document state, so reopening a document returns to the stage the
artist left, and switching stages SHALL NOT modify geometry.

#### Scenario: The UV stage shows the UV workspace
- **WHEN** the artist switches to the UV stage
- **THEN** the UV workspace SHALL be presented

#### Scenario: Switching stages changes no geometry
- **WHEN** the artist switches from retopology to UV and back
- **THEN** the mesh payload SHALL be unchanged

#### Scenario: A mesh with no UVs says so rather than showing an empty view
- **WHEN** the UV stage is entered with a mesh that has never been unwrapped
- **THEN** the 2D view SHALL state that there is no UV layout yet and offer to unwrap

### Requirement: Automatic unwrap is one undoable step that reports what it produced
The artist SHALL be able to unwrap a mesh in one action, journaled as a single undoable step, and the result SHALL be reported rather than silently applied.

The report SHALL include chart count, seam count, distortion and packed area, because those
are what decide whether a layout is usable. An unwrap that fails SHALL refuse with a stated
reason and leave the mesh unchanged.

#### Scenario: Unwrapping produces a reported layout
- **WHEN** the artist unwraps a mesh
- **THEN** UV coordinates SHALL be written
- **AND** the chart count, seam count, distortion and packed area SHALL be reported

#### Scenario: An unwrap is one undo step
- **WHEN** the artist unwraps and then undoes once
- **THEN** the mesh SHALL be exactly as it was before the unwrap

#### Scenario: A failed unwrap changes nothing
- **WHEN** an unwrap cannot be produced
- **THEN** it SHALL refuse with a stated reason and the mesh SHALL be unchanged
