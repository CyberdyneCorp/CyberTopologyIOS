import CyberKit
import CyberKitTesting
import Foundation

// Real-stroke fixture export (change: simplify-gesture-grammar, task 1.1).
//
// The gesture grammar cannot be re-tuned against synthesized strokes. Two
// attempts have been made and both misled: a programmatic square is either
// perfectly closed (never exercising the nearly-closed rescue) or a perfect
// square wave (claimed by grid detection), and neither resembles what a hand
// on a Pencil actually produces. Real device strokes measured endpoint gap
// ratios of 0.21 against a 0.22 threshold — the kind of number no one
// invents.
//
// `ViewportStrokeCapture` has been able to BUILD a `StrokeFixture` from the
// last stroke since task 1.1b, but nothing could get one off the device, so
// the corpus stayed empty and the re-tune stayed blocked. This writes the
// fixture into the app's Documents directory, which is already Files-app
// visible (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`), so
// a recorded stroke can be pulled off the iPad and committed under
// `CyberKit/Tests/CyberKitTests/Fixtures/Strokes/`.

/// Where recorded strokes land and what they are called. Pure file-name and
/// path math, unit-tested without a device.
enum StrokeFixtureExport {
    /// Subdirectory of Documents holding exported strokes. A folder rather
    /// than loose files: the Documents root is the user's DOCUMENT browser,
    /// and debug artifacts must not look like something they authored.
    static let directoryName = "RecordedStrokes"

    /// Suffix matching the committed corpus (`square_pencil.stroke.json`).
    static let fileExtension = "stroke.json"

    /// The intents a recorded stroke can be labelled with.
    ///
    /// Deliberately the three-gesture set the grammar is being cut down to,
    /// not today's nine: a fixture records what the user MEANT, and the
    /// point of the corpus is to assert that meaning survives the re-tune.
    /// A stroke the user intended as a quad is labelled `createQuad` even
    /// though the current classifier answers `createGrid` — that gap is the
    /// bug the fixture exists to pin down.
    enum Intent: String, CaseIterable, Identifiable {
        case createQuad
        case createTriangle
        case deleteFaces

        var id: String { rawValue }

        var label: String {
            switch self {
            case .createQuad: return "Quad"
            case .createTriangle: return "Triangle"
            case .deleteFaces: return "Delete faces"
            }
        }
    }

    /// The exported file's name: `<sanitized>.stroke.json`.
    ///
    /// Names reach the filesystem from a text field, so anything that is
    /// not a safe identifier collapses to an underscore. An empty or
    /// entirely unsafe name falls back rather than producing a dotfile or
    /// escaping the directory with `../`.
    static func fileName(for name: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789_-")
        let sanitized = String(
            name.lowercased().map { allowed.contains($0) ? $0 : "_" }
        )
        // Collapse runs and trim, so "quad // adjacent" is not
        // "quad___adjacent".
        let collapsed = sanitized
            .split(separator: "_", omittingEmptySubsequences: true)
            .joined(separator: "_")
        let stem = collapsed.isEmpty ? "stroke" : collapsed
        return "\(stem).\(fileExtension)"
    }

    /// Destination directory, created on demand.
    static func directory(
        inDocuments documents: URL, fileManager: FileManager = .default
    ) throws -> URL {
        let directory = documents.appendingPathComponent(directoryName, isDirectory: true)
        try fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    /// One provenance line: device, Target model, and the user's own words.
    ///
    /// Assembled here rather than left to the caller so every exported
    /// fixture carries the same fields in the same order — the corpus is
    /// meant to be read as a set, and task 1.1 requires all three.
    static func provenance(
        device: String, target: String, intent: Intent, notes: String,
        recognizedAs: String?
    ) -> String {
        var parts = [
            "device: \(device)",
            "target: \(target)",
            "intended: \(intent.rawValue)",
        ]
        // What the classifier ACTUALLY said, when it said anything. This is
        // the before-picture the re-tune is measured against, and it is
        // gone the moment the app is rebuilt.
        if let recognizedAs, !recognizedAs.isEmpty {
            parts.append("recognized: \(recognizedAs)")
        }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            parts.append("notes: \(trimmed)")
        }
        return parts.joined(separator: "; ")
    }

    /// Writes `fixture` into the recorded-strokes directory, returning the
    /// file it created. Overwrites an existing file of the same name —
    /// re-recording a stroke under the same name is a correction, not a
    /// second sample.
    @discardableResult
    static func write(
        _ fixture: StrokeFixture, inDocuments documents: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let directory = try directory(inDocuments: documents, fileManager: fileManager)
        let url = directory.appendingPathComponent(fileName(for: fixture.name))
        try fixture.write(to: url)
        return url
    }

    /// The app's Documents directory (the Files-visible one).
    static func documentsDirectory(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .documentDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
    }
}
