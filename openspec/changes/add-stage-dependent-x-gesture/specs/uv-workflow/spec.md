# uv-workflow — Delta Spec (add-stage-dependent-x-gesture)

## ADDED Requirements

### Requirement: An X gesture re-unwraps one island
In the UV stage, an X gesture over a region SHALL re-unwrap the island containing that region as a single undoable step. Islands SHALL be re-unwrappable at any time.

Re-unwrapping SHALL change only the island's internal parameterization. The island SHALL stay
within its previous footprint in the atlas, and the UVs of every other island SHALL be
unchanged, so a localized gesture cannot rearrange a layout the artist has already arranged.

The fit SHALL be UNIFORM. Stretching the new parameterization to exactly fill the previous
bounding box would scale u and v by different factors, which is a shear that destroys the
conformality the unwrap just solved for — the fit must not undo the thing being computed.

#### Scenario: Re-unwrapping one island leaves the others alone
- **WHEN** a multi-island layout exists and the user draws an X over one island
- **THEN** that island's UVs SHALL be recomputed and every other island's UVs SHALL be unchanged

#### Scenario: A re-unwrapped island keeps its place
- **WHEN** an island is re-unwrapped
- **THEN** it SHALL stay within its previous UV footprint, centred on the same point, and SHALL NOT be non-uniformly scaled to fill it

#### Scenario: Repeating the gesture is stable
- **WHEN** the same island is re-unwrapped twice in succession
- **THEN** the second unwrap SHALL not move the island

#### Scenario: An X on a never-unwrapped mesh unwraps the whole mesh
- **WHEN** an X is drawn over a region of a mesh that has never been unwrapped
- **THEN** the whole mesh SHALL be unwrapped, and no island SHALL be left with UVs collapsed at the origin

#### Scenario: Re-unwrapping never leaves an island collapsed at the origin
- **WHEN** any X-gesture unwrap completes
- **THEN** every island SHALL have a non-degenerate UV footprint
