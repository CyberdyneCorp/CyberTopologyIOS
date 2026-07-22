import CyberRemesherC
import Foundation

/// Per-object annotation state of the gesture grammar's non-topological
/// verbs (task 3.4; spec: pencil-interaction / "Contextual gesture
/// grammar"): loop tags ("line along a loop → tag it") and partial
/// visibility ("lasso → hide portion", "line down/up → invert/show all"),
/// extended in task 4.3 with PINS (spec: retopology-tools / "Pins immune
/// to smoothing") and PER-TAG COLORS (spec: "Loop tags" — users color-tag
/// edge loops).
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
///
/// **Encoding is deterministic**: every id list is stored sorted ascending,
/// and `tagColorIndices` is a PARALLEL array to `taggedEdges` (same count,
/// same order) rather than a dictionary, so two equal states always encode
/// to the same bytes. Documents written before 4.3 decode fine: a missing
/// `pinnedVertices` is empty and a missing/short `tagColorIndices` fills
/// with the default color.
public struct MeshAnnotations: Codable, Equatable, Sendable {
    /// Number of distinct loop-tag colors (the "small palette" the spec
    /// asks for). Color *values* are presentation and live in the overlay;
    /// only the index is document state.
    public static let tagColorCount: UInt8 = 6
    /// Color index a tag gets when the user has not chosen one.
    public static let defaultTagColor: UInt8 = 0

    /// Tagged loop edges, sorted ascending (deterministic encoding).
    public private(set) var taggedEdges: [UInt32]
    /// Palette index per entry of `taggedEdges` — same count, same order.
    public private(set) var tagColorIndices: [UInt8]
    /// Hidden faces, sorted ascending (deterministic encoding).
    public private(set) var hiddenFaces: [UInt32]
    /// Pinned vertices, sorted ascending (deterministic encoding). Pinned
    /// vertices are immune to Move / Relax / Auto Relax (the engine's
    /// `PinSet`, passed on every brush call) and render as distinct
    /// markers in the EditMesh overlay.
    public private(set) var pinnedVertices: [UInt32]

    public init(
        taggedEdges: [UInt32] = [], tagColorIndices: [UInt8] = [],
        hiddenFaces: [UInt32] = [], pinnedVertices: [UInt32] = []
    ) {
        // Sort tags and their colors together so the parallel arrays stay
        // aligned no matter what order the caller supplies, and DEDUPLICATE
        // (last color wins). Uniqueness is a structural invariant here, not
        // an assumption about callers: `togglingTags` builds a dictionary
        // keyed on `taggedEdges` with `uniqueKeysWithValues`, which TRAPS on
        // a repeat — and `init(from:)` decodes whatever a bundle contains,
        // so a hand-edited or merge-mangled manifest would otherwise crash
        // the app on the next Pencil stroke rather than degrade.
        // Collapsing in INPUT order before sorting (rather than relying on a
        // stable sort, which `sorted()` does not promise) keeps the "last
        // color wins" rule — and the resulting bytes — deterministic.
        var byEdge: [UInt32: UInt8] = [:]
        byEdge.reserveCapacity(taggedEdges.count)
        for (edge, color) in zip(
            taggedEdges, Self.paddedColors(tagColorIndices, to: taggedEdges.count)
        ) {
            byEdge[edge] = color
        }
        let edges = byEdge.keys.sorted()
        self.taggedEdges = edges
        self.tagColorIndices = edges.map { byEdge[$0]! }
        self.hiddenFaces = Array(Set(hiddenFaces)).sorted()
        self.pinnedVertices = Array(Set(pinnedVertices)).sorted()
    }

    /// Pads/truncates `colors` to `count` entries, clamping out-of-palette
    /// indices (a future build's extra colors decode to the default rather
    /// than rendering as nothing).
    private static func paddedColors(_ colors: [UInt8], to count: Int) -> [UInt8] {
        (0..<count).map { index in
            let raw = index < colors.count ? colors[index] : defaultTagColor
            return raw < tagColorCount ? raw : defaultTagColor
        }
    }

    public var isEmpty: Bool {
        taggedEdges.isEmpty && hiddenFaces.isEmpty && pinnedVertices.isEmpty
    }

    /// Palette index of `edge`, or nil when it carries no tag.
    public func tagColor(of edge: UInt32) -> UInt8? {
        taggedEdges.firstIndex(of: edge).map { tagColorIndices[$0] }
    }

    /// Tagged edges grouped by palette index, each group sorted ascending
    /// (the overlay builds one colored line pass per group).
    public func taggedEdgesByColor() -> [UInt8: [UInt32]] {
        var groups: [UInt8: [UInt32]] = [:]
        for (edge, color) in zip(taggedEdges, tagColorIndices) {
            groups[color, default: []].append(edge)
        }
        return groups
    }

    // MARK: - Loop tags

    /// This state with `edges` toggled in `color`: drawing along a loop
    /// already tagged in that exact color CLEARS it (the 3.4 toggle
    /// semantics, now color-aware); drawing in a different color RETAGS —
    /// re-drawing with a new color recolors instead of erasing, which is
    /// what "color-tag edge loops by drawing along them" needs.
    public func togglingTags(
        on edges: [UInt32], color: UInt8 = MeshAnnotations.defaultTagColor
    ) -> MeshAnnotations {
        let incoming = Set(edges)
        guard !incoming.isEmpty else { return self }
        let alreadyInThisColor = incoming.allSatisfy { tagColor(of: $0) == color }
        if alreadyInThisColor {
            return clearingTags(on: edges)
        }
        // `uniqueKeysWithValues` is safe because `taggedEdges` is
        // deduplicated in `init` (see the invariant note there).
        var pairs = Dictionary(uniqueKeysWithValues: zip(taggedEdges, tagColorIndices))
        for edge in incoming { pairs[edge] = color }
        let edges = Array(pairs.keys)
        return MeshAnnotations(
            taggedEdges: edges, tagColorIndices: edges.map { pairs[$0]! },
            hiddenFaces: hiddenFaces, pinnedVertices: pinnedVertices
        )
    }

    /// This state with the tags on `edges` removed (individual clear —
    /// spec: "tags SHALL … be clearable individually and en masse").
    public func clearingTags(on edges: [UInt32]) -> MeshAnnotations {
        let removing = Set(edges)
        let kept = zip(taggedEdges, tagColorIndices).filter { !removing.contains($0.0) }
        return MeshAnnotations(
            taggedEdges: kept.map(\.0), tagColorIndices: kept.map(\.1),
            hiddenFaces: hiddenFaces, pinnedVertices: pinnedVertices
        )
    }

    /// This state with EVERY loop tag cleared (en-masse clear; hosted by
    /// the task-4.5 batch-commands panel).
    public func clearingAllTags() -> MeshAnnotations {
        MeshAnnotations(hiddenFaces: hiddenFaces, pinnedVertices: pinnedVertices)
    }

    // MARK: - Pins

    /// True when `vertex` is pinned.
    public func isPinned(_ vertex: UInt32) -> Bool { pinnedVertices.contains(vertex) }

    /// This state with `vertices` flipped: an all-pinned selection unpins,
    /// anything else pins (the PinFlip action's semantics — the same
    /// toggle shape the loop tags use, so a second flip over a loop always
    /// undoes the first).
    public func togglingPins(on vertices: [UInt32]) -> MeshAnnotations {
        let incoming = Set(vertices)
        guard !incoming.isEmpty else { return self }
        var pinned = Set(pinnedVertices)
        if incoming.isSubset(of: pinned) {
            pinned.subtract(incoming)
        } else {
            pinned.formUnion(incoming)
        }
        return MeshAnnotations(
            taggedEdges: taggedEdges, tagColorIndices: tagColorIndices,
            hiddenFaces: hiddenFaces, pinnedVertices: Array(pinned)
        )
    }

    /// This state with EVERY pin cleared (the spec's batch "clear pins").
    public func clearingAllPins() -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges, tagColorIndices: tagColorIndices,
            hiddenFaces: hiddenFaces
        )
    }

    // MARK: - Visibility

    /// This state with `faces` added to the hidden set.
    public func hiding(faces: [UInt32]) -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges, tagColorIndices: tagColorIndices,
            hiddenFaces: Array(Set(hiddenFaces).union(faces)),
            pinnedVertices: pinnedVertices
        )
    }

    /// This state with visibility inverted against the full live-face set.
    public func invertingVisibility(allFaces: [UInt32]) -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges, tagColorIndices: tagColorIndices,
            hiddenFaces: Array(Set(allFaces).subtracting(hiddenFaces)),
            pinnedVertices: pinnedVertices
        )
    }

    /// This state with every face shown again.
    public func showingAll() -> MeshAnnotations {
        MeshAnnotations(
            taggedEdges: taggedEdges, tagColorIndices: tagColorIndices,
            pinnedVertices: pinnedVertices
        )
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case taggedEdges, tagColorIndices, hiddenFaces, pinnedVertices
    }

    /// Explicit decode so pre-4.3 documents (no pins, no tag colors) round
    /// -trip: the new keys are optional and default to empty/default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            taggedEdges: try container.decodeIfPresent([UInt32].self, forKey: .taggedEdges) ?? [],
            tagColorIndices: try container.decodeIfPresent(
                [UInt8].self, forKey: .tagColorIndices) ?? [],
            hiddenFaces: try container.decodeIfPresent([UInt32].self, forKey: .hiddenFaces) ?? [],
            pinnedVertices: try container.decodeIfPresent(
                [UInt32].self, forKey: .pinnedVertices) ?? []
        )
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

    /// Distinct vertices of the edge loop through `edge`, in walk order —
    /// what a per-LOOP pin flip pins (spec: "Pinning SHALL be applicable
    /// per vertex and per edge loop"). Empty for a dead edge.
    public func edgeLoopVertices(from edge: UInt32) -> [UInt32] {
        var ordered: [UInt32] = []
        var seen: Set<UInt32> = []
        for loopEdge in edgeLoop(from: edge) {
            guard let ends = edgeEndpoints(of: loopEdge) else { continue }
            for vertex in [ends.0, ends.1] where seen.insert(vertex).inserted {
                ordered.append(vertex)
            }
        }
        return ordered
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
    ///
    /// Pins and tag COLORS are not render filters — the overlay draws them
    /// from standalone world-space marker buffers (task 4.3) — so they do
    /// not participate here.
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
