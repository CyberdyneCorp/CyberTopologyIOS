# Delta: retopology-tools

## ADDED Requirements

### Requirement: Created faces weld onto existing topology

A face created by a Pencil gesture SHALL reuse existing topology its corners
land on: a corner within a scale-free radius of an existing vertex SHALL
reuse that vertex, and a corner landing on an existing edge SHALL share that
edge rather than duplicating it.

Welding SHALL happen inside the creating stroke's single journal entry, so
one undo removes the face and its welds together.

Rationale: retopology is built face by face against a reference surface, and
a face that does not connect to its neighbour is not topology — it is a
disconnected shell that will not relax, will not loop, and will not export as
one mesh. The Build Quad TOOL already merges new vertices onto nearby
existing ones on release; the gesture path SHALL use the same semantics.

#### Scenario: Drawing a quad against an existing quad
- **GIVEN** one existing quad (4 vertices, 4 edges, 1 face)
- **WHEN** a quad is drawn adjacent to it, sharing one edge
- **THEN** the mesh SHALL contain 6 vertices, 7 edges and 2 faces
- **AND** the shared edge SHALL be interior, not two coincident boundary
  edges

#### Scenario: Drawing a quad away from existing topology
- **WHEN** a quad is drawn with no existing vertex or edge near its corners
- **THEN** it SHALL create four new vertices and remain a separate island
