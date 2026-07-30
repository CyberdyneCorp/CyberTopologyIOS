# Delta: pencil-interaction (fix-quad-rim-sharing)

## ADDED Requirements

### Requirement: A created face shares the rim it was drawn along

A created face SHALL share every existing rim vertex that lies along the side it was drawn
against, not only the vertices its corners snapped to.

When a side of a created quad runs ALONG an existing boundary chain — the chain's vertices lie
on that side and cover most of its length — the chain SHALL be continued across the drawn
region instead of one face being created over it: one welded quad per chain cell, at the
chain's own cell size. A side spanning less than about one and a half chain cells is a
one-cell append and SHALL stay a single face, as before.

Vertices created by that continuation SHALL weld onto coincident existing vertices, so a patch
whose far side lands on a second rim meets that rim rather than duplicating it.

Rationale: a quad SIDE is one edge however many cells it spans, so welding only the corners
leaves every rim vertex the side passes T-junctioned against it. That is a crack — geometry no
solver, unwrap or bake can read — and it is what the artist sees as "the quads are not sharing
the same edge". The trigger is geometric rather than corner-based because a stroke read as an
L has two ring corners in mid-air (the bend, and the inferred fourth corner) and its two
existing vertices sit diagonally opposite, so a corner-based test can never see the rim the
stroke actually followed.

#### Scenario: A quad drawn along a subdivided rim shares every vertex of it
- **WHEN** the user draws a face whose side runs along an existing rim of two or more cells
- **THEN** the created geometry SHALL share every rim vertex along that side
- **AND** no rim vertex along it SHALL be left T-junctioned against a longer new edge

#### Scenario: A one-cell append is still a single face
- **WHEN** a drawn face's side spans about one cell of the neighbouring rim
- **THEN** exactly one welded face SHALL be created, as before

#### Scenario: A patch that reaches a second rim closes onto it
- **WHEN** a continued patch's far side lands on another existing rim
- **THEN** its vertices there SHALL weld onto that rim's vertices rather than duplicate them

### Requirement: A rounded bend counts as one corner

Corner detection SHALL treat a single rounded bend as ONE corner. Two detected corners SHALL
be read as two distinct bends only when they are separated both along the stroke and in space;
otherwise the stroke SHALL be read as single-bend.

Rationale: the corner scan suppresses one window after a detected corner, and a hand-drawn
rounded turn is still turning after that skip, so it reports the same bend twice — measured on
device at 4 samples and 0.08 of the chord apart. Trusted as a U's two bends, that builds a
ring with two nearly coincident corners: a face stretched across everything between the
stroke's endpoints.

#### Scenario: An L with a rounded bend is read as one bend
- **WHEN** an open stroke has a single rounded bend
- **THEN** it SHALL be read by its dominant bend, not as a two-bend U

#### Scenario: A genuine U is still read as two bends
- **WHEN** an open stroke has two bends separated along the stroke and in space
- **THEN** its four quad corners SHALL be its endpoints plus its two bends, as before
