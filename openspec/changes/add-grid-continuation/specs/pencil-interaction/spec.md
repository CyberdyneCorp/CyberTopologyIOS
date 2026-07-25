# pencil-interaction — Delta Spec (add-grid-continuation)

## MODIFIED Requirements

### Requirement: Open strokes between two vertices create welded faces
The recognizer SHALL create a welded face from an open Pencil stroke whose start and
end lie near existing EditMesh vertices, snapping those endpoints to the vertices and
choosing the face type by the stroke's dominant bend. A sharp (~right-angle) bend
SHALL create a QUAD that completes the traced corner into a four-sided ring; a gentle
bend SHALL create a TRIANGLE from the two endpoints and the bend; a near-straight
stroke SHALL NOT create a face. The created face SHALL share the endpoint vertices
rather than duplicating them.

When a created QUAD is drawn against an existing SUBDIVIDED boundary — a shared side
that snaps onto a boundary chain of two or more cells — the create SHALL continue that
boundary's edge loops instead of dropping a single oversized quad: the shared chain
SHALL be extruded across the drawn region as welded rows that share the boundary
vertices, one welded column per neighbour cell of drawn depth, sized to the neighbour's
cells. A quad with no such neighbour — a standalone quad, or a one-cell append whose
shared side spans only about a single neighbour cell — SHALL remain a single welded
face, and a triangle SHALL never be continued.

#### Scenario: L-shaped stroke between two vertices makes a quad
- **WHEN** an open stroke with a sharp ~90° bend starts and ends near two existing vertices
- **THEN** a quad SHALL be created whose ring welds the two endpoint vertices and completes the traced corner

#### Scenario: Gently bent stroke between two vertices makes a triangle
- **WHEN** an open stroke with a shallow bend starts and ends near two existing vertices
- **THEN** a triangle SHALL be created from the two endpoint vertices and the bend point

#### Scenario: A straight stroke makes no face
- **WHEN** an open stroke between two vertices is nearly straight
- **THEN** no quad or triangle SHALL be created from it

#### Scenario: Endpoints are shared, not duplicated
- **WHEN** a face is created from an open stroke anchored to two vertices
- **THEN** the created face SHALL reference those existing vertices, adding no coincident duplicates

#### Scenario: A quad drawn against a subdivided boundary continues its loops
- **WHEN** a quad is drawn whose side snaps onto an existing boundary chain of two or more cells
- **THEN** the region SHALL fill with welded rows that continue the neighbour's edge loops, sharing the boundary vertices rather than duplicating them, and the row count SHALL match the neighbour's

#### Scenario: A one-cell append stays a single quad
- **WHEN** a quad is drawn against a single boundary edge (a shared side spanning about one neighbour cell)
- **THEN** a single welded quad SHALL be created, not a subdivided patch

#### Scenario: A standalone quad stays a single quad
- **WHEN** a quad is drawn with no adjacent subdivided boundary
- **THEN** a single face SHALL be created
