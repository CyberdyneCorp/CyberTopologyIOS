# Tasks: add-uv-imported-preview (6.3d)

## 1. Engine — per-vertex UV move
- [x] 1.1 `moveIslandUvVertex`: move every corner within tolerance of a UV position.
- [x] 1.2 Compare against ORIGINAL positions so a move cannot cascade.
- [x] 1.3 Return the moved count; zero for a miss is not an error.
- [x] 1.4 Refuse a negative tolerance and a mesh with no layout.
- [x] 1.5 C API + patch (0021).
- [x] 1.6 Tests: coincident corners move together; a different island is untouched; a wide
      tolerance moves every corner exactly ONCE.

## 2. CyberKit + app
- [x] 2.1 `Mesh.moveUVVertex(inIslandContaining:at:by:)`.
- [x] 2.2 `runMoveUVVertex` as one journaled step; silent on a miss.
- [x] 2.3 Distinguish "ran and matched nothing" from "refused before running".
- [x] 2.4 Tests, including that a zero delta is not an edit.

## 3. 2D per-vertex mode
- [x] 3.1 `EditTarget` mode, captured at drag start.
- [x] 3.2 Segmented control in the panel.
- [x] 3.3 Route the drag by target.

## 4. Imported image
- [x] 4.1 Texture binding, sampler (repeat, mipmapped), 1×1 placeholder for one pipeline.
- [x] 4.2 Shader samples the image INSTEAD of the checker, with v flipped.
- [x] 4.3 `MTKTextureLoader` load; a failure clears rather than keeping a stale image.
- [x] 4.4 Texture mode with no image falls back to the checker.
- [x] 4.5 Import intent + panel toggle, journaling nothing.
- [x] 4.6 Tests with a REAL generated PNG, mutation-verified against never-sampling and against
      dropping the fallback.

## 5. 2D seam authoring (6.2's remaining half)
- [x] 5.1 Carry the mesh EDGE id per ring segment, from the face's authored vertex order.
- [x] 5.2 Build a vertex-pair -> edge map in Swift; no engine addition needed, since
      `edgeEndpoints` already reports endpoint vertex ids.
- [x] 5.3 Claim NO edge for a valence-mismatched face rather than guessing one.
- [x] 5.4 Nearest-SEGMENT picking, clamped to the segment rather than its infinite line.
- [x] 5.5 A third edit target; resolves on the first sample and consumes the drag, so a miss cannot
      fall through into an island transform.
- [x] 5.6 Route to the SAME `togglingSeams` edit the 3D tool uses.
- [x] 5.7 Tests, including that toggling twice sews back.

## 6. Close out
- [x] 6.1 validate; engine, simulator, device.
- [x] 6.2 Master 6.3d AND 6.2 entries.
