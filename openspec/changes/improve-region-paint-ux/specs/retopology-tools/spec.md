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

### Requirement: The face count is entered with a keypad, and can be halved or doubled

The custom face-count prompt SHALL provide its own numeric keypad and Half / Double controls,
rather than relying on the system keyboard.

Halving SHALL never go below the solver's minimum and doubling SHALL never exceed the
available ceiling. A digit that would exceed the ceiling SHALL be ignored rather than
accepted and then rewritten. The prompt SHALL refuse to run below the solver's minimum.

Rationale: the value is always a number, so a text keyboard is the wrong instrument — and
the system number pad floats OVER the dialog, covering the line that states what is
reachable. Half and Double are how a density is actually chosen (relative to what you have),
and an alert cannot host them. Silently rewriting a typed number is worse than declining the
keystroke, because the ceiling is on screen beside the field.

#### Scenario: Typing a count
- **WHEN** the user types digits
- **THEN** the count SHALL be built from them
- **AND** a digit that would exceed the ceiling SHALL be ignored

#### Scenario: Halving and doubling
- **WHEN** the user halves or doubles the count repeatedly
- **THEN** it SHALL stay between the solver's minimum and the available ceiling

#### Scenario: Below the minimum
- **WHEN** the count is below the solver's minimum
- **THEN** the prompt SHALL NOT run a solve

#### Scenario: The dialog is not covered
- **WHEN** the prompt is shown
- **THEN** the statement of what is available SHALL remain visible while entering a count

### Requirement: The region paints while the stroke is in progress

Painting SHALL apply as the pencil moves, not when the stroke ends.

Rationale: with the extent appearing only after the pen lifts, a long stroke is drawn blind —
the artist cannot see what has been covered until it is too late to adjust.

#### Scenario: The extent grows during a stroke
- **WHEN** the user paints a stroke across the Target
- **THEN** faces SHALL be added to the region as the stroke passes over them

#### Scenario: A tap paints
- **WHEN** the user taps once with the paint tool armed
- **THEN** the faces under that tap SHALL be painted

### Requirement: Undo and redo cover painting

Undo SHALL step back one paint stroke at a time, and redo SHALL reapply it. Where there is no
paint history, undo and redo SHALL act on the document as before.

A paint stroke SHALL be one undo step regardless of how many samples it covered. Starting a
new stroke SHALL drop any redo branch, and clearing the region — which running a solve does —
SHALL drop the history with it.

Rationale: the artist's undo means "the last thing I did", and painting is one of those
things. It is NOT a document command, because the mask is viewport state that is never
persisted and a journal entry mutating nothing in the bundle would break the journal's replay
contract — so paint keeps its own history and undo consumes that first.

Stale history after a solve would be worse than none: those strokes describe a mask the solve
has already consumed.

#### Scenario: Undoing a paint stroke
- **WHEN** the user paints a stroke and then undoes
- **THEN** that stroke's faces SHALL be unpainted
- **AND** the document's own history SHALL be untouched

#### Scenario: Falling through to the document
- **WHEN** there is no paint history and the user undoes
- **THEN** the document's last command SHALL be undone

#### Scenario: An erase stroke is undoable too
- **WHEN** the user erases part of the region and then undoes
- **THEN** the erased faces SHALL come back

#### Scenario: Running a solve drops the history
- **WHEN** a solve runs and clears the region
- **THEN** there SHALL be no paint history to step back into
