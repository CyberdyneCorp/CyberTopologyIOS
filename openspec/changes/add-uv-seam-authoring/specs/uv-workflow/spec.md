# uv-workflow — Delta Spec (add-uv-seam-authoring)

## ADDED Requirements

### Requirement: Seams are authorable and persist
An artist SHALL be able to mark edges of the EditMesh as UV seams, and SHALL be able to sew a seam back by marking it again. Seams SHALL persist with the document and SHALL survive id compaction.

Every seam change SHALL be journaled so a single undo restores the previous seam set.

#### Scenario: Drawing a seam and sewing it back
- **WHEN** an edge is marked as a seam and then marked again
- **THEN** it SHALL no longer be a seam

#### Scenario: Seams survive a save and reload
- **WHEN** seams are authored, the document is saved and reopened
- **THEN** the same edges SHALL still be seams

#### Scenario: A seam change is one undo step
- **WHEN** seams are marked along a stroke and the user undoes once
- **THEN** the seam set SHALL be exactly what it was before the stroke

### Requirement: An unwrap honours authored seams
When the EditMesh carries authored seams, an unwrap SHALL cut along them instead of generating its own seams, so the layout an artist gets is the one their seams describe.

Authored seams SHALL REPLACE the automatic ones rather than being added to them: cutting
where the artist did not ask is a worse failure than a distorted layout, which the
distortion report already surfaces. With no authored seams the unwrap SHALL behave exactly as
before.

#### Scenario: A seam ringing a region gives it its own island
- **WHEN** a closed loop of seams is authored around a region and the mesh is unwrapped
- **THEN** that region SHALL form its own chart

#### Scenario: No authored seams is unchanged behaviour
- **WHEN** a mesh with no authored seams is unwrapped
- **THEN** the result SHALL match an unwrap from before seams were authorable

#### Scenario: Authored seams are not supplemented
- **WHEN** a mesh with authored seams is unwrapped
- **THEN** the chart count SHALL follow from those seams rather than from automatic seaming
