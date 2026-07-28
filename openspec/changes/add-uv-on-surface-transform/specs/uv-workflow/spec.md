# uv-workflow — Delta Spec (add-uv-on-surface-transform)

## ADDED Requirements

### Requirement: Island UVs are adjustable from the 3D surface
Drawing over a shell in the UV stage SHALL arm an on-surface transform of that island's UVs, after which camera motion adjusts them: pinch scales, a two-finger twist rotates, and orbit moves.

Each channel SHALL come from a DISTINCT gesture, so no gesture can be mistaken for another.

Camera input SHALL reach the tool through the existing camera-as-manipulator routing, so that a
touch which the arbiter withholds from the camera never drives the tool either.

The translation mapping SHALL be normalized by scene scale, so the same gesture moves an island the
same UV distance regardless of model size.

Arming SHALL be refused when the mesh has no UV layout, rather than accepting the stroke and failing
at commit.

The accumulated transform SHALL be applied as a SINGLE undoable step on commit, and a session that
was armed but not moved SHALL journal nothing.

A transform SHALL never request a non-positive scale, which would mirror or collapse the island.

#### Scenario: Pinch, twist and orbit drive different components
- **WHEN** the camera pinches, twists, or orbits during an armed on-surface session
- **THEN** the island's UVs SHALL scale, rotate, or translate respectively

#### Scenario: An unmoved session leaves no trace
- **WHEN** an on-surface session is armed and committed without moving the camera
- **THEN** nothing SHALL be journaled

#### Scenario: Arming needs a layout
- **WHEN** the tool is used on a mesh that has never been unwrapped
- **THEN** no session SHALL be armed

#### Scenario: Model scale does not change the feel
- **WHEN** the same camera displacement occurs on models of different size
- **THEN** the island SHALL move by the same UV distance relative to the model
