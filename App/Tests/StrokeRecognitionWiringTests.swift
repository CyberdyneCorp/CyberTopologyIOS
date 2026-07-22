import CyberKit
import CyberKitTesting
import SwiftUI
import Testing
import UIKit
@testable import CyberTopology

/// Task 3.2 app wiring: the arbiter's capture pipeline feeds completed
/// strokes into the ENGINE two-stage recognizer, interpretation records are
/// published to the model, and the DEBUG stroke HUD renders polyline +
/// record. Fixtures replay through the exact objects live input drives.
@MainActor
struct StrokeRecognitionWiringTests {
    /// Replays a fixture through the capture pipeline exactly as arbitrated
    /// live input arrives: begin with the first sample, append the rest,
    /// end. (`ViewportStrokeCapture` rebases times; fixture times already
    /// start at zero, so samples arrive unchanged at the recognizer.)
    private func replay(
        _ fixture: StrokeFixture, into capture: ViewportStrokeCapture,
        source: InputArbiter.StrokeSource = .pencil
    ) {
        var samples = fixture.samples
        let first = samples.removeFirst()
        capture.begin(source: source, verb: .pencil, sample: first)
        for sample in samples {
            capture.append(sample: sample)
        }
        capture.end()
    }

    /// The seed quad (`UITestSupport.writeSeedOBJ`) spans x/y ∈ [0, 1] at
    /// z = 0. This column-major matrix maps it onto the full normalized
    /// viewport (mesh (x, y) → screen (x, 1 - y)), so stroke coordinates
    /// address the mesh directly.
    private static let seedQuadViewProjection: [Float] = [
        2, 0, 0, 0,
        0, 2, 0, 0,
        0, 0, 0, 0,
        -1, -1, 0, 1,
    ]

    private func seedQuadMesh() throws -> Mesh {
        try Mesh.loadOBJ(at: UITestSupport.writeSeedOBJ())
    }

    // MARK: - Model → engine recognizer

    @Test func capturedStrokesFlowThroughTheEngineRecognizer() throws {
        let model = ViewportInputModel()
        let fixture = StrokeGestureCorpus.square()
        replay(fixture, into: model.controller.capture)

        let record = try #require(model.lastInterpretation)
        #expect(record.shape == .closedLoop)
        #expect(record.best?.action == .createQuad)
        #expect(record.shapeConfidence > 0)
        #expect(model.lastStrokePolyline.count == fixture.samples.count)
        #expect(model.lastStrokeSummary?.contains("-> closedLoop createQuad") == true)
    }

    @Test func fingerFallbackStrokesInterpretIdenticallyToPencil() throws {
        // Recognizer-level parity through the app capture pipeline (not
        // just the CyberKit facade): the corpus is recorded as finger
        // fixtures and the UI-test injection hooks replay them as such, so
        // finger-typed samples must interpret identically to Pencil ones.
        // (Live authoring itself is Pencil-only — task 3.9.)
        let pencilModel = ViewportInputModel()
        replay(StrokeGestureCorpus.square(), into: pencilModel.controller.capture)
        let fingerModel = ViewportInputModel()
        replay(
            StrokeGestureCorpus.square(type: .finger),
            into: fingerModel.controller.capture, source: .finger
        )
        let pencil = try #require(pencilModel.lastInterpretation)
        let finger = try #require(fingerModel.lastInterpretation)
        #expect(pencil == finger)
    }

    @Test func recognizerResolvesAgainstTheInstalledMeshContext() throws {
        let model = ViewportInputModel()
        let mesh = try seedQuadMesh()
        model.setRecognizerContext {
            (editMesh: mesh, viewProjection: Self.seedQuadViewProjection, aspect: 1)
        }

        // An X over the projected quad must resolve to delete-faces on the
        // quad's engine face id — stage 2 running against the real mesh.
        let cross = StrokeGestureCorpus.fixture(
            name: "wiring_x", expectedOutcome: "cross:deleteFaces",
            points: StrokeGestureCorpus.path(through: [
                .init(0.3, 0.3), .init(0.7, 0.7), .init(0.7, 0.3), .init(0.3, 0.7),
            ]),
            type: .pencil
        )
        replay(cross, into: model.controller.capture)

        let record = try #require(model.lastInterpretation)
        #expect(record.shape == .cross)
        #expect(record.context == .face)
        #expect(record.best?.action == .deleteFaces)
        #expect(record.best?.elements == [.init(kind: .face, id: 0)])
    }

    @Test func cancelledStrokesNeverReachTheRecognizer() throws {
        let model = ViewportInputModel()
        let capture = model.controller.capture
        capture.begin(
            source: .pencil, verb: .pencil,
            sample: .init(time: 0, x: 0.2, y: 0.2)
        )
        capture.append(sample: .init(time: 0.1, x: 0.5, y: 0.5))
        capture.cancel()
        #expect(model.lastInterpretation == nil)

        // The next completed stroke publishes normally (no stale state).
        replay(StrokeGestureCorpus.square(), into: capture)
        #expect(model.lastInterpretation?.shape == .closedLoop)
    }

    // MARK: - Debug HUD building blocks

    @Test func hudPathScalesNormalizedPolylineIntoViewSpace() {
        let polyline = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 1)]
        let path = StrokeDebugHUD.strokePath(
            for: polyline, in: CGSize(width: 200, height: 100)
        )
        #expect(!path.isEmpty)
        let box = path.boundingRect
        #expect(box.minX == 0 && box.minY == 0)
        #expect(box.maxX == 100 && box.maxY == 100)

        // Degenerate polylines draw nothing rather than asserting.
        #expect(StrokeDebugHUD.strokePath(
            for: [CGPoint(x: 0.5, y: 0.5)], in: CGSize(width: 10, height: 10)
        ).isEmpty)
    }

    @Test func hudRecordLinesListShapeContextAndRankedCandidates() {
        let record = StrokeInterpretation(
            shape: .line, shapeConfidence: 0.97, context: .vertex,
            candidates: [
                .init(
                    action: .mergeVertices, confidence: 0.9,
                    elements: [.init(kind: .vertex, id: 0), .init(kind: .vertex, id: 2)]
                ),
                .init(action: .toggleVisibility, confidence: 0.4, elements: []),
            ]
        )
        let lines = StrokeDebugHUD.recordLines(for: record)
        #expect(lines == [
            "line 0.97 on vertex",
            "1. mergeVertices 0.90 [vertex:0,vertex:2]",
            "2. toggleVisibility 0.40",
        ])
        #expect(StrokeDebugHUD.recordLines(for: nil) == ["no interpretation"])
    }

    @Test func hudViewHostsAndLaysOut() throws {
        let model = ViewportInputModel()
        replay(StrokeGestureCorpus.square(), into: model.controller.capture)
        let hud = StrokeDebugHUD(
            polyline: model.lastStrokePolyline,
            interpretation: model.lastInterpretation
        )
        let host = UIHostingController(rootView: hud)
        host.view.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        host.view.layoutIfNeeded()
        #expect(host.view.bounds.width == 400)
    }
}
