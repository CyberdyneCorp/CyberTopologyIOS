# Delta: pencil-interaction (fix-lost-finger-navigation)

## ADDED Requirements

### Requirement: Finger navigation recovers from a touch that never ends

The viewport SHALL NOT stay unable to accept camera gestures because of a touch whose end was
never delivered. Touch tracking SHALL be reconciled against the system's own record of which
touches are still down, so a lost end costs at most the gesture in progress.

An authoring stroke whose touch has vanished SHALL be cancelled rather than left open.

Rationale: camera gestures are refused once two finger touches are tracked, and tracked touches
were removed only by the end and cancel callbacks. One undelivered end therefore disabled orbit,
pinch and pan for the whole session — while the pen, gated separately, and the toolbar, outside
the viewport, kept working. That asymmetry is what the failure looks like from the outside.

#### Scenario: A finger whose end is never delivered
- **WHEN** a finger touch is tracked and the system has already finished it
- **THEN** it SHALL be released
- **AND** subsequent finger gestures SHALL be admitted

#### Scenario: A pen touch that never ends
- **WHEN** a pen touch is tracked and the system has already finished it
- **THEN** palm rejection SHALL stop refusing fingers

#### Scenario: A stroke whose touch vanished
- **WHEN** an authoring touch is released by reconciliation
- **THEN** the stroke SHALL be cancelled, not left in progress

#### Scenario: Live touches are never dropped
- **WHEN** touches are still down
- **THEN** reconciliation SHALL leave them tracked
