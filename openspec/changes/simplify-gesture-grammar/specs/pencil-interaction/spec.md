# Delta: pencil-interaction

## MODIFIED Requirements

### Requirement: Contextual gesture grammar

The Pencil stroke grammar SHALL express exactly three authoring actions:
create a quad face, create a triangle face, and delete faces. Every other
retopology capability (edge dissolve, loop insert, loop tag, merge, edge
rotate, grid fill, region visibility) SHALL be reachable only through an
explicitly armed tool or a batch command, never through stroke
interpretation.

Rationale: the classifier is a deterministic geometric heuristic over
hand-tuned thresholds, not a learned model. Separating nine shapes made the
quad branch the narrowest in the cascade, and device testing showed a single
intended quad gesture resolving as quad, lasso, scribble and unknown across
consecutive strokes. Every attempt to widen the quad branch collided with a
neighbouring gesture. A three-action grammar is a problem this classifier can
solve reliably; a nine-action one is not. A capability the user arms
deliberately cannot be triggered by a misread stroke.

#### Scenario: A closed stroke creates a quad
- **WHEN** a closed (or nearly closed) stroke with quad-like corner
  structure is drawn on the Target
- **THEN** it SHALL resolve to create-quad, whether or not the stroke
  overshoots or stops short of its own start point

#### Scenario: Stroke ambiguity never destroys work
- **WHEN** a stroke cannot be classified with useful confidence
- **THEN** it SHALL resolve to no action and say so
- **AND** it SHALL NOT fall back to any action that hides, dissolves or
  deletes existing geometry

### Requirement: Sloppy-stroke forgiveness

Closure judgement SHALL tolerate the two ways a hand closes a loop: an
overshoot that crosses the stroke near its start, and a gap that stops short
of it. Neither SHALL prevent a stroke with quad-like corner structure from
reading as a closed loop.

Thresholds SHALL be tuned against a committed corpus of strokes recorded
from real hardware. Synthesized strokes are insufficient: a programmatic
square is either perfectly closed or a perfect square wave, and neither
exercises the tolerance this requirement exists to guarantee.

#### Scenario: Overshooting the join
- **WHEN** a quad stroke crosses itself near its start point
- **THEN** the crossing SHALL be treated as a seam artifact
- **AND** the stroke SHALL resolve to create-quad

#### Scenario: Stopping short of the join
- **WHEN** a quad stroke ends without reaching its start point
- **THEN** it SHALL still resolve to create-quad
- **AND** the reported confidence MAY be lower, so the interpretation chip
  can still offer alternatives

## ADDED Requirements

### Requirement: Live stroke feedback

The stroke in progress SHALL be visible under the Pencil as it is drawn, and
SHALL clear when the stroke resolves so the committed result is what the user
sees next.

#### Scenario: Ink follows the pen
- **WHEN** a Pencil stroke is in progress
- **THEN** a trail SHALL render along the sampled path without waiting for
  the viewport's next paced frame

#### Scenario: Ink clears on resolution
- **WHEN** the stroke ends or is cancelled
- **THEN** the trail SHALL clear
