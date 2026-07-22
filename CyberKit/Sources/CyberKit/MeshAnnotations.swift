import CyberRemesherC
import Foundation

/// Per-object annotation state of the gesture grammar's non-topological
/// verbs (task 3.4; spec: pencil-interaction / "Contextual gesture
/// grammar"): loop tags ("line along a loop → tag it") and partial
/// visibility ("lasso → hide portion", "line down/up → invert/show all").
///
/// Annotations are DOCUMENT state (CozyBlanket persists loop tags and
/// occlusion settings in the document): they live on the manifest object
/// and change only through journaled `DocumentCommand.annotationEdit`
/// commands, so undo/redo restore them exactly.
///
/// Element ids are the engine's stable ids for the object's CURRENT
/// payload (payload deserialization assigns ids deterministically). A
/// later topology edit can retire an id; stale ids are skipped when the
/// annotations are pushed to the render state, never crash.
public struct MeshAnnotations: Codable, Equatable, Sendable {
    /// Tagged loop edges, sorted ascending (deterministic encoding).
    public var taggedEdges: [UInt32]
    /// Hidden faces, sorted ascending (deterministic encoding).
    public var hiddenFaces: [UInt32]

    public init(taggedEdges: [UInt32] = [], hiddenFaces: [UInt32] = []) {
        self.taggedEdges = taggedEdges.sorted()
        self.hiddenFaces = hiddenFaces.sorted()
    }

    public var isEmpty: Bool { taggedEdges.isEmpty && hiddenFaces.isEmpty }

    /// This state with `edges` toggled: already-tagged edges untag, new
    /// ones tag (drawing along a tagged loop clears the tag).
    public func togglingTags(on edges: [UInt32]) -> MeshAnnotations {
        var tagged = Set(taggedEdges)
        let incoming = Set(edges)
        if incoming.isSubset(of: tagged) {
            tagged.subtract(incoming)
        } else {
            tagged.formUnion(incoming)
        }
        return MeshAnnotations(taggedEdges: Array(tagged), hiddenFaces: hiddenFaces)
    }

    /// This state with `faces` added to the hidden set.
    public func hiding(faces: [UInt32]) -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges,
            hiddenFaces: Array(Set(hiddenFaces).union(faces))
        )
    }

    /// This state with visibility inverted against the full live-face set.
    public func invertingVisibility(allFaces: [UInt32]) -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges,
            hiddenFaces: Array(Set(allFaces).subtracting(hiddenFaces))
        )
    }

    /// This state with every face shown again.
    public func showingAll() -> MeshAnnotations {
        MeshAnnotations(taggedEdges: taggedEdges, hiddenFaces: [])
    }
}

// Topology queries and overlay render state backing the annotation verbs.
// The walks run engine-side (retopo/loops.hpp, design D1); the render
// state setters filter the engine render cache without touching topology
// (stable ids unaffected), but they DO invalidate pointer views like any
// mutating op.
extension Mesh {
    /// Edge loop through `edge` in walk order ("line along a loop"):
    /// continues through each regular (valence-4 interior) vertex along the
    /// topologically opposite edge; stops at boundaries/poles or on
    /// closure. Empty for a dead edge.
    public func edgeLoop(from edge: UInt32) -> [UInt32] {
        let count = cyber_mesh_edge_loop(handle, edge, nil, 0)
        guard count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_edge_loop(handle, edge, buffer.baseAddress, count)
        }
    }

    /// Quad ring through `edge` ("line across a face ring"): the
    /// consecutive across-edges crossing each quad to its opposite edge.
    /// `closed` is true when the ring wrapped around.
    public func quadRing(from edge: UInt32) -> (edges: [UInt32], closed: Bool) {
        var closed: Int32 = 0
        let count = cyber_mesh_quad_ring(handle, edge, nil, 0, &closed)
        guard count > 0 else { return ([], false) }
        let edges = [UInt32](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_quad_ring(handle, edge, buffer.baseAddress, count, &closed)
        }
        return (edges, closed == 1)
    }

    /// Stable ids of every live face, in id order (the universe the
    /// visibility gestures complement against).
    public func liveFaceIDs() -> [UInt32] {
        let count = cyber_mesh_live_faces(handle, nil, 0)
        guard count > 0 else { return [] }
        return [UInt32](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_live_faces(handle, buffer.baseAddress, count)
        }
    }

    /// Pushes annotation state into the handle's render filters: hidden
    /// faces drop out of the render streams, tagged edges surface through
    /// `RenderBuffers.taggedEdgeIndices`. Stale ids are skipped engine-side.
    public func applyAnnotations(_ annotations: MeshAnnotations?) throws {
        let state = annotations ?? MeshAnnotations()
        try state.hiddenFaces.withUnsafeBufferPointer { buffer in
            try check(cyber_mesh_set_hidden_faces(handle, buffer.baseAddress, buffer.count))
        }
        try state.taggedEdges.withUnsafeBufferPointer { buffer in
            try check(cyber_mesh_set_tagged_edges(handle, buffer.baseAddress, buffer.count))
        }
    }

    /// Number of face ids currently in the handle's hidden set.
    public var hiddenFaceCount: Int { cyber_mesh_hidden_face_count(handle) }
}
