import CyberRemesherC
import Foundation

// Opaque per-object document payload (design D4).
//
// These two calls are the only place document payload bytes are produced or
// parsed; callers (the document bundle, the app) treat them as opaque.
//
// TODO(upstream): the engine capi exposes no in-memory serialization and no
// document container with persistent element IDs (needed by the undo journal,
// task 1.4). Until `cyber_mesh_serialize`/`cyber_mesh_deserialize` (or a
// document API) exists, the payload is the engine's own OBJ writer
// round-tripped through a scratch file — lossless for geometry, faces, and
// vertex colors, but without persistent element IDs.
extension Mesh {
    /// Serializes this mesh into an opaque document payload.
    public func payloadData() throws -> Data {
        let scratch = try Self.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("payload.obj")
        try saveOBJ(to: file)
        return try Data(contentsOf: file)
    }

    /// Deserializes a mesh from an opaque document payload produced by
    /// `payloadData()`.
    public convenience init(payloadData: Data) throws {
        let scratch = try Mesh.makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("payload.obj")
        try payloadData.write(to: file)

        var out: OpaquePointer?
        try check(cyber_mesh_load_obj(file.path, &out))
        guard let out else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        self.init(owning: out)
    }

    private static func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyberKit-payload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
