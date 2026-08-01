# Delta: retopology-tools (add-island-scoped-halve)

## ADDED Requirements

### Requirement: Halve acts on a selected island

Halve SHALL act only on the selected faces when those faces are a self-contained island, SHALL
leave the rest of the cage untouched, and SHALL run on the whole cage otherwise — reporting
which it did. A selection SHALL count as an island only when no face outside it shares a
VERTEX with it.

An island SHALL still satisfy every rule Halve enforces, and SHALL refuse for its own reasons
without changing the cage.

Rationale: Halve is whole-cage because an edge loop does not stop at a patch boundary, so
dissolving one partway leaves a hanging half-loop. Nothing outside an island is attached to it,
so no loop can leave, and halving it is as well-defined as halving a cage containing only that
island. Vertices rather than edges decide, because two patches meeting at one corner share no
edge, and splicing one back would duplicate that corner and tear them apart.

#### Scenario: One patch of two
- **WHEN** one patch of a two-patch cage is selected and Halve runs
- **THEN** that patch SHALL be halved and the other SHALL be untouched

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
- **THEN** Halve SHALL be marked as whole-cage only when that selection would not scope it
