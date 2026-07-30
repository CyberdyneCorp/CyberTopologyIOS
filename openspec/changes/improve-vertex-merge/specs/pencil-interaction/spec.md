# Delta: pencil-interaction (improve-vertex-merge)

## ADDED Requirements

### Requirement: Dragging a vertex onto another merges them

A drag that releases a vertex within merge range of another vertex SHALL merge the two, for
BOTH the Tweak and the Move verb, as part of the same journal entry as the drag.

Only the vertex under the finger — the drag's seed — SHALL merge. Vertices carried by a
falloff region SHALL NOT merge, however close they come, so a moved region keeps its
structure.

Merge range SHALL be measured from the grabbed vertex's OWN CELL — the spacing of the edges
meeting it — not from the size of the scene, so the same gesture behaves the same on a coarse
cage and a fine one. It SHALL have a floor, so a degenerate cell cannot make merging
impossible.

While a drag holds a merge, the system SHALL name that outcome before the release, not only
highlight the target.

Rationale: welding a vertex's POSITION onto another without merging leaves two coincident
vertices — a crack that looks merged until a solver, unwrap or bake reads it. And a
scene-relative window is a different multiple of a cell on every cage, so it is either
unreachably tight or dangerously loose depending on what is being edited.

#### Scenario: Move merges the vertex it is released on
- **WHEN** the user drags a vertex with Move and releases it within merge range of another
- **THEN** the two SHALL become one vertex
- **AND** the merge SHALL be part of the drag's single journal entry

#### Scenario: Tweak merges as before
- **WHEN** the user drags a vertex with Tweak and releases it within merge range of another
- **THEN** the two SHALL become one vertex

#### Scenario: The falloff never merges
- **WHEN** a Move drag's falloff carries other vertices near existing ones
- **THEN** only the seed SHALL merge

#### Scenario: The window follows the cage, not the scene
- **WHEN** the same cage is edited in a large scene and in a small one
- **THEN** the merge range SHALL be the same fraction of the local cell in both

#### Scenario: The merge is named before release
- **WHEN** a drag holds a vertex within merge range
- **THEN** the viewport SHALL state that releasing will merge
- **AND** that statement SHALL clear when the drag leaves range
