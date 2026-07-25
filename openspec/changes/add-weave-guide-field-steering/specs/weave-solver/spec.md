# weave-solver — Delta Spec (add-weave-guide-field-steering)

Adds orientation steering: guide strokes and tagged loops bias the solver's cross
field so edge flow follows them. Hard-pin only; soft/weighted constraints, frozen
patches, pins, and the prescribed-boundary guarantee remain deferred.

## ADDED Requirements

### Requirement: Guide-stroke orientation steering
The solver SHALL accept directional orientation guides (a set of world-space
directions attached to surface locations) and bias the proposed cage's edge flow to
follow them: in the neighbourhood of a guide, the dominant edge direction SHALL align
with the guide direction more closely than it does in an unguided solve of the same
input. The solve SHALL remain deterministic given identical inputs and guides.

#### Scenario: Flow follows the guide
- **WHEN** a Target is solved with an orientation guide along a chosen direction
- **THEN** near the guide the cage's edges SHALL run more nearly parallel to that
  direction than the same region does when solved with no guide

#### Scenario: No guide, unchanged behaviour
- **WHEN** a Target is solved with an empty guide set
- **THEN** the result SHALL be identical to the unguided solve of that Target

#### Scenario: Determinism with guides
- **WHEN** the same Target is solved twice with the same guides
- **THEN** the two cages SHALL be identical vertex-for-vertex and face-for-face

### Requirement: Tagged loops steer flow
A colour-tagged edge loop supplied as a flow constraint SHALL bias the cross field so
the proposed cage's edges run along the loop's direction in its neighbourhood, using
the same orientation-guide channel as guide strokes.

#### Scenario: Loop tag aligns flow
- **WHEN** a Target is solved with a tagged loop supplied as a flow constraint
- **THEN** near the loop the cage's edges SHALL align with the loop's tangent direction
  more closely than in an unguided solve
