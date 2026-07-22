import Foundation

/// Manifest of a `.cybertopo` document package (design D4).
///
/// Serialized as `manifest.json` at the root of the bundle. Holds the schema
/// version, the stage-state placeholder, and the object list; the mesh bytes
/// themselves live in per-object payload files (see `DocumentBundle`).
public struct DocumentManifest: Codable, Equatable, Sendable {
    /// Schema version written by this build. Readers accept 1...current.
    public static let currentSchemaVersion = 1

    /// Document stages (spec: document-model / "Stage state machine").
    ///
    /// Placeholder for the full per-stage state (pins, loop tags, seams,
    /// occlusion settings, cage distances, viewport layout — task 6.1): only
    /// the active stage is persisted today; richer per-stage state will slot
    /// in beside it under the same schema-version discipline.
    public enum Stage: String, Codable, Equatable, Sendable, CaseIterable {
        case retopology = "rt"
        case uv = "uv"
        case baking = "bk"
    }

    /// One mesh object in the document (Target or EditMesh).
    public struct Object: Codable, Equatable, Sendable, Identifiable {
        /// Two-mesh architecture roles (spec: document-model).
        public enum Role: String, Codable, Equatable, Sendable {
            /// Immutable high-poly reference surface.
            case target
            /// Editable low-poly mesh.
            case editMesh
        }

        /// Topology summary captured at import time (stats readout, spec:
        /// retopology-tools) so the UI never has to deserialize a payload
        /// just to show counts. Optional: absent in pre-1.5 documents.
        public struct Counts: Codable, Equatable, Sendable {
            public let vertices: Int
            public let faces: Int

            public init(vertices: Int, faces: Int) {
                self.vertices = vertices
                self.faces = faces
            }
        }

        public let id: UUID
        public var name: String
        public var role: Role
        /// File name of this object's opaque payload inside `objects/`.
        public var payloadFile: String
        public var counts: Counts?
        /// Monotonic edit generation, bumped by every `meshEdit` command so
        /// equal-count edits (a moved vertex) still change the manifest
        /// entry — the signal manifest observers (viewport sync) key on.
        /// Optional: absent in pre-3.3 documents and for never-edited
        /// objects.
        public var revision: Int?
        /// Loop tags + partial visibility (task 3.4). Optional: absent in
        /// pre-3.4 documents and for never-annotated objects.
        public var annotations: MeshAnnotations?

        public init(
            id: UUID = UUID(), name: String, role: Role, payloadFile: String,
            counts: Counts? = nil, revision: Int? = nil,
            annotations: MeshAnnotations? = nil
        ) {
            self.id = id
            self.name = name
            self.role = role
            self.payloadFile = payloadFile
            self.counts = counts
            self.revision = revision
            self.annotations = annotations
        }
    }

    public var schemaVersion: Int
    public var stage: Stage
    public var objects: [Object]

    public init(
        schemaVersion: Int = DocumentManifest.currentSchemaVersion,
        stage: Stage = .retopology,
        objects: [Object] = []
    ) {
        self.schemaVersion = schemaVersion
        self.stage = stage
        self.objects = objects
    }
}

/// Failure modes of reading/writing a document bundle.
public enum DocumentBundleError: Error, Equatable, Sendable {
    /// The file wrapper handed to `init(fileWrapper:)` is not a directory.
    case notADirectory
    /// `manifest.json` is absent from the bundle root.
    case missingManifest
    /// The manifest declares a schema version this build cannot read.
    case unsupportedSchemaVersion(Int)
    /// An object references a payload file that is not in the bundle.
    case missingPayload(objectName: String, payloadFile: String)
}

/// In-memory model of a `.cybertopo` document package (design D4).
///
/// On-disk layout of the directory bundle:
///
///     MyDoc.cybertopo/
///       manifest.json      — schema version, stage state, object list
///       objects/
///         <payloadFile>    — one opaque engine payload per object
///
/// Payload bytes are produced and consumed exclusively by
/// `Mesh.payloadData()` / `Mesh(payloadData:)`; nothing outside CyberKit
/// interprets them, so this container survives the switch to engine-native
/// document serialization unchanged.
///
/// TODO(upstream): the engine capi has no document/serialization API with
/// persistent element IDs (required by the undo journal, design D4). When it
/// lands, the per-object payload swaps format behind the same two facade
/// calls and `schemaVersion` bumps.
public struct DocumentBundle: Equatable, Sendable {
    public static let manifestFilename = "manifest.json"
    public static let objectsDirectoryName = "objects"
    public static let journalFilename = "journal.json"

    public var manifest: DocumentManifest
    /// Opaque engine payload bytes, keyed by file name inside `objects/`.
    public var payloads: [String: Data]
    /// Undo history; persisted so it survives reopen (spec: document-model /
    /// "Unbounded undo tree" — bounded only by storage).
    public var journal: UndoJournal

    public init(
        manifest: DocumentManifest = DocumentManifest(),
        payloads: [String: Data] = [:],
        journal: UndoJournal = UndoJournal()
    ) {
        self.manifest = manifest
        self.payloads = payloads
        self.journal = journal
    }

    // MARK: - Object convenience

    /// Serializes `mesh` into the bundle and appends a manifest entry for it.
    @discardableResult
    public mutating func addObject(
        name: String, role: DocumentManifest.Object.Role, mesh: Mesh
    ) throws -> DocumentManifest.Object {
        let id = UUID()
        let payloadFile = "\(id.uuidString).payload"
        payloads[payloadFile] = try mesh.payloadData()
        let object = DocumentManifest.Object(id: id, name: name, role: role, payloadFile: payloadFile)
        manifest.objects.append(object)
        return object
    }

    /// Applies `mutate` to the manifest object with `id` (no-op when the
    /// object is absent — e.g. reverting past its deletion).
    public mutating func updateObject(
        id: UUID, _ mutate: (inout DocumentManifest.Object) -> Void
    ) {
        guard let index = manifest.objects.firstIndex(where: { $0.id == id }) else { return }
        mutate(&manifest.objects[index])
    }

    /// Deserializes the engine mesh stored for `object`.
    public func mesh(for object: DocumentManifest.Object) throws -> Mesh {
        guard let data = payloads[object.payloadFile] else {
            throw DocumentBundleError.missingPayload(
                objectName: object.name, payloadFile: object.payloadFile
            )
        }
        return try Mesh(payloadData: data)
    }

    // MARK: - FileWrapper (dis)assembly

    /// Reads a bundle from the directory file wrapper of a `.cybertopo` package.
    public init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isDirectory else { throw DocumentBundleError.notADirectory }
        let children = fileWrapper.fileWrappers ?? [:]
        guard let manifestData = children[Self.manifestFilename]?.regularFileContents else {
            throw DocumentBundleError.missingManifest
        }
        let manifest = try JSONDecoder().decode(DocumentManifest.self, from: manifestData)
        guard (1...DocumentManifest.currentSchemaVersion).contains(manifest.schemaVersion) else {
            throw DocumentBundleError.unsupportedSchemaVersion(manifest.schemaVersion)
        }

        var payloads: [String: Data] = [:]
        if let objects = children[Self.objectsDirectoryName], objects.isDirectory {
            for (name, child) in objects.fileWrappers ?? [:] {
                if let data = child.regularFileContents { payloads[name] = data }
            }
        }
        self.manifest = manifest
        self.payloads = payloads
        // A missing or corrupt journal costs undo history, never the document.
        self.journal = children[Self.journalFilename]?.regularFileContents
            .flatMap { try? JSONDecoder().decode(UndoJournal.self, from: $0) }
            ?? UndoJournal()
        try validate()
    }

    /// Assembles the directory file wrapper for saving.
    public func fileWrapper() throws -> FileWrapper {
        try validate()
        let encoder = JSONEncoder()
        // Stable key order keeps saved manifests diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let journalData = try encoder.encode(journal)
        return FileWrapper(directoryWithFileWrappers: [
            Self.manifestFilename: FileWrapper(regularFileWithContents: manifestData),
            Self.journalFilename: FileWrapper(regularFileWithContents: journalData),
            Self.objectsDirectoryName: FileWrapper(
                directoryWithFileWrappers: payloads.mapValues(FileWrapper.init(regularFileWithContents:))
            ),
        ])
    }

    /// Every manifest object must have its payload present in the bundle.
    /// (Extra payloads are tolerated: forward compatibility for readers of
    /// older schema versions.)
    public func validate() throws {
        for object in manifest.objects where payloads[object.payloadFile] == nil {
            throw DocumentBundleError.missingPayload(
                objectName: object.name, payloadFile: object.payloadFile
            )
        }
    }
}
