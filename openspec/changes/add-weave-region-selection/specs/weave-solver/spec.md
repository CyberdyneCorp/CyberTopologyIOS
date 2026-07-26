# weave-solver — Delta Spec (add-weave-region-selection)

Gives regional prescribed-boundary solve a user: fill bare Target outward from an
open cage boundary, entered either by tapping or by painting an extent.

## ADDED Requirements

### Requirement: Weave fills bare Target outward from an open cage boundary
The system SHALL let the user fill unretopologized Target surface with quads that
meet the existing cage's open boundary exactly, growing the solve domain outward
from that boundary. The Target SHALL NOT be modified. Every vertex on the cage
boundary SHALL be preserved with its identity and position, and the fill SHALL be
presented as a ghost the user accepts or discards.

#### Scenario: Fill meets the hand-drawn boundary exactly
- **WHEN** the user fills bare Target next to an open cage boundary
- **THEN** the proposed quads SHALL share the cage's boundary vertices exactly
- **AND** the existing cage faces SHALL be unchanged
- **AND** the Target SHALL be unchanged

#### Scenario: Accepting is one undoable step
- **WHEN** a fill proposal is accepted
- **THEN** it SHALL become ordinary EditMesh in exactly one journal entry
- **AND** one undo SHALL restore the document to its exact pre-accept bytes

#### Scenario: Discarding leaves nothing
- **WHEN** a fill proposal is discarded
- **THEN** the document SHALL be byte-unchanged and no journal entry SHALL exist

### Requirement: Fill is entered by tapping or by painting an extent
The system SHALL offer two ways to start a fill: tapping near an open cage boundary,
which proposes the next patch outward from it, and painting over bare Target, which
grows the fill until it covers the painted area. Neither SHALL depend on classifying
the SHAPE of a free-form stroke, because a shape-classified enclosure was measured on
device to be indistinguishable from an intended quad and was removed from the
gesture grammar for that reason.

#### Scenario: Tap proposes the next patch
- **WHEN** the user taps bare Target near an open cage boundary
- **THEN** a fill proposal SHALL appear without any prior selection step

#### Scenario: Painting bounds how far the fill grows
- **WHEN** the user paints over bare Target before solving
- **THEN** the proposal SHALL cover the painted area rather than a default extent

#### Scenario: Bounding the area changes nothing in the document
- **WHEN** the user paints an extent and then clears it
- **THEN** the document SHALL be byte-unchanged and no journal entry SHALL exist

### Requirement: A fill with nothing to grow from is refused
The system SHALL refuse, with a reason the user can act on, a fill requested where
there is no open cage boundary to grow from — including bare Target disconnected
from the cage. It SHALL NOT silently substitute a whole-mesh solve or produce
geometry unattached to the cage.

#### Scenario: An isolated area is refused, not mis-filled
- **WHEN** the user requests a fill over bare Target that touches no open cage boundary
- **THEN** the system SHALL refuse and say why
- **AND** no ghost SHALL be produced

### Requirement: A pending fill re-solves when its inputs change
While a fill proposal is pending, changing the painted extent or the density SHALL
re-run the solve and replace the proposal, without journaling anything. The system
SHALL NOT present a result whose inputs have since changed.

#### Scenario: Extending the paint re-solves
- **WHEN** the user paints further with a proposal pending
- **THEN** a new proposal SHALL replace the previous one
- **AND** the document SHALL remain byte-unchanged

#### Scenario: A superseded solve never appears
- **WHEN** the inputs change again before an in-flight solve finishes
- **THEN** the stale result SHALL be discarded rather than shown

### Requirement: A fill proposal reports what it could not make regular
The system SHALL show the user, before they accept, any interface vertices a fill
left irregular and any triangles it left at the seam. It SHALL NOT treat either as a
failure, because interface regularity is measured and not guaranteed.

#### Scenario: An irregular interface is surfaced, not hidden
- **WHEN** a fill proposal contains irregular interface vertices
- **THEN** the count SHALL be shown alongside the accept affordance
- **AND** accepting SHALL still be possible
