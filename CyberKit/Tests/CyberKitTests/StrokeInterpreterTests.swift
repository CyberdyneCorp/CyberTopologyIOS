import CyberKit
import Foundation
import Testing
import simd
@testable import CyberKitTesting

/// Task 3.2 (spec: pencil-interaction / "Contextual gesture grammar" first
/// stage; quality-assurance / "Gesture grammar regression suite"): the
/// committed stroke-fixture corpus replays through the REAL engine
/// recognizer (capi `cyber_stroke_interpret` — both stages run in C++),
/// classification and interpretation records are asserted, and the records
/// are golden-filed for determinism.
@Suite("Engine stroke interpreter")
struct StrokeInterpreterTests {
    // MARK: - Locations

    /// Committed corpus files (bundled test resources).
    private static var corpusURLs: [URL] {
        let urls = Bundle.module.urls(
            forResourcesWithExtension: "json", subdirectory: "Fixtures/Strokes"
        ) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Goldens live next to the test sources (host FS on the simulator).
    private static var goldensDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Goldens", isDirectory: true)
            .appendingPathComponent("Strokes", isDirectory: true)
    }

    /// Committed fixture SOURCE directory (host FS on the simulator) —
    /// where corpus regeneration writes.
    private static var fixturesSourceDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("Strokes", isDirectory: true)
    }

    private func cubeMesh() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "cube", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    /// 3x2 quad grid strip (grid32.obj): the loop-gesture fixture — its
    /// middle horizontal edge row is a 3-edge loop through two interior
    /// valence-4 vertices, and each column is an open 2-quad ring.
    private func gridMesh() throws -> Mesh {
        let url = try #require(Bundle.module.url(
            forResource: "grid32", withExtension: "obj", subdirectory: "Fixtures"
        ))
        return try Mesh.loadOBJ(at: url)
    }

    /// Orthographic-style column-major world→clip matrix mapping the cube's
    /// x/y ∈ [-0.5, 0.5] onto normalized screen [0.1, 0.9] (front and back
    /// faces overlap in screen space; picking is 2D by design).
    private static let cubeViewProjection: [Float] = [
        1.6, 0, 0, 0,
        0, 1.6, 0, 0,
        0, 0, 0, 0,
        0, 0, 0, 1,
    ]

    /// Replays a fixture through the engine recognizer exactly as the live
    /// capture path does (same `StrokeRecognizerConsumer`).
    private func interpret(
        _ fixture: StrokeFixture,
        context: StrokeRecognizerConsumer.ContextProvider? = nil
    ) throws -> StrokeInterpretation {
        var recognizer = StrokeRecognizerConsumer(contextProvider: context)
        StrokeReplayer.replay(fixture, into: &recognizer)
        if let error = recognizer.lastError { throw error }
        return try #require(recognizer.lastInterpretation)
    }

    // MARK: - Corpus provenance

    @Test("committed corpus files match their programmatic recordings exactly")
    func corpusMatchesGenerators() throws {
        // Intentional corpus changes regenerate the committed files
        // alongside the goldens (REGEN_GOLDENS=1) — same discipline, never
        // in CI. The write goes to the SOURCE directory; the bundled copies
        // refresh on the next build.
        if GoldenFile.regenerationRequested {
            try FileManager.default.createDirectory(
                at: Self.fixturesSourceDirectory, withIntermediateDirectories: true
            )
            for fixture in StrokeGestureCorpus.all {
                try fixture.write(to: Self.fixturesSourceDirectory
                    .appendingPathComponent("\(fixture.name).stroke.json"))
            }
            return
        }
        let committed = Self.corpusURLs
        #expect(committed.count == StrokeGestureCorpus.all.count)
        for fixture in StrokeGestureCorpus.all {
            let url = try #require(
                committed.first { $0.lastPathComponent == "\(fixture.name).stroke.json" },
                "missing committed fixture for \(fixture.name)"
            )
            let loaded = try StrokeFixture(contentsOf: url)
            #expect(loaded == fixture, "\(fixture.name) drifted from its generator")
        }
    }

    // MARK: - Regression suite: fixtures → engine recognizer

    @Test("every committed fixture replays through the engine recognizer to its expected outcome")
    func committedFixturesReplayThroughEngineRecognizer() throws {
        for url in Self.corpusURLs {
            let fixture = try StrokeFixture(contentsOf: url)
            let expected = fixture.expectedOutcome.split(separator: ":")
            try #require(expected.count == 2, "bad expectedOutcome in \(fixture.name)")

            let record = try interpret(fixture)
            #expect(
                record.shape.rawValue == String(expected[0]),
                "\(fixture.name): shape \(record.shape) != \(expected[0])"
            )
            #expect(
                record.best?.action.rawValue == String(expected[1]),
                "\(fixture.name): best \(String(describing: record.best?.action)) != \(expected[1])"
            )
            #expect(record.shapeConfidence > 0)
            #expect(!record.candidates.isEmpty)
        }
    }

    @Test("finger and pencil squares produce identical interpretations (injection-hook parity)")
    func fingerStrokeClassifiesIdenticallyToPencil() throws {
        let pencil = try interpret(StrokeGestureCorpus.square())
        let finger = try interpret(StrokeGestureCorpus.square(type: .finger))
        #expect(pencil == finger)
        #expect(pencil.shape == .closedLoop)
        #expect(pencil.best?.action == .createQuad)
    }

    @Test("interpretation is deterministic across repeated runs")
    func interpretationIsDeterministic() throws {
        let fixture = StrokeGestureCorpus.square()
        let first = try interpret(fixture)
        let second = try interpret(fixture)
        #expect(first == second)
    }

    /// REGRESSION: an X whose four ends come close together (the natural way
    /// a hand draws one) reads as "closed", and the closed branch used to run
    /// first and drop a self-intersecting stroke to Lasso -> hideRegion — an
    /// X that HID faces instead of deleting them. The crossing is now detected
    /// before the closed test, so every X resolves to the delete gesture.
    @Test("a closed X still resolves to the delete (cross) gesture, never hide")
    func closedXResolvesToDeleteNotHide() throws {
        // Two diagonals crossing, ending back near the start so the stroke
        // is "closed" (endpoints within closedFraction of the path length).
        let closedX = StrokeGestureCorpus.fixture(
            name: "closed_x_probe",
            expectedOutcome: "cross:none",
            points: StrokeGestureCorpus.path(through: [
                // Two diagonals crossing in the MIDDLE, ends brought back
                // near the start so the stroke reads as "closed". The crossing
                // is interior (not at the seam), so it is an X, not a quad.
                .init(0.35, 0.35), .init(0.65, 0.65), .init(0.65, 0.35),
                .init(0.35, 0.65), .init(0.36, 0.36),
            ]),
            type: .pencil
        )
        let record = try interpret(closedX)
        #expect(record.shape == .cross, "closed X shape was \(record.shape)")
        // No mesh context here, so the cross has no faces to target and best
        // is none — but crucially NOT hideRegion. Over real faces it deletes.
        #expect(record.best?.action != .hideRegion)
        // The open X fixture is unchanged.
        let openX = try interpret(StrokeGestureCorpus.cross())
        #expect(openX.shape == .cross)
    }

    // MARK: - Triangle vs quad (change simplify-gesture-grammar, task 2/user set)

    /// A closed three-corner stroke resolves to `createTriangle` with three
    /// corners, while the four-corner square stays `createQuad`. Triangle
    /// detection is conservative — three corners plus the seam count to
    /// exactly three — so a quad is never misread as a triangle.
    @Test("a three-corner closed stroke resolves to createTriangle")
    func closedTriangleResolvesToCreateTriangle() throws {
        let triangle = StrokeGestureCorpus.fixture(
            name: "triangle_probe",
            expectedOutcome: "closedLoop:createTriangle",
            points: StrokeGestureCorpus.path(through: [
                .init(0.50, 0.28), .init(0.71, 0.69), .init(0.29, 0.69),
                .init(0.50, 0.29),
            ]),
            type: .pencil
        )
        let record = try interpret(triangle)
        #expect(record.shape == .closedLoop)
        #expect(record.best?.action == .createTriangle)
        #expect(record.quadCorners.count == 3)

        // The square is unmistakably four-sided and must not regress.
        let square = try interpret(StrokeGestureCorpus.square())
        #expect(square.best?.action == .createQuad)
        #expect(square.quadCorners.count == 4)
    }

    @Test("cancelled strokes are never interpreted")
    func cancelledStrokeProducesNoInterpretation() {
        let recognizer = StrokeRecognizerConsumer()
        recognizer.strokeBegan()
        for sample in StrokeGestureCorpus.square().samples {
            recognizer.consume(sample)
        }
        recognizer.strokeCancelled()
        #expect(recognizer.lastInterpretation == nil)
        #expect(recognizer.lastError == nil)
    }

    // MARK: - Golden-filed interpretation records (determinism)

    @Test("interpretation records match the committed goldens byte for byte")
    func interpretationRecordsMatchGoldens() throws {
        // Regeneration reads the generators directly so brand-new corpus
        // entries golden on the same run (their bundled copies only exist
        // after the next build).
        let fixtures = GoldenFile.regenerationRequested
            ? StrokeGestureCorpus.all
            : try Self.corpusURLs.map(StrokeFixture.init(contentsOf:))
        for fixture in fixtures {
            let record = try interpret(fixture)
            let golden = Self.goldensDirectory
                .appendingPathComponent("\(fixture.name).interpretation.golden")
            try GoldenFile.compare(Data(record.summary.utf8), golden: golden)
        }
    }

    // MARK: - Stage 2: mesh-context resolution (real engine mesh)

    private func cubeContext() throws -> StrokeRecognizerConsumer.ContextProvider {
        let mesh = try cubeMesh()
        return { (mesh, Self.cubeViewProjection, 1) }
    }

    @Test("vertex-to-vertex line resolves to a merge of those vertices")
    func lineBetweenVerticesResolvesMerge() throws {
        // Cube corners v0 and v2 project to (0.1, 0.9) and (0.9, 0.1).
        let fixture = StrokeGestureCorpus.fixture(
            name: "merge_line", expectedOutcome: "line:mergeVertices",
            points: StrokeGestureCorpus.path(through: [
                .init(0.1, 0.9), .init(0.9, 0.1),
            ]),
            type: .pencil
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .line)
        // Context is resolved at the probe point — a line probes at its
        // midpoint, which sits over the cube face; the merge targets live in
        // the candidate's element list, not in the context field.
        #expect(record.context == .face)
        let best = try #require(record.best)
        #expect(best.action == .mergeVertices)
        #expect(best.elements.map(\.kind) == [.vertex, .vertex])
        #expect(best.elements.map(\.id) == [0, 2])
    }

    @Test("hold on a vertex resolves to tweak of that vertex")
    func holdOnVertexResolvesTweak() throws {
        // Cube corner v2 projects to (0.9, 0.1).
        var samples: [StrokeSample] = []
        for i in 0...60 {
            samples.append(StrokeSample(
                time: Double(i) / 120, x: 0.9 + 0.001 * sin(Double(i)), y: 0.1
            ))
        }
        let fixture = StrokeFixture(
            name: "hold_vertex", samples: samples, expectedOutcome: "holdPoint:tweakVertex"
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .holdPoint)
        #expect(record.context == .vertex)
        #expect(record.best?.action == .tweakVertex)
        #expect(record.best?.elements == [.init(kind: .vertex, id: 2)])
    }

    @Test("small circle over an edge resolves to rotate-edge with alternatives")
    func circleOverEdgeResolvesRotate() throws {
        // Midpoint of the cube's projected top border edge is (0.5, 0.1).
        var points: [StrokeGestureCorpus.Point] = []
        for i in 0...72 {
            let angle = 2.0 * Double.pi * Double(i) / 72
            points.append(.init(0.5 + 0.05 * cos(angle), 0.1 + 0.05 * sin(angle)))
        }
        let fixture = StrokeGestureCorpus.fixture(
            name: "rotate_circle", expectedOutcome: "circle:rotateEdge",
            points: points, type: .pencil
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .circle)
        #expect(record.context == .edge)
        let best = try #require(record.best)
        #expect(best.action == .rotateEdge)
        #expect(best.elements.count == 1)
        #expect(best.elements.first?.kind == .edge)
        // The record carries ranked alternatives (design D5).
        #expect(record.candidates.count > 1)
    }

    @Test("X over a face resolves to delete-faces")
    func crossOverFaceResolvesDelete() throws {
        let fixture = StrokeGestureCorpus.fixture(
            name: "x_on_face", expectedOutcome: "cross:deleteFaces",
            points: StrokeGestureCorpus.path(through: [
                .init(0.35, 0.35), .init(0.65, 0.65), .init(0.65, 0.35), .init(0.35, 0.65),
            ]),
            type: .pencil
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .cross)
        #expect(record.context == .face)
        let best = try #require(record.best)
        #expect(best.action == .deleteFaces)
        #expect(best.elements.first?.kind == .face)
    }

    @Test("closed square on empty surface resolves to create-quad only")
    func squareOnEmptySurfaceResolvesCreateQuad() throws {
        // Drawn entirely outside the cube's projected region.
        let fixture = StrokeGestureCorpus.fixture(
            name: "square_empty", expectedOutcome: "closedLoop:createQuad",
            points: StrokeGestureCorpus.path(through: [
                .init(1.05, 0.05), .init(1.3, 0.06), .init(1.29, 0.3),
                .init(1.04, 0.29), .init(1.06, 0.07),
            ]),
            type: .pencil
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .closedLoop)
        #expect(record.context == .emptySurface)
        #expect(record.best?.action == .createQuad)
        // hideRegion is retired from the grammar: a closed loop offers no
        // hide alternative any more.
        #expect(!record.candidates.map(\.action).contains(.hideRegion))
    }

    /// dissolveEdge is retired from the stroke grammar (it is a tool). A
    /// scribble over geometry is a DELETE gesture now — it removes the faces
    /// it covers rather than dissolving an edge under it.
    @Test("scribble over geometry resolves to deleting the covered faces")
    func scribbleOverGeometryResolvesDelete() throws {
        // Zig-zag over the cube's projected face (moving right, so it does
        // not self-cross — a Scribble, not a Cross).
        let fixture = StrokeGestureCorpus.fixture(
            name: "delete_scribble", expectedOutcome: "scribble:deleteFaces",
            points: StrokeGestureCorpus.path(through: [
                .init(0.30, 0.08), .init(0.38, 0.13), .init(0.44, 0.07),
                .init(0.52, 0.14), .init(0.58, 0.07), .init(0.66, 0.13),
            ]),
            type: .pencil
        )
        let record = try interpret(fixture, context: cubeContext())
        #expect(record.shape == .scribble)
        let best = try #require(record.best)
        #expect(best.action == .deleteFaces)
        #expect(!best.elements.isEmpty)
        #expect(best.elements.allSatisfy { $0.kind == .face })
    }

    // MARK: - Task 3.4: full grammar over committed fixtures

    /// Loads a committed corpus file by fixture name (grammar tests replay
    /// the COMMITTED bytes, not the generator, so a stale bundle fails
    /// loudly instead of testing uncommitted strokes).
    private func committedFixture(named name: String) throws -> StrokeFixture {
        let url = try #require(
            Self.corpusURLs.first { $0.lastPathComponent == "\(name).stroke.json" },
            "missing committed fixture \(name)"
        )
        return try StrokeFixture(contentsOf: url)
    }

    private func gridContext() throws -> StrokeRecognizerConsumer.ContextProvider {
        let mesh = try gridMesh()
        return { (mesh, Self.cubeViewProjection, 1) }
    }

    /// Endpoint pairs (as sets) of the edge elements of a candidate,
    /// resolved against `mesh` — stable across edge-id assignment details.
    private func endpointSets(
        of candidate: StrokeInterpretation.Candidate, in mesh: Mesh
    ) throws -> [Set<UInt32>] {
        try candidate.elements
            .filter { $0.kind == .edge }
            .map { element in
                let ends = try #require(mesh.edgeEndpoints(of: element.id))
                return Set([ends.0, ends.1])
            }
    }

    @Test("one-stroke grid classifies as grid with a 2x4 lattice estimate")
    func gridStrokeClassifiesWithLattice() throws {
        let record = try interpret(try committedFixture(named: "grid_pencil"))
        #expect(record.shape == .grid)
        #expect(record.best?.action == .createGrid)
        let grid = try #require(record.gridSize)
        #expect(grid.rows == 1)
        #expect(grid.cols == 3)
        #expect(record.quadCorners.count == (grid.rows + 1) * (grid.cols + 1))
        // Lattice sanity: row 0 near the rails' downstroke side, columns
        // ordered with the stroke (rails at x ~ 0.30/0.44/0.58/0.72).
        let xs = record.quadCorners.prefix(4).map(\.x)
        #expect(xs == xs.sorted())
    }

    /// Spec scenario "Loop insert vs loop tag disambiguation", insert half:
    /// a line ACROSS the 3x2 grid's middle column resolves to a full-ring
    /// loop insert whose elements walk the whole open ring.
    @Test("line across a face ring resolves to a FULL ring loop insert")
    func lineAcrossRingResolvesFullLoopInsert() throws {
        let mesh = try gridMesh()
        let record = try interpret(
            try committedFixture(named: "ring_insert_line_pencil"),
            context: { (mesh, Self.cubeViewProjection, 1) }
        )
        #expect(record.shape == .line)
        let best = try #require(record.best)
        #expect(best.action == .insertLoop)
        // The whole ring, not just the crossed edge (engine loop walk):
        // the middle column's three horizontal edges, bottom to top.
        let rings = try endpointSets(of: best, in: mesh)
        #expect(rings == [Set([1, 2]), Set([5, 6]), Set([9, 10])])
        // Ranked alternatives exist (the tag reading of the same stroke).
        #expect(record.candidates.map(\.action).contains(.tagLoop))
    }

    /// Spec scenario "Loop insert vs loop tag disambiguation", tag half:
    /// the same-length stroke ALONG the middle loop resolves to tagging the
    /// WHOLE loop (walked through the interior valence-4 vertices).
    @Test("line along a loop resolves to tagging the whole loop")
    func lineAlongLoopResolvesWholeLoopTag() throws {
        let mesh = try gridMesh()
        let record = try interpret(
            try committedFixture(named: "loop_tag_line_pencil"),
            context: { (mesh, Self.cubeViewProjection, 1) }
        )
        #expect(record.shape == .line)
        let best = try #require(record.best)
        #expect(best.action == .tagLoop)
        // Whole middle row (walk order runs prepend-first; compare as set).
        let loop = try endpointSets(of: best, in: mesh)
        #expect(Set(loop) == Set([Set([4, 5]), Set([5, 6]), Set([6, 7])]))
    }

    @Test("committed merge-line fixture resolves to merging its end vertices")
    func committedMergeLineResolvesMerge() throws {
        let record = try interpret(
            try committedFixture(named: "merge_line_pencil"), context: cubeContext()
        )
        let best = try #require(record.best)
        #expect(best.action == .mergeVertices)
        #expect(best.elements.map(\.kind) == [.vertex, .vertex])
        #expect(best.elements.map(\.id) == [0, 2])
    }

    /// The committed scribble fixture now deletes the faces it covers
    /// (dissolveEdge retired from the grammar), never an edge dissolve.
    @Test("committed scribble fixture resolves to deleting faces, not dissolve")
    func committedScribbleResolvesDelete() throws {
        let record = try interpret(
            try committedFixture(named: "dissolve_scribble_pencil"), context: cubeContext()
        )
        let best = try #require(record.best)
        #expect(best.action == .deleteFaces)
        #expect(best.elements.allSatisfy { $0.kind == .face })
    }

    @Test("committed rotate-circle fixture resolves to rotate-edge")
    func committedRotateCircleResolvesRotate() throws {
        let record = try interpret(
            try committedFixture(named: "rotate_circle_pencil"), context: cubeContext()
        )
        #expect(record.shape == .circle)
        let best = try #require(record.best)
        #expect(best.action == .rotateEdge)
        #expect(best.elements.first?.kind == .edge)
    }

    /// X over a region: every face whose centroid lies under the X's
    /// footprint is listed (the cube's overlapping front/back faces), not
    /// just the face under the crossing point.
    @Test("committed X fixture resolves to deleting the faces under it")
    func committedCrossResolvesRegionDelete() throws {
        let record = try interpret(
            try committedFixture(named: "x_pencil"), context: cubeContext()
        )
        #expect(record.shape == .cross)
        let best = try #require(record.best)
        #expect(best.action == .deleteFaces)
        #expect(best.elements.count == 2)
        #expect(best.elements.allSatisfy { $0.kind == .face })
    }

    /// A large closed stroke that used to be the hide gesture now resolves
    /// to createQuad — hideRegion is retired from the stroke grammar (it is
    /// a tool). This fixture stays as the proof that hide is truly gone.
    @Test("committed hide-lasso fixture now resolves to createQuad, never hide")
    func committedHideLassoResolvesQuad() throws {
        let record = try interpret(
            try committedFixture(named: "hide_lasso_pencil"), context: cubeContext()
        )
        #expect(record.shape == .closedLoop)
        #expect(record.best?.action == .createQuad)
        #expect(!record.candidates.map(\.action).contains(.hideRegion))
    }

    @Test("committed tap fixture resolves to tweak of the vertex under it")
    func committedTapResolvesTweakVertex() throws {
        let record = try interpret(
            try committedFixture(named: "double_tap_pencil"), context: cubeContext()
        )
        #expect(record.shape == .holdPoint)
        #expect(record.best?.action == .tweakVertex)
        #expect(record.best?.elements == [.init(kind: .vertex, id: 2)])
    }

    /// A straight line over mesh elements that matches no grammar rule must
    /// NOT offer toggle-visibility (that gesture lives in empty space); the
    /// stage-1-only replay of the same fixture still does.
    @Test("visibility line offer is restricted to empty space")
    func visibilityLineRequiresEmptySpace() throws {
        let fixture = try committedFixture(named: "line_down_pencil")
        let overFace = try interpret(fixture, context: cubeContext())
        #expect(overFace.context == .face)
        #expect(overFace.best?.action == StrokeInterpretation.Action.none)
        let emptyStage1 = try interpret(fixture)
        #expect(emptyStage1.best?.action == .toggleVisibility)
    }

    // MARK: - Quad-corner estimates (engine patch 0008 regression)

    /// Closed teardrop loop: a rounded body with one sharp tip pointing
    /// right. The tip sample maximizes BOTH the {1,1} and {1,-1} diagonal
    /// directions of the inscribed-quad fallback (no corners are detected —
    /// the tip sits on the seam the non-wrapping scan never evaluates), so
    /// the pre-dedup argmax returned the SAME point for two ring slots: a
    /// degenerate quad `createFace` rightly rejects, silently dropping the
    /// user's stroke. The fallback must return four spatially distinct
    /// corners.
    @Test("inscribed-quad fallback never repeats a corner (teardrop loop)")
    func fallbackQuadCornersAreDistinct() throws {
        let samples = Self.teardropSamples()
        let record = try StrokeInterpreter.interpret(samples: samples)
        let corners = record.quadCorners
        try #require(corners.count == 4)
        for i in 0..<corners.count {
            for j in (i + 1)..<corners.count {
                let distance = simd_distance(corners[i], corners[j])
                #expect(
                    distance > 1e-3,
                    "corners \(i) and \(j) coincide (\(corners[i]) vs \(corners[j]))"
                )
            }
        }
    }

    /// Teardrop polyline in normalized viewport coordinates: apex at
    /// (0.8, 0.5), tangent lines to a circle of radius 0.12 centered at
    /// (0.35, 0.5), closed one step short of the apex (still well within
    /// the closed-stroke tolerance).
    private static func teardropSamples() -> [StrokeInterpreter.Sample] {
        let center = SIMD2<Double>(0.35, 0.5)
        let radius = 0.12
        let apex = SIMD2<Double>(0.8, 0.5)
        let distance = simd_length(apex - center)
        let halfAngle = asin(radius / distance)
        let tangentLength = (distance * distance - radius * radius).squareRoot()
        let axis = atan2(center.y - apex.y, center.x - apex.x)
        let upperTangent = apex + tangentLength
            * SIMD2(cos(axis - halfAngle), sin(axis - halfAngle))
        let lowerTangent = apex + tangentLength
            * SIMD2(cos(axis + halfAngle), sin(axis + halfAngle))

        var points: [SIMD2<Double>] = []
        for i in 0..<40 {
            points.append(apex + (upperTangent - apex) * (Double(i) / 40))
        }
        let upperAngle = atan2(upperTangent.y - center.y, upperTangent.x - center.x)
        var lowerAngle = atan2(lowerTangent.y - center.y, lowerTangent.x - center.x)
        if lowerAngle < upperAngle { lowerAngle += 2 * .pi }
        for i in 1...60 {
            let angle = upperAngle + (lowerAngle - upperAngle) * Double(i) / 60
            points.append(center + radius * SIMD2(cos(angle), sin(angle)))
        }
        for i in 1..<40 {  // stop one step short of the apex
            points.append(lowerTangent + (apex - lowerTangent) * (Double(i) / 40))
        }
        return points.enumerated().map { index, point in
            .init(x: point.x, y: point.y, time: Double(index) * 0.005)
        }
    }

    // MARK: - Facade validation

    @Test("empty sample list is rejected")
    func emptyStrokeIsRejected() {
        #expect(throws: CyberKitError.self) {
            _ = try StrokeInterpreter.interpret(samples: [])
        }
    }

    @Test("mesh context requires a view-projection matrix")
    func meshWithoutMatrixIsRejected() throws {
        let mesh = try cubeMesh()
        #expect(throws: CyberKitError.self) {
            _ = try StrokeInterpreter.interpret(
                samples: [.init(x: 0.5, y: 0.5, time: 0)], editMesh: mesh,
                viewProjection: nil
            )
        }
    }

    @Test("summary encoding is stable and lists ranked candidates")
    func summaryEncodingIsStable() throws {
        let record = try interpret(StrokeGestureCorpus.square())
        #expect(record.summary.hasPrefix("shape=closedLoop conf=0.85 context=emptySurface"))
        #expect(record.summary.contains("createQuad:0.85"))
        // Ranked: best first.
        let confidences = record.candidates.map(\.confidence)
        #expect(confidences == confidences.sorted(by: >))
    }
}
