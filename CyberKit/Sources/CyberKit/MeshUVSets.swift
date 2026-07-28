import CyberRemesherC
import Foundation

/// Multiple UV sets per mesh (openspec add-uv-sets, 6.7a; spec: uv-workflow / "UDIMs and multiple
/// UV sets").
///
/// The ACTIVE set is the ordinary per-corner UV attribute every other UV operation reads and
/// writes, so nothing else in `MeshUV` needs to know sets exist and none of it can read the wrong
/// one. Switching sets swaps the underlying columns.
extension Mesh {
    /// Every set's name, ascending.
    ///
    /// Ascending so a serialized set list is deterministic — the same document must not save
    /// differently run to run.
    public func uvSetNames() -> [String] {
        (0..<cyber_mesh_uv_set_count(handle)).compactMap { index in
            var length = 0
            guard cyber_mesh_uv_set_name(handle, index, nil, 0, &length) == CYBER_OK,
                length > 1
            else { return nil }
            var buffer = [CChar](repeating: 0, count: length)
            guard cyber_mesh_uv_set_name(handle, index, &buffer, length, &length) == CYBER_OK
            else { return nil }
            return String(cString: buffer)
        }
    }

    /// The active set's name.
    public func activeUVSetName() -> String? {
        var length = 0
        guard cyber_mesh_uv_set_active(handle, nil, 0, &length) == CYBER_OK, length > 1
        else { return nil }
        var buffer = [CChar](repeating: 0, count: length)
        guard cyber_mesh_uv_set_active(handle, &buffer, length, &length) == CYBER_OK
        else { return nil }
        return String(cString: buffer)
    }

    /// Creates `name` as a COPY of the active set, which stays active.
    ///
    /// A copy rather than an empty set: a new UV set is nearly always a variant of the layout you
    /// already have, and an empty one would read downstream as a real layout collapsed at the
    /// origin — the absence-versus-zero trap the whole UV path avoids.
    ///
    /// Throws when there is no layout to copy, or when the name is empty, taken, or contains ':'.
    public func createUVSet(named name: String) throws {
        try check(cyber_mesh_uv_set_create(handle, name))
    }

    /// Makes `name` the active set, storing the previously active one under its own name.
    public func activateUVSet(named name: String) throws {
        try check(cyber_mesh_uv_set_activate(handle, name))
    }

    /// Deletes a set. Throws for the ACTIVE one, which would leave the mesh without a layout.
    public func deleteUVSet(named name: String) throws {
        try check(cyber_mesh_uv_set_delete(handle, name))
    }

    /// Renames a set, active or stored.
    public func renameUVSet(from: String, to: String) throws {
        try check(cyber_mesh_uv_set_rename(handle, from, to))
    }

    /// Builds a mesh from a document payload TOGETHER with its UV-set sidecar.
    ///
    /// The pairing exists in one place deliberately. The payload is OBJ, which carries exactly one
    /// `vt` channel, so **every payload round trip destroys stored UV sets** — and a mesh edit
    /// round-trips through the payload by design (that is what makes revert byte-exact). Any site
    /// that rebuilds a live mesh from payload bytes and forgets the sidecar silently drops every
    /// set but the active one, which is how this was first written and what a test caught.
    ///
    /// `uvSets` may be nil (no sidecar) and a bad sidecar is ignored rather than fatal: losing
    /// extra UV sets is recoverable, refusing to load the mesh over them is not.
    public static func fromPayload(_ payload: Data, uvSets: Data?) throws -> Mesh {
        let mesh = try Mesh(payloadData: payload)
        if let uvSets, !uvSets.isEmpty {
            try? mesh.restoreUVSets(from: uvSets)
        }
        return mesh
    }

    // MARK: - Document sidecar

    /// Serializes every UV set, for storage beside the object's payload.
    ///
    /// Needed because the payload is OBJ, which carries exactly ONE `vt` channel — so a second set
    /// cannot round-trip a save without this. The active set is included even though the payload
    /// also holds it: the payload's copy exists for export and for readers that know nothing about
    /// sets, and a sidecar missing the active set would only be complete once the payload had been
    /// parsed too.
    ///
    /// Returns nil when the mesh has only the default set and no layout, so a document with
    /// nothing to record writes no sidecar at all.
    public func uvSetsSidecarData() throws -> Data? {
        var length = 0
        try check(cyber_mesh_uv_sets_serialize(handle, nil, 0, &length))
        guard length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        try check(cyber_mesh_uv_sets_serialize(handle, &bytes, length, &length))
        return Data(bytes.prefix(length))
    }

    /// Restores UV sets from a sidecar.
    ///
    /// Throws — leaving every UV untouched — when the data is truncated, carries an unknown
    /// version, or was written for a different corner count. A UV set applied to the wrong topology
    /// shears every island, which looks plausible and is wrong.
    ///
    /// REPLACES the mesh's stored sets rather than merging, so sets from a previously loaded
    /// document cannot survive into this one.
    public func restoreUVSets(from data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { raw in
            try check(
                cyber_mesh_uv_sets_deserialize(
                    handle, raw.bindMemory(to: UInt8.self).baseAddress, data.count
                )
            )
        }
    }
}
