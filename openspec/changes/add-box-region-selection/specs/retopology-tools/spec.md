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

### Requirement: A see-through box takes both sides

The system SHALL provide a see-through box mode that selects faces on the FAR side of the
surface as well as the near side, SHALL exclude faces behind the camera even in that mode,
and SHALL make the mode visible while it is active.

Rationale: a thin feature — an ear — is ONE thing to retopologize, and a visible-only box
takes one wall at a time, so covering both means finding a camera angle for each and running
two solves on halves of the same feature. A face behind the camera is still excluded: it
projects to a mirrored position that can land inside the box, which is an artefact rather
than something the artist boxed.

#### Scenario: Both walls of a thin feature
- **WHEN** a see-through box covers an ear
- **THEN** faces on both the near and far sides SHALL be selected

#### Scenario: Behind the camera stays out
- **WHEN** a see-through box's rectangle covers the mirrored projection of a face behind the camera
- **THEN** that face SHALL NOT be selected

#### Scenario: The mode is visible
- **WHEN** see-through selection is active
- **THEN** the mode SHALL be announced and the rectangle SHALL be drawn distinctly from a
  visible-only box

### Requirement: A pencil double-tap switches what the armed region tool most needs

A pencil double-tap SHALL toggle erase while the brush is armed and SHALL toggle see-through
while the box is armed, and SHALL do nothing while no region tool is armed.

Rationale: the double-tap is the gesture artists already reach for, and each region tool has
a different most-wanted switch — the brush needs to stop adding and start removing, a box
needs the far side of a thin feature. Binding it per tool gives each the switch that matters
there instead of one compromise. Doing nothing when no region tool is armed keeps it from
silently changing a mode with nothing on screen to show it.

#### Scenario: The brush
- **WHEN** the brush is armed and the pencil is double-tapped
- **THEN** erase mode SHALL toggle

#### Scenario: The box
- **WHEN** the box is armed and the pencil is double-tapped
- **THEN** see-through mode SHALL toggle

#### Scenario: Neither
- **WHEN** no region tool is armed and the pencil is double-tapped
- **THEN** no region mode SHALL change
