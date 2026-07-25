import CyberRemesherC
import Foundation

/// Typed RAII wrapper over the engine's opaque `CyberMesh*` handle.
///
/// Owns exactly one handle for its lifetime and releases it on deinit.
/// Not `Sendable`: a mesh belongs to whichever task created it; hand off
/// whole instances, never share one across concurrent contexts.
public final class Mesh {
    /// Topology summary as reported by the engine.
    public struct Stats: Equatable, Sendable {
        public let vertices: Int
        public let quads: Int
        public let triangles: Int
        /// Faces that are neither triangles nor quads (n-gons).
        public let other: Int
        /// Connected components.
        public let islands: Int
        /// Islands the remesher failed on (0 unless produced by `remeshed`).
        public let islandsFailed: Int
    }

    let handle: OpaquePointer

    /// Takes ownership of an engine handle.
    init(owning handle: OpaquePointer) {
        self.handle = handle
    }

    /// Creates an empty mesh.
    public convenience init() throws {
        guard let handle = cyber_mesh_create() else {
            throw CyberKitError(status: CYBER_ERR_RUNTIME)
        }
        self.init(owning: handle)
    }

    deinit {
        cyber_mesh_free(handle)
    }

    // MARK: - OBJ I/O (the only in/out path the engine C API exposes today)

    /// Loads a Wavefront OBJ (vertex colors, if present, are preserved
    /// through save round-trips).
    public static func loadOBJ(at url: URL) throws -> Mesh {
        var out: OpaquePointer?
        try check(cyber_mesh_load_obj(url.path, &out))
        guard let out else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        return Mesh(owning: out)
    }

    /// Writes the mesh to a Wavefront OBJ (a sibling .mtl may be written).
    public func saveOBJ(to url: URL) throws {
        try check(cyber_mesh_save_obj(handle, url.path))
    }

    // MARK: - Queries

    /// Number of live vertices.
    public var vertexCount: Int { cyber_mesh_vertex_count(handle) }

    /// Number of live faces.
    public var faceCount: Int { cyber_mesh_face_count(handle) }

    /// Compacted vertex positions, laid out x,y,z per vertex.
    public func positions() -> [Float] {
        let count = cyber_mesh_copy_positions(handle, nil, 0)
        guard count > 0 else { return [] }
        return [Float](unsafeUninitializedCapacity: count) { buffer, written in
            written = cyber_mesh_copy_positions(handle, buffer.baseAddress, count)
        }
    }

    /// Computes topology statistics.
    public func stats() throws -> Stats {
        var raw = CyberStats()
        try check(cyber_mesh_stats(handle, &raw))
        return Stats(
            vertices: Int(raw.vertices),
            quads: Int(raw.quads),
            triangles: Int(raw.triangles),
            other: Int(raw.other),
            islands: Int(raw.islands),
            islandsFailed: Int(raw.islandsFailed)
        )
    }

    // MARK: - Remeshing

    /// Runs the automatic quad-remeshing pipeline; `self` is not modified.
    ///
    /// The no-callback form: a remesh with no cancellation can only succeed or
    /// throw, so it returns a non-optional `Mesh`.
    public func remeshed(parameters: RemeshParameters = RemeshParameters()) throws -> Mesh {
        guard let result = try remeshed(
            parameters: parameters, onProgress: nil, isCancelled: nil
        ) else {
            throw CyberKitError(status: CYBER_ERR_RUNTIME)
        }
        return result
    }

    /// Runs the automatic quad-remeshing pipeline with progress reporting and
    /// cooperative cancellation; `self` is never modified. `onProgress` is
    /// advisory (fraction in 0…1 plus a stage label). `isCancelled` is polled
    /// by the engine between steps; when it returns `true` the remesh stops and
    /// this method returns `nil` having produced no mesh.
    public func remeshed(
        parameters: RemeshParameters = RemeshParameters(),
        onProgress: ((Float, String) -> Void)?,
        isCancelled: (() -> Bool)?
    ) throws -> Mesh? {
        var params = parameters.cParams
        var out: OpaquePointer?

        let context = RemeshCallbackContext(onProgress: onProgress, isCancelled: isCancelled)
        // Only hand the engine a non-NULL callback when a Swift closure exists,
        // so the no-callback path is byte-for-byte the previous behaviour.
        let progressCb: CyberProgressCb? = onProgress == nil ? nil : { fraction, stage, user in
            guard let user else { return }
            let ctx = Unmanaged<RemeshCallbackContext>.fromOpaque(user).takeUnretainedValue()
            ctx.onProgress?(fraction, stage.map { String(cString: $0) } ?? "")
        }
        let cancelCb: CyberCancelCb? = isCancelled == nil ? nil : { user in
            guard let user else { return 0 }
            let ctx = Unmanaged<RemeshCallbackContext>.fromOpaque(user).takeUnretainedValue()
            return (ctx.isCancelled?() ?? false) ? 1 : 0
        }
        let userPtr = Unmanaged.passUnretained(context).toOpaque()

        do {
            try withExtendedLifetime(context) {
                try check(cyber_remesh(handle, &params, progressCb, cancelCb, userPtr, &out))
            }
        } catch let error as CyberKitError where error.code == .cancelled {
            return nil
        }
        guard let out else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        return Mesh(owning: out)
    }
}

/// Boxes the Swift remesh callbacks so they can be reached from the engine's C
/// callbacks through the `void* user` context pointer.
private final class RemeshCallbackContext {
    let onProgress: ((Float, String) -> Void)?
    let isCancelled: (() -> Bool)?
    init(onProgress: ((Float, String) -> Void)?, isCancelled: (() -> Bool)?) {
        self.onProgress = onProgress
        self.isCancelled = isCancelled
    }
}

/// Typed mirror of the engine's `CyberRemeshParams`, initialized with the
/// engine defaults.
public struct RemeshParameters: Equatable, Sendable {
    /// Quadrangulation method for `RemeshParameters.quadMethod`.
    public enum QuadMethod: Int32, Equatable, Sendable {
        case fieldAligned = 0
        case instantMeshes = 1
        case integerParametrization = 2
        // Note: the engine's QuadCover method (3) shells out to an external
        // CLI and is unavailable on iOS, so it is deliberately not exposed.
    }

    public var targetQuads: Int
    public var edgeScale: Float
    public var sharpEdgeDegrees: Float
    public var smoothNormalDegrees: Float
    /// 0 = uniform … 1 = fully curvature-adaptive.
    public var adaptivity: Float
    public var pureQuads: Bool
    /// Maximum boundary edge count of holes to fill; 0 disables hole filling.
    public var holeFillMaxBoundary: Int
    public var quadMethod: QuadMethod

    /// Engine defaults (via `cyber_default_params`).
    public init() {
        var defaults = CyberRemeshParams()
        cyber_default_params(&defaults)
        targetQuads = Int(defaults.targetQuads)
        edgeScale = defaults.edgeScale
        sharpEdgeDegrees = defaults.sharpEdgeDegrees
        smoothNormalDegrees = defaults.smoothNormalDegrees
        adaptivity = defaults.adaptivity
        pureQuads = defaults.pureQuads != 0
        holeFillMaxBoundary = Int(defaults.holeFillMaxBoundary)
        quadMethod = QuadMethod(rawValue: defaults.quadMethod) ?? .fieldAligned
    }

    var cParams: CyberRemeshParams {
        CyberRemeshParams(
            targetQuads: Int32(targetQuads),
            edgeScale: edgeScale,
            sharpEdgeDegrees: sharpEdgeDegrees,
            smoothNormalDegrees: smoothNormalDegrees,
            adaptivity: adaptivity,
            pureQuads: pureQuads ? 1 : 0,
            holeFillMaxBoundary: Int32(holeFillMaxBoundary),
            quadMethod: quadMethod.rawValue
        )
    }
}
