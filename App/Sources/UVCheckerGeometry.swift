import CyberKit
import Foundation
import simd

/// Corner-expanded geometry for the UV checker preview (openspec add-uv-texture-preview, 6.3c;
/// spec: uv-workflow / "live heatmap overlays ... checker and imported-texture preview").
///
/// Pure, so the buffer building is testable without a GPU — the same discipline the 2D panel's
/// geometry follows.
///
/// **Why corners rather than vertices.** UVs are a per-CORNER attribute, because a seam gives one
/// vertex several different UVs. So a vertex-indexed stream cannot carry them: it would have to pick
/// one UV per vertex and would weld every seam shut, which is exactly the trap
/// `cyber_mesh_uvs_ptr` was designed per-corner to avoid. The preview therefore expands to a
/// non-indexed triangle list — three unique vertices per triangle — and pays a little memory to
/// keep the seams the artist authored.
enum UVCheckerGeometry {

    /// Interleaved vertex for the checker pipeline: position, normal, uv.
    ///
    /// Interleaved rather than three parallel buffers because every attribute here is per-corner
    /// and expanded together, so there is nothing to gain from separating them and one stride to
    /// get wrong if they drift.
    struct Vertex: Equatable {
        var position: SIMD3<Float>
        var normal: SIMD3<Float>
        var uv: SIMD2<Float>
    }

    /// Builds the corner-expanded triangle list.
    ///
    /// `uvs` is parallel to the TRIANGLE INDEX stream (one entry per emitted corner), which is the
    /// contract `cyber_mesh_uvs_ptr` documents. Returns nil — rather than a partial mesh — when the
    /// streams disagree, because a preview built from mismatched streams would texture the model
    /// with plausible-looking nonsense.
    static func build(
        positions: [Float], normals: [Float], triangleIndices: [UInt32], uvs: [SIMD2<Float>]
    ) -> [Vertex]? {
        guard !triangleIndices.isEmpty, triangleIndices.count % 3 == 0 else { return nil }
        // One UV per emitted corner. A mismatch means the UV stream was built for a different
        // topology than the index stream, so nothing here can be trusted.
        guard uvs.count == triangleIndices.count else { return nil }
        guard positions.count % 3 == 0 else { return nil }
        let vertexCount = positions.count / 3
        // Normals are optional in principle but the checker needs them for shading; a stream of the
        // wrong length is a mismatch rather than something to pad.
        guard normals.count == positions.count else { return nil }

        var out: [Vertex] = []
        out.reserveCapacity(triangleIndices.count)
        for (corner, index) in triangleIndices.enumerated() {
            let vertex = Int(index)
            // Bounds-checked: an out-of-range index would otherwise read past the buffer, and the
            // engine's streams are only as trustworthy as the cache they came from.
            guard vertex >= 0, vertex < vertexCount else { return nil }
            let base = vertex * 3
            out.append(
                Vertex(
                    position: SIMD3(positions[base], positions[base + 1], positions[base + 2]),
                    normal: SIMD3(normals[base], normals[base + 1], normals[base + 2]),
                    uv: uvs[corner]
                )
            )
        }
        return out
    }

    /// Builds directly from a mesh, or nil when it has no UV layout.
    ///
    /// nil for "never unwrapped" keeps absence distinguishable from an empty preview, exactly as
    /// `uvCoordinates()` returns nil rather than `[]`.
    static func build(from mesh: Mesh) -> [Vertex]? {
        guard let uvs = mesh.uvCoordinates() else { return nil }
        return mesh.withRenderBuffers { buffers in
            build(
                positions: Array(buffers.positions),
                normals: Array(buffers.normals),
                triangleIndices: Array(buffers.triangleIndices),
                uvs: uvs
            )
        }
    }
}
