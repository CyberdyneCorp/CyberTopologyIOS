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

        public let id: UUID
        public var name: String
        public var role: Role
        /// File name of this object's opaque payload inside `objects/`.
        public var payloadFile: String

        public init(id: UUID = UUID(), name: String, role: Role, payloadFile: String) {
            self.id = id
            self.name = name
            self.role = role
            self.payloadFile = payloadFile
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

    public var manifest: DocumentManifest
    /// Opaque engine payload bytes, keyed by file name inside `objects/`.
    public var payloads: [String: Data]

    public init(manifest: DocumentManifest = DocumentManifest(), payloads: [String: Data] = [:]) {
        self.manifest = manifest
        self.payloads = payloads
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
        try validate()
    }

    /// Assembles the directory file wrapper for saving.
    public func fileWrapper() throws -> FileWrapper {
        try validate()
        let encoder = JSONEncoder()
        // Stable key order keeps saved manifests diffable.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        return FileWrapper(directoryWithFileWrappers: [
            Self.manifestFilename: FileWrapper(regularFileWithContents: manifestData),
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
