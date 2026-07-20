# baking — Delta Spec

## ADDED Requirements

### Requirement: Component linking by drawing
In the BK stage, users SHALL link a low-poly component to one or more high-poly components by drawing a line between them; an X over a component SHALL bake that component; an X in empty space SHALL bake the whole document. Links SHALL persist in the document and be shown side-by-side in low/high viewports.

#### Scenario: Explicit link then bake
- **WHEN** the user draws a line from a low-poly glove to the high-poly hand and draws an X over the glove
- **THEN** only the linked hand geometry SHALL contribute rays to the glove's bake

### Requirement: Brush-editable per-vertex cage
The bake cage SHALL be a first-class editable object: Relax smooths cage shape, Tweak adjusts cage distance with area falloff (double-tap for single-vertex distance), Erase resets to default. Per-vertex cage distances SHALL persist in the document.

#### Scenario: Local cage fix
- **WHEN** ray misses occur in a crevice and the user Tweaks the cage distance locally
- **THEN** only that region's cage SHALL change and the next bake SHALL use the edited distances

### Requirement: Full bake map set
The system SHALL bake, per linked pair and at configurable resolutions: tangent-space normal maps, ambient occlusion, bent normals, curvature, thickness, position, material/object ID, and color/vertex-color transfer. Bakes SHALL run on GPU (Metal ray tracing where available, intersector fallback otherwise).

#### Scenario: Substance-ready export
- **WHEN** the user bakes AO, curvature, thickness, position, and ID maps and exports
- **THEN** all maps SHALL be written as separate textures usable as texturing-suite inputs

### Requirement: Progressive live bake preview
While the cage or links are edited, the system SHALL continuously render a low-sample progressive bake preview in the viewport, refining when input is idle. Move SHALL reposition the preview light for normal-map inspection.

#### Scenario: Cage edit feedback
- **WHEN** the user tweaks cage distance over an artifact-prone area
- **THEN** the preview bake for that area SHALL visibly update within one second, without a manual re-bake

### Requirement: Tangent-space correctness
Normal maps SHALL use MikkTSpace tangents, verified bit-exact against Blender/Unity/Unreal golden files in the regression suite. Exported bakes SHALL exhibit no scale mismatches or snapping artifacts relative to the source: a sculpt baked and exported SHALL shade identically in the target engine.

#### Scenario: Golden-file tangent check
- **WHEN** the regression suite bakes the reference asset
- **THEN** its tangent basis SHALL match the MikkTSpace golden file exactly

### Requirement: Texture-to-texture rebake
Given a Target that already has UVs and textures, the system SHALL rebake those textures onto the new low-poly UV layout, including across UDIM tiles.

#### Scenario: Rebake scanned texture
- **WHEN** a photogrammetry scan with an 8K diffuse texture is retopologized and unwrapped, and the user runs texture-to-texture bake
- **THEN** the diffuse SHALL be transferred onto the new UV layout without visible seam artifacts at island boundaries

### Requirement: Bake mesh export
The system SHALL optionally export the triangulated mesh actually used for baking, so downstream tools reproduce identical shading.

#### Scenario: Export bake mesh
- **WHEN** the user enables "export bake mesh" during export
- **THEN** the exact triangulation used by the baker SHALL be written alongside the main export
