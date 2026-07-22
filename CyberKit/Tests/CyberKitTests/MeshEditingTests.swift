import CyberKit
import CyberKitTesting
import Foundation
import Testing
import simd

/// Task 3.3 engine patch 0006 (mesh-editing ops): the five verbs' engine
/// operations exercised through the CyberKit facade against real engine
/// meshes — continuous Target snapping (spec: document-model / "EditMesh
/// vertex snapping"), geodesic Move falloff (spec: pencil-interaction /
/// "Geodesic Move falloff"), pin-honoring relax, pressure-scaled erase, and
/// the render-cache invalidation contract every mutation must uphold.
@Suite("Mesh editing verbs (engine ops)")
struct MeshEditingTests {
    // MARK: - Fixtures

    /// Loads a mesh from inline OBJ text (engine parser; no app code).
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mesh-edit-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// Big flat quad at z = 0.5 — a Target whose surface is visibly OFF the
    /// z = 0 plane the test points live on, so a "snap happened" assert can
    /// never pass vacuously.
    private func planeTarget() throws -> Mesh {
        try mesh(fromOBJ: """
        v -5 -5 0.5
        v 5 -5 0.5
        v 5 5 0.5
        v -5 5 0.5
        f 1 2 3 4
        """)
    }

    /// Two disconnected 4-quad strips 0.2 apart — geodesically infinitely
    /// far, Euclidean-close (the "Geodesic Move falloff" scenario setup).
    private func disconnectedStrips() throws -> Mesh {
        try mesh(fromOBJ: """
        v 0 0 0
        v 1 0 0
        v 2 0 0
        v 3 0 0
        v 4 0 0
        v 0 1 0
        v 1 1 0
        v 2 1 0
        v 3 1 0
        v 4 1 0
        v 0 1.2 0
        v 1 1.2 0
        v 2 1.2 0
        v 3 1.2 0
        v 4 1.2 0
        v 0 2.2 0
        v 1 2.2 0
        v 2 2.2 0
        v 3 2.2 0
        v 4 2.2 0
        f 1 2 7 6
        f 2 3 8 7
        f 3 4 9 8
        f 4 5 10 9
        f 11 12 17 16
        f 12 13 18 17
        f 13 14 19 18
        f 14 15 20 19
        """)
    }

    /// 3x3-quad grid (4x4 vertices, unit spacing) with the interior vertex
    /// nominally at (1,1) perturbed to (1.35, 0.75) — relax should pull it
    /// back toward its neighbor centroid.
    private func perturbedGrid() throws -> Mesh {
        var obj = ""
        for row in 0...3 {
            for col in 0...3 {
                if row == 1 && col == 1 {
                    obj += "v 1.35 0.75 0\n"
                } else {
                    obj += "v \(col) \(row) 0\n"
                }
            }
        }
        for row in 0..<3 {
            for col in 0..<3 {
                let a = row * 4 + col + 1
                obj += "f \(a) \(a + 1) \(a + 5) \(a + 4)\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    private func vertexPositions(_ mesh: Mesh) -> [UInt32: SIMD3<Float>] {
        var out: [UInt32: SIMD3<Float>] = [:]
        var id: UInt32 = 0
        var found = 0
        // Ids are compact after an OBJ load; walk until every live vertex
        // was seen (dead-id probes return nil and are skipped).
        while found < mesh.vertexCount && id < 100_000 {
            if let position = mesh.vertexPosition(id) {
                out[id] = position
                found += 1
            }
            id += 1
        }
        return out
    }

    private func vertexID(
        at position: SIMD3<Float>, in mesh: Mesh
    ) throws -> UInt32 {
        let pick = try #require(mesh.nearestVertex(to: position, maxDistance: 1e-3))
        return pick.vertex
    }

    // MARK: - Create face (Pencil quad) + Target snapping

    @Test("created quad vertices land exactly on the Target surface")
    func createFaceSnapsNewVerticesOntoTargetSurface() throws {
        let target = try planeTarget()
        let snapper = try SurfaceSnapper(target: target)
        let editMesh = try Mesh()

        let corners: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
        ]
        let face = try editMesh.createFace(at: corners, snapping: snapper)
        #expect(editMesh.vertexCount == 4)
        #expect(editMesh.faceCount == 1)
        #expect(face != 0xFFFF_FFFF)

        // Every vertex sits on the Target plane (z = 0.5) within tolerance —
        // spec: document-model / "EditMesh vertex snapping".
        for (_, position) in vertexPositions(editMesh) {
            #expect(abs(position.z - 0.5) < 1e-5)
            let hit = try #require(snapper.snapToSurface(position))
            #expect(simd_distance(hit.point, position) < 1e-5)
        }
    }

    @Test("create face without a snapper keeps the given positions; triangles work")
    func createFaceWithoutSnapperKeepsPositions() throws {
        let editMesh = try Mesh()
        try editMesh.createFace(at: [SIMD3(0, 0, 1), SIMD3(1, 0, 2), SIMD3(0, 1, 3)])
        #expect(editMesh.vertexCount == 3)
        #expect(editMesh.faceCount == 1)
        let zs = vertexPositions(editMesh).values.map(\.z).sorted()
        #expect(zs == [1, 2, 3])
    }

    @Test("degenerate quads are rejected and leave the mesh untouched")
    func createFaceRejectsDegenerateInput() throws {
        let editMesh = try Mesh()
        // Too few points.
        #expect(throws: CyberKitError.self) {
            try editMesh.createFace(at: [SIMD3(0, 0, 0), SIMD3(1, 0, 0)])
        }
        // Repeated corner.
        #expect(throws: CyberKitError.self) {
            try editMesh.createFace(at: [
                SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0),
            ])
        }
        #expect(editMesh.vertexCount == 0)
        #expect(editMesh.faceCount == 0)
    }

    /// Canonical quad-create golden: byte-exact document payload of one
    /// snapped quad (deterministic engine serialization).
    @Test("canonical quad-create result matches the committed golden")
    func quadCreateMatchesGolden() throws {
        let snapper = try SurfaceSnapper(target: planeTarget())
        let editMesh = try Mesh()
        try editMesh.createFace(
            at: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            snapping: snapper
        )
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens/MeshEdits/quad_create.payload.golden")
        try GoldenFile.compare(try editMesh.payloadData(), golden: golden)
    }

    // MARK: - Tweak

    @Test("tweak drops the vertex at the target, snapped to the surface")
    func tweakVertexSnapsToTarget() throws {
        let snapper = try SurfaceSnapper(target: planeTarget())
        let editMesh = try disconnectedStrips()
        let vertex = try vertexID(at: SIMD3(2, 0, 0), in: editMesh)

        try editMesh.tweakVertex(vertex, to: SIMD3(2.4, 0.3, 2), snapping: snapper)
        let moved = try #require(editMesh.vertexPosition(vertex))
        #expect(abs(moved.x - 2.4) < 1e-5)
        #expect(abs(moved.y - 0.3) < 1e-5)
        #expect(abs(moved.z - 0.5) < 1e-5)  // projected onto the plane

        // Without a snapper the exact position is kept.
        try editMesh.tweakVertex(vertex, to: SIMD3(2, 0, 0))
        #expect(try #require(editMesh.vertexPosition(vertex)) == SIMD3(2, 0, 0))

        // Dead vertex ids are rejected.
        #expect(throws: CyberKitError.self) {
            try editMesh.tweakVertex(9_999, to: .zero)
        }
    }

    // MARK: - Move (geodesic falloff)

    @Test("move displaces the seed fully and falls off with geodesic distance")
    func moveAppliesGeodesicFalloff() throws {
        let editMesh = try disconnectedStrips()
        let seed = try vertexID(at: SIMD3(0, 0, 0), in: editMesh)
        let near = try vertexID(at: SIMD3(1, 0, 0), in: editMesh)
        let far = try vertexID(at: SIMD3(4, 1, 0), in: editMesh)

        try editMesh.moveWithGeodesicFalloff(
            seed: seed, displacement: SIMD3(0, 0, 1), radius: 2.5
        )
        let seedZ = try #require(editMesh.vertexPosition(seed)).z
        let nearZ = try #require(editMesh.vertexPosition(near)).z
        let farZ = try #require(editMesh.vertexPosition(far)).z
        #expect(abs(seedZ - 1) < 1e-5)  // full displacement at the seed
        #expect(nearZ > 0 && nearZ < seedZ)  // smooth falloff
        #expect(farZ == 0)  // beyond the geodesic radius
    }

    @Test("move never affects a disconnected component, however close in space")
    func moveIgnoresDisconnectedComponent() throws {
        let editMesh = try disconnectedStrips()
        let seed = try vertexID(at: SIMD3(0, 1, 0), in: editMesh)
        // 0.2 away in space, unreachable through the surface.
        let acrossGap = try vertexID(at: SIMD3(0, 1.2, 0), in: editMesh)
        let before = vertexPositions(editMesh)

        try editMesh.moveWithGeodesicFalloff(
            seed: seed, displacement: SIMD3(0, 0, 1), radius: 3
        )
        #expect(try #require(editMesh.vertexPosition(seed)).z == 1)
        // The whole second strip is bit-identical (spec scenario
        // "Geodesic Move falloff").
        for id in before.keys {
            let position = try #require(editMesh.vertexPosition(id))
            if position.y >= 1.2 {
                #expect(position == before[id])
            }
        }
        #expect(try #require(editMesh.vertexPosition(acrossGap)).z == 0)
    }

    @Test("pinned vertices resist move; dead seeds are rejected")
    func moveRespectsPinsAndValidatesSeed() throws {
        let editMesh = try disconnectedStrips()
        let seed = try vertexID(at: SIMD3(0, 0, 0), in: editMesh)
        let pinnedVertex = try vertexID(at: SIMD3(1, 0, 0), in: editMesh)

        try editMesh.moveWithGeodesicFalloff(
            seed: seed, displacement: SIMD3(0, 0, 1), radius: 2.5, pinned: [pinnedVertex]
        )
        #expect(try #require(editMesh.vertexPosition(pinnedVertex)).z == 0)

        #expect(throws: CyberKitError.self) {
            try editMesh.moveWithGeodesicFalloff(
                seed: 9_999, displacement: SIMD3(0, 0, 1), radius: 1
            )
        }
    }

    // MARK: - Relax

    @Test("relax pulls a perturbed interior vertex toward its neighbor centroid")
    func relaxSmoothsPerturbedVertex() throws {
        let editMesh = try perturbedGrid()
        let vertex = try vertexID(at: SIMD3(1.35, 0.75, 0), in: editMesh)
        let centroid = SIMD3<Float>(1, 1, 0)  // its 4 neighbors average
        let before = simd_distance(SIMD3(1.35, 0.75, 0), centroid)

        try editMesh.relax(around: SIMD3(1, 1, 0), radius: 2, strength: 0.5)
        let after = simd_distance(try #require(editMesh.vertexPosition(vertex)), centroid)
        #expect(after < before)
    }

    @Test("explicitly pinned vertices are immune to relax")
    func relaxPreservesPinnedVertices() throws {
        let editMesh = try perturbedGrid()
        let vertex = try vertexID(at: SIMD3(1.35, 0.75, 0), in: editMesh)

        try editMesh.relax(around: SIMD3(1, 1, 0), radius: 2, pinned: [vertex])
        #expect(
            try #require(editMesh.vertexPosition(vertex)) == SIMD3(1.35, 0.75, 0)
        )
    }

    @Test("auto-pinned grid corners survive a whole-mesh relax")
    func relaxAutoPinsGridCorners() throws {
        let editMesh = try perturbedGrid()
        let corner = try vertexID(at: SIMD3(0, 0, 0), in: editMesh)
        try editMesh.relax(around: .zero, radius: 0)  // radius <= 0: whole mesh
        #expect(try #require(editMesh.vertexPosition(corner)) == SIMD3(0, 0, 0))
    }

    @Test("relax with a snapper keeps every vertex on the Target surface")
    func relaxKeepsVerticesOnTarget() throws {
        let snapper = try SurfaceSnapper(target: planeTarget())
        let editMesh = try perturbedGrid()
        // The grid lives at z = 0; relaxing with the z = 0.5 plane Target
        // reprojects every relaxed vertex onto it.
        try editMesh.relax(around: SIMD3(1, 1, 0), radius: 2, snapping: snapper)
        let vertex = try #require(
            editMesh.nearestVertex(to: SIMD3(1, 1, 0.5), maxDistance: 1)
        )
        #expect(abs(vertex.position.z - 0.5) < 1e-5)
    }

    @Test("invalid relax parameters are rejected")
    func relaxValidatesParameters() throws {
        let editMesh = try perturbedGrid()
        #expect(throws: CyberKitError.self) {
            try editMesh.relax(around: .zero, radius: 1, strength: 2)
        }
        #expect(throws: CyberKitError.self) {
            try editMesh.relax(around: .zero, radius: 1, iterations: 0)
        }
    }

    // MARK: - Erase

    @Test("erase removes faces under the brush and scales with pressure")
    func eraseScalesWithPressure() throws {
        // Zero pressure: half the base radius (0.5) covers only the faces
        // whose centroid is within it.
        let light = try perturbedGrid()  // 9 quads, centroids on the half grid
        let removedLight = try light.erase(
            around: SIMD3(1.5, 1.5, 0), baseRadius: 1.0, pressure: 0
        )
        // Full pressure: 1.5x the base radius reaches every neighbor.
        let heavy = try perturbedGrid()
        let removedHeavy = try heavy.erase(
            around: SIMD3(1.5, 1.5, 0), baseRadius: 1.0, pressure: 1
        )
        #expect(removedLight > 0)
        #expect(removedHeavy > removedLight)
        #expect(heavy.faceCount == 9 - removedHeavy)
        // Vertices left without any face are removed too.
        #expect(heavy.vertexCount < 16)
    }

    @Test("delete faces removes listed live faces and skips dead ids")
    func deleteFacesRemovesListed() throws {
        let editMesh = try perturbedGrid()
        #expect(editMesh.faceCount == 9)
        let removed = try editMesh.deleteFaces([0, 1, 999])
        #expect(removed == 2)
        #expect(editMesh.faceCount == 7)
    }

    // MARK: - Render-cache invalidation (the 0002 LIFETIME contract)

    @Test("every mutation invalidates the render cache; accessors rebuild")
    func mutationsInvalidateRenderCache() throws {
        let snapper = try SurfaceSnapper(target: planeTarget())
        let editMesh = try Mesh()
        try editMesh.createFace(
            at: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0)],
            snapping: snapper
        )
        // Build the cache, keep pre-mutation copies.
        let positionsBefore = editMesh.positions()
        #expect(editMesh.triangleCount == 2)
        #expect(editMesh.edgeCount == 4)

        // Mutation 1: append a second quad — triangulation and edge set grow.
        try editMesh.createFace(
            at: [SIMD3(1, 0, 0), SIMD3(2, 0, 0), SIMD3(2, 1, 0), SIMD3(1, 1, 0)],
            snapping: snapper
        )
        #expect(editMesh.triangleCount == 4)
        #expect(editMesh.edgeCount == 8)
        #expect(editMesh.positions().count == positionsBefore.count + 12)

        // Mutation 2: move a vertex — same counts, fresh positions.
        let vertex = try vertexID(at: SIMD3(0, 0, 0.5), in: editMesh)
        try editMesh.tweakVertex(vertex, to: SIMD3(-1, -1, 0.5))
        let positionsAfter = editMesh.positions()
        #expect(positionsAfter.count == positionsBefore.count + 12)
        #expect(positionsAfter.contains(-1))  // the tweak is visible
        #expect(!positionsBefore.contains(-1))

        // Zero-copy views fetched AFTER the mutations see the new geometry
        // (re-fetching per the LIFETIME contract).
        editMesh.withRenderBuffers { buffers in
            #expect(buffers.positions.count == 8 * 3)
            #expect(buffers.triangleIndices.count == 4 * 3)
            #expect(Array(buffers.positions) == positionsAfter)
        }
    }

    // MARK: - Interpretation corner estimates (quad application input)

    @Test("closed strokes carry 4 corner estimates; open strokes none")
    func interpretationCarriesQuadCorners() throws {
        func interpret(_ fixture: StrokeFixture) throws -> StrokeInterpretation {
            try StrokeInterpreter.interpret(
                samples: fixture.samples.map { .init(x: $0.x, y: $0.y, time: $0.time) }
            )
        }
        let square = try interpret(StrokeGestureCorpus.square())
        #expect(square.best?.action == .createQuad)
        #expect(square.quadCorners.count == 4)
        // Each estimate sits near one drawn corner of the ~[0.31, 0.69]²
        // square (generous tolerance: corner detection is heuristic).
        let drawn: [SIMD2<Float>] = [
            SIMD2(0.32, 0.30), SIMD2(0.68, 0.31), SIMD2(0.69, 0.68), SIMD2(0.31, 0.69),
        ]
        for corner in square.quadCorners {
            let nearest = drawn.map { simd_distance($0, corner) }.min() ?? 1
            #expect(nearest < 0.08, "corner \(corner) far from every drawn corner")
        }

        // A circle still yields a stable inscribed quad (fallback path).
        let circle = try interpret(StrokeGestureCorpus.circle())
        #expect(circle.quadCorners.count == 4)

        // Open strokes carry no corners.
        let line = try interpret(StrokeGestureCorpus.line())
        #expect(line.quadCorners.isEmpty)
    }

    // MARK: - Journaled command (MeshEditTransaction)

    @Test("transaction produces a byte-exact apply/revert command")
    func transactionProducesExactCommand() throws {
        var bundle = DocumentBundle()
        let editMesh = try perturbedGrid()
        let object = try bundle.addObject(name: "cage", role: .editMesh, mesh: editMesh)
        let beforePayload = try #require(bundle.payloads[object.payloadFile])

        let transaction = MeshEditTransaction(
            object: object, mesh: editMesh, currentPayload: beforePayload
        )
        let vertex = try vertexID(at: SIMD3(1.35, 0.75, 0), in: editMesh)
        try editMesh.tweakVertex(vertex, to: SIMD3(1, 1, 0))
        let command = try #require(try transaction.command(verb: "tweak"))

        command.apply(to: &bundle)
        let afterPayload = try #require(bundle.payloads[object.payloadFile])
        #expect(afterPayload != beforePayload)
        #expect(bundle.manifest.objects[0].revision == 1)

        // Revert restores the payload byte-exactly, plus counts/revision.
        command.revert(on: &bundle)
        #expect(bundle.payloads[object.payloadFile] == beforePayload)
        #expect(bundle.manifest.objects[0].revision == nil)
        #expect(bundle.manifest.objects[0].counts == object.counts)

        // Journal round trip: the command re-applies from its own data.
        var journal = UndoJournal()
        journal.record(command)
        let undone = journal.undo()
        #expect(undone == command)

        // Codable round trip (persisted journal).
        let encoded = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(DocumentCommand.self, from: encoded)
        #expect(decoded == command)
    }

    @Test("a no-op stroke yields no command (no empty journal entries)")
    func transactionReturnsNilWhenUnchanged() throws {
        var bundle = DocumentBundle()
        let editMesh = try perturbedGrid()
        let object = try bundle.addObject(name: "cage", role: .editMesh, mesh: editMesh)
        let payload = try #require(bundle.payloads[object.payloadFile])
        let transaction = MeshEditTransaction(
            object: object, mesh: editMesh, currentPayload: payload
        )
        #expect(try transaction.command(verb: "relax") == nil)
    }
}
