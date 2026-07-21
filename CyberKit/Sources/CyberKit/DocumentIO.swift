import Foundation

// OBJ import/export at the document level (task 1.5, spec: scene-pipeline).
// Parsing and mesh construction stay in the engine (design D1); this file is
// I/O plumbing: payload packaging, manifest entries, and export layout.
extension DocumentBundle {
    /// Loads an OBJ from `url` and packages it as a journaled import command
    /// for an object named `name` with `role`. The caller records the
    /// returned command in the undo journal and applies it; nothing is
    /// mutated here.
    public func importCommandForOBJ(
        at url: URL, name: String, role: DocumentManifest.Object.Role
    ) throws -> DocumentCommand {
        let mesh = try Mesh.loadOBJ(at: url)
        let id = UUID()
        let object = DocumentManifest.Object(
            id: id,
            name: name,
            role: role,
            payloadFile: "\(id.uuidString).payload",
            counts: .init(vertices: mesh.vertexCount, faces: mesh.faceCount)
        )
        return .addObject(object: object, payload: try mesh.payloadData())
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
