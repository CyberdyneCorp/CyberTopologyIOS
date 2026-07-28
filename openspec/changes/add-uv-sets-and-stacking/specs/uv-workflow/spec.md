# uv-workflow — Delta Spec (add-uv-sets-and-stacking)

## ADDED Requirements

### Requirement: UDIM tiles are derived from UV space, not stored
The system SHALL report which UDIM tiles a layout occupies, using standard numbering (1001 + u + 10·v), and SHALL allow an island to be moved to a chosen tile.

A tile assignment SHALL NOT be persisted separately from the UVs. A tile IS a region of UV space,
so the assignment is derivable; a stored copy could disagree with the geometry, and the
disagreement would surface only at export.

Moving an island to a tile SHALL translate it by a whole number of tiles, preserving its position
within the tile and its size.

The system SHALL identify islands whose UVs span more than one tile, because such an island is
split across texture files on export.

#### Scenario: The default layout occupies one tile
- **WHEN** a mesh is unwrapped with the automatic atlas
- **THEN** the occupied-tile list SHALL be exactly tile 1001 and no island SHALL straddle a border

#### Scenario: Retiling preserves the island
- **WHEN** an island is moved to another UDIM tile
- **THEN** it SHALL be translated by a whole number of tiles, and its size and position within the tile SHALL be unchanged

#### Scenario: A straddling island is reported
- **WHEN** an island's UVs span two tiles
- **THEN** the system SHALL report it as straddling

#### Scenario: An island flush to the tile edge is not straddling
- **WHEN** an island's UV maximum lies exactly on a tile border
- **THEN** it SHALL NOT be reported as straddling

#### Scenario: No layout means no tiles
- **WHEN** the tile list is requested for a mesh that has never been unwrapped
- **THEN** it SHALL be empty rather than reporting a tile or failing

### Requirement: Mirrored islands can share UV space
For a symmetric mesh, the system SHALL offer stacking mirrored island pairs onto identical UV space, halving their texel cost, as an alternative to keeping them unique.

Pairs SHALL be identified by GEOMETRY — reflecting one island onto another across the symmetry
plane — and corner correspondence SHALL be established by reflected position. Neither SHALL depend
on island, face or corner ORDER, which would map the wrong corners and produce a shell whose
bounding box is correct and whose parameterization is scrambled.

The symmetry plane SHALL come from the document's own symmetry state. The system SHALL refuse to
stack when no mirror axis is enabled, rather than assuming an axis.

A mesh with no matching pairs SHALL be left unchanged, and the system SHALL report that nothing
was stacked rather than pairing unrelated islands.

#### Scenario: Stack mirrored islands
- **WHEN** the user enables mirrored-island stacking on a symmetric mesh
- **THEN** each left/right island pair SHALL occupy identical UV space, with every corner carrying the UV of its mirrored counterpart

#### Scenario: The primary island does not move
- **WHEN** a mirror pair is stacked
- **THEN** the primary island's UVs SHALL be unchanged and only the mirror island SHALL be moved onto it

#### Scenario: Stacking requires an enabled mirror axis
- **WHEN** stacking is requested with no mirror symmetry enabled
- **THEN** the system SHALL refuse and state that a mirror plane is needed

#### Scenario: A non-symmetric mesh is left alone
- **WHEN** stacking is requested for a mesh with no mirrored island pairs
- **THEN** no UV SHALL change and the system SHALL report that nothing was stacked
