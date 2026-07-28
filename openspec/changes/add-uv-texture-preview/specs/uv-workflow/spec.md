# uv-workflow — Delta Spec (add-uv-texture-preview)

## ADDED Requirements

### Requirement: A checker preview shows the layout on the 3D model
The UV stage SHALL be able to draw a checker pattern on the 3D surface, sampled from the mesh's active UV set, so a layout can be judged on the model rather than only in the 2D view.

The pattern SHALL be derived from per-CORNER UVs, so that seams are preserved: a per-vertex
approximation would assign one UV per vertex and close every seam the artist authored.

The preview SHALL be drawn only in the UV stage, and SHALL NOT be drawn for a mesh with no UV layout.

Geometry SHALL NOT be built at all when the UV and topology streams disagree, rather than producing a
partial or misaligned preview.

The preview SHALL be opaque surface shading, and the wireframe and annotation overlays SHALL remain
visible on top of it.

#### Scenario: The checker appears on an unwrapped cage
- **WHEN** the checker preview is enabled on an unwrapped EditMesh in the UV stage
- **THEN** the rendered image SHALL change, and the pattern SHALL vary with the checker density

#### Scenario: Seams keep their own UVs
- **WHEN** two triangles share a vertex across a seam, with different UVs at that vertex
- **THEN** each SHALL be textured with its own UV rather than a single shared value

#### Scenario: No layout means no preview
- **WHEN** the preview is requested for a mesh that has never been unwrapped
- **THEN** nothing SHALL be drawn

#### Scenario: Mismatched streams draw nothing
- **WHEN** the UV stream does not correspond to the topology stream
- **THEN** no preview geometry SHALL be built
