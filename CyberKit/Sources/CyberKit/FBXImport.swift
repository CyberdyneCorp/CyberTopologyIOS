import Foundation
import ufbx

// FBX import (task 3.10, spec: scene-pipeline / "Import formats").
//
// Division of labor (design D1): ufbx PARSES the file (format parsing is I/O
// plumbing and may live in CyberKit); the engine still does all mesh
// CONSTRUCTION — the parsed geometry is serialized to OBJ text and loaded
// through the engine's existing OBJ path, so the document payload format
// stays uniform with OBJ imports.
//
// TODO(upstream): engine-native FBX loading (`cyber_mesh_load_fbx` or an
// in-memory buffer entry point). When it lands, `Mesh.loadFBX` swaps its
// body and the OBJ bridge below disappears.
public enum FBXImport {
    /// Deterministic OBJ-text serialization of the FBX file's mesh geometry:
    /// positions (world-space, meters, y-up), faces exactly as ufbx reports
    /// them (triangles/quads/n-gons), and per-vertex colors where present.
    ///
    /// Multi-mesh documents are combined into ONE mesh for now — the
    /// document model has no component hierarchy yet; per-component import
    /// (outliner, "Import GLB as target" scenario) lands with the phase-8
    /// multi-object work. Instanced meshes are emitted once per instancing
    /// node, each under its node's transform.
    ///
    /// FBX color layers are usually mapped by polygon-corner; OBJ vertex
    /// colors are per-vertex, so the first corner color seen per vertex wins
    /// (exact for the common per-point case, an approximation for meshes
    /// with corner-split color seams).
    public static func objText(contentsOf url: URL) throws -> String {
        var opts = ufbx_load_opts()
        // Normalize every FBX into the app's world: meters, right-handed,
        // y-up (FBX files carry their own unit scale and axis conventions —
        // Blender exports centimeters by default).
        opts.target_axes = ufbx_axes_right_handed_y_up
        opts.target_unit_meters = 1.0
        // Untrusted-file hardening: cap ufbx allocations so a crafted FBX
        // (e.g. deflate-compressed arrays declaring multi-gigabyte
        // decompressed sizes) fails with a clean parser error (mapped to
        // .io below) instead of allocating until iPadOS jetsams the app.
        // 512 MB per allocator is far beyond any mesh this app imports.
        let memoryLimit = 512 << 20
        opts.temp_allocator.memory_limit = numericCast(memoryLimit)
        opts.result_allocator.memory_limit = numericCast(memoryLimit)

        var error = ufbx_error()
        guard let scene = ufbx_load_file(url.path, &opts, &error) else {
            throw CyberKitError(code: .io, message: Self.describe(error))
        }
        defer { ufbx_free_scene(scene) }

        var text = "# CyberKit FBX import bridge (ufbx)\n"
        var vertexOffset = 1  // OBJ face indices are 1-based
        var totalFaces = 0

        let nodes = scene.pointee.nodes
        for nodeIndex in 0..<nodes.count {
            guard let node = nodes.data[nodeIndex], node.pointee.mesh != nil else { continue }
            append(node: node.pointee, to: &text, vertexOffset: &vertexOffset, faces: &totalFaces)
        }

        guard totalFaces > 0 else {
            throw CyberKitError(code: .emptyMesh, message: "FBX contains no mesh geometry")
        }
        return text
    }

    /// Serializes one mesh-bearing node: world-space vertex lines (with the
    /// first corner color seen per vertex, when a color layer exists) and
    /// 1-based face lines.
    private static func append(
        node: ufbx_node, to text: inout String, vertexOffset: inout Int, faces totalFaces: inout Int
    ) {
        guard let mesh = node.mesh else { return }
        var toWorld = node.geometry_to_world
        let vertices = mesh.pointee.vertices
        let faces = mesh.pointee.faces
        let corners = mesh.pointee.vertex_indices
        guard vertices.count > 0, faces.count > 0 else { return }

        // ufbx preserves control characters (including newlines) in node
        // names, so the name must not reach the OBJ text verbatim: a node
        // named "evil\nv 9 9 9" would inject a phantom vertex line and
        // shift every face index. Control characters become spaces.
        let name = String(cString: node.name.data)
            .components(separatedBy: .controlCharacters).joined(separator: " ")
        text += "# mesh: \(name)\n"
        let vertexColors = firstCornerColors(of: mesh.pointee)

        for vertexIndex in 0..<vertices.count {
            let position = ufbx_transform_position(&toWorld, vertices.data[vertexIndex])
            var line = "v \(format(position.x)) \(format(position.y)) \(format(position.z))"
            if let color = vertexColors[vertexIndex] {
                line += " \(format(color.x)) \(format(color.y)) \(format(color.z))"
            }
            text += line + "\n"
        }

        for faceIndex in 0..<faces.count {
            let face = faces.data[faceIndex]
            guard face.num_indices >= 3 else { continue }  // stray edges/points
            var line = "f"
            for corner in face.index_begin..<(face.index_begin + face.num_indices) {
                line += " \(Int(corners.data[Int(corner)]) + vertexOffset)"
            }
            text += line + "\n"
            totalFaces += 1
        }
        vertexOffset += vertices.count
    }

    /// Per-vertex colors from the mesh's color layer: the first polygon
    /// corner seen per vertex wins (see `objText` doc comment). All nil when
    /// the mesh carries no color layer.
    private static func firstCornerColors(of mesh: ufbx_mesh) -> [ufbx_vec4?] {
        var colors = [ufbx_vec4?](repeating: nil, count: mesh.vertices.count)
        let layer = mesh.vertex_color
        guard layer.exists else { return colors }
        for corner in 0..<mesh.vertex_indices.count {
            let vertex = Int(mesh.vertex_indices.data[corner])
            if colors[vertex] == nil {
                colors[vertex] = layer.values.data[Int(layer.indices.data[corner])]
            }
        }
        return colors
    }

    /// Locale-independent fixed-point formatting keeps the OBJ bridge
    /// byte-deterministic (golden-filed).
    private static func format(_ value: Double) -> String {
        String(format: "%.6f", value)
    }

    private static func describe(_ error: ufbx_error) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = ufbx_format_error(&buffer, buffer.count, [error])
        return String(decoding: buffer.prefix(length).map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
}

extension Mesh {
    /// Loads an FBX (binary or ASCII) via the ufbx→OBJ bridge above; the
    /// engine builds the mesh from the bridged OBJ (design D1).
    public static func loadFBX(at url: URL) throws -> Mesh {
        let text = try FBXImport.objText(contentsOf: url)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("CyberKit-fbx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("bridge.obj")
        try text.write(to: file, atomically: true, encoding: .utf8)
        return try loadOBJ(at: file)
    }
}
