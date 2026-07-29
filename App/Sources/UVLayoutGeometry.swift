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
        /// A representative FACE id per ring, parallel to `rings`.
        ///
        /// Carried so a 2D gesture can name the island it hit without the panel reproducing the
        /// engine's island partition — the same reason the flip and retile readbacks return face
        /// ids rather than island indices.
        var faceIDs: [UInt32] = []
        /// Mesh EDGE ids per ring, parallel to `rings`. `edgeIDs[r][i]` is the edge between
        /// `rings[r][i]` and `rings[r][i+1]` (wrapping), or `nil` where no live edge was found.
        ///
        /// Carried so a 2D tap can author a SEAM — the spec allows seams to be drawn "on the 3D
        /// model or in the 2D UV editor", and the 2D half needs an edge id, which a UV position
        /// alone cannot supply.
        var edgeIDs: [[UInt32?]] = []
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
        /// The ring segment nearest `uv`, as (ring, segment), within `maxDistance` in UV units.
        ///
        /// Nearest SEGMENT rather than nearest corner: a seam is an edge, and picking the closest
        /// corner would need an arbitrary rule for which of its incident edges was meant — the same
        /// reasoning that made the 3D seam tool edge-based rather than vertex-based.
        func nearestSegment(
            to uv: SIMD2<Float>, maxDistance: Float
        ) -> (ring: Int, segment: Int)? {
            var best: (ring: Int, segment: Int)?
            var bestDistance = maxDistance
            for (r, ring) in rings.enumerated() where ring.count >= 2 {
                for i in ring.indices {
                    let a = ring[i]
                    let b = ring[(i + 1) % ring.count]
                    let distance = Self.distance(from: uv, toSegment: (a, b))
                    if distance < bestDistance {
                        bestDistance = distance
                        best = (r, i)
                    }
                }
            }
            return best
        }

        /// The mesh edge for a picked segment, when one is known.
        func edgeID(ring: Int, segment: Int) -> UInt32? {
            guard ring < edgeIDs.count, segment < edgeIDs[ring].count else { return nil }
            return edgeIDs[ring][segment]
        }

        /// Point-to-segment distance, clamped to the segment (not the infinite line).
        static func distance(
            from point: SIMD2<Float>, toSegment segment: (SIMD2<Float>, SIMD2<Float>)
        ) -> Float {
            let (a, b) = segment
            let ab = b - a
            let lengthSquared = simd_dot(ab, ab)
            guard lengthSquared > 0 else { return simd_distance(point, a) }
            // Clamped, so a tap beyond an edge's end measures to its ENDPOINT rather than to a
            // point on the extended line where no edge exists.
            let t = min(max(simd_dot(point - a, ab) / lengthSquared, 0), 1)
            return simd_distance(point, a + ab * t)
        }

        /// The ring whose polygon contains `uv`, or the nearest by centre when none does.
        ///
        /// Nearest-by-centre fallback rather than nil: a drag that starts a hair outside a thin
        /// island should grab it, not silently do nothing. Returns nil only when there are no
        /// rings at all.
        func ringIndex(at uv: SIMD2<Float>) -> Int? {
            guard !rings.isEmpty else { return nil }
            for (index, ring) in rings.enumerated() where Self.contains(ring, uv) {
                return index
            }
            var best = 0
            var bestDistance = Float.greatestFiniteMagnitude
            for (index, ring) in rings.enumerated() {
                let centre = Self.bounds(ring)
                let mid = (centre.min + centre.max) * 0.5
                let distance = simd_distance(mid, uv)
                if distance < bestDistance {
                    bestDistance = distance
                    best = index
                }
            }
            return best
        }

        /// Axis-aligned bounds of one ring, in UV space.
        static func bounds(_ ring: [SIMD2<Float>]) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
            var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var hi = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for uv in ring {
                lo = simd_min(lo, uv)
                hi = simd_max(hi, uv)
            }
            return (lo, hi)
        }

        /// Even-odd point-in-polygon.
        static func contains(_ ring: [SIMD2<Float>], _ point: SIMD2<Float>) -> Bool {
            guard ring.count >= 3 else { return false }
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i]
                let b = ring[j]
                if (a.y > point.y) != (b.y > point.y) {
                    let t = (point.y - a.y) / (b.y - a.y)
                    if point.x < a.x + t * (b.x - a.x) { inside.toggle() }
                }
                j = i
            }
            return inside
        }

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

    /// Order-independent key for an undirected vertex pair.
    static func edgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        let low = UInt64(min(a, b))
        let high = UInt64(max(a, b))
        return low << 32 | high
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
        var faces_: [UInt32] = []
        var edgeIDs_: [[UInt32?]] = []
        rings.reserveCapacity(faces.count)
        faces_.reserveCapacity(faces.count)
        edgeIDs_.reserveCapacity(faces.count)
        // Vertex-pair -> edge id, built once. O(edges) at cage scale, and it needs no engine
        // addition: `edgeEndpoints` already reports endpoint VERTEX ids.
        var edgeLookup: [UInt64: UInt32] = [:]
        for edge in 0..<UInt32(mesh.edgeCount) {
            guard let (a, b) = mesh.edgeEndpoints(of: edge) else { continue }
            edgeLookup[Self.edgeKey(a, b)] = edge
        }
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
            faces_.append(face)
            // Edge ids for this ring's segments, from the face's AUTHORED vertex order — which is
            // parallel to the ring corners by the same fan contract the ring walk relies on.
            let faceVerts = mesh.faceVertices(face)
            var ringEdges: [UInt32?] = []
            if faceVerts.count == ring.count {
                for i in faceVerts.indices {
                    let a = faceVerts[i]
                    let b = faceVerts[(i + 1) % faceVerts.count]
                    ringEdges.append(edgeLookup[Self.edgeKey(a, b)])
                }
            } else {
                // Valence mismatch: no edge is claimed rather than guessing one, so a 2D seam tap
                // on such a face does nothing instead of cutting an unrelated edge.
                ringEdges = Array(repeating: nil, count: ring.count)
            }
            edgeIDs_.append(ringEdges)
        }
        guard !rings.isEmpty else {
            return .unreadable(reason: "no drawable faces")
        }
        // Only pair distortion with rings when the counts agree. A silent mismatch would
        // colour face N with face M's measurement — visually plausible and completely wrong,
        // which is the same failure mode the corner-stream check above guards against.
        let paired = measured.count == rings.count ? measured : []
        return .laidOut(
            Layout(
                rings: rings, overflowCorners: overflow, faceIDs: faces_, edgeIDs: edgeIDs_,
                distortion: paired
            )
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
