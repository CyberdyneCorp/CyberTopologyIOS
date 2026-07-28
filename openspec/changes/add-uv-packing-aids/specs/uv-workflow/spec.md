# uv-workflow — Delta Spec (add-uv-packing-aids)

## MODIFIED Requirements

### Requirement: Interactive island packing
The system SHALL pack UV islands into a target region without overlaps, with configurable margin, at interactive speed — fast enough to sit inside an edit loop rather than being a batch step.

The requirement is on the OUTCOME, not the mechanism. It previously named Metal-compute
acceleration; measurement showed the CPU packer meets the bar with room to spare once its inner
sliding-window maximum is computed properly (200 islands in 1.45 ms, and 0.014 ms for the shelf
strategy an interactive repack uses), so no GPU path is required to satisfy it. A future
implementation MAY use compute acceleration if a workload is found that needs it; nothing in
this requirement depends on it.

Packing SHALL preserve each island's internal UVs, applying only a uniform scale and a
translation per island, so packing never changes how a shell is parameterized.

The system SHALL also provide manual packing aids: packing into a chosen sub-region, resolving
overlapping islands by distributing them, and revealing mirrored islands with a one-gesture
flip.

#### Scenario: One-tap pack
- **WHEN** the user invokes auto-pack on a layout of 200 islands
- **THEN** all islands SHALL be packed without overlaps within the target region at interactive speed, preserving each island's internal UVs

#### Scenario: Packing into a sub-region
- **WHEN** the user packs into a region smaller than the unit square
- **THEN** every island SHALL lie inside that region

#### Scenario: Distributing overlapping islands
- **WHEN** islands overlap and the user asks for them to be distributed
- **THEN** no two islands' bounding boxes SHALL overlap afterwards, and each island's size and orientation SHALL be preserved

#### Scenario: A mirrored island is revealed and fixable
- **WHEN** a layout contains an island whose UV winding is mirrored
- **THEN** the system SHALL indicate which islands are mirrored, and a single gesture SHALL flip one back

#### Scenario: Flipping twice restores the original
- **WHEN** an island is flipped and then flipped again
- **THEN** its UVs SHALL match their original values
