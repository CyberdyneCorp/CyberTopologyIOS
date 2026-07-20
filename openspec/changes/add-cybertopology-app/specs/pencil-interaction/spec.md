# pencil-interaction — Delta Spec

## ADDED Requirements

### Requirement: Input division of labor
Apple Pencil input SHALL author (draw gestures, pressure-modulated tools); finger input SHALL navigate (orbit, pinch, undo/redo taps). Every Pencil interaction SHALL have a finger fallback so the app is fully usable without a Pencil. A touch-arbitration state machine SHALL classify pen vs 1/2/3+ finger input; more than two simultaneous touches SHALL NOT cause erratic camera motion; stray palm touches SHALL NOT trigger tool actions (Pencil-priority filtering with a rejection zone around the pen/hover point).

#### Scenario: Palm rejection during pen stroke
- **WHEN** the user rests a palm on screen while drawing with the Pencil
- **THEN** the palm contact SHALL NOT fire any tool, button, or camera action

#### Scenario: No-Pencil session
- **WHEN** a user without a Pencil draws a quad gesture with a finger while a navigation modifier is not active
- **THEN** the gesture SHALL be recognized identically to a Pencil stroke

### Requirement: Five coherent verbs across stages
The system SHALL provide five primary verbs — **Pencil**, **Relax**, **Move**, **Tweak**, **Erase** — with consistent semantics in every stage: Relax smooths (topology positions in RT, UV coordinates in UV, cage shape in BK); Erase deletes the stage's primary element (faces / seams / cage overrides); Move drags with geodesic surface falloff that never affects disconnected components.

#### Scenario: Relax semantics per stage
- **WHEN** the user holds Relax and scrubs in RT, UV, and BK stages
- **THEN** the same brush interaction SHALL smooth mesh vertices, UV coordinates, and cage shape respectively, with corner auto-pinning preserving grid patch shapes

#### Scenario: Geodesic Move falloff
- **WHEN** Move is used near a disconnected EditMesh component that is close in screen space
- **THEN** the disconnected component SHALL NOT move

### Requirement: Contextual gesture grammar
Pencil strokes SHALL be interpreted by shape plus mesh context, implementing at minimum the CozyBlanket-compatible grammar: closed square on empty surface → new quad; one-stroke grid → block of quads; line across a face ring → full edge loop insert; line along a loop → tag/color it; scribble over an edge → dissolve; X over faces/region/component → delete (RT) / unwrap (UV) / bake (BK); vertex-to-vertex line → merge; double-tap → Tweak vertex or slide loop; circle over an edge → rotate edge; lasso from empty space → hide portion; straight line down/up in empty space → invert/show-all visibility. Recognition SHALL tolerate sloppy strokes.

#### Scenario: Loop insert vs loop tag disambiguation
- **WHEN** the user draws a line roughly perpendicular across a quad ring
- **THEN** an edge loop SHALL be inserted around the ring; a stroke along the loop direction SHALL tag the loop instead

#### Scenario: Stage-dependent X gesture
- **WHEN** the user draws an X over a region in RT, UV, and BK stages
- **THEN** the system SHALL delete faces, unwrap the island, and bake the component respectively

### Requirement: Post-stroke interpretation chip
After each recognized (or rejected) stroke, the system SHALL display a transient chip stating what the recognizer did, with one-tap alternative interpretations when the stroke was ambiguous. Choosing an alternative SHALL replace the applied result without requiring undo.

#### Scenario: One-tap misrecognition fix
- **WHEN** a stroke is interpreted as "tag loop" but the user intended "insert loop"
- **THEN** tapping the alternative on the chip SHALL swap the result in place

### Requirement: Hover gesture preview
On hover-capable hardware, hovering the Pencil SHALL preview what a stroke or tap at that location would do (ghost quad, highlighted loop, snap-target highlight) before contact.

#### Scenario: Hover over an edge
- **WHEN** the Pencil hovers over an interior edge
- **THEN** the loop that a double-tap would slide SHALL be highlighted without modifying the mesh

### Requirement: Hold-chord spring-loaded modifiers
Toolbar buttons SHALL act as spring-loaded modifiers: holding a button (finger hold, or configurable Pencil-hold timeout) activates that verb for the duration of the hold and returns to the previous tool on release. Left-handed mode and toolbar repositioning (either side, upper half) SHALL be supported. Hardware-keyboard chords SHALL map to the verbs.

#### Scenario: Spring-loaded Relax
- **WHEN** the user holds the Relax button with a finger and scrubs with the Pencil, then releases
- **THEN** Relax SHALL apply during the hold and the prior tool SHALL be active immediately after release

### Requirement: Customizable toolbar and Action Gallery
The system SHALL provide an Action Gallery listing every action with a help panel containing a looping demo video and usage notes. Users SHALL be able to drag actions into a bounded set of toolbar slots, replace and remove them; the configuration SHALL persist reliably across sessions.

#### Scenario: Toolbar persistence
- **WHEN** the user customizes toolbar slots and relaunches the app
- **THEN** the customized toolbar SHALL be restored exactly

### Requirement: Pencil Pro and haptic feedback
On supporting hardware, Pencil Pro squeeze SHALL open a radial Action Gallery at the pen tip and barrel roll SHALL rotate the element being placed (patch, strip, UV island). The system SHALL emit haptic ticks (Pencil or device) plus a micro-animation on vertex snap and merge events, with snap targets highlighted before commit; haptics SHALL be user-disableable.

#### Scenario: Snap feedback
- **WHEN** a dragged vertex comes within merge distance of another vertex
- **THEN** the target SHALL highlight before commit and a haptic tick SHALL fire when the merge happens

### Requirement: First-run onboarding
On first launch the app SHALL offer an interactive tutorial on a bundled practice model covering navigation, the five verbs, core gestures, and one Weave. The tutorial SHALL be skippable and re-launchable.

#### Scenario: Tutorial completion
- **WHEN** a new user completes the tutorial
- **THEN** they SHALL have performed at least one quad draw, loop insert, relax, unwrap, and Weave accept on the bundled model
