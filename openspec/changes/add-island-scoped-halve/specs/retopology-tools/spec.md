# Delta: retopology-tools (add-island-scoped-halve)

## ADDED Requirements

### Requirement: The whole-cage commands act on a selected island

Halve, Subdivide and Subdivide + Reproject SHALL act only on the selected faces when those
faces are a self-contained island, SHALL leave the rest of the cage untouched, and SHALL run
on the whole cage otherwise — reporting which it did. A selection SHALL count as an island
only when no face outside it shares a VERTEX with it.

An island SHALL still satisfy every rule the command enforces, and SHALL refuse for its own
reasons without changing the cage.

Rationale: Halve is whole-cage because an edge loop does not stop at a patch boundary, so
dissolving one partway leaves a hanging half-loop; Subdivide is whole-cage because subdividing
a patch splits the edges it SHARES with its neighbours, leaving them n-gons. Neither applies to
an island: nothing outside it is attached, so no loop can leave and there is no shared edge to
split. Vertices rather than edges decide, because two patches meeting at one corner share no
edge, and splicing one back would duplicate that corner and tear them apart.

#### Scenario: One patch of two
- **WHEN** one patch of a two-patch cage is selected and Halve runs
- **THEN** that patch SHALL be halved and the other SHALL be untouched

#### Scenario: Subdividing one patch of two
- **WHEN** one patch of a two-patch cage is selected and Subdivide runs
- **THEN** only that patch SHALL gain density

#### Scenario: An attached selection
- **WHEN** the selection is attached to the rest of the cage and Halve runs
- **THEN** it SHALL run on the whole cage and SHALL report that it did

#### Scenario: A corner touch is not an island
- **WHEN** the selection shares only a single vertex with a face outside it
- **THEN** it SHALL NOT count as an island

#### Scenario: An island that cannot be halved
- **WHEN** the selected island has an odd number of quads across in both directions
- **THEN** Halve SHALL refuse and the cage SHALL be unchanged

#### Scenario: The panel says which it will do
- **WHEN** a selection exists
- **THEN** a command SHALL be marked as whole-cage only when that selection would not scope it
