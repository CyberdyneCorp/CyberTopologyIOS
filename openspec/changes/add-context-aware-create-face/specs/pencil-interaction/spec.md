# pencil-interaction — Delta Spec (add-context-aware-create-face)

Adds context-aware face creation from open strokes and a no-overlap rule.

## ADDED Requirements

### Requirement: Open strokes between two vertices create welded faces
When an open Pencil stroke begins and ends near existing EditMesh vertices, the
recognizer SHALL snap those endpoints to the vertices and create a face welded to
them, choosing the face type by the stroke's dominant bend: a sharp (~right-angle)
bend SHALL create a QUAD that completes the traced corner into a four-sided ring, and
a gentle bend SHALL create a TRIANGLE from the two endpoints and the bend. A
near-straight stroke SHALL NOT create a face. The created face SHALL share the
endpoint vertices rather than duplicating them.

#### Scenario: L-shaped stroke between two vertices makes a quad
- **WHEN** an open stroke with a sharp ~90° bend starts and ends near two existing vertices
- **THEN** a quad SHALL be created whose ring welds the two endpoint vertices and completes the traced corner

#### Scenario: Gently bent stroke between two vertices makes a triangle
- **WHEN** an open stroke with a shallow bend starts and ends near two existing vertices
- **THEN** a triangle SHALL be created from the two endpoint vertices and the bend point

#### Scenario: A straight stroke makes no face
- **WHEN** an open stroke between two vertices is nearly straight
- **THEN** no quad or triangle SHALL be created from it

#### Scenario: Endpoints are shared, not duplicated
- **WHEN** a face is created from an open stroke anchored to two vertices
- **THEN** the created face SHALL reference those existing vertices, adding no coincident duplicates

### Requirement: A new face is never stacked on an existing face
Creating a face SHALL NOT produce a face that duplicates an existing one: a build
whose resolved vertex set already bounds a live face SHALL be rejected, and the
recognizer SHALL NOT offer a create action whose interior already contains a face.

#### Scenario: Duplicate face is refused
- **WHEN** a create gesture resolves to the exact vertex set of an existing face
- **THEN** no second face SHALL be created and the document SHALL be unchanged

#### Scenario: Create over an existing face is not offered
- **WHEN** a create stroke's interior lies over an existing face
- **THEN** the recognizer SHALL NOT offer a quad/triangle create for it
