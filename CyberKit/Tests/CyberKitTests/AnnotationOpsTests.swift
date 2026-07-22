import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 4.3: pins and loop metrics through the REAL engine (spec:
/// retopology-tools / "Pins immune to smoothing", scenario "Relax over
/// pinned loop", and the roster's "Loop Info inspection … in O(loop)
/// time"), plus the annotation model's persistence contract.
///
/// No mocks: every assertion below drives the capi (`cyber_retopo_relax`,
/// `cyber_retopo_move`, `cyber_mesh_loop_metrics`) against a real engine
/// mesh built from the committed grid32 fixture.
@Suite("Pins, loop metrics and annotation persistence")
struct AnnotationOpsTests {
    // MARK: - Fixtures

    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotations-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The committed 3x2 quad grid strip (4 columns x 3 rows of vertices).
    private func grid32() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "grid32", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    private func positions(of mesh: Mesh, _ ids: [UInt32]) -> [UInt32: SIMD3<Float>] {
        var out: [UInt32: SIMD3<Float>] = [:]
        for id in ids {
            if let position = mesh.vertexPosition(id) { out[id] = position }
        }
        return out
    }

    private func edge(of mesh: Mesh, near point: SIMD3<Float>) throws -> UInt32 {
        try #require(mesh.nearestEdge(to: point, maxDistance: 0.01)).edge
    }

    /// Perturbs every vertex off the flat grid by a deterministic amount,
    /// so relax has real work to do (a flat grid is already relaxed and
    /// would make an "unpinned moved" assertion vacuous).
    private func perturb(_ mesh: Mesh) throws {
        let count = mesh.vertexCount
        for id in 0..<UInt32(count) {
            guard let position = mesh.vertexPosition(id) else { continue }
            // Alternating in-plane jitter: keeps the patch a valid quad
            // grid while making the spacing visibly uneven.
            let sign: Float = id % 2 == 0 ? 1 : -1
            try mesh.tweakVertex(
                id, to: position + SIMD3(0.04 * sign, 0.03 * sign, 0)
            )
        }
    }

    // MARK: - Pins immune to smoothing (spec scenario "Relax over pinned loop")

    @Test("Relax over a pinned loop: unpinned vertices move, pinned ones do not")
    func relaxHonorsPinnedLoop() throws {
        let grid = try grid32()
        // The MIDDLE horizontal edge row is a real interior edge loop.
        let seed = try edge(of: grid, near: SIMD3(-0.25, 0, 0))
        let loop = grid.edgeLoop(from: seed)
        #expect(loop.count >= 3, "the fixture must offer a multi-edge loop to pin")
        let pinned = grid.edgeLoopVertices(from: seed)
        #expect(pinned.count >= 4)

        try perturb(grid)
        let allIDs = (0..<UInt32(grid.vertexCount)).map { $0 }
        let unpinned = allIDs.filter { !pinned.contains($0) }
        #expect(!unpinned.isEmpty, "the assertion needs unpinned vertices to move")
        let before = positions(of: grid, allIDs)

        // Relax the WHOLE mesh (radius 0 = global) with the loop pinned.
        try grid.relax(
            around: SIMD3(0, 0, 0), radius: 0, strength: 0.9, iterations: 6,
            autoPinCorners: false, pinned: pinned
        )
        let after = positions(of: grid, allIDs)

        // Pinned: bit-exactly where they were.
        for id in pinned {
            #expect(after[id] == before[id], "pinned vertex \(id) moved under Relax")
        }
        // Unpinned: at least one genuinely smoothed. Asserting "some moved"
        // rather than "all moved" keeps the test honest — a vertex already
        // at its relaxed position legitimately stays put.
        let moved = unpinned.filter { id in
            guard let a = before[id], let b = after[id] else { return false }
            return simd_distance(a, b) > 1e-5
        }
        #expect(!moved.isEmpty, "Relax displaced no unpinned vertex — assertion vacuous")
    }

    @Test("Relax without pins moves the same vertices the pinned run held fixed")
    func relaxWithoutPinsMovesThoseVertices() throws {
        // Control for the test above: proves the immunity comes from the
        // PIN SET and not from those vertices being unmovable anyway.
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, 0, 0))
        let loopVertices = grid.edgeLoopVertices(from: seed)
        try perturb(grid)
        let before = positions(of: grid, loopVertices)

        try grid.relax(
            around: SIMD3(0, 0, 0), radius: 0, strength: 0.9, iterations: 6,
            autoPinCorners: false, pinned: []
        )
        let after = positions(of: grid, loopVertices)
        let moved = loopVertices.filter { id in
            guard let a = before[id], let b = after[id] else { return false }
            return simd_distance(a, b) > 1e-5
        }
        #expect(!moved.isEmpty, "unpinned run must move what the pinned run held")
    }

    @Test("Move's geodesic falloff leaves pinned neighbours in place")
    func moveHonorsPins() throws {
        let grid = try grid32()
        let seed: UInt32 = 0
        // Pin every vertex except the seed: only the seed may move.
        let pinned = (1..<UInt32(grid.vertexCount)).map { $0 }
        let allIDs = (0..<UInt32(grid.vertexCount)).map { $0 }
        let before = positions(of: grid, allIDs)

        try grid.moveWithGeodesicFalloff(
            seed: seed, displacement: SIMD3(0, 0, 0.2), radius: 10, pinned: pinned
        )
        let after = positions(of: grid, allIDs)

        for id in pinned {
            #expect(after[id] == before[id], "pinned vertex \(id) moved under Move")
        }
        let seedBefore = try #require(before[seed])
        let seedAfter = try #require(after[seed])
        #expect(simd_distance(seedBefore, seedAfter) > 1e-4, "the seed must have moved")
    }

    @Test("Unpinned Move displaces the neighbours pins protected")
    func moveWithoutPinsDisplacesNeighbours() throws {
        let grid = try grid32()
        let neighbours = (1..<UInt32(grid.vertexCount)).map { $0 }
        let before = positions(of: grid, neighbours)
        try grid.moveWithGeodesicFalloff(
            seed: 0, displacement: SIMD3(0, 0, 0.2), radius: 10, pinned: []
        )
        let after = positions(of: grid, neighbours)
        let moved = neighbours.filter { id in
            guard let a = before[id], let b = after[id] else { return false }
            return simd_distance(a, b) > 1e-5
        }
        #expect(!moved.isEmpty, "falloff must reach neighbours when nothing is pinned")
    }

    // MARK: - Loop metrics (engine patch 0020)

    @Test("Loop metrics on grid32: counts, length and open-chain endpoints")
    func loopMetricsOnGrid() throws {
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, 0, 0))
        let metrics = try #require(grid.loopMetrics(from: seed))
        let loopEdges = grid.edgeLoop(from: seed)
        let loopVertices = grid.edgeLoopVertices(from: seed)

        #expect(metrics.edgeCount == loopEdges.count)
        #expect(metrics.vertexCount == loopVertices.count)
        // The grid is an open strip, so its interior loop is an open chain
        // with one more vertex than edges and two real endpoints.
        #expect(!metrics.isClosed)
        #expect(metrics.vertexCount == metrics.edgeCount + 1)
        let endpoints = try #require(metrics.endpoints)
        #expect(endpoints.0 != endpoints.1)
        #expect(loopVertices.contains(endpoints.0))
        #expect(loopVertices.contains(endpoints.1))

        // Length equals the summed edge lengths of the walked loop.
        var expected: Float = 0
        for edge in loopEdges {
            guard
                let ends = grid.edgeEndpoints(of: edge),
                let a = grid.vertexPosition(ends.0), let b = grid.vertexPosition(ends.1)
            else { continue }
            expected += simd_distance(a, b)
        }
        #expect(abs(metrics.length - expected) < 1e-5)
        // The fixture's interior loop runs the full width of the strip.
        #expect(abs(metrics.length - 0.75) < 1e-4)
        #expect(metrics.boundaryEdgeCount == 0, "an interior loop has no boundary edges")
    }

    @Test("Loop metrics report snapping state only when a Target is supplied")
    func loopMetricsSnappingState() throws {
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, 0, 0))
        // Without a snapper: unmeasured, not "adrift".
        #expect(try #require(grid.loopMetrics(from: seed)).snapping == nil)

        // Target coincident with the grid plane: every vertex is snapped.
        let onPlane = try SurfaceSnapper(target: mesh(fromOBJ: """
        v -10 -10 0
        v 10 -10 0
        v 10 10 0
        v -10 10 0
        f 1 2 3 4
        """))
        let snapped = try #require(grid.loopMetrics(from: seed, snapping: onPlane))
        let snappedState = try #require(snapped.snapping)
        #expect(snappedState.snappedVertexCount == snapped.vertexCount)
        #expect(snappedState.maxDistance < 1e-5)
        #expect(snapped.isFullySnapped)

        // Target well off the plane: nothing is snapped and the reported
        // max distance is the real gap.
        let offPlane = try SurfaceSnapper(target: mesh(fromOBJ: """
        v -10 -10 0.5
        v 10 -10 0.5
        v 10 10 0.5
        v -10 10 0.5
        f 1 2 3 4
        """))
        let adrift = try #require(grid.loopMetrics(from: seed, snapping: offPlane))
        let adriftState = try #require(adrift.snapping)
        #expect(adriftState.snappedVertexCount == 0)
        #expect(abs(adriftState.maxDistance - 0.5) < 1e-4)
        #expect(!adrift.isFullySnapped)
    }

    @Test("Loop metrics of a dead edge are nil, not a zeroed chip")
    func loopMetricsOfDeadEdgeIsNil() throws {
        let grid = try grid32()
        #expect(grid.loopMetrics(from: 9999) == nil)
    }

    @Test("edgeLoopVertices returns each loop vertex once, in walk order")
    func edgeLoopVerticesAreDistinctAndOrdered() throws {
        let grid = try grid32()
        let seed = try edge(of: grid, near: SIMD3(-0.25, 0, 0))
        let vertices = grid.edgeLoopVertices(from: seed)
        #expect(Set(vertices).count == vertices.count, "no vertex may repeat")
        // Consecutive vertices in the walk are joined by a loop edge.
        let loopEdges = Set(grid.edgeLoop(from: seed))
        for (a, b) in zip(vertices, vertices.dropFirst()) {
            let shared = loopEdges.filter { edge in
                guard let ends = grid.edgeEndpoints(of: edge) else { return false }
                return (ends.0 == a && ends.1 == b) || (ends.0 == b && ends.1 == a)
            }
            #expect(!shared.isEmpty, "v\(a) and v\(b) are not adjacent along the loop")
        }
        #expect(grid.edgeLoopVertices(from: 9999).isEmpty)
    }

    // MARK: - Annotation model (pins + per-tag colours)

    @Test("Pin flip toggles: a second pass over the same set unpins it")
    func pinFlipToggles() {
        let empty = MeshAnnotations()
        let pinned = empty.togglingPins(on: [4, 1, 7])
        #expect(pinned.pinnedVertices == [1, 4, 7], "ids must be stored sorted")
        #expect(pinned.isPinned(4))
        #expect(pinned.togglingPins(on: [4, 1, 7]).pinnedVertices.isEmpty)
        // A partially-overlapping set pins the remainder rather than
        // unpinning: only an all-pinned selection flips off.
        #expect(pinned.togglingPins(on: [4, 9]).pinnedVertices == [1, 4, 7, 9])
        #expect(pinned.togglingPins(on: []).pinnedVertices == [1, 4, 7])
        #expect(pinned.clearingAllPins().pinnedVertices.isEmpty)
    }

    @Test("Loop tags carry a palette colour; retagging recolours, same colour clears")
    func loopTagColours() {
        let tagged = MeshAnnotations().togglingTags(on: [3, 1], color: 2)
        #expect(tagged.taggedEdges == [1, 3])
        #expect(tagged.tagColor(of: 1) == 2)
        #expect(tagged.tagColor(of: 3) == 2)
        #expect(tagged.tagColor(of: 99) == nil)
        // Same colour again: clears (the 3.4 toggle, now colour-aware).
        #expect(tagged.togglingTags(on: [3, 1], color: 2).taggedEdges.isEmpty)
        // Different colour: recolours instead of erasing.
        let recoloured = tagged.togglingTags(on: [3, 1], color: 4)
        #expect(recoloured.taggedEdges == [1, 3])
        #expect(recoloured.tagColor(of: 1) == 4)
    }

    @Test("Tags clear individually and en masse, leaving pins untouched")
    func tagClears() {
        let state = MeshAnnotations(pinnedVertices: [5])
            .togglingTags(on: [1, 2], color: 0)
            .togglingTags(on: [7], color: 3)
        #expect(state.taggedEdges == [1, 2, 7])

        let individual = state.clearingTags(on: [1, 2])
        #expect(individual.taggedEdges == [7])
        #expect(individual.tagColor(of: 7) == 3, "the surviving tag keeps its colour")
        #expect(individual.pinnedVertices == [5])

        let all = state.clearingAllTags()
        #expect(all.taggedEdges.isEmpty)
        #expect(all.tagColorIndices.isEmpty)
        #expect(all.pinnedVertices == [5], "clearing tags must not clear pins")
    }

    @Test("Tags group by colour for the overlay's per-colour passes")
    func tagsGroupByColour() {
        let state = MeshAnnotations()
            .togglingTags(on: [1, 4], color: 0)
            .togglingTags(on: [2], color: 3)
        let groups = state.taggedEdgesByColor()
        #expect(groups[0] == [1, 4])
        #expect(groups[3] == [2])
        #expect(groups.count == 2)
    }

    @Test("Out-of-palette colour indices clamp to the default")
    func outOfPaletteColoursClamp() {
        let state = MeshAnnotations(
            taggedEdges: [1], tagColorIndices: [MeshAnnotations.tagColorCount + 5]
        )
        #expect(state.tagColor(of: 1) == MeshAnnotations.defaultTagColor)
    }

    /// REGRESSION: `togglingTags` keys a `Dictionary(uniqueKeysWithValues:)`
    /// on `taggedEdges`, which TRAPS on a repeat. A manifest carrying a
    /// duplicate tagged-edge id (hand-edited bundle, merge artifact) used to
    /// decode fine and then crash on the next Pencil stroke, so uniqueness
    /// is now enforced in `init` — last colour wins, deterministically.
    @Test("Duplicate tagged-edge ids collapse instead of trapping later")
    func duplicateTagIDsDeduplicate() throws {
        let direct = MeshAnnotations(
            taggedEdges: [7, 3, 7, 3], tagColorIndices: [1, 2, 4, 5],
            hiddenFaces: [2, 2], pinnedVertices: [6, 6, 1]
        )
        #expect(direct.taggedEdges == [3, 7])
        #expect(direct.tagColor(of: 7) == 4)  // last colour supplied wins
        #expect(direct.tagColor(of: 3) == 5)
        #expect(direct.hiddenFaces == [2])
        #expect(direct.pinnedVertices == [1, 6])

        // The path that used to trap: a duplicate decoded straight off disk,
        // then drawn over.
        let mangled = Data(#"{"taggedEdges":[4,4],"tagColorIndices":[1,1]}"#.utf8)
        let decoded = try JSONDecoder().decode(MeshAnnotations.self, from: mangled)
        #expect(decoded.taggedEdges == [4])
        #expect(decoded.togglingTags(on: [9], color: 2).taggedEdges == [4, 9])
        #expect(decoded.togglingTags(on: [4], color: 1).taggedEdges.isEmpty)
    }

    // MARK: - Persistence

    @Test("Annotations round-trip through Codable with colours and pins intact")
    func annotationsRoundTripThroughCodable() throws {
        let original = MeshAnnotations(hiddenFaces: [8])
            .togglingTags(on: [5, 2], color: 4)
            .togglingPins(on: [9, 3])
        let encoder = JSONEncoder()
        // Sorted keys so "identical bytes" tests the VALUES' determinism
        // (sorted id arrays, aligned colour indices), not the encoder's
        // key ordering.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(MeshAnnotations.self, from: data)
        #expect(decoded == original)
        #expect(decoded.pinnedVertices == [3, 9])
        #expect(decoded.tagColor(of: 5) == 4)
        #expect(decoded.hiddenFaces == [8])

        // Deterministic encoding: equal states encode to identical bytes,
        // whatever order the caller supplied ids in.
        let shuffled = MeshAnnotations(hiddenFaces: [8])
            .togglingTags(on: [2, 5], color: 4)
            .togglingPins(on: [3, 9])
        #expect(try encoder.encode(shuffled) == data)
    }

    @Test("Pre-4.3 documents decode: no pins, tags default to the first colour")
    func legacyAnnotationsDecode() throws {
        let legacy = Data(#"{"taggedEdges":[4,2],"hiddenFaces":[1]}"#.utf8)
        let decoded = try JSONDecoder().decode(MeshAnnotations.self, from: legacy)
        #expect(decoded.taggedEdges == [2, 4])
        #expect(decoded.tagColorIndices == [MeshAnnotations.defaultTagColor, MeshAnnotations.defaultTagColor])
        #expect(decoded.pinnedVertices.isEmpty)
        #expect(decoded.hiddenFaces == [1])
    }

    @Test("Pins and coloured tags survive a document bundle round-trip")
    func annotationsSurviveDocumentBundle() throws {
        let grid = try grid32()
        var bundle = DocumentBundle()
        let object = try bundle.addObject(name: "cage", role: .editMesh, mesh: grid)
        let annotations = MeshAnnotations()
            .togglingPins(
                on: grid.edgeLoopVertices(from: try edge(of: grid, near: SIMD3(-0.25, 0, 0))))
            .togglingTags(on: [1, 2], color: 5)
        bundle.updateObject(id: object.id) { $0.annotations = annotations }

        // Through the real file wrapper the document writes to disk.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("annotations-\(UUID().uuidString).topo")
        try bundle.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let reloaded = try DocumentBundle(fileWrapper: FileWrapper(url: url))

        let restored = try #require(reloaded.manifest.objects.first { $0.id == object.id })
        #expect(restored.annotations == annotations)
        #expect(restored.annotations?.pinnedVertices == annotations.pinnedVertices)
        #expect(restored.annotations?.tagColor(of: 1) == 5)
    }
}
