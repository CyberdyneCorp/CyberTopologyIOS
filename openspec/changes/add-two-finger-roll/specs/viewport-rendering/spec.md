# Delta: viewport-rendering (add-two-finger-roll)

## ADDED Requirements

### Requirement: Two-finger twist rolls the view around the fingers

A two-finger twist SHALL roll the camera, and the point between the fingers SHALL stay where it
is on screen while it does.

The roll SHALL be part of the camera's state, so that picking, panning and the camera-driven
tools use the same up direction the viewer can see.

Rationale: retopology is stroke work, and a permanently level horizon forces the artist to
contort the wrist or re-pose the model to draw a comfortable line. Rolling about the screen
centre instead of the fingers would slide the work being done out from under the hand.

#### Scenario: The scene turns with the fingers
- **WHEN** the user twists two fingers clockwise
- **THEN** the scene SHALL turn clockwise on screen

#### Scenario: The pivot does not drift
- **WHEN** the user rolls the view about a point between their fingers
- **THEN** that point SHALL remain at the same screen position

#### Scenario: Picking follows the rolled view
- **WHEN** the camera is rolled
- **THEN** a ray cast through a screen point SHALL hit what is drawn at that screen point

#### Scenario: Rolling does not zoom or orbit
- **WHEN** the view is rolled
- **THEN** the camera's distance, azimuth and elevation SHALL be unchanged

### Requirement: The twist coexists with pinch and pan

Rolling SHALL be recognized simultaneously with two-finger pinch and two-finger pan, and SHALL
require a small twist threshold before it begins.

When the threshold is crossed, the roll SHALL continue from that angle rather than jumping by the
threshold.

Rationale: one physical two-finger gesture routinely carries zoom, pan and twist at once. Without
a threshold, the rotational noise in a straight two-finger drag accumulates into a tilted horizon
over a long pan — the problem is drift, not a false start.

#### Scenario: A straight two-finger drag does not roll
- **WHEN** the user drags two fingers without twisting past the threshold
- **THEN** the view SHALL NOT roll

#### Scenario: No jump when the twist engages
- **WHEN** a twist first crosses the threshold
- **THEN** the applied roll SHALL be the amount past the threshold, not the whole rotation

### Requirement: Rolling is optional and reframing levels the horizon

Two-finger roll SHALL be a user setting, enabled by default; while disabled, a twist SHALL leave
the camera unchanged.

Reframing and camera rescue SHALL restore a level horizon.

Rationale: a tilted horizon is disorienting for anyone who did not ask for it, and a twist is
easy to trigger accidentally while pinching. Reframe is what someone reaches for when the camera
is somewhere they did not intend, so it must undo a roll along with everything else.

#### Scenario: The setting is off
- **WHEN** two-finger roll is disabled and the user twists two fingers
- **THEN** the camera SHALL NOT roll

#### Scenario: Reframing levels a rolled camera
- **WHEN** the camera is rolled and the user reframes
- **THEN** the resulting camera SHALL have a level horizon
