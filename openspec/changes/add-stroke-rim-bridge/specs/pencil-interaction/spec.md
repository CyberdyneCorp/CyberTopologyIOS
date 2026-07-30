# Delta: pencil-interaction (add-stroke-rim-bridge)

## ADDED Requirements

### Requirement: A stroke across a gap bridges the two facing rims with quads

A near-straight stroke across a gap SHALL fill that gap with quads bridging the two rims:
a stroke whose two endpoints snap to existing vertices that each lie on an OPEN BOUNDARY
(a rim), and which passes over no existing face between them.

The stroke's two endpoint vertices SHALL be read as ONE corresponding pair, not as the
extent of the fill: from that pair both rims SHALL be walked outward and each paired step
SHALL emit one quad, so the corridor between the two rims fills beyond the stroke's own
footprint. The walk direction along each rim SHALL be chosen so the emitted quads do not
fold, and the walk SHALL stop where the rims stop facing each other — at the end of a
rim, where the two rims diverge, where the corridor is already covered by a face, or at a
bounded maximum — rather than wrapping around the cage.

Bridge quads SHALL reuse the existing rim vertices: no vertex SHALL be added on either
rim, and no rim vertex SHALL move. Across the gap the bridge SHALL be subdivided into as
many rows as the gap is wide in mean rim cells, so its quads stay approximately
cage-sized; vertices created for those interior rows SHALL be snapped onto the Target.

The whole bridge SHALL be exactly one undoable journal entry. When no bridge can be
built the stroke SHALL leave the document unchanged and report that it did nothing,
rather than falling back to another action.

#### Scenario: Stroke across a gap fills the corridor between two rims
- **WHEN** the user draws a near-straight stroke from a rim vertex, over bare Target, to a vertex on the rim facing it
- **THEN** quads SHALL be created bridging the two rims
- **AND** the fill SHALL extend along both rims past the stroke's own endpoints, for as far as the two rims face each other

#### Scenario: Rim vertices are reused, never duplicated or moved
- **WHEN** a rim bridge is created
- **THEN** every quad corner on either rim SHALL be an existing rim vertex
- **AND** no rim vertex SHALL change position

#### Scenario: A wide gap is subdivided into cage-sized rows
- **WHEN** the gap the stroke crosses is several rim cells wide
- **THEN** the bridge SHALL be subdivided into that many rows of quads
- **AND** the vertices created for the interior rows SHALL lie on the Target surface

#### Scenario: One undo removes the whole bridge
- **WHEN** a rim bridge of many quads is created and the user undoes once
- **THEN** the document SHALL be restored to its exact pre-stroke state

#### Scenario: Nothing to bridge changes nothing
- **WHEN** a near-straight stroke over empty surface ends on a vertex that is not on an open rim, or on rims that do not face each other
- **THEN** no geometry SHALL be created and the document SHALL be unchanged

### Requirement: Loop insert requires faces under the stroke

A line SHALL resolve to insert-loop only when the line actually passes over existing
faces. A line that crosses ring edges solely by clipping them at its endpoints — the
signature of a stroke drawn across a GAP between two rims — SHALL NOT offer insert-loop.

Rationale: edge crossing alone cannot tell a loop cut from a gap crossing, because a
stroke that starts and ends on rim vertices necessarily crosses those vertices' rim
edges. On device this inserted a loop into a ring the user's stroke never ran along.

#### Scenario: A line across a group of faces still inserts a loop
- **WHEN** a straight line is drawn across a ring of quads
- **THEN** it SHALL resolve to insert-loop, as before

#### Scenario: A line across a gap does not insert a loop
- **WHEN** a straight line is drawn between two rim vertices and passes over no face
- **THEN** insert-loop SHALL NOT be offered for it

## MODIFIED Requirements

### Requirement: Open strokes between two vertices create welded faces

The recognizer SHALL create a welded face from an open Pencil stroke whose start and
end lie near existing EditMesh vertices, snapping those endpoints to the vertices and
choosing the face type by the stroke's dominant bend. A sharp (~right-angle) bend
SHALL create a QUAD that completes the traced corner into a four-sided ring; a gentle
bend SHALL create a TRIANGLE from the two endpoints and the bend. The created face SHALL
share the endpoint vertices rather than duplicating them.

A near-straight stroke traces no face and SHALL NOT create one. It is instead read by
what lies under it: over faces it is the loop-cut gesture, and between two vertices that
both sit on an open rim with no face under the stroke it is the rim bridge (see "A stroke
across a gap bridges the two facing rims with quads"). A near-straight stroke that is
neither — no rim under an endpoint, or no gap to cross — SHALL create nothing.

#### Scenario: L-shaped stroke between two vertices makes a quad
- **WHEN** an open stroke with a sharp ~90° bend starts and ends near two existing vertices
- **THEN** a quad SHALL be created whose ring welds the two endpoint vertices and completes the traced corner

#### Scenario: Gently bent stroke between two vertices makes a triangle
- **WHEN** an open stroke with a shallow bend starts and ends near two existing vertices
- **THEN** a triangle SHALL be created from the two endpoint vertices and the bend point

#### Scenario: A straight stroke makes no single face
- **WHEN** an open stroke between two vertices is nearly straight
- **THEN** no quad or triangle SHALL be created from it

#### Scenario: A straight stroke across a gap bridges instead
- **WHEN** a near-straight stroke between two vertices crosses a gap between two open rims
- **THEN** it SHALL resolve to the rim bridge rather than to no action

#### Scenario: Endpoints are shared, not duplicated
- **WHEN** a face is created from an open stroke anchored to two vertices
- **THEN** the created face SHALL reference those existing vertices, adding no coincident duplicates
