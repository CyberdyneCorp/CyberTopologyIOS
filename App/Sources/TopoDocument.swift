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
    @discardableResult
    func perform(_ command: DocumentCommand) -> Bool {
        // LOCK ENFORCEMENT (task 8.1). Refused here rather than by disabling buttons: a
        // disabled control is a UI convention, while a refusal at the single point every
        // NEW command passes through also stops a programmatic caller and a test driving
        // the session directly. Deliberately NOT in `DocumentCommand.apply`, which is
        // also the undo/redo and journal-replay path — history must replay faithfully,
        // and an object locked AFTER an edge was moved must not retroactively make that
        // edit unreplayable.
        if let blocked = lockedObjectBlocking(command) {
            lastRefusal = "\(blocked.name) is locked — unlock it in the outliner to edit"
            return false
        }
        lastRefusal = nil
        updateBundle { bundle in
            bundle.journal.record(command)
            command.apply(to: &bundle)
        }
        return true
    }

    /// The locked object a command would edit, or nil when it edits none.
    private func lockedObjectBlocking(_ command: DocumentCommand) -> DocumentManifest.Object? {
        let touched = command.payloadMutatedObjectIDs
        guard !touched.isEmpty else { return nil }
        return bundle.manifest.objects.first { touched.contains($0.id) && $0.isLocked }
    }

    /// Why the last `perform` was refused, or nil when it succeeded. A refusal has to be
    /// SAYABLE — silently dropping a stroke reads as the app being broken.
    private(set) var lastRefusal: String?

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

    /// Imports a low-poly mesh as a UV-ONLY project: the EditMesh with no Target, opening
    /// directly in the UV stage (openspec add-uv-only-projects, 6.1a; spec: document-model /
    /// "UV-only document without a Target").
    ///
    /// A COMPOUND command, so the import and the stage switch are ONE undo. Two separate
    /// commands would leave an undo that removed the mesh while stranding the document in a UV
    /// stage with nothing to unwrap, and a second undo needed to get back.
    ///
    /// A "project type" here is a derived BEHAVIOUR, not stored state: "an EditMesh with no
    /// Target" is the whole definition, exactly as a UDIM tile is derived from where an island's
    /// UVs are. It needs no manifest field, no second document type and no separate browser
    /// entry — the earlier scoping note claiming otherwise was wrong. Snapping is disabled for
    /// free, because `MetalViewport.syncTargetSnapper` leaves `targetSnapper` nil when the
    /// document has no Target.
    func importUVOnlyProject(at url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.deletingPathExtension().lastPathComponent
        let importCommand = try bundle.importCommand(for: url, name: name, role: .editMesh)
        let stage = bundle.manifest.stage
        guard stage != .uv else {
            // Already in UV: a compound carrying a no-op `setStage(from: .uv, to: .uv)` would
            // journal a step that changes nothing on undo.
            perform(importCommand)
            return
        }
        perform(
            .compound(
                verb: "import.uvOnlyProject",
                commands: [importCommand, .setStage(from: stage, to: .uv)]
            )
        )
    }

    /// True when this document is a UV-only project: an EditMesh and no Target.
    ///
    /// Derived, never stored — see `importUVOnlyProject`. Any document can become one by having
    /// its Target removed, and must then behave the same way, which a stored flag would not
    /// survive.
    var isUVOnlyProject: Bool {
        let objects = bundle.manifest.objects
        return objects.contains { $0.role == .editMesh }
            && !objects.contains { $0.role == .target }
    }

    /// Removes the object `id` (delete affordance) as one undoable step.
    /// No-op for an unknown id.
    func removeObject(id: UUID) {
        guard let command = bundle.removeObjectCommand(id: id) else { return }
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
