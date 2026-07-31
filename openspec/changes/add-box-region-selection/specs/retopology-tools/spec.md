# Delta: retopology-tools (add-box-region-selection)

## ADDED Requirements

### Requirement: A drag box selects Target faces into the region

The system SHALL provide a box-selection tool that adds every VISIBLE Target face inside a
drag rectangle to the region auto-retopology solves, and SHALL draw the rectangle while the
drag is in progress.

A face counts as visible when it lies inside the box, faces the camera, and is the first
thing a ray at its centroid meets.

Rationale: the brush suits irregular areas; "this whole flank" is one drag. Taking everything
the box covers in depth would carve a domain wrapping both walls of a shape, which is not
what the drag said — and a normal test alone cannot see geometry in between, so both a facing
test and a first-hit test are needed.

#### Scenario: Selecting a region
- **WHEN** the user drags a box over part of the Target
- **THEN** the visible faces inside it SHALL join the region

#### Scenario: The far side is not taken
- **WHEN** a box covers faces turned away from the camera
- **THEN** those faces SHALL NOT be selected

#### Scenario: Hidden faces are not taken
- **WHEN** a box covers faces behind other geometry
- **THEN** those faces SHALL NOT be selected

#### Scenario: The box is visible while dragging
- **WHEN** a box drag is in progress
- **THEN** the rectangle SHALL be drawn

#### Scenario: A tap selects nothing
- **WHEN** the drag is too small to be a box
- **THEN** nothing SHALL be selected

### Requirement: Box and brush share one region

Box selection and brush painting SHALL contribute to the SAME region, SHALL share its undo
history, and SHALL both honour erase mode — a box while erasing DESELECTS.

Rationale: which tool was reached for should not change what happens next. Composing them is
the point: box a flank, then tidy its edge with the brush.

#### Scenario: Composing the two
- **WHEN** the user boxes an area and then paints beside it
- **THEN** the region SHALL contain both

#### Scenario: One box is one undo step
- **WHEN** the user selects a box and then undoes
- **THEN** that box's faces SHALL leave the region

#### Scenario: A deselect box
- **WHEN** the brush is erasing and the user drags a box over painted faces
- **THEN** those faces SHALL be removed from the region
