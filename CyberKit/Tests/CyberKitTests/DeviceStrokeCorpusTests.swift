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
    /// Captured quad strokes bundled under Fixtures/DeviceStrokes.
    private static var deviceStrokeURLs: [URL] {
        let urls =
            Bundle.module.urls(
                forResourcesWithExtension: "json", subdirectory: "Fixtures/DeviceStrokes"
            ) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Replays a fixture through the engine recognizer exactly as the live
    /// capture path does — the same `StrokeRecognizerConsumer` the app uses.
    private func interpret(_ fixture: StrokeFixture) throws -> StrokeInterpretation {
        var recognizer = StrokeRecognizerConsumer(contextProvider: nil)
        StrokeReplayer.replay(fixture, into: &recognizer)
        if let error = recognizer.lastError { throw error }
        return try #require(recognizer.lastInterpretation)
    }

    /// Anti-vacuity: the bundle must actually contain the four captures, or
    /// the acceptance test below would pass by iterating nothing.
    @Test("the four device quad captures are present and every one is labelled createQuad")
    func corpusIsPresentAndIntendedAsQuads() throws {
        let urls = Self.deviceStrokeURLs
        #expect(urls.count == 4)
        for url in urls {
            let fixture = try StrokeFixture(contentsOf: url)
            #expect(fixture.expectedOutcome == "createQuad", "\(fixture.name)")
            #expect(
                fixture.provenance?.contains("intended: createQuad") == true,
                "\(fixture.name) is missing its intent provenance"
            )
            // Real device strokes are dense (hundreds of samples); a handful
            // of points would mean a truncated or synthetic capture.
            #expect(fixture.samples.count > 100, "\(fixture.name) is suspiciously sparse")
        }
    }

    /// ACCEPTANCE GATE for the classifier re-tune (task 3.3): every real quad
    /// stroke must resolve to `createQuad` through the engine recognizer.
    ///
    /// Today they do not — an open U-shaped stroke never enters the
    /// classifier's closed-shape branch, the only path to `createQuad`, and
    /// falls through to `unknown / none`. Each assertion is therefore wrapped
    /// in `withKnownIssue`: the failure is EXPECTED, so the suite stays green
    /// while the bug is documented. When the re-tune makes a stroke resolve
    /// correctly, its `withKnownIssue` sees no failure and reports it as
    /// unexpectedly passing — that is the signal to drop the wrapper and turn
    /// this into a plain regression assertion. Per-fixture wrapping (not one
    /// wrapper around the loop) is what makes that signal fire the moment a
    /// SINGLE stroke starts working.
    @Test("every device quad stroke should resolve to createQuad (known-failing until the re-tune)")
    func deviceQuadStrokesResolveToCreateQuad() throws {
        let urls = Self.deviceStrokeURLs
        try #require(!urls.isEmpty)
        for url in urls {
            let fixture = try StrokeFixture(contentsOf: url)
            withKnownIssue(
                "open U-shaped quad strokes classify as unknown until simplify-gesture-grammar task 3 lands (\(fixture.name))"
            ) {
                let record = try interpret(fixture)
                #expect(
                    record.best?.action == .createQuad,
                    "\(fixture.name): got \(String(describing: record.best?.action))"
                )
            }
        }
    }
}
