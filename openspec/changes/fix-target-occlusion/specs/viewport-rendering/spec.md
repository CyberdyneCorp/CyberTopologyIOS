# Delta: viewport-rendering (fix-target-occlusion)

## ADDED Requirements

### Requirement: EditMesh geometry behind the Target is occluded

EditMesh wireframe and fill that lie behind the Target SHALL be hidden by it, unless x-ray mode
is enabled.

Geometry snapped ONTO the Target SHALL remain visible: the occlusion allowance exists so a cage
lying exactly on the surface is not z-fought out of existence, and it SHALL be small enough that
the far side of the model never survives it.

Rationale: a cage whose far side reads as its near side cannot be judged. X-ray mode is the
deliberate way to see through the Target, and it should be the only one.

#### Scenario: The far side of a wrapped cage
- **WHEN** an EditMesh wraps around the Target and the camera views one side
- **THEN** the faces on the far side SHALL NOT be drawn over the Target

#### Scenario: A cage on the surface still reads
- **WHEN** an EditMesh is snapped onto the Target facing the camera
- **THEN** its wireframe and fill SHALL be visible

#### Scenario: X-ray still sees through
- **WHEN** x-ray mode is enabled
- **THEN** far-side EditMesh geometry SHALL be visible, depth-attenuated

### Requirement: The occlusion allowance is scene-relative

The allowance that keeps surface-snapped overlays visible SHALL be expressed relative to the
scene's size, not in normalized-device depth, and SHALL be converted for the depth test using the
camera's current projection.

Rationale: NDC depth is nonlinear and its scale depends on the near and far planes, so one fixed
number cannot mean the same thing on two scenes — measured on a fitted unit-radius model, an
allowance of 0.002 NDC is fifty times the model's entire depth range, which disables occlusion
rather than tuning it.

#### Scenario: The same allowance on scenes of different size
- **WHEN** the same allowance is applied to a small scene and a large one
- **THEN** it SHALL correspond to the same fraction of each scene's size

#### Scenario: The allowance never swallows the model
- **WHEN** the camera is framed to fit the scene
- **THEN** the allowance SHALL be a small fraction of the scene's own depth range

### Requirement: Depth precision separates the front of a model from its back

The near and far planes SHALL keep a ratio that leaves the depth buffer able to distinguish the
near and far surfaces of the framed scene, at every camera pose including inside the model.

Rationale: with the near plane collapsing toward zero at the default framing, the whole scene
occupied a 4e-5 sliver of the depth range; no depth test — biased or not — can be relied on in
that state.

#### Scenario: Framed to fit
- **WHEN** the camera frames the scene to fit
- **THEN** the front and back of the scene SHALL differ measurably in depth

#### Scenario: Inside the model
- **WHEN** the camera is inside the scene bounds
- **THEN** rendering SHALL continue without the near plane collapsing
