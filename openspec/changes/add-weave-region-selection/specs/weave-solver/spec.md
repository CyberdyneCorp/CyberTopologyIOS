# weave-solver — Delta Spec (add-weave-region-selection)

Gives regional solve a user: an armed selection tool, a solve over the selected
patch, and live re-solve while the selection is being adjusted.

## ADDED Requirements

### Requirement: A solve region is selected with an armed tool, not a shape gesture
The system SHALL let the user select the faces a region solve rewrites by painting
over them with a Pencil stroke while a region tool is armed. Region selection SHALL
NOT be driven by classifying a free-form stroke's SHAPE, because a shape-classified
enclosure was measured on device to be indistinguishable from an intended quad and
was removed from the gesture grammar for that reason. Successive strokes SHALL add
to the selection rather than replace it, and the user SHALL be able to clear it.

#### Scenario: Painting selects the faces under the stroke
- **WHEN** the region tool is armed and the user paints across several faces
- **THEN** exactly the faces the stroke crossed SHALL be selected
- **AND** no shape classification SHALL be involved

#### Scenario: A second stroke extends the selection
- **WHEN** the user paints again over different faces with a selection already active
- **THEN** the new faces SHALL be added to the existing selection

#### Scenario: Selecting changes nothing in the document
- **WHEN** the user selects, extends and clears a region
- **THEN** the document SHALL be byte-unchanged
- **AND** no journal entry SHALL be created

### Requirement: A region solve rewrites the EditMesh against its frozen remainder
A region solve SHALL operate on the EditMesh, rewriting only the selected faces
while every unselected face keeps its exact geometry, ring and element id. The
resulting proposal SHALL be presented as a ghost the user accepts or discards, and
accepting SHALL be exactly one undoable journal entry. The system SHALL make it
evident which input a solve is running over, because the whole-mesh mode solves the
Target instead.

#### Scenario: Only the selected patch changes
- **WHEN** a region solve over a selection is accepted
- **THEN** every unselected face SHALL be unchanged
- **AND** one undo SHALL restore the document to its exact pre-accept bytes

#### Scenario: Discard leaves nothing behind
- **WHEN** a region proposal is discarded
- **THEN** the document SHALL be byte-unchanged and no journal entry SHALL exist

### Requirement: An armed region re-solves when its inputs change
While a region selection is armed, changing the selection or the density SHALL
re-run the solve and replace the pending proposal, without journaling anything. The
system SHALL NOT run more than one solve at a time for a session, and SHALL discard
a superseded result rather than presenting it.

#### Scenario: Changing density re-solves
- **WHEN** the density is changed with a region proposal pending
- **THEN** a new proposal SHALL replace the previous one
- **AND** the document SHALL remain byte-unchanged

#### Scenario: A superseded solve never appears
- **WHEN** the inputs change again before an in-flight solve finishes
- **THEN** the stale result SHALL be discarded rather than shown

### Requirement: A region proposal reports what it could not make regular
The system SHALL show the user, before they accept, any interface vertices a region
proposal left irregular and any triangles it left at the seam. It SHALL NOT treat
it as a failure, because interface regularity is measured and not guaranteed.

#### Scenario: An irregular interface is surfaced, not hidden
- **WHEN** a region proposal contains irregular interface vertices
- **THEN** the count SHALL be shown alongside the accept affordance
- **AND** accepting SHALL still be possible
