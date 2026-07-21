import CyberKit
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// Exported `.cybertopo` package type (declared in Info.plist).
    static let cybertopoDocument = UTType(exportedAs: "com.cyberdynecorp.cybertopology.document")
}

/// `UIDocument` wrapper around the CyberKit document bundle (design D4).
///
/// UIKit's document machinery provides coordinated reads/writes, iCloud
/// conflict handling, and autosave scheduling: `updateBundle(_:)` registers a
/// change, and UIKit persists it at the next safe point and when the app is
/// backgrounded (the editor additionally forces an autosave on backgrounding).
final class TopoDocument: UIDocument, ObservableObject {
    static let fileExtension = "cybertopo"

    @Published private(set) var bundle = DocumentBundle()

    /// User-facing name: the file name without the package extension.
    var documentName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }

    override func contents(forType typeName: String) throws -> Any {
        try bundle.fileWrapper()
    }

    override func load(fromContents contents: Any, ofType typeName: String?) throws {
        guard let wrapper = contents as? FileWrapper else {
            throw DocumentBundleError.notADirectory
        }
        bundle = try DocumentBundle(fileWrapper: wrapper)
    }

    /// Mutates the in-memory bundle and registers the change so autosave
    /// picks it up (spec: document-model / "Autosave and session recovery").
    func updateBundle(_ mutate: (inout DocumentBundle) -> Void) {
        var copy = bundle
        mutate(&copy)
        bundle = copy
        updateChangeCount(.done)
    }

    /// "Save new version": writes the current state to a named sibling copy;
    /// the original file is untouched and this document stays open on it
    /// (spec: document-model / "Save new version").
    @discardableResult
    func saveNewVersion(named name: String) throws -> URL {
        let url = Self.uniqueDocumentURL(named: name, in: fileURL.deletingLastPathComponent())
        try bundle.fileWrapper().write(to: url, options: .atomic, originalContentsURL: nil)
        return url
    }

    /// First free `<name>.cybertopo` URL in `directory`, suffixing " 2",
    /// " 3", … on collision.
    static func uniqueDocumentURL(named name: String, in directory: URL) -> URL {
        var candidate = directory
            .appendingPathComponent(name)
            .appendingPathExtension(fileExtension)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(name) \(counter)")
                .appendingPathExtension(fileExtension)
            counter += 1
        }
        return candidate
    }

    /// Writes a brand-new empty document at `url` (no UIDocument round trip:
    /// the template is just an empty bundle).
    static func writeNewDocument(at url: URL) throws {
        try DocumentBundle().fileWrapper()
            .write(to: url, options: .atomic, originalContentsURL: nil)
    }
}
