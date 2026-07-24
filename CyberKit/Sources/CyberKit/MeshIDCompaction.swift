import Foundation

// Element-id compaction across the document payload round trip.
//
// **The problem this file exists for.** The document payload is the
// engine's OBJ writer round-tripped through a scratch file (see
// `MeshPayload`), and `exportObj` writes only LIVE elements, "remapped to a
// compact 1-based index space". So a payload round trip RENUMBERS: every
// element after a retired one shifts down. Every journaled command
// re-serializes the live mesh, and the viewport reloads the live handle
// from those bytes (`MetalViewport.syncOverlay`), so a single deleted
// vertex silently renumbers the whole mesh.
//
// `MeshAnnotations` (pins, loop tags, hidden faces) are keyed on stable
// element ids. Without reconciliation a delete anywhere in the cage
// re-points every pin at a DIFFERENT vertex: Relax/Move then refuse to
// move geometry the user never froze and smooth away the geometry they
// did — silently, with no error and nothing on screen to explain it.
//
// **What this file does.** It computes the exact map the OBJ writer will
// apply and carries the annotations across it. The map is derived from the
// same rule the exporter uses (live elements, in id order, renumbered from
// zero) — it is NOT a positional heuristic, so it cannot re-attach a pin to
// a coincident neighbour the way the "clear, never remap" note on
// `AnnotationIDPolicy` warns about. That warning applies to the batch
// commands' full REBUILD (`Mesh::linearSubdivide` invents ids from
// scratch); compaction is a permutation and is exactly recoverable.
//
// **Honest scope (see tasks.md 4.5b).** The round trip renumbers THREE id
// spaces, and this file describes each as exactly as the capi allows:
//
//   * VERTICES — liveness is queryable (`cyber_mesh_vertex_position`
//     rejects dead ids), so pins remap exactly.
//   * FACES — `cyber_mesh_live_faces` enumerates the live face ids in id
//     order, which is precisely the order the OBJ writer emits them in, so
//     hidden faces remap exactly too.
//   * EDGES — the OBJ format stores no edges at all; the loader REBUILDS
//     every edge id from face-construction order. Nothing in the capi
//     hands back that ordering, so loop tags cannot be mapped and are
//     CLEARED whenever the round trip is not the identity on both of the
//     spaces above (a retired vertex or face reshuffles the face stream the
//     edges are rebuilt from). That is the documented conservative
//     convention — a wrong tag is worse than no tag — and this is the
//     single place it happens.
//
// **The identity case has a boundary, and callers own it.** "No vertex hole
// and no face hole" means the round trip is a no-op on the two spaces this
// file can map — and, for an op that only MOVED vertices, on the rebuilt
// edge ids too, since the face stream is untouched. It does NOT cover an op
// that reshuffles the face stream without retiring anything: triangulate
// splits faces in place and appends the extra triangles, so it retires
// nothing (identity here) while renumbering every rebuilt edge. The edge
// answer for those ops comes from `AnnotationIDPolicy` (`.pinsOnly`), which
// is applied BEFORE this compaction in `MeshEditTransaction.command`.
//
// The vertex scan alone is NOT a sufficient identity test, which is the
// bug this shape exists to prevent: dissolving an interior edge or deleting
// a face retires a face (and an edge) while every vertex stays used by a
// neighbour. A vertex-only scan calls that the identity, the annotations
// pass through untouched, and on reload the hidden set names two faces the
// user never hid.

/// What `Mesh.payloadData()` will do to this mesh's stable element ids.
public struct PayloadIDCompaction: Equatable, Sendable {
    /// True when the round trip is a no-op on EVERY id space: vertices and
    /// faces have no holes, so the rebuilt edge ids match as well and every
    /// annotation survives untouched.
    public let isIdentity: Bool
    /// Exact old→new vertex id map. Empty when `isIdentity`, and also empty
    /// when the map could not be determined — in which case every
    /// annotation keyed on a vertex is dropped (fail safe, never fail
    /// silent).
    public let vertices: [UInt32: UInt32]
    /// Exact old→new face id map, with the same empty-means-drop contract.
    public let faces: [UInt32: UInt32]
    /// Exact old→new EDGE id map (task 4.5b). The payload stores no edges, so
    /// the loader rebuilds every edge id from face-construction order; this
    /// map replays that numbering, so loop tags survive a non-identity round
    /// trip instead of being cleared. Same empty-means-drop contract: a tag on
    /// an edge missing from the map (retired, or beyond the liveness scan) is
    /// dropped rather than reattached to the wrong edge.
    public let edges: [UInt32: UInt32]

    public static let identity = PayloadIDCompaction(
        isIdentity: true, vertices: [:], faces: [:], edges: [:]
    )
    /// Ids move in a way this layer cannot describe: drop everything.
    public static let indeterminate = PayloadIDCompaction(
        isIdentity: false, vertices: [:], faces: [:], edges: [:]
    )

    public init(
        isIdentity: Bool, vertices: [UInt32: UInt32], faces: [UInt32: UInt32] = [:],
        edges: [UInt32: UInt32] = [:]
    ) {
        self.isIdentity = isIdentity
        self.vertices = vertices
        self.faces = faces
        self.edges = edges
    }
}

extension Mesh {
    /// Safety bound on the id-liveness scan, on top of the live count: a
    /// mesh whose dead slots outnumber this is treated as indeterminate
    /// rather than scanned without limit.
    private static let compactionProbeHeadroom = 4096

    /// The id compaction `payloadData()` will apply to this mesh.
    ///
    /// Cheap on the common path: a mesh with no dead slots (which is every
    /// mesh freshly loaded from a payload) returns `.identity` after one
    /// linear liveness scan and no allocation of a map.
    public func payloadIDCompaction() -> PayloadIDCompaction {
        let liveVertices = vertexCount
        guard liveVertices > 0 else { return .identity }
        var vertexMap: [UInt32: UInt32] = [:]
        vertexMap.reserveCapacity(liveVertices)
        var next = 0
        var id: UInt32 = 0
        var sawVertexHole = false
        let limit = liveVertices + Self.compactionProbeHeadroom
        while next < liveVertices, Int(id) < limit {
            if vertexPosition(id) != nil {
                if Int(id) != next { sawVertexHole = true }
                vertexMap[id] = UInt32(next)
                next += 1
            } else {
                sawVertexHole = true
            }
            id += 1
        }
        // Did not find every live vertex inside the probe window: the mesh
        // is more fragmented than this scan can describe.
        guard next == liveVertices else { return .indeterminate }

        // FACES: `liveFaceIDs()` is already "live faces, in id order" —
        // exactly the sequence the OBJ writer emits — so its index IS the
        // new id. No probe window is needed and no fragmentation can hide
        // from it.
        let live = liveFaceIDs()
        guard live.count == faceCount else { return .indeterminate }
        var faceMap: [UInt32: UInt32] = [:]
        faceMap.reserveCapacity(live.count)
        var sawFaceHole = false
        for (index, face) in live.enumerated() {
            if Int(face) != index { sawFaceHole = true }
            faceMap[face] = UInt32(index)
        }

        guard sawVertexHole || sawFaceHole else { return .identity }

        // EDGES (task 4.5b): the OBJ writer stores no edges, so the loader
        // rebuilds every edge id by walking the face stream in emission order
        // and assigning a new id the first time each undirected vertex pair
        // appears. Replay that here in NEW (compacted) vertex ids to get the
        // rebuilt id for every pair, then map each OLD engine edge id through
        // its endpoints. This is what lets loop tags survive the round trip.
        let edgeMap = rebuiltEdgeMap(liveFaces: live, vertexMap: vertexMap)

        return PayloadIDCompaction(
            isIdentity: false, vertices: vertexMap, faces: faceMap, edges: edgeMap
        )
    }

    /// old→new edge id map for a non-identity compaction. The new id of an
    /// undirected vertex pair is the order it is first seen while walking
    /// `liveFaces` (emission order) over each face's `faceVertices` ring — the
    /// exact numbering the OBJ loader produces. Every live OLD edge is then
    /// mapped by looking up its endpoints (compacted) in that table; an edge
    /// not reached (fragmented past the scan window) is simply absent, so its
    /// tag drops rather than reattaching wrongly.
    private func rebuiltEdgeMap(
        liveFaces: [UInt32], vertexMap: [UInt32: UInt32]
    ) -> [UInt32: UInt32] {
        var newIDByPair: [UInt64: UInt32] = [:]
        var nextEdge: UInt32 = 0
        for face in liveFaces {
            let ring = faceVertices(face)
            guard ring.count >= 2 else { continue }
            for i in ring.indices {
                guard let a = vertexMap[ring[i]],
                    let b = vertexMap[ring[(i + 1) % ring.count]]
                else { continue }
                let key = Self.undirectedEdgeKey(a, b)
                if newIDByPair[key] == nil {
                    newIDByPair[key] = nextEdge
                    nextEdge += 1
                }
            }
        }
        let liveEdges = edgeCount
        guard liveEdges > 0 else { return [:] }
        var edgeMap: [UInt32: UInt32] = [:]
        edgeMap.reserveCapacity(liveEdges)
        var found = 0
        var id: UInt32 = 0
        let limit = liveEdges + Self.compactionProbeHeadroom
        while found < liveEdges, Int(id) < limit {
            if let ends = edgeEndpoints(of: id) {
                found += 1
                if let a = vertexMap[ends.0], let b = vertexMap[ends.1],
                    let newID = newIDByPair[Self.undirectedEdgeKey(a, b)] {
                    edgeMap[id] = newID
                }
            }
            id += 1
        }
        return edgeMap
    }

    /// Order-independent key for an undirected edge between two vertex ids.
    private static func undirectedEdgeKey(_ a: UInt32, _ b: UInt32) -> UInt64 {
        let lo = min(a, b), hi = max(a, b)
        return UInt64(lo) << 32 | UInt64(hi)
    }
}

extension MeshAnnotations {
    /// These annotations carried across a payload round trip.
    ///
    /// * identity compaction — returned unchanged.
    /// * otherwise — pins are remapped through the exact vertex map, hidden
    ///   faces through the exact face map, and LOOP TAGS through the exact
    ///   edge map the compaction rebuilt from face-construction order (task
    ///   4.5b). Entries on retired elements are dropped, which is correct: the
    ///   vertex the user froze / the face they hid / the edge they tagged no
    ///   longer exists. A tag's colour, riding in the parallel
    ///   `tagColorIndices`, drops with it.
    ///
    /// Returns nil when nothing survives, so callers can journal "no
    /// annotations" rather than an empty record.
    public func reconciled(through compaction: PayloadIDCompaction) -> MeshAnnotations? {
        guard !compaction.isIdentity else { return self }
        let pins = pinnedVertices.compactMap { compaction.vertices[$0] }
        let hidden = hiddenFaces.compactMap { compaction.faces[$0] }
        var tags: [UInt32] = []
        var colors: [UInt8] = []
        for (edge, color) in zip(taggedEdges, tagColorIndices) {
            guard let mapped = compaction.edges[edge] else { continue }
            tags.append(mapped)
            colors.append(color)
        }
        guard !pins.isEmpty || !hidden.isEmpty || !tags.isEmpty else { return nil }
        return MeshAnnotations(
            taggedEdges: tags, tagColorIndices: colors,
            hiddenFaces: hidden, pinnedVertices: pins
        )
    }
}
