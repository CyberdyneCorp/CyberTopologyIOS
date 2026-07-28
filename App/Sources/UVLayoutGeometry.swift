import CyberKit
import Foundation
import simd

/// UV layout geometry for the 2D view (openspec add-uv-stage-foundation, 6.1 task 3.2).
///
/// Pure: no SwiftUI, no Metal, no engine mutation. Reconstructs AUTHORED face rings in UV
/// space from the engine's per-corner stream so the 2D view draws a quad as four edges,
/// matching the convention the 3D wireframe is careful about — a fan diagonal is an artifact
/// of triangulation, not something the artist made.
///
/// The reconstruction is derived from the documented fan contract rather than inferred:
/// `fanTriangulate` emits `(v0, v[k-1], v[k])` for k in 2..<n with the UV emission in
/// lockstep, so a face's ring is corners [0], [1], [2] of its first triangle plus corner [2]
/// of each later one. The rejected alternative — testing vertex pairs against the mesh-wide
/// `edgeIndices()` set — answers "is this pair an edge SOMEWHERE", not "an edge of THIS
/// face", so a diagonal coinciding with a real edge elsewhere would be drawn. A proof beats
/// a heuristic with a known false-positive mode. `MeshUVTests` asserts the walk directly.
enum UVLayoutGeometry {

    /// One reconstructed layout: authored face rings in UV space.
    struct Layout: Equatable {
        /// Face rings, each a closed polygon of UV coordinates in authored order.
        var rings: [[SIMD2<Float>]]
        /// Corners falling outside the unit square. Reported rather than clamped, because
        /// an overflowing layout is a real defect the artist needs to see.
        var overflowCorners: Int
        /// Per-face distortion, parallel to `rings`, or empty when the engine reported none.
        /// Parallel rather than a dictionary because both come from the same live-face walk,
        /// and an index is impossible to desynchronise where a key lookup could silently miss.
        var distortion: [Mesh.FaceDistortion]

        var ringCount: Int { rings.count }
        var cornerCount: Int { rings.reduce(0) { $0 + $1.count } }
        /// Faces whose UV winding is reversed — a defect, counted so the panel can name it.
        var flippedFaces: Int { distortion.filter(\.flipped).count }
        /// Worst per-face angle error, or nil when distortion was unavailable.
        var worstAngle: Float? { distortion.map(\.angle).max() }

        /// The MEDIAN texel density, used as the reference a density heatmap shades against.
        /// Median rather than mean because one collapsed face at density 0, or one enormous
        /// chart, would drag a mean far enough to wash out every other face.
        func referenceDensity(textureSize: Int) -> Float {
            let values = distortion.map { $0.texelDensity(textureSize: textureSize) }
                .filter { $0 > 0 }
                .sorted()
            guard !values.isEmpty else { return 0 }
            return values[values.count / 2]
        }
    }

    /// What a heatmap shades by.
    enum HeatmapMode: String, CaseIterable, Equatable {
        case angle = "Angle"
        case texelDensity = "Density"
    }

    /// What the 2D view should show. Four distinct states, because collapsing any two of
    /// them would make the view lie about what it is looking at.
    enum State: Equatable {
        /// No EditMesh in the document at all — nothing to unwrap yet.
        case noEditMesh
        /// An EditMesh exists but has never been unwrapped. Carries the face count so the
        /// empty state can say what WOULD be unwrapped rather than just "nothing here".
        case notUnwrapped(faceCount: Int)
        /// UVs exist but the corner stream and the face valences disagree, so the rings
        /// cannot be trusted. Surfaced rather than drawn: a sheared layout looks plausible
        /// and would be believed.
        case unreadable(reason: String)
        case laidOut(Layout)
    }

    /// Reconstructs the layout state of `mesh`.
    ///
    /// Deliberately takes the mesh the UNWRAP targets — the document's EditMesh — not
    /// whatever the viewport happens to be rendering. `MetalViewport.renderableObject`
    /// returns the TARGET when one exists, and reading UVs from a multi-million-triangle
    /// Target would copy the whole corner stream on the main thread while also describing
    /// an object the Unwrap button does not touch.
    static func state(of mesh: Mesh) -> State {
        guard let uvs = mesh.uvCoordinates() else {
            return .notUnwrapped(faceCount: mesh.faceCount)
        }

        let faces = mesh.liveFaceIDs()
        // Validate BEFORE slicing. The engine carries UVs per face only when that face's
        // corner count matches, so a mismatch is possible and would shear every ring by
        // one corner — plausible-looking and wrong.
        let expected = faces.reduce(0) { total, face in
            total + max(0, (mesh.faceVertices(face).count - 2) * 3)
        }
        guard expected == uvs.count else {
            return .unreadable(
                reason: "UV stream is \(uvs.count) corners; the topology implies \(expected)"
            )
        }

        // nil when there is no layout, which cannot happen here (UVs were just read), but
        // empty is also tolerated: the panel degrades to strokes rather than refusing.
        let measured = mesh.uvDistortion() ?? []
        var rings: [[SIMD2<Float>]] = []
        rings.reserveCapacity(faces.count)
        var overflow = 0
        var cursor = 0
        for face in faces {
            let valence = mesh.faceVertices(face).count
            guard valence >= 3 else { continue }
            let triangles = valence - 2
            var ring: [SIMD2<Float>] = [uvs[cursor], uvs[cursor + 1], uvs[cursor + 2]]
            for triangle in 1..<max(triangles, 1) {
                ring.append(uvs[cursor + triangle * 3 + 2])
            }
            cursor += triangles * 3
            for uv in ring where uv.x < 0 || uv.x > 1 || uv.y < 0 || uv.y > 1 {
                overflow += 1
            }
            rings.append(ring)
        }
        guard !rings.isEmpty else {
            return .unreadable(reason: "no drawable faces")
        }
        // Only pair distortion with rings when the counts agree. A silent mismatch would
        // colour face N with face M's measurement — visually plausible and completely wrong,
        // which is the same failure mode the corner-stream check above guards against.
        let paired = measured.count == rings.count ? measured : []
        return .laidOut(
            Layout(rings: rings, overflowCorners: overflow, distortion: paired)
        )
    }

    /// The layout state of a document's EDIT MESH, or `.noEditMesh`.
    ///
    /// Reads from the document payload rather than the renderer's live handle: a fresh mesh
    /// has no hidden-face filtering applied, so its corner stream aligns with `liveFaceIDs()`
    /// exactly. The live handle has hidden faces pushed into its render filters, which would
    /// silently skew the ring walk.
    static func state(inDocument bundle: DocumentBundle) -> State {
        guard let object = bundle.manifest.objects.first(where: { $0.role == .editMesh }),
            let mesh = try? bundle.mesh(for: object)
        else { return .noEditMesh }
        return state(of: mesh)
    }
}
