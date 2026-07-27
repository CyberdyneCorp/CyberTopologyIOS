import CyberKit
import Foundation
import Testing
import simd

/// Authored constraints reaching a region solve (openspec
/// add-weave-constraint-authoring, tasks 1-2, 4). Public-API + inline fixtures, so this
/// suite is device-safe and shared into the app-hosted target.
///
/// The failure this suite exists to catch is a SILENT DROP. `WeaveConstraints` stored
/// pins and tagged loops for two phases while nothing supplied them, and a test that
/// asserted only "the solve succeeded with pins supplied" would have passed throughout
/// that entire period. So the assertions here are about pins CHANGING something, not
/// about solves returning non-nil.
@Suite("Authored constraints reach a region solve")
struct ConstraintBridgeTests {
    private func mesh(fromOBJ text: String) throws -> Mesh {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-\(UUID().uuidString).obj")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// A 6x6 quad grid: face (i,j) is i*6 + j, vertex (i,j) is i*7 + j.
    private func grid66() throws -> Mesh {
        var obj = ""
        for i in 0...6 {
            for j in 0...6 { obj += "v \(i) \(j) 0\n" }
        }
        for i in 0..<6 {
            for j in 0..<6 {
                let v = { (a: Int, b: Int) in a * 7 + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        return try mesh(fromOBJ: obj)
    }

    /// The centre 4x4 block, whose interior vertices are strictly inside the region.
    private var centreBlock: [UInt32] {
        var faces: [UInt32] = []
        for i in 1...4 {
            for j in 1...4 { faces.append(UInt32(i * 6 + j)) }
        }
        return faces
    }

    private func vertex(_ i: Int, _ j: Int) -> UInt32 { UInt32(i * 7 + j) }

    // MARK: - Classification

    @Test("An interior pin freezes its one-ring; an interface pin becomes a prescription")
    func classification() throws {
        let source = try grid66()
        let region = centreBlock

        // Vertex (3,3) is surrounded entirely by centre-block faces -> interior.
        let interior = try RegionWeaveSolverProbe.resolve(
            source: source, region: region, pinned: [vertex(3, 3)]
        )
        #expect(interior.interiorPinned == [vertex(3, 3)])
        #expect(interior.interfacePinned.isEmpty)
        // Its four incident faces left the region.
        #expect(interior.regionFaces.count == region.count - 4)

        // Vertex (1,1) is a corner of the block: it also touches faces outside it.
        let onInterface = try RegionWeaveSolverProbe.resolve(
            source: source, region: region, pinned: [vertex(1, 1)]
        )
        #expect(onInterface.interfacePinned == [vertex(1, 1)])
        #expect(onInterface.interiorPinned.isEmpty)
        #expect(onInterface.regionFaces.count == region.count, "no face should be frozen")
        // Prescribed at its authored valence, so an authored pole is not "irregular".
        #expect(onInterface.valence[vertex(1, 1)] == source.vertexFaceCount(vertex(1, 1)))
    }

    @Test("A pin outside the region is ignored")
    func outsideRegionIgnored() throws {
        let source = try grid66()
        let resolved = try RegionWeaveSolverProbe.resolve(
            source: source, region: centreBlock, pinned: [vertex(0, 0)]
        )
        #expect(resolved.interiorPinned.isEmpty)
        #expect(resolved.interfacePinned.isEmpty)
        #expect(resolved.regionFaces.count == centreBlock.count)
        #expect(resolved.valence.isEmpty)
    }

    @Test("An explicit caller override beats a pin's inferred prescription")
    func overrideWins() throws {
        let source = try grid66()
        let pin = vertex(1, 1)
        let authored = try #require(source.vertexFaceCount(pin))
        let resolved = try RegionWeaveSolverProbe.resolve(
            source: source, region: centreBlock, pinned: [pin], overrides: [pin: authored + 5]
        )
        // Assert the path RAN as well as the outcome. Checking only the value passes
        // vacuously when pins are ignored entirely, since the override is copied in
        // either way — caught by mutation-testing this suite.
        #expect(resolved.interfacePinned == [pin], "the pin must have been classified")
        #expect(
            resolved.valence[pin] == authored + 5,
            "the caller's explicit override must survive; a pin is the weaker signal"
        )
    }

    @Test("A stale pin id is skipped, not fatal")
    func stalePinSkipped() throws {
        let source = try grid66()
        let resolved = try RegionWeaveSolverProbe.resolve(
            source: source, region: centreBlock, pinned: [999_999]
        )
        #expect(resolved.interiorPinned.isEmpty)
        #expect(resolved.regionFaces.count == centreBlock.count)
    }

    // MARK: - The pin actually changes the solve (task 1.4)

    @Test("An interior pin changes the solve and survives it exactly")
    func interiorPinIsHonoured() throws {
        let solver = RegionWeaveSolver()
        let pin = vertex(3, 3)

        let unpinnedSource = try grid66()
        let pinnedSource = try grid66()
        let before = try #require(pinnedSource.vertexPosition(pin))

        let unpinned = try #require(
            try solver.solve(
                source: unpinnedSource, region: .faces(centreBlock),
                constraints: WeaveConstraints(), params: SolverParameters(),
                onProgress: nil, isCancelled: { false }
            )
        )
        let pinned = try #require(
            try solver.solve(
                source: pinnedSource, region: .faces(centreBlock),
                constraints: WeaveConstraints(pinnedVertices: [pin]),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        )

        // The load-bearing assertion: a pin that changed NOTHING is indistinguishable
        // from a pin that was silently discarded, which is the bug this guards.
        #expect(
            pinned.mesh.faceCount != unpinned.mesh.faceCount
                || pinned.addedFaces.count != unpinned.addedFaces.count,
            "supplying a pin must change the solve; identical output means it was dropped"
        )

        // And the pin's own geometry is preserved bitwise, since its ring was frozen.
        let after = try #require(pinned.mesh.vertexPosition(pin))
        #expect(after == before, "a pinned vertex must not move")
    }

    @Test("Pinning every vertex of the region refuses instead of solving nothing")
    func fullyPinnedRegionRefuses() throws {
        let source = try grid66()
        var allVertices: Set<UInt32> = []
        for face in centreBlock { allVertices.formUnion(source.faceVertices(face)) }

        #expect(throws: (any Error).self) {
            _ = try RegionWeaveSolver().solve(
                source: source, region: .faces(centreBlock),
                constraints: WeaveConstraints(pinnedVertices: allVertices.sorted()),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        }
    }

    // MARK: - Inertness (task 4.2)

    @Test("No annotations means byte-identical to a solve with none supplied")
    func emptyAnnotationsAreInert() throws {
        let solver = RegionWeaveSolver()
        let plain = try #require(
            try solver.solve(
                source: try grid66(), region: .faces(centreBlock),
                constraints: WeaveConstraints(), params: SolverParameters(),
                onProgress: nil, isCancelled: { false }
            )
        )
        let explicitlyEmpty = try #require(
            try solver.solve(
                source: try grid66(), region: .faces(centreBlock),
                constraints: WeaveConstraints(taggedLoops: [], pinnedVertices: []),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        )
        #expect(
            try plain.mesh.payloadData() == explicitlyEmpty.mesh.payloadData(),
            "the bridge must be provably inert when nothing is authored"
        )
    }

    @Test("An interface pin does not weaken exact landing")
    func interfacePinKeepsExactLanding() throws {
        let source = try grid66()
        let pin = vertex(1, 1)
        let before = try #require(source.vertexPosition(pin))

        let ghost = try #require(
            try RegionWeaveSolver().solve(
                source: source, region: .faces(centreBlock),
                constraints: WeaveConstraints(pinnedVertices: [pin]),
                params: SolverParameters(), onProgress: nil, isCancelled: { false }
            )
        )
        // 5.3's guarantee must still hold with pins in play: bitwise, not epsilon.
        let after = try #require(ghost.mesh.vertexPosition(pin))
        #expect(after == before)
        #expect(ghost.interfaceVertices.contains(pin))
    }
}

/// Multi-axis mirror symmetry in a whole-mesh solve (task 5.2).
///
/// Radial is deliberately NOT here: it does not reduce to half-space clipping and is
/// split out as 5.2b. Testing it against this implementation would only assert that a
/// radial setting is currently ignored.
@Suite("Multi-axis symmetry")
struct MultiAxisSymmetryTests {
    /// A grid spanning both sides of x = 0 and y = 0, so clipping to an orthant has
    /// something to remove on either axis.
    private func centredGrid() throws -> Mesh {
        var obj = ""
        let n = 6
        for i in 0...n {
            for j in 0...n {
                obj += "v \(Float(i) - 3) \(Float(j) - 3) 0\n"
            }
        }
        for i in 0..<n {
            for j in 0..<n {
                let v = { (a: Int, b: Int) in a * (n + 1) + b + 1 }
                obj += "f \(v(i, j)) \(v(i + 1, j)) \(v(i + 1, j + 1)) \(v(i, j + 1))\n"
            }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sym-\(UUID().uuidString).obj")
        try obj.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        return try Mesh.loadOBJ(at: url)
    }

    /// The COARSE preset (600 quads), not `SolverParameters()`. The bare initialiser
    /// inherits the engine's raw default of 50 000 target quads, which on a 36-face grid
    /// makes every solve here enormously slow for no added coverage — the property under
    /// test is whether an extra mirror axis changes the output, not how fine it is.
    private static let budget = SolverParameters.coarse

    private func solve(_ settings: SymmetrySettings) throws -> SolverGhost? {
        try EngineRemeshSolver().solve(
            source: try centredGrid(), region: .wholeMesh,
            constraints: WeaveConstraints(symmetry: settings),
            params: Self.budget, onProgress: nil, isCancelled: { false }
        )
    }

    @Test("Two axes clip to a quadrant, so the result differs from one axis")
    func twoAxesDifferFromOne() throws {
        // The assertion that matters: if the second axis were ignored — the behaviour
        // before this change — these two solves would be identical.
        let oneAxis = try #require(
            try solve(SymmetrySettings(mirrorAxes: [.x], isEnabled: true))
        )
        let twoAxes = try #require(
            try solve(SymmetrySettings(mirrorAxes: [.x, .y], isEnabled: true))
        )
        #expect(
            try oneAxis.mesh.payloadData() != twoAxes.mesh.payloadData(),
            "adding a mirror axis must change the result; identical output means it was ignored"
        )
    }

    @Test("Symmetry disabled, or no axes, leaves the solve alone")
    func inertWhenOff() throws {
        let plain = try #require(
            try EngineRemeshSolver().solve(
                source: try centredGrid(), region: .wholeMesh,
                constraints: WeaveConstraints(), params: Self.budget,
                onProgress: nil, isCancelled: { false }
            )
        )
        // isEnabled == false must be inert even with axes configured, since the master
        // switch deliberately KEEPS the user's axis setup when toggled off.
        let disabled = try #require(
            try solve(SymmetrySettings(mirrorAxes: [.x, .y], isEnabled: false))
        )
        #expect(try plain.mesh.payloadData() == disabled.mesh.payloadData())

        let noAxes = try #require(try solve(SymmetrySettings(mirrorAxes: [], isEnabled: true)))
        #expect(try plain.mesh.payloadData() == noAxes.mesh.payloadData())
    }

    @Test("A three-axis setting is accepted and clips to an octant")
    func threeAxes() throws {
        let three = try #require(
            try solve(SymmetrySettings(mirrorAxes: [.x, .y, .z], isEnabled: true))
        )
        // The grid is planar at z = 0, so the z plane passes through every vertex and
        // clips nothing on its own — but it must not throw or empty the mesh.
        #expect(three.mesh.faceCount > 0)
    }
}

/// Frozen-face authoring (task 3). The solver half already worked; these cover the
/// annotation state that now carries it, and the trap that came with adding a field.
@Suite("Frozen faces are authorable")
struct FrozenFaceAnnotationTests {
    @Test("Freezing toggles, and a second flip undoes the first")
    func toggles() {
        let empty = MeshAnnotations()
        #expect(empty.frozenFaces.isEmpty)
        #expect(!empty.isFrozen(7))

        let frozen = empty.togglingFrozen(on: [7, 3])
        #expect(frozen.frozenFaces == [3, 7], "stored sorted, for deterministic encoding")
        #expect(frozen.isFrozen(7))
        #expect(frozen.togglingFrozen(on: [7, 3]).frozenFaces.isEmpty, "a second flip thaws")
        #expect(frozen.clearingAllFrozen().frozenFaces.isEmpty)
    }

    @Test("Freezing alone makes annotations non-empty")
    func freezingCountsAsState() {
        // `isEmpty` gates whether annotations are journaled at all, so a frozen-only
        // state reading as empty would discard the user's freeze on the next edit.
        #expect(!MeshAnnotations(frozenFaces: [1]).isEmpty)
    }

    @Test("EVERY transform preserves frozen faces")
    func everyTransformPreservesFrozenFaces() {
        // The trap this guards: each transform used to reconstruct the struct with an
        // explicit field list, so a new field silently vanished through any unrelated
        // edit — freeze a patch, toggle a pin, lose the freeze. They now route through
        // one `replacing` helper; this asserts they still do.
        let base = MeshAnnotations(
            taggedEdges: [5], tagColorIndices: [2], hiddenFaces: [9],
            pinnedVertices: [4], frozenFaces: [11, 12]
        )
        let transforms: [(String, MeshAnnotations)] = [
            ("togglingTags", base.togglingTags(on: [6], color: 1)),
            ("clearingTags", base.clearingTags(on: [5])),
            ("clearingAllTags", base.clearingAllTags()),
            ("togglingPins", base.togglingPins(on: [8])),
            ("clearingAllPins", base.clearingAllPins()),
            ("hiding", base.hiding(faces: [20])),
            ("invertingVisibility", base.invertingVisibility(allFaces: [9, 20])),
            ("showingAll", base.showingAll()),
        ]
        for (name, result) in transforms {
            #expect(result.frozenFaces == [11, 12], "\(name) dropped the frozen faces")
        }
    }

    @Test("Frozen faces survive a Codable round-trip, and older documents still decode")
    func codableRoundTrip() throws {
        let original = MeshAnnotations(pinnedVertices: [2], frozenFaces: [3, 4])
        let restored = try JSONDecoder().decode(
            MeshAnnotations.self, from: try JSONEncoder().encode(original)
        )
        #expect(restored == original)

        // A document written before this change has no `frozenFaces` key at all.
        let legacy = Data(#"{"taggedEdges":[1],"tagColorIndices":[0]}"#.utf8)
        let decoded = try JSONDecoder().decode(MeshAnnotations.self, from: legacy)
        #expect(decoded.frozenFaces.isEmpty)
        #expect(decoded.taggedEdges == [1])
    }
}

/// Reaches `RegionWeaveSolver.resolvePins` without making it public API. The pin
/// classification is an internal decision, but it is the part worth asserting directly:
/// through `solve` alone, an interior and an interface pin can look the same.
private enum RegionWeaveSolverProbe {
    static func resolve(
        source: Mesh, region: [UInt32], pinned: [UInt32], overrides: [UInt32: Int] = [:]
    ) throws -> RegionWeaveSolver.PinResolution {
        RegionWeaveSolver.resolvePins(
            source: source, requested: region, frozen: [], pinned: pinned, overrides: overrides
        )
    }
}
