# uv-workflow — Delta Spec (add-uv-island-editing)

## ADDED Requirements

### Requirement: Islands are editable in the 2D UV view by a positional grammar
In the 2D UV view, dragging on an island SHALL transform it, with the transform chosen by where the drag STARTS: the upper third of the island rotates it, the lower third scales it, and the middle moves it.

The zone SHALL be determined at the start of the drag and SHALL NOT change while the drag
continues, so a rotation cannot become a scale as the finger crosses a boundary.

A drag SHALL commit on release as a SINGLE undoable step, and a drag that resolves to no change
SHALL journal nothing.

A drag beginning too close to the island's centre to define an angle or a ratio SHALL produce no
transform, rather than an arbitrarily large one.

Scaling SHALL be derived from the ratio of distances to the island's centre, so the same drag
means the same multiplication regardless of island size, and SHALL be bounded so a single input
sample cannot collapse or explode an island.

#### Scenario: The grammar's three zones
- **WHEN** a drag starts in the upper third, the middle third, or the lower third of an island
- **THEN** it SHALL rotate, move, or scale that island respectively

#### Scenario: One gesture is one undo step
- **WHEN** the user drags an island and releases
- **THEN** exactly one undoable step SHALL be journaled

#### Scenario: An abandoned drag leaves no trace
- **WHEN** a drag returns to where it began before release
- **THEN** nothing SHALL be journaled

#### Scenario: A drag on the island centre does not lurch
- **WHEN** a rotate or scale drag begins at the island's centre
- **THEN** no transform SHALL be produced

### Requirement: Island UV operations preserve intent
The system SHALL provide, per island: transform (move, rotate, uniform scale), grid straightening onto an axis-aligned UV grid, partial symmetrization about a UV axis, cloning onto an island with matching topology, and stitching islands along chosen edges.

A transform SHALL refuse a non-positive scale. Mirroring an island is a separate operation, and
allowing a negative scale would let a transform silently produce a mirrored shell, which bakes
inverted detail.

Cloning SHALL refuse an island onto itself rather than reporting success for a no-op.

Stitching SHALL validate every edge before changing anything, so a rejected edge leaves the mesh
unstitched rather than partially stitched, and SHALL update the authored seam set so a later
unwrap does not re-cut what was just merged.

Every one of these SHALL refuse, with a stated reason, when the mesh has no UV layout yet.

#### Scenario: A transform will not mirror an island
- **WHEN** an island transform is requested with a zero or negative scale
- **THEN** it SHALL be refused and no UV SHALL change

#### Scenario: Cloning onto the same island is refused
- **WHEN** a clone names one island as both source and destination
- **THEN** it SHALL be refused and no UV SHALL change

#### Scenario: Stitching is all or nothing
- **WHEN** a stitch names one valid and one invalid edge
- **THEN** no edge SHALL be sewn

#### Scenario: Editing before unwrapping is refused clearly
- **WHEN** any island operation is requested on a mesh that has never been unwrapped
- **THEN** it SHALL be refused and the system SHALL state that an unwrap is needed first
