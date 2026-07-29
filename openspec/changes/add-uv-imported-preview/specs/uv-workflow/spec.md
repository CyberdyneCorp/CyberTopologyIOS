# uv-workflow — Delta Spec (add-uv-imported-preview)

## ADDED Requirements

### Requirement: A single UV vertex can be moved in the 2D view
The 2D UV view SHALL offer a per-vertex mode in which dragging moves one UV vertex rather than a whole island.

A UV vertex SHALL mean every corner sharing that UV position within a tolerance, so moving it does not
tear an island at a point the artist did not cut. Corners separated by a seam carry different UVs and
SHALL therefore move independently.

Matching SHALL be evaluated against the positions as they were before the move, so that moving one
corner cannot drag another into range.

A drag matching no vertex SHALL journal nothing and SHALL NOT be reported as a failure. A drag with no
movement SHALL journal nothing. A successful move SHALL be a single undoable step.

Per-vertex mode SHALL be a distinct, visible mode rather than a region of the island, and the mode in
force SHALL be fixed when the drag begins.

#### Scenario: Coincident corners move together
- **WHEN** a UV vertex shared by several corners of an island is dragged
- **THEN** every one of those corners SHALL move by the same amount, exactly once

#### Scenario: A seam is not crossed
- **WHEN** a UV vertex adjacent to a seam is dragged
- **THEN** corners on the other side of the seam SHALL NOT move

#### Scenario: A missed drag is silent
- **WHEN** a per-vertex drag begins where there is no UV vertex
- **THEN** nothing SHALL be journaled and no failure SHALL be reported

### Requirement: An imported image can be previewed on the 3D surface
The UV stage SHALL be able to preview an imported image on the 3D surface, sampled through the mesh's UVs, as an alternative to the procedural checker.

The image SHALL REPLACE the checker rather than being combined with it, so that dark artwork is not
confused with a dark checker square.

Sampling SHALL account for image space being top-down while UV space is bottom-up, so an imported
image is not shown inverted. Addressing SHALL repeat, so islands placed outside the unit square for
UDIM tile assignment sample the image rather than a smeared edge.

Requesting the image preview when none is loaded SHALL fall back to the checker rather than rendering
a blank surface. A failed load SHALL clear any previously loaded image.

A preview image SHALL NOT be part of the document and SHALL NOT be journaled.

#### Scenario: The image is visible on the model
- **WHEN** an image is loaded and the image preview is enabled
- **THEN** the rendered surface SHALL show the image rather than the checker

#### Scenario: No image means the checker
- **WHEN** the image preview is enabled with no image loaded
- **THEN** the checker SHALL be rendered

#### Scenario: A failed load leaves no stale image
- **WHEN** loading an unreadable file is attempted after a successful load
- **THEN** no preview image SHALL remain loaded

#### Scenario: A preview image is not a document edit
- **WHEN** a preview image is loaded
- **THEN** the undo stack SHALL be unchanged

### Requirement: Seams can be authored in the 2D UV editor
Seams SHALL be creatable and deletable in the 2D UV view as well as on the 3D model, completing the requirement that they be drawn "on the 3D model or in the 2D UV editor".

A pick in the 2D view SHALL resolve to a mesh EDGE, measured to the nearest ring SEGMENT rather than
the nearest corner: a seam is an edge, and picking a corner would need an arbitrary rule for which of
its incident edges was meant.

Distance SHALL be measured to the segment, not to the line through it, so a pick beyond an edge's end
does not select that edge from a distance.

A 2D seam edit SHALL produce the same journaled document change as the 3D seam tool, including sewing
a seam when toggled again, so a seam authored in either place is indistinguishable from the other.

A pick that resolves to no edge SHALL change nothing, and SHALL NOT fall through to another edit.

#### Scenario: Authoring a seam in 2D
- **WHEN** the user picks an edge in the 2D UV view in seam mode
- **THEN** that mesh edge SHALL become a seam as one undoable step

#### Scenario: Toggling sews it back
- **WHEN** the same edge is picked again
- **THEN** the seam SHALL be removed

#### Scenario: A pick far from any edge does nothing
- **WHEN** the user picks in the middle of an island in seam mode
- **THEN** no seam SHALL change and no island transform SHALL begin
