# Delta: retopology-tools (improve-region-paint-ux)

## ADDED Requirements

### Requirement: The region brush shows its footprint

While the region paint tool is armed, hovering over the Target SHALL show a ring of the
brush's actual radius at the hover point, and that cursor SHALL take precedence over any
element highlight.

Rationale: painting a region is aiming, and the brush covers a band per stroke. Without a
cursor its size is only knowable after the fact, from which faces changed colour. And while
a paint tool is in hand, what a drag would grab is not the question being asked.

#### Scenario: The cursor appears with the tool
- **WHEN** the region paint tool is armed and the pointer hovers over the Target
- **THEN** a ring of the brush's radius SHALL be drawn at that point

#### Scenario: The cursor outranks element highlights
- **WHEN** the brush cursor is shown over a vertex, edge or face
- **THEN** the cursor SHALL be shown rather than that element's highlight

#### Scenario: No cursor without the tool
- **WHEN** any other tool or verb is active
- **THEN** no brush ring SHALL be drawn

### Requirement: A pencil double-tap toggles erase

A double-tap on the pencil SHALL switch the region brush between painting and erasing, and
back, while the region paint tool is armed. Erasing SHALL unpaint the faces under the
stroke, leaving the rest of the region intact and in its existing order.

The mode SHALL be visible: the cursor SHALL differ between painting and erasing, and the
change SHALL be announced.

Rationale: painting additively means an over-painted region has to be cleared and redone.
The double-tap is the gesture other apps use to reach an eraser, so it needs no on-screen
control — but a mode with no visible state is a trap, since the tool looks identical either
way.

#### Scenario: Toggling and back
- **WHEN** the user double-taps the pencil twice with the tool armed
- **THEN** the brush SHALL erase after the first and paint after the second

#### Scenario: Erasing part of a region
- **WHEN** the user erases over some painted faces
- **THEN** those faces SHALL be unpainted
- **AND** the remaining painted faces SHALL keep their order

#### Scenario: The mode is visible
- **WHEN** the brush is erasing
- **THEN** the cursor SHALL be distinguishable from the painting cursor

### Requirement: The face-count prompt states the reachable budget

The custom face-count prompt SHALL state what is available for the current solve: the
painted region's size and the ceiling the solve will clamp to, or the Target's face count
when nothing is painted. It SHALL pre-fill a value within that ceiling.

Rationale: the prompt pre-filled the Target's face count, which for a painted region is far
above the clamp, so the artist typed a number that could not happen. A prompt that invites
an impossible answer is worse than one that says nothing.

#### Scenario: With a painted region
- **WHEN** the prompt is shown with a region painted
- **THEN** it SHALL state the region's size and the maximum quads it supports

#### Scenario: With nothing painted
- **WHEN** the prompt is shown with no region painted
- **THEN** it SHALL state the Target's face count

#### Scenario: The pre-filled value is reachable
- **WHEN** the prompt is shown with a region painted
- **THEN** the pre-filled count SHALL NOT exceed the ceiling
