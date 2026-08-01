# Delta: retopology-tools (add-patch-selection-scope)

## ADDED Requirements

### Requirement: A double-tap selects the quad patch under the pencil

The system SHALL select the grid patch containing the face under the pencil when the pencil is
double-tapped and no region tool is armed, SHALL draw the selected faces distinctly, and SHALL
treat the patch as the faces reachable from that face without crossing a separatrix, a mesh
boundary, or a non-quad face.

A separatrix is an edge loop traced from an irregular (non-valence-4) vertex.

Rationale: this is the retopology notion of a quad patch and the one that matches what the
artist sees — a rectangular region of regular grid, bounded where the topology actually
changes. A connected island would be the entire cage after an auto-retopo; a crease angle has
nothing to stop at on an organic model.

#### Scenario: Selecting a patch
- **WHEN** the pencil is double-tapped over a face of a regular grid
- **THEN** the grid block containing it SHALL be selected and drawn

#### Scenario: The fill stops at a singularity
- **WHEN** a patch is bounded by separatrices from irregular vertices
- **THEN** faces beyond those separatrices SHALL NOT be selected

#### Scenario: A non-quad face
- **WHEN** the double-tapped face is not a quad
- **THEN** only that face SHALL be selected

#### Scenario: Adding and removing
- **WHEN** a second patch is double-tapped
- **THEN** it SHALL join the selection, and double-tapping a face already selected SHALL
  remove its patch

#### Scenario: A region tool owns the gesture
- **WHEN** a region tool is armed and the pencil is double-tapped
- **THEN** that tool's own switch SHALL happen and no patch SHALL be selected

### Requirement: Batch commands run on the selection when there is one

A batch command that can scope SHALL act only on the selected faces when a selection exists,
and on the whole EditMesh when none does. Those commands are Snap All to Target, Relax All,
Triangulate, and Clear Pins / Loop Tags / Frozen / Seams.

Rationale: the commands are useful and blunt — snapping the whole cage to re-fit one ear also
re-snaps a flank the artist hand-placed. Falling back to the whole cage when nothing is
selected keeps the existing behaviour reachable with no mode and no extra control.

#### Scenario: A scoped command
- **WHEN** a selection exists and Relax All runs
- **THEN** only the selected faces' vertices SHALL move

#### Scenario: No selection
- **WHEN** no selection exists and a batch command runs
- **THEN** it SHALL act on the whole EditMesh

#### Scenario: The border holds
- **WHEN** a scoped Snap All or Relax All runs
- **THEN** vertices outside the selection SHALL NOT move

### Requirement: Subdivide and Halve stay whole-cage and say so

Subdivide, Subdivide + Reproject, and Halve SHALL act on the whole EditMesh even when a
selection exists, and SHALL report that they did.

Rationale: a scoped subdivide splits the edges the patch shares with its neighbours, so those
neighbours become 5-gons or fans — a border of non-quads in a quad cage, which Halve and the
solver both refuse to work with. A halve dissolves every other edge loop, and a loop does not
stop at a patch boundary: dissolving one partway leaves a hanging half-loop. Saying so beats
silently ignoring the selection.

#### Scenario: Subdivide with a selection
- **WHEN** a selection exists and Subdivide runs
- **THEN** the whole cage SHALL be subdivided and the system SHALL report that the selection
  did not apply

### Requirement: The selection does not outlive the ids it names

The selection SHALL be dropped whenever the EditMesh's topology changes.

Rationale: face ids are renumbered by the payload compaction every topology-changing command
goes through, so a surviving selection would silently name different faces — the same trap
that once made region solves act on arbitrary geometry.

#### Scenario: After a topology change
- **WHEN** a command changes the cage's topology
- **THEN** the selection SHALL be empty
