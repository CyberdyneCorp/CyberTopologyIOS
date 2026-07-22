import CyberRemesherC
import Foundation
import simd

// Camera-as-manipulator placement operations (task 4.2; spec:
// retopology-tools / "Core RT action roster" — Patch Clone, Extend
// Boundary, Draw Strip, Transform Vertices).
//
// Thin typed facades over the engine patch-0018/0019 capi entry points;
// every algorithm (boundary-chain walk, patch cloning with shared-vertex
// dedup, welded boundary-ring extrusion with winding correction, the
// stroke-following strip, the affine transform with the Target re-snap
// report) runs engine-side (design D1). The mutating calls follow the
// MeshEditing contract: render cache invalidated, argument failures throw
// `.invalidArgument` leaving the mesh unchanged.

/// Column-major 3x3 linear part + translation, the engine's `Affine`
/// layout. Pure value type so placement math stays headless-testable.
public struct MeshTransform: Equatable, Sendable {
    public var columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    public var translation: SIMD3<Float>

    public static let identity = MeshTransform(
        columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)),
        translation: .zero
    )

    public init(
        columns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        translation: SIMD3<Float>
    ) {
        self.columns = columns
        self.translation = translation
    }

    /// The affine (upper 3x4) part of a 4x4 world transform. The
    /// projective row is ignored — placement transforms are rigid/similar
    /// by construction (view-matrix compositions, rolls, uniform scales).
    public init(_ matrix: simd_float4x4) {
        self.init(
            columns: (
                SIMD3(matrix.columns.0.x, matrix.columns.0.y, matrix.columns.0.z),
                SIMD3(matrix.columns.1.x, matrix.columns.1.y, matrix.columns.1.z),
                SIMD3(matrix.columns.2.x, matrix.columns.2.y, matrix.columns.2.z)
            ),
            translation: SIMD3(matrix.columns.3.x, matrix.columns.3.y, matrix.columns.3.z)
        )
    }

    public func apply(_ point: SIMD3<Float>) -> SIMD3<Float> {
        columns.0 * point.x + columns.1 * point.y + columns.2 * point.z + translation
    }

    /// Rotates a direction (linear part only — no translation).
    public func applyDirection(_ direction: SIMD3<Float>) -> SIMD3<Float> {
        columns.0 * direction.x + columns.1 * direction.y + columns.2 * direction.z
    }

    /// The engine capi's 12-float layout (col0, col1, col2, translation).
    var engineFloats: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z,
            translation.x, translation.y, translation.z,
        ]
    }

    public static func == (lhs: MeshTransform, rhs: MeshTransform) -> Bool {
        lhs.columns.0 == rhs.columns.0 && lhs.columns.1 == rhs.columns.1
            && lhs.columns.2 == rhs.columns.2 && lhs.translation == rhs.translation
    }
}

extension Mesh {
    /// An ordered boundary chain (engine walk through a boundary edge).
    public struct BoundaryChain: Equatable, Sendable {
        public let vertices: [UInt32]
        public let closed: Bool
    }

    /// Walks the boundary chain through `edge` (an edge with exactly one
    /// incident face): ordered vertices in walk order, closed when the
    /// chain loops back onto its first vertex. nil when `edge` is dead or
    /// not a boundary edge. Read-only.
    public func boundaryChain(through edge: UInt32) -> BoundaryChain? {
        var closed: Int32 = 0
        let count = cyber_mesh_boundary_loop(handle, edge, nil, 0, &closed)
        guard count > 0 else { return nil }
        var vertices = [UInt32](repeating: 0, count: count)
        _ = cyber_mesh_boundary_loop(handle, edge, &vertices, count, &closed)
        return BoundaryChain(vertices: vertices, closed: closed != 0)
    }

    /// Patch Clone: duplicates `faces` (shared vertices cloned once)
    /// transformed by `transform`, new vertices snapped onto the Target
    /// when a snapper is given. `flipped` reverses every cloned face's
    /// winding (the flip option for mirroring transforms). Returns the new
    /// face ids. Throws `.invalidArgument` (mesh unchanged) on empty,
    /// dead, or repeated face ids.
    @discardableResult
    public func patchClone(
        faces: [UInt32], transform: MeshTransform, flipped: Bool = false,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> [UInt32] {
        var newFaces = [UInt32](repeating: 0, count: faces.count)
        var newCount = 0
        try faces.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_patch_clone(
                handle, buffer.baseAddress, faces.count, transform.engineFloats,
                flipped ? 1 : 0, snapper?.handle, &newFaces, &newCount
            ))
        }
        return Array(newFaces.prefix(newCount))
    }

    /// Result of one Extend Boundary ring extrusion.
    public struct BoundaryExtension: Equatable, Sendable {
        /// Number of new quads.
        public let newFaces: Int
        /// The OUTERMOST ring's vertex ids in chain order — feed back as
        /// the next call's chain to stack rings with different offsets.
        public let outerChain: [UInt32]
    }

    /// Extend Boundary (quad strips): extrudes the ordered boundary chain
    /// by `offset` in `rings` welded rows of quads (wrap quad included for
    /// closed chains), winding-corrected, snapped onto the Target when a
    /// snapper is given. Throws `.invalidArgument` (mesh unchanged) on
    /// invalid chains, rings < 1, or a zero offset.
    @discardableResult
    public func extendBoundary(
        chain: [UInt32], closed: Bool, offset: SIMD3<Float>, rings: Int = 1,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> BoundaryExtension {
        let xyz: [Float] = [offset.x, offset.y, offset.z]
        var outer = [UInt32](repeating: 0, count: chain.count)
        var newFaces = 0
        try chain.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_extend_boundary_grid(
                handle, buffer.baseAddress, chain.count, closed ? 1 : 0, xyz,
                Int32(rings), snapper?.handle, &outer, &newFaces
            ))
        }
        return BoundaryExtension(newFaces: newFaces, outerChain: outer)
    }

    /// Extend Boundary (triangle fan): closes the ordered boundary chain
    /// onto one apex at the chain centroid + `apexOffset` (snapped when a
    /// snapper is given). Returns the apex vertex id and the new face
    /// count. Throws `.invalidArgument` (mesh unchanged) on invalid
    /// chains.
    @discardableResult
    public func extendBoundaryFan(
        chain: [UInt32], closed: Bool, apexOffset: SIMD3<Float>,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> (apex: UInt32, newFaces: Int) {
        let xyz: [Float] = [apexOffset.x, apexOffset.y, apexOffset.z]
        var apex: UInt32 = 0
        var newFaces = 0
        try chain.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_extend_boundary_fan(
                handle, buffer.baseAddress, chain.count, closed ? 1 : 0, xyz,
                snapper?.handle, &apex, &newFaces
            ))
        }
        return (apex, newFaces)
    }

    /// Draw Strip: a quad strip welded onto the boundary edge
    /// `weldingOnto` whose stations follow `path` (world-space stroke
    /// samples, resampled app-side at quad-size arc length), rails
    /// spanning `width` along cross(view, tangent) with sign continuity.
    /// Returns the new face count. Throws `.invalidArgument` (mesh
    /// unchanged) on an empty path, non-positive width, a degenerate view
    /// direction, or start vertices not spanning a live boundary edge.
    @discardableResult
    public func drawStrip(
        path: [SIMD3<Float>], width: Float, viewDirection: SIMD3<Float>,
        weldingOnto edge: (UInt32, UInt32), snapping snapper: SurfaceSnapper? = nil
    ) throws -> Int {
        var xyz: [Float] = []
        xyz.reserveCapacity(path.count * 3)
        for point in path {
            xyz.append(contentsOf: [point.x, point.y, point.z])
        }
        let view: [Float] = [viewDirection.x, viewDirection.y, viewDirection.z]
        var newFaces = 0
        try xyz.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_draw_strip(
                handle, buffer.baseAddress, path.count, width, view, edge.0, edge.1,
                snapper?.handle, &newFaces
            ))
        }
        return newFaces
    }

    /// Transform Vertices' re-snap report: how many vertices the Target
    /// reprojection moved (beyond epsilon) and the farthest such move.
    public struct ResnapReport: Equatable, Sendable {
        public let resnapped: Int
        public let maxDistance: Float

        public init(resnapped: Int, maxDistance: Float) {
            self.resnapped = resnapped
            self.maxDistance = maxDistance
        }
    }

    /// Transform Vertices: applies `transform` to `vertices` in place;
    /// when a snapper is given every transformed vertex reprojects onto
    /// the Target and the re-snap report counts moves beyond
    /// `resnapEpsilon`. Throws `.invalidArgument` (mesh unchanged) on
    /// empty, dead, or repeated vertex ids.
    @discardableResult
    public func transformVertices(
        _ vertices: [UInt32], transform: MeshTransform,
        reprojecting snapper: SurfaceSnapper? = nil, resnapEpsilon: Float = 0
    ) throws -> ResnapReport {
        var resnapped = 0
        var maxDistance: Float = 0
        try vertices.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_transform_vertices(
                handle, buffer.baseAddress, vertices.count, transform.engineFloats,
                snapper?.handle, resnapEpsilon, &resnapped, &maxDistance
            ))
        }
        return ResnapReport(resnapped: resnapped, maxDistance: maxDistance)
    }
}
