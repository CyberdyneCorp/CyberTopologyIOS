# Delta: retopology-tools (fix-halve-one-direction)

## MODIFIED Requirements

### Requirement: Halve reduces the cage's quad density

Halve SHALL dissolve every other edge loop in each grid direction that has an EVEN number of
quads across, SHALL leave a direction with an odd number untouched, and SHALL refuse only when
neither direction can be halved. It SHALL report when only one direction was halved.

Halve SHALL require an all-quad cage and SHALL require the cage to be a rectangular grid — one
whose two spans multiply to its face count. The silhouette SHALL NOT move: every vertex of the
result SHALL be one that already existed.

Rationale: a direction with an odd number of quads across cannot be halved, because its last
"every other" loop is the far boundary and dissolving it would move the silhouette. But
refusing the WHOLE operation for that leaves the artist with nothing on a cage where half the
work is available — reported from device on a 5 x 6 patch. The rectangle rule replaces a guard
that was working only by accident: an L-shaped cage passed the regularity check, because its
extra faces meet at boundary vertices which are regular at valence 3, and was refused only
because one of its spans happened to be odd.

#### Scenario: One direction odd
- **WHEN** Halve runs on a cage that is even in one direction and odd in the other
- **THEN** the even direction SHALL be halved, the odd one SHALL be untouched, and the result
  SHALL say that only one direction was halved

#### Scenario: Both directions even
- **WHEN** Halve runs on a cage even in both directions
- **THEN** both SHALL be halved

#### Scenario: Both directions odd
- **WHEN** Halve runs on a cage odd in both directions
- **THEN** it SHALL refuse and the cage SHALL be unchanged

#### Scenario: Not a rectangle
- **WHEN** Halve runs on a cage whose spans do not multiply to its face count
- **THEN** it SHALL refuse as irregular and the cage SHALL be unchanged

#### Scenario: The silhouette holds
- **WHEN** a cage is halved
- **THEN** every vertex of the result SHALL be one that already existed
