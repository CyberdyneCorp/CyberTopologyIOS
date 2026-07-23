import CyberKit
import CyberKitTesting
import Foundation
import Testing

@testable import CyberTopology

/// Real-stroke fixture export (change: simplify-gesture-grammar, task 1.1).
///
/// The gesture re-tune is blocked on a corpus of strokes that actually
/// failed on a device — two attempts driven by synthesized strokes both
/// misled. `ViewportStrokeCapture` could already BUILD a fixture; nothing
/// could get one off the iPad, so the corpus stayed empty. These assert the
/// export path that unblocks it.
@MainActor
struct StrokeFixtureExportTests {
    private func scratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stroke-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stroke(samples: Int = 3) -> [StrokeSample] {
        (0..<samples).map {
            StrokeSample(
                time: Double($0) * 0.01, x: Double($0) / 10, y: 0.5,
                pressure: 0.4, type: .pencil
            )
        }
    }

    // MARK: - File naming

    /// Names arrive from a text field and reach the filesystem, so anything
    /// unsafe must collapse rather than escape the directory or produce a
    /// dotfile.
    @Test func unsafeNamesAreSanitizedIntoOneSafeFileName() {
        #expect(
            StrokeFixtureExport.fileName(for: "quad_adjacent_pencil")
                == "quad_adjacent_pencil.stroke.json"
        )
        // Path traversal and separators cannot survive.
        let traversal = StrokeFixtureExport.fileName(for: "../../etc/passwd")
        #expect(!traversal.contains("/"))
        #expect(!traversal.contains(".."))
        #expect(traversal == "etc_passwd.stroke.json")
        // Runs collapse instead of stuttering.
        #expect(
            StrokeFixtureExport.fileName(for: "quad // adjacent")
                == "quad_adjacent.stroke.json"
        )
        // Case is normalized, matching the committed corpus.
        #expect(StrokeFixtureExport.fileName(for: "QuadSeam") == "quadseam.stroke.json")
    }

    /// An empty or entirely unsafe name must still produce a usable file,
    /// never a bare extension or a hidden file.
    @Test func degenerateNamesFallBackRatherThanProducingADotfile() {
        #expect(StrokeFixtureExport.fileName(for: "") == "stroke.stroke.json")
        #expect(StrokeFixtureExport.fileName(for: "///") == "stroke.stroke.json")
        #expect(!StrokeFixtureExport.fileName(for: "").hasPrefix("."))
    }

    /// The suffix must match the committed corpus, or a recorded stroke
    /// will not be picked up as a fixture once it lands in the repo.
    @Test func theExtensionMatchesTheCommittedCorpus() {
        #expect(StrokeFixtureExport.fileName(for: "x").hasSuffix(".stroke.json"))
    }

    // MARK: - Round trip

    /// The whole point: what is written must decode back into an identical
    /// fixture, or the corpus records something the recognizer never saw.
    @Test func anExportedStrokeDecodesBackIdentically() throws {
        let documents = try scratchDirectory()
        let fixture = StrokeFixture(
            name: "quad_adjacent_pencil", samples: stroke(samples: 12),
            expectedOutcome: StrokeFixtureExport.Intent.createQuad.rawValue,
            provenance: "device: iPad; target: seed-target; intended: createQuad"
        )

        let url = try StrokeFixtureExport.write(fixture, inDocuments: documents)
        let reloaded = try StrokeFixture(contentsOf: url)

        #expect(reloaded == fixture)
        #expect(reloaded.samples.count == 12)
        #expect(reloaded.provenance == fixture.provenance)
    }

    /// Exports land in their own folder: the Documents root is the user's
    /// DOCUMENT browser, and debug artifacts must not appear there as
    /// something they authored.
    @Test func exportsLandInTheirOwnFolderNotTheDocumentRoot() throws {
        let documents = try scratchDirectory()
        let fixture = StrokeFixture(
            name: "seam", samples: stroke(), expectedOutcome: "createQuad"
        )

        let url = try StrokeFixtureExport.write(fixture, inDocuments: documents)

        #expect(url.deletingLastPathComponent().lastPathComponent
            == StrokeFixtureExport.directoryName)
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Nothing loose in the root.
        let root = try FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )
        #expect(root.count == 1)
    }

    /// Re-recording under the same name is a CORRECTION (the first attempt
    /// was a mis-draw), so it replaces rather than accumulating junk the
    /// user then has to tell apart.
    @Test func reRecordingTheSameNameReplacesTheEarlierFile() throws {
        let documents = try scratchDirectory()
        let first = StrokeFixture(
            name: "seam", samples: stroke(samples: 3), expectedOutcome: "createQuad"
        )
        let second = StrokeFixture(
            name: "seam", samples: stroke(samples: 9), expectedOutcome: "createQuad"
        )

        let a = try StrokeFixtureExport.write(first, inDocuments: documents)
        let b = try StrokeFixtureExport.write(second, inDocuments: documents)

        #expect(a == b)
        #expect(try StrokeFixture(contentsOf: b).samples.count == 9)
    }

    // MARK: - Provenance

    /// Task 1.1 requires device, Target and intent on every committed
    /// fixture: 700 anonymous coordinates cannot be re-tuned against
    /// without knowing what the hand was trying to do.
    @Test func provenanceCarriesDeviceTargetAndIntent() {
        let line = StrokeFixtureExport.provenance(
            device: "iPad", target: "seed-target",
            intent: .createQuad, notes: "U shape against the existing quad's edge",
            recognizedAs: "grid createGrid 0.43"
        )

        #expect(line.contains("device: iPad"))
        #expect(line.contains("target: seed-target"))
        #expect(line.contains("intended: createQuad"))
        #expect(line.contains("notes: U shape against the existing quad's edge"))
    }

    /// What the classifier ACTUALLY answered is the before-picture the
    /// re-tune is measured against, and it is gone the moment the app is
    /// rebuilt — so it is recorded, not left to memory.
    @Test func provenanceRecordsWhatTheRecognizerAnswered() {
        let line = StrokeFixtureExport.provenance(
            device: "iPad", target: "t", intent: .createQuad, notes: "",
            recognizedAs: "grid createGrid 0.43"
        )
        #expect(line.contains("recognized: grid createGrid 0.43"))

        // Absent when the recognizer produced nothing at all, rather than
        // recording an empty claim.
        let unrecognized = StrokeFixtureExport.provenance(
            device: "iPad", target: "t", intent: .createQuad, notes: "", recognizedAs: nil
        )
        #expect(!unrecognized.contains("recognized:"))
    }

    /// Fixtures recorded before provenance existed must still decode — the
    /// committed corpus predates the field.
    @Test func fixturesWithoutProvenanceStillDecode() throws {
        let json = """
            {"expectedOutcome":"createQuad","name":"legacy","samples":[],"schemaVersion":1}
            """
        let fixture = try JSONDecoder().decode(
            StrokeFixture.self, from: Data(json.utf8)
        )
        #expect(fixture.name == "legacy")
        #expect(fixture.provenance == nil)
    }

    // MARK: - Capture integration

    /// The recorder exports the LAST COMPLETED stroke. A stroke still in
    /// progress is not exportable — half a gesture is not a fixture.
    @Test func onlyCompletedStrokesAreExportable() {
        let capture = ViewportStrokeCapture()
        #expect(capture.fixture(named: "n", expectedOutcome: "createQuad") == nil)

        capture.begin(
            source: .pencil, verb: .pencil,
            sample: StrokeSample(time: 0, x: 0.1, y: 0.1)
        )
        capture.append(sample: StrokeSample(time: 0.01, x: 0.2, y: 0.2))
        // Mid-stroke: nothing to export yet.
        #expect(capture.fixture(named: "n", expectedOutcome: "createQuad") == nil)

        capture.end(sample: StrokeSample(time: 0.02, x: 0.3, y: 0.3))
        let fixture = capture.fixture(
            named: "n", expectedOutcome: "createQuad", provenance: "device: iPad"
        )
        #expect(fixture?.samples.count == 3)
        #expect(fixture?.provenance == "device: iPad")
    }

    /// Exported samples are rebased to t=0 like every committed fixture, so
    /// a recorded stroke replays identically regardless of when it was drawn.
    @Test func exportedSamplesAreRebasedToZero() {
        let capture = ViewportStrokeCapture()
        capture.begin(
            source: .pencil, verb: .pencil,
            sample: StrokeSample(time: 9_999, x: 0.1, y: 0.1)
        )
        capture.end(sample: StrokeSample(time: 9_999.5, x: 0.2, y: 0.2))

        let fixture = capture.fixture(named: "n", expectedOutcome: "createQuad")
        #expect(fixture?.samples.first?.time == 0)
        #expect(fixture?.samples.last?.time == 0.5)
    }
}
