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

    // MARK: - Journaled commands (spec: document-model / "Unbounded undo tree")

    var canUndo: Bool { bundle.journal.canUndo }
    var canRedo: Bool { bundle.journal.canRedo }

    /// Records `command` in the undo journal and applies it. All mutating
    /// document operations go through here (task 1.4; phase 2+ tools adopt
    /// the same path).
    func perform(_ command: DocumentCommand) {
        updateBundle { bundle in
            bundle.journal.record(command)
            command.apply(to: &bundle)
        }
    }

    /// Interpretation-chip alternative swap (task 3.5, spec:
    /// pencil-interaction / "One-tap misrecognition fix"): atomically
    /// replaces the LAST journaled command — revert the old command, apply
    /// the replacement, and swap the journal node in place, all in one
    /// bundle update. Exactly one journal entry stands for the stroke after
    /// the swap, and a single undo steps back over the replacement.
    ///
    /// `expecting` guards against a stale chip: when the journal's current
    /// command is no longer the one the chip applied (an undo tap or
    /// another commit landed since), nothing is touched and the swap
    /// reports failure.
    @discardableResult
    func performReplacingLast(
        with command: DocumentCommand, expecting current: DocumentCommand
    ) -> Bool {
        guard bundle.journal.currentCommand == current else { return false }
        updateBundle { bundle in
            guard let replaced = bundle.journal.replaceCurrent(with: command) else { return }
            replaced.revert(on: &bundle)
            command.apply(to: &bundle)
        }
        return true
    }

    /// Three-finger tap. Steps the journal back one command.
    func undoLast() {
        updateBundle { bundle in
            if let command = bundle.journal.undo() {
                command.revert(on: &bundle)
            }
        }
    }

    /// Four-finger tap. Steps the journal forward along the active branch.
    func redoLast() {
        updateBundle { bundle in
            if let command = bundle.journal.redo() {
                command.apply(to: &bundle)
            }
        }
    }

    // MARK: - Mesh import/export (tasks 1.5 + 3.10, spec: scene-pipeline)

    /// Imports a mesh file (OBJ or FBX, dispatched by extension) as a new
    /// journaled object. `url` may be security-scoped (Files picker).
    func importMesh(at url: URL, role: DocumentManifest.Object.Role) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let command = try bundle.importCommand(for: url, name: name, role: role)
        perform(command)
    }

    /// Exports every EditMesh object as OBJ+MTL into the user-visible
    /// Export folder; returns the written URLs.
    func exportEditMeshes() throws -> [URL] {
        let directory = URL.documentsDirectory
            .appendingPathComponent("Export", isDirectory: true)
            .appendingPathComponent(documentName, isDirectory: true)
        var written: [URL] = []
        for object in bundle.manifest.objects where object.role == .editMesh {
            written += try bundle.exportOBJ(object: object, to: directory)
        }
        return written
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
