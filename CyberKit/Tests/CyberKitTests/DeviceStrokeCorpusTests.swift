import CyberKit
import Foundation
import Testing

@testable import CyberKitTesting

/// Real device-captured quad strokes (change: simplify-gesture-grammar,
/// task 1.2). Distinct from `StrokeInterpreterTests`, which drives a
/// SYNTHETIC corpus (every file matches a code generator and is asserted to
/// replay to its expected outcome). These are captured with the DEBUG
/// recorder and cannot be regenerated from code — and they currently resolve
/// to the WRONG outcome, which is the entire reason they exist.
///
/// The re-tune failed twice against synthetic strokes: a programmatic square
/// is either perfectly closed (never exercising the nearly-closed rescue) or
/// a perfect square wave (claimed by grid detection), and neither resembles a
/// hand on a Pencil. This suite is the mechanical acceptance gate for the fix
/// — every one of these must resolve to `createQuad` when the classifier
/// re-tune lands.
@Suite("Device stroke corpus")
struct DeviceStrokeCorpusTests {
    /// Captured strokes bundled under Fixtures/DeviceStrokes.
    private static var deviceStrokeURLs: [URL] {
        let urls =
            Bundle.module.urls(
                forResourcesWithExtension: "json", subdirectory: "Fixtures/DeviceStrokes"
            ) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Captured strokes whose recorded INTENT is `outcome`.
    private static func urls(intending outcome: String) throws -> [URL] {
        try deviceStrokeURLs.filter {
            try StrokeFixture(contentsOf: $0).expectedOutcome == outcome
        }
    }

    /// Replays a fixture through the engine recognizer exactly as the live
    /// capture path does — the same `StrokeRecognizerConsumer` the app uses.
    private func interpret(_ fixture: StrokeFixture) throws -> StrokeInterpretation {
        var recognizer = StrokeRecognizerConsumer(contextProvider: nil)
        StrokeReplayer.replay(fixture, into: &recognizer)
        if let error = recognizer.lastError { throw error }
        return try #require(recognizer.lastInterpretation)
    }

    /// Anti-vacuity: the bundle must actually contain the captures, or the
    /// acceptance test below would pass by iterating nothing. Four open
    /// adjacent-quad U's plus two closed smooth quads (the latter were
    /// misread as lasso until the closed path was geometry-gated and made
    /// seam-tolerant).
    @Test("the device captures are present, dense, and carry intent provenance")
    func corpusIsPresentAndIntended() throws {
        let quads = try Self.urls(intending: "createQuad")
        let deletes = try Self.urls(intending: "deleteFaces")
        #expect(quads.count == 11)
        #expect(deletes.count == 4)
        for url in quads + deletes {
            let fixture = try StrokeFixture(contentsOf: url)
            #expect(
                fixture.provenance?.contains("intended:") == true,
                "\(fixture.name) is missing its intent provenance"
            )
            // Real device strokes are dense; a handful of points would mean a
            // truncated or synthetic capture.
            #expect(fixture.samples.count > 100, "\(fixture.name) is suspiciously sparse")
        }
    }

    /// ACCEPTANCE GATE for the classifier re-tune (task 3.3): every real quad
    /// stroke must resolve to `createQuad` through the engine recognizer.
    ///
    /// These were `unknown / none` until the nearly-closed quad rescue
    /// (engine patch 0023): an open U-shaped stroke never entered the
    /// classifier's closed-shape branch, the only path to `createQuad`. The
    /// rescue, placed last so it only upgrades would-be-Unknown strokes,
    /// classifies an open stroke that bounds a recoverable quad ring as a
    /// ClosedLoop. This test was the failing-by-design gate (per-fixture
    /// `withKnownIssue`) that the rescue turned green; it is now a plain
    /// regression assertion.
    @Test("every device quad stroke resolves to createQuad")
    func deviceQuadStrokesResolveToCreateQuad() throws {
        let urls = try Self.urls(intending: "createQuad")
        try #require(!urls.isEmpty)
        for url in urls {
            let fixture = try StrokeFixture(contentsOf: url)
            let record = try interpret(fixture)
            #expect(
                record.best?.action == .createQuad,
                "\(fixture.name): got \(String(describing: record.best?.action))"
            )
            #expect(record.shape == .closedLoop, "\(fixture.name): shape \(record.shape)")
            // A quad has FOUR corners — a poor corner estimate that dropped
            // one made the face render as a triangle even though it resolved
            // to createQuad.
            #expect(record.quadCorners.count == 4, "\(fixture.name): \(record.quadCorners.count) corners")
        }
    }

    /// ACCEPTANCE GATE for the X delete gesture: four real X strokes drawn to
    /// delete faces, all previously misread as lasso/scribble (which now
    /// resolve to nothing) because the Cross test wanted exactly one crossing
    /// and at most three corners. Detection now keys on the INTERIOR
    /// (seam-tolerant) crossing count, so a wobbly hand-drawn X still reads as
    /// the delete gesture. Context-free here, so the cross has no faces to
    /// target and best is none — over real faces the cross deletes them; the
    /// invariant that matters is the SHAPE.
    @Test("every device X stroke resolves to the cross (delete) gesture")
    func deviceXStrokesResolveToCross() throws {
        let urls = try Self.urls(intending: "deleteFaces")
        try #require(!urls.isEmpty)
        for url in urls {
            let fixture = try StrokeFixture(contentsOf: url)
            let record = try interpret(fixture)
            #expect(record.shape == .cross, "\(fixture.name): shape \(record.shape)")
            #expect(record.best?.action != .createQuad, "\(fixture.name) must not create a quad")
        }
    }
}
