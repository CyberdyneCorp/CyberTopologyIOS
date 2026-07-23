import Foundation

// Mesh import/export at the document level (tasks 1.5 + 3.10, spec:
// scene-pipeline). Mesh construction stays in the engine (design D1); this
// file is I/O plumbing: format dispatch, payload packaging, manifest
// entries, and export layout.
extension DocumentBundle {
    /// Import formats accepted by `importCommand(for:name:role:)`, keyed by
    /// (lowercased) file extension. glTF/GLB and USD(z) land with task 8.2.
    public enum ImportFormat: String, CaseIterable, Sendable {
        case obj
        case fbx

        public init?(url: URL) {
            self.init(rawValue: url.pathExtension.lowercased())
        }

        /// Engine-backed load for this format (design D1: the engine builds
        /// the mesh; FBX goes through the ufbx→OBJ bridge in CyberKit).
        func loadMesh(at url: URL) throws -> Mesh {
            switch self {
            case .obj: return try Mesh.loadOBJ(at: url)
            case .fbx: return try Mesh.loadFBX(at: url)
            }
        }
    }

    /// Loads a mesh file (dispatching on the URL's extension) and packages
    /// it as a journaled import command for an object named `name` with
    /// `role`. The caller records the returned command in the undo journal
    /// and applies it; nothing is mutated here.
    public func importCommand(
        for url: URL, name: String, role: DocumentManifest.Object.Role
    ) throws -> DocumentCommand {
        guard let format = ImportFormat(url: url) else {
            throw CyberKitError(
                code: .invalidArgument,
                message: "unsupported import format '.\(url.pathExtension)' "
                    + "(supported: \(ImportFormat.allCases.map(\.rawValue).joined(separator: ", ")))"
            )
        }
        let mesh = try format.loadMesh(at: url)
        let id = UUID()
        let object = DocumentManifest.Object(
            id: id,
            name: name,
            role: role,
            payloadFile: "\(id.uuidString).payload",
            counts: .init(vertices: mesh.vertexCount, faces: mesh.faceCount)
        )
        let add = DocumentCommand.addObject(object: object, payload: try mesh.payloadData())
        // Single-instance import: an existing object of the SAME role is
        // replaced, not stacked. The remove + add land as one undoable step,
        // so a single undo restores the previous object exactly. Importing
        // into an empty slot is a plain add.
        if let existing = removeObjectCommand(role: role) {
            return .compound(verb: "import.replace", commands: [existing, add])
        }
        return add
    }

    /// A `removeObject` command for the object `id`, carrying its current
    /// manifest entry and payload so undo restores it verbatim. Nil for an
    /// unknown id or one whose payload is missing.
    public func removeObjectCommand(id: UUID) -> DocumentCommand? {
        guard
            let index = manifest.objects.firstIndex(where: { $0.id == id }),
            let payload = payloads[manifest.objects[index].payloadFile]
        else { return nil }
        return .removeObject(object: manifest.objects[index], payload: payload, index: index)
    }

    /// A `removeObject` command for the FIRST object of `role` (the
    /// single-instance import slot), or nil when the slot is empty.
    public func removeObjectCommand(role: DocumentManifest.Object.Role) -> DocumentCommand? {
        guard let object = manifest.objects.first(where: { $0.role == role }) else { return nil }
        return removeObjectCommand(id: object.id)
    }

    /// Exports one object as OBJ + MTL into `directory` (created if needed).
    /// Returns the written file URLs, OBJ first.
    ///
    /// The engine writes the OBJ. An MTL sibling is guaranteed: if the
    /// engine's writer emitted no `mtllib` reference, a minimal default
    /// material is written and referenced. TODO(upstream): engine-native
    /// material export (`cyber_mesh_save_obj` writes geometry only today).
    public func exportOBJ(
        object: DocumentManifest.Object, to directory: URL
    ) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = Self.exportFilename(for: object.name)
        let objURL = directory.appendingPathComponent(base).appendingPathExtension("obj")
        let mtlURL = directory.appendingPathComponent(base).appendingPathExtension("mtl")

        try mesh(for: object).saveOBJ(to: objURL)

        var objText = try String(contentsOf: objURL, encoding: .utf8)
        if !objText.contains("mtllib ") {
            objText = "mtllib \(base).mtl\n" + objText
            try objText.write(to: objURL, atomically: true, encoding: .utf8)
        }
        if !FileManager.default.fileExists(atPath: mtlURL.path) {
            let mtl = "# CyberTopology default material\nnewmtl default\nKd 0.8 0.8 0.8\n"
            try mtl.write(to: mtlURL, atomically: true, encoding: .utf8)
        }
        return [objURL, mtlURL]
    }

    /// File-system-safe base name for an export.
    static func exportFilename(for name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }
}
