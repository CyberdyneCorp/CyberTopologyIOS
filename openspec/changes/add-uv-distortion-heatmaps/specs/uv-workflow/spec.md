# uv-workflow — Delta Spec (add-uv-distortion-heatmaps)

## ADDED Requirements

### Requirement: Per-face UV distortion is readable
Per-face UV distortion SHALL be readable for a mesh carrying a layout — angle (conformal) error, the UV-to-surface area ratio, and whether the face's winding is flipped.

A mesh with no layout SHALL report absence rather than zero distortion: no layout and a
perfect layout are different states, and reporting zeros for both would show a
never-unwrapped mesh as flawless.

#### Scenario: Distortion is readable after an unwrap
- **WHEN** per-face distortion is read from an unwrapped mesh
- **THEN** one measurement SHALL be returned per live face

#### Scenario: A mesh with no layout reports no distortion
- **WHEN** per-face distortion is read from a mesh that has never been unwrapped
- **THEN** the result SHALL indicate absence rather than zero distortion

### Requirement: The UV view shows where distortion is, not only how much
The 2D UV view SHALL shade each face by its distortion, so an artist can see WHICH faces are stretched rather than only that the atlas contains stretch.

Angle distortion and texel density SHALL both be available, texel density expressed against
a stated texture size rather than an implicit one. Flipped faces SHALL be distinguished from
high-distortion faces, because a flipped face is a defect rather than a point on a scale.

#### Scenario: A stretched face is visibly distinct
- **WHEN** a layout contains faces of differing angle distortion
- **THEN** the view SHALL shade them differently

#### Scenario: A flipped face is called out, not merely coloured
- **WHEN** a layout contains a flipped face
- **THEN** the view SHALL identify it as flipped rather than only shading it

#### Scenario: Texel density names its texture size
- **WHEN** the view shows texel density
- **THEN** the texture size the figure is expressed against SHALL be stated
