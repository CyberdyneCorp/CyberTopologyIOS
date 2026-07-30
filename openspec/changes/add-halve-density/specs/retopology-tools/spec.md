# Delta: retopology-tools (add-halve-density)

## ADDED Requirements

### Requirement: Halving the cage's quad density

The system SHALL provide a whole-cage command that halves quad density: every other edge loop
in each loop family is dissolved, so each 2x2 block of quads becomes one quad and a 16x16 cage
becomes 8x8. It SHALL be one undoable journal entry, and it SHALL be the counterpart to
Subdivide rather than a solver invocation.

Halving SHALL preserve the cage's silhouette EXACTLY: the surviving loops SHALL include the
cage's boundary loops, and every surviving vertex SHALL keep its position. No vertex SHALL be
averaged or reprojected, so the command SHALL NOT require a Target.

Halving SHALL REFUSE, leaving the document byte-unchanged and reporting why, whenever "every
other loop" has no consistent answer: a cage that is not quad-only, a loop that cannot be
walked end to end because it meets a vertex of valence other than four, a loop family with an
odd number of loops, or a cage with fewer than two loops in a family.

Rationale for refusing rather than approximating: a partial halving leaves a row or column at
double width, which is worse than declining — the artist can see and fix an untouched cage, but
has to hunt for a silently mangled one. This mirrors the create rules, which withhold rather
than down-weight.

#### Scenario: A regular grid halves
- **WHEN** the artist halves a quad-only cage whose loop families each have an even loop count
- **THEN** each 2x2 block of quads SHALL become one quad
- **AND** the result SHALL be quad-only

#### Scenario: The silhouette does not move
- **WHEN** a cage is halved
- **THEN** every surviving vertex SHALL be at the position it held before
- **AND** the cage's boundary SHALL still pass through the same points

#### Scenario: One undo restores the cage
- **WHEN** a halve is undone
- **THEN** the document SHALL be restored to its exact pre-command bytes

#### Scenario: A cage with a pole is refused
- **WHEN** the artist halves a cage in which a loop meets a vertex of valence other than four
- **THEN** no geometry SHALL change and the refusal SHALL be reported

#### Scenario: An odd loop count is refused
- **WHEN** a loop family has an odd number of loops
- **THEN** no geometry SHALL change and the refusal SHALL be reported

#### Scenario: A non-quad cage is refused
- **WHEN** the cage contains a triangle or an n-gon
- **THEN** no geometry SHALL change and the refusal SHALL be reported

### Requirement: Halving rebuilds the element id space

Halving SHALL be treated as an id-rebuilding command, exactly as subdivision is: annotations
keyed on element ids — loop tags, pins, hidden faces, frozen faces, seams — SHALL be cleared as
part of the same journal entry, and the command SHALL say so before it runs.

Rationale: the surviving elements are not the elements that were there before — faces are merged
and mid-side vertices are removed — so an annotation kept by id would point at unrelated
geometry.

#### Scenario: Annotations clear with the halve
- **WHEN** a cage carrying loop tags and pins is halved
- **THEN** those annotations SHALL be cleared in the same undoable entry as the halve
