# Delta: pencil-interaction (add-context-aware-move)

## ADDED Requirements

### Requirement: Move's scope is what the drag starts on

A Move drag SHALL determine its scope from the element under its FIRST sample, and SHALL keep
that scope for the whole drag:

- starting on a **vertex** SHALL move that vertex ALONE;
- starting on an **edge** SHALL move that edge's whole loop;
- starting elsewhere on a **face** SHALL drag with geodesic surface falloff, as before.

The scope SHALL NOT be re-evaluated during the drag, so a gesture cannot change meaning under
the finger.

Rationale: the element under the finger already states the artist's intent and its precision.
One behavior for all three targets means the most precise intent — one vertex — is the one
Move cannot express.

#### Scenario: A drag from a vertex moves only that vertex
- **WHEN** the user begins a Move drag on a vertex
- **THEN** only that vertex SHALL be displaced
- **AND** its neighbours SHALL keep their positions

#### Scenario: A drag from an edge moves the loop
- **WHEN** the user begins a Move drag on an edge
- **THEN** every vertex of that edge's loop SHALL be displaced

#### Scenario: A drag from a face keeps the falloff
- **WHEN** the user begins a Move drag on a face, away from its vertices and edges
- **THEN** the drag SHALL displace the region with geodesic falloff as it did before this
  change

#### Scenario: The scope survives the drag
- **WHEN** a Move drag begins on a vertex and later passes over an edge
- **THEN** it SHALL still be moving only the vertex it started on

### Requirement: An edge loop moves rigidly

A loop-scope drag SHALL apply the SAME displacement to every vertex of the loop, and each moved
vertex SHALL be re-snapped to the Target surface.

Where the loop cannot be walked end to end — a pole, a boundary, or a neighbourhood that is not
quad-regular — the drag SHALL move the picked edge's own vertices rather than doing nothing.

Rationale: a loop is a structural line in the cage, and its value is its shape. A falloff that
bends the loop from the grab point is a sculpting gesture; retopology wants the loop moved and
still a loop. And a drag that visibly grabbed an edge must move something.

#### Scenario: The loop keeps its shape
- **WHEN** the user drags an edge loop
- **THEN** the distance between each pair of adjacent loop vertices SHALL be preserved, up to
  the re-snap onto the Target

#### Scenario: The loop follows the surface
- **WHEN** a loop is dragged across a curved Target
- **THEN** every moved loop vertex SHALL lie on the Target surface

#### Scenario: An unwalkable loop degrades to its edge
- **WHEN** a Move drag begins on an edge whose loop cannot be walked
- **THEN** the two vertices of that edge SHALL be displaced
- **AND** the drag SHALL NOT be inert

### Requirement: Only vertex and surface scopes merge on release

The merge-on-release behavior SHALL apply to the seed of a vertex-scope and a surface-scope
drag. A loop-scope drag SHALL NOT merge any of its vertices, however close they are released to
others.

Rationale: merging is a single-target decision the artist can see before releasing. A loop
release would decide it for every vertex of the loop at once, from a gesture that shows only
where the loop landed.

#### Scenario: A dragged vertex still merges
- **WHEN** the user releases a vertex-scope Move within merge range of another vertex
- **THEN** the two SHALL merge, in the drag's single journal entry

#### Scenario: A dragged loop never merges
- **WHEN** the user releases a loop-scope Move with its vertices inside merge range of others
- **THEN** no vertices SHALL be merged
- **AND** the loop SHALL keep its vertex count

### Requirement: Move's pick windows follow the cage, not the scene

The windows deciding whether a touch is on a vertex or on an edge SHALL be measured from the
LOCAL cage spacing — the edges meeting the candidate — not from the size of the scene. Each
SHALL be strictly less than half a cell, so vertex and edge scope cannot both claim one touch.

Where the local cell cannot be measured — an isolated vertex, or edges of zero length — the
touch SHALL resolve to vertex scope rather than to no scope at all.

A scene-derived FLOOR under these windows is explicitly NOT the answer for that case: a floor
wins on any cage smaller than the scene, which is every cage, and so reinstates the very
scene-relative behavior this requirement removes (the same trap already documented on the
merge window).

Rationale: the same gesture must pick the same thing on a coarse cage and a fine one. A
scene-relative window is a different multiple of a cell on every cage — on a fine cage it spans
several cells, and "on this vertex" stops being a statement the system can make.

#### Scenario: The same gesture on cages of different density
- **WHEN** the same touch offset from a vertex is made on a coarse cage and on a fine one
- **THEN** the resolved scope SHALL be the same for both

#### Scenario: Vertex and edge windows do not overlap
- **WHEN** a touch lands between a vertex and the midpoint of one of its edges
- **THEN** at most one of vertex scope and edge scope SHALL claim it

#### Scenario: A cell that cannot be measured
- **WHEN** a Move drag begins near a vertex whose local cell cannot be measured
- **THEN** the drag SHALL move that vertex alone

### Requirement: The viewport names the scope before the drag commits

While a Move drag is live, the system SHALL state which scope it picked up — vertex, loop, or
surface — in the viewport, and SHALL clear that statement when the drag ends.

Rationale: the scope is decided by something as small as a fraction of a cell. If it is only
knowable from the result, a mis-pick is discovered after the mesh has already changed, and the
gesture is not learnable.

#### Scenario: The scope is stated during the drag
- **WHEN** a Move drag is live
- **THEN** the viewport SHALL name its scope

#### Scenario: The statement clears
- **WHEN** the drag ends
- **THEN** the scope statement SHALL be cleared
