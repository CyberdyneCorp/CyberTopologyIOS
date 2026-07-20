# retopology-tools — Delta Spec

## ADDED Requirements

### Requirement: Core RT action roster
The RT stage SHALL provide, at minimum, CozyBlanket-parity actions: Build Quad, Build Triangle, Patch Clone (select faces → reposition via camera → paste, with flip and repeat), Extend Boundary (camera-driven quad-strip extrusion with single/once/automatic modes, boundary grid fill, triangle fans, boundary auto-select on hold), Draw Strip (stroke-following quad strip preserving source quad size), Transform Vertices (screen-space lock, camera-driven move/rotate/scale, re-snap report), Merge Pair, Path Distribute, Surface Cut (knife with auto-triangulated n-gons), Pin toggle (per-vertex and per-loop), lasso hide/show, and Loop Info inspection (vertex/edge counts, boundary length, snapping state in O(loop) time).

#### Scenario: Patch Clone round-trip
- **WHEN** the user selects a scale patch with one stroke, orbits the camera, and taps to paste
- **THEN** a copy of the patch SHALL be projected onto the Target at the new location and remain repeatable for further pastes

#### Scenario: Extend Boundary automatic mode
- **WHEN** the user selects a boundary and orbits with automatic steps enabled
- **THEN** quad strips SHALL extrude continuously following the camera until the user commits or cancels

### Requirement: Pins immune to smoothing
Pinned vertices SHALL be visually marked and SHALL NOT be displaced by Move, Relax, Auto Relax, or the Weave solver. Pinning SHALL be applicable per vertex and per edge loop.

#### Scenario: Relax over pinned loop
- **WHEN** the user relaxes across a region containing a pinned loop
- **THEN** unpinned vertices SHALL smooth while pinned vertices remain fixed

### Requirement: Loop tags
Users SHALL color-tag edge loops by drawing along them; tags SHALL persist in the document, be clearable individually and en masse, and be consumable as flow constraints by the Weave solver.

#### Scenario: Tag then weave
- **WHEN** the user tags a loop around an eye socket and later runs Weave over the surrounding region
- **THEN** the solved edge flow SHALL align with the tagged loop

### Requirement: Multi-axis and radial symmetry
The system SHALL support mirror symmetry on any combination of X/Y/Z axes with configurable origin, and radial symmetry with configurable count. Center-line vertices SHALL snap to the symmetry plane. Apply-symmetry SHALL bake the mirror, and a re-symmetrize tool SHALL restore symmetry to a mesh that has drifted asymmetric.

#### Scenario: Radial symmetry editing
- **WHEN** 8-fold radial symmetry is enabled and the user draws one quad
- **THEN** eight symmetric quads SHALL be created, all snapped to the Target

#### Scenario: Re-symmetrize
- **WHEN** a previously symmetric mesh has asymmetric edits and the user invokes re-symmetrize about X
- **THEN** the chosen side SHALL be mirrored to the other, preserving topology correspondence where it exists

### Requirement: Auto Relax
An optional Auto Relax mode SHALL adjust surrounding topology after each editing operation to maintain even quad distribution, honoring pins and frozen Weave constraints.

#### Scenario: Auto Relax after quad creation
- **WHEN** Auto Relax is on and the user appends quads along a strip
- **THEN** neighboring unpinned vertices SHALL redistribute automatically after each append

### Requirement: EditMesh batch commands
The system SHALL provide batch commands: snap-all to Target, relax-all, subdivide, triangulate, clear loop tags, clear pins, and subdivide+reproject (also available at export).

#### Scenario: Subdivide and reproject
- **WHEN** the user runs subdivide+reproject
- **THEN** the mesh SHALL be subdivided once and all new vertices projected onto the Target surface

### Requirement: Subdivision preview
The RT stage SHALL offer a 1–2 level smooth-subdivision preview (with reprojection) rendered non-destructively while editing continues on the base cage.

#### Scenario: Editing under preview
- **WHEN** subdivision preview level 1 is active and the user slides an edge loop
- **THEN** the smoothed preview SHALL update live while the stored mesh remains the base cage
