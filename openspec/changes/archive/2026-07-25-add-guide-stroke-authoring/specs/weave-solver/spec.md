# weave-solver — Delta Spec (add-guide-stroke-authoring)

Adds the AUTHORING side of orientation guides: drawing guide strokes on the Target and
feeding them into Auto-Retopo. The steering itself is already specified (guide-stroke
orientation steering). Per-guide editing, document persistence, and tagged-loop
authoring remain out of scope.

## ADDED Requirements

### Requirement: Guide strokes are authored on the Target surface
The system SHALL let the user draw guide strokes on the Target: while guide authoring
is active, a stroke over the Target SHALL be captured as a world-space polyline lying
on the Target surface, and a stroke that does not hit the Target SHALL add no guide.
Authored guides SHALL be clearable in one action.

#### Scenario: A stroke over the Target becomes a guide on its surface
- **WHEN** guide authoring is active and the user draws a stroke across the Target
- **THEN** a guide polyline SHALL be stored whose points lie on the Target surface

#### Scenario: A stroke that misses the Target adds nothing
- **WHEN** guide authoring is active and the user draws a stroke over empty space
- **THEN** no guide SHALL be stored

#### Scenario: Clear removes all guides
- **WHEN** guides exist and the user clears them
- **THEN** no authored guides SHALL remain

### Requirement: Authored guides are shown as a surface overlay
Authored guide strokes SHALL be rendered as a world-space overlay on the Target that
tracks the camera, so the user can see the active guides from any viewpoint.

#### Scenario: Guides remain visible as the camera moves
- **WHEN** guides exist and the camera orbits
- **THEN** the guide overlay SHALL remain registered to the Target surface

### Requirement: Auto-Retopo follows authored guides
When guides are authored, an Auto-Retopo solve SHALL supply them to the solver as
orientation guides, so the proposed cage's edge flow follows them. With no authored
guides, the solve SHALL be unchanged.

#### Scenario: Authored guides steer the retopo
- **WHEN** guides are authored on the Target and Auto-Retopo is run
- **THEN** the solve SHALL receive those guides as orientation constraints

#### Scenario: No guides, unchanged solve
- **WHEN** no guides are authored and Auto-Retopo is run
- **THEN** the solve SHALL behave exactly as it does without the guide feature
