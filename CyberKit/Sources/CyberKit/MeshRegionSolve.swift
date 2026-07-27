import CyberRemesherC
import Foundation

/// Regional prescribed-boundary solve primitives (openspec add-weave-regional-solve,
/// task 11).
///
/// A region solve rewrites a SUBSET of a mesh's faces in place while the
/// complement keeps its exact geometry, topology and element ids, so the solved
/// patch meets the existing cage on a prescribed boundary instead of replacing
/// the whole mesh.
///
/// What the engine guarantees, and what it does not:
///
/// - **Exact landing IS guaranteed.** Every interface vertex survives with the
///   same id at a bitwise-identical position, and the interface edge set is
///   preserved. The engine refuses to publish a solve that would break this.
/// - **Interface regularity is NOT guaranteed.** It is measured and reported.
///   Forcing it to zero is a coupled degree-constrained matching over the
///   interface ring, which no local pass solves — three were built and measured
///   during the design spike. Read `SolverGhost.interfaceIrregular` and decide;
///   do not assume it is empty. The guarantee is tracked as task 5.3a.
extension Mesh {

    /// The report a region solve produces. Empty on a whole-mesh solve.
    public struct RegionReport: Equatable, Sendable {
        /// Interface vertices, ascending. Their positions are bitwise unchanged.
        public var interfaceVertices: [UInt32] = []
        /// Interface vertices whose valence differs from the cage prescription.
        /// **Not an error** — see the type doc.
        public var interfaceIrregular: [UInt32] = []
        /// Non-quads touching the interface.
        public var interfaceTriangles: Int = 0
        /// Predicted interior singularity budget from the boundary charge.
        public var interiorIndexBudget: Int = 0
        /// Measured discrete-index residual; 0 means the identity balances.
        public var indexResidual: Int = 0

        public init() {}
    }

    /// Selects the faces the next remesh rewrites. Empty clears the selection.
    ///
    /// Throws `.invalidArgument` if any id is dead or repeated; the mesh is
    /// untouched on failure (the engine validates the whole array first).
    public func setSolveRegion(faces: [UInt32]) throws {
        if faces.isEmpty {
            try check(cyber_mesh_set_solve_region(handle, nil, 0))
            return
        }
        try faces.withUnsafeBufferPointer { buffer in
            try check(cyber_mesh_set_solve_region(handle, buffer.baseAddress, faces.count))
        }
    }

    /// Per-vertex prescribed TOTAL valence overrides, so a deliberately authored
    /// pole on the interface is not reported as irregular. Empty clears them.
    public func setRegionValence(_ overrides: [UInt32: Int]) throws {
        if overrides.isEmpty {
            try check(cyber_mesh_set_region_valence(handle, nil, nil, 0))
            return
        }
        let ids = overrides.keys.sorted()
        let values = ids.map { Int32(overrides[$0] ?? 4) }
        try ids.withUnsafeBufferPointer { idBuffer in
            try values.withUnsafeBufferPointer { valueBuffer in
                try check(cyber_mesh_set_region_valence(
                    handle, idBuffer.baseAddress, valueBuffer.baseAddress, ids.count
                ))
            }
        }
    }

    /// Faces produced by the region solve that made this mesh, or nil when it
    /// did not come from one. Deliberately nil rather than empty: "no region
    /// solve ran" must not read as "the region was empty".
    public func solvedFaceIDs() -> [UInt32]? {
        readRegionIDs { mesh, buffer, capacity, count in
            cyber_mesh_solved_faces(mesh, buffer, capacity, count)
        }
    }

    /// Interface vertices of the region solve that made this mesh, ascending.
    public func interfaceVertexIDs() -> [UInt32]? {
        readRegionIDs { mesh, buffer, capacity, count in
            cyber_mesh_interface_vertices(mesh, buffer, capacity, count)
        }
    }

    /// Interface vertices whose valence differs from the prescription.
    public func interfaceIrregularIDs() -> [UInt32]? {
        readRegionIDs { mesh, buffer, capacity, count in
            cyber_mesh_interface_irregular(mesh, buffer, capacity, count)
        }
    }

    /// The full region report, or nil when this mesh did not come from a
    /// region solve.
    public func regionReport() -> RegionReport? {
        var raw = CyberRegionReport()
        guard cyber_mesh_region_report(handle, &raw) == CYBER_OK else { return nil }
        var report = RegionReport()
        report.interfaceVertices = interfaceVertexIDs() ?? []
        report.interfaceIrregular = interfaceIrregularIDs() ?? []
        report.interfaceTriangles = Int(raw.interface_triangles)
        report.interiorIndexBudget = Int(raw.interior_index_budget)
        report.indexResidual = Int(raw.index_residual)
        return report
    }

    /// Number of live faces incident to `vertex`, or nil for a dead id. The
    /// valence primitive the interface guarantees are asserted with.
    public func vertexFaceCount(_ vertex: UInt32) -> Int? {
        var count: UInt32 = 0
        guard cyber_mesh_vertex_face_count(handle, vertex, &count) == CYBER_OK else { return nil }
        return Int(count)
    }

    /// An ID-PRESERVING deep copy.
    ///
    /// `payloadData()` round-trips through OBJ, which renumbers every element
    /// and writes positions at 6 significant digits — so it cannot be used to
    /// snapshot a mesh for an id-based or bitwise comparison. This can.
    public func duplicated() throws -> Mesh {
        var out: OpaquePointer?
        try check(cyber_mesh_duplicate(handle, &out))
        guard let out else { throw CyberKitError(status: CYBER_ERR_RUNTIME) }
        return Mesh(owning: out)
    }

    /// The external surface the next region solve projects its interior onto
    /// (openspec add-region-external-reference). nil clears.
    ///
    /// Without one, the region path builds its reference from the mesh it is
    /// REWRITING — for a Weave Fill that is the cage plus a grown seed band, so the
    /// solve refines the seed and reprojects onto its own approximation, losing any
    /// Target detail finer than the band. Measured on rippled geometry: 0.42 quads
    /// mean and 1.26 quads MAX interior deviation, i.e. the worst interior vertex
    /// sits more than a full quad edge off the surface it should lie on.
    ///
    /// Interface vertices are unaffected — they are never smoothed (Invariant P) — so
    /// exact landing does not depend on which surface is used.
    ///
    /// The engine builds the surface lazily and CACHES it on the reference handle,
    /// dropping it whenever that handle is mutated. That is not an optimisation:
    /// construction costs ~636 µs per 1k faces, so seconds on a multi-million-triangle
    /// Target, and a fill solves synchronously on the main actor.
    public func setRegionReference(_ reference: Mesh?) throws {
        try check(cyber_mesh_set_region_reference(handle, reference?.handle))
    }

    /// Region-scoped remesh: rewrites only `faces`, leaving every other face's
    /// geometry, ring and element id untouched. `self` is never modified.
    ///
    /// The projection surface rides the HANDLE — set `setRegionReference` on the source
    /// before calling, exactly as orientation guides are set. It is deliberately not a
    /// parameter here: `Mesh` is not `Sendable`, so threading it through the `WeaveSolving`
    /// seam would force a non-Sendable stored property into a Sendable solver.
    ///
    /// Returns nil when cancelled. Throws when the engine refuses the region —
    /// disconnected, whole-mesh, coincident duplicates, inconsistent winding — or
    /// when a solve would have broken exact landing.
    public func remeshedRegion(
        faces: [UInt32],
        parameters: RemeshParameters = RemeshParameters(),
        valenceOverrides: [UInt32: Int] = [:],
        onProgress: ((Float, String) -> Void)? = nil,
        isCancelled: (() -> Bool)? = nil
    ) throws -> Mesh? {
        // The region rides the handle, exactly like the orientation guides, so
        // it must be set on the SOURCE before the remesh reads it.
        try setSolveRegion(faces: faces)
        try setRegionValence(valenceOverrides)
        defer {
            try? setSolveRegion(faces: [])
            try? setRegionValence([:])
        }
        return try remeshed(
            parameters: parameters, onProgress: onProgress, isCancelled: isCancelled
        )
    }

    // Two-call size-then-fill over a status-returning readback. Returns nil when
    // the handle did not come from a region solve (the engine reports that as
    // CYBER_ERR_INVALID_ARG rather than a zero count).
    private func readRegionIDs(
        _ call: (OpaquePointer?, UnsafeMutablePointer<UInt32>?, Int, UnsafeMutablePointer<Int>?)
            -> CyberStatus
    ) -> [UInt32]? {
        var count = 0
        guard call(handle, nil, 0, &count) == CYBER_OK else { return nil }
        guard count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: count)
        var written = 0
        let status = ids.withUnsafeMutableBufferPointer { buffer in
            call(handle, buffer.baseAddress, count, &written)
        }
        guard status == CYBER_OK else { return nil }
        return Array(ids.prefix(written))
    }
}
