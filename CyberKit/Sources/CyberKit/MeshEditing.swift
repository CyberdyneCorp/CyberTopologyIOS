import CyberRemesherC
import Foundation
import simd

// Mesh-editing verb operations (task 3.3; specs: pencil-interaction / "Five
// coherent verbs across stages", retopology-tools, document-model / "EditMesh
// vertex snapping").
//
// Thin typed facades over the mutating capi entry points — every algorithm
// (snap projection, geodesic falloff, Laplacian relax, pressure-scaled
// erase) runs engine-side (design D1). Each call invalidates the handle's
// render cache: pointer views from `withRenderBuffers` obtained before a
// mutation are dead afterwards and must be re-fetched, and compacted render
// indices may shift — address elements by their stable engine ids only.
extension Mesh {
    /// Creates a face over 3 or 4 NEW vertices (ring order). With a snapper
    /// every vertex is projected onto the Target surface before the face is
    /// committed (continuous shrink-wrap snapping). Returns the engine face
    /// id. Throws `.invalidArgument` for degenerate rings, leaving the mesh
    /// unchanged.
    @discardableResult
    public func createFace(
        at points: [SIMD3<Float>], snapping snapper: SurfaceSnapper? = nil
    ) throws -> UInt32 {
        var xyz: [Float] = []
        xyz.reserveCapacity(points.count * 3)
        for point in points {
            xyz.append(point.x)
            xyz.append(point.y)
            xyz.append(point.z)
        }
        var face: UInt32 = 0
        try xyz.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_create_face(
                handle, buffer.baseAddress, points.count, snapper?.handle, &face
            ))
        }
        return face
    }

    /// Tweak: drops one live vertex at `target`, projected onto the Target
    /// surface when a snapper is given. Ignores pins by design.
    public func tweakVertex(
        _ vertex: UInt32, to target: SIMD3<Float>, snapping snapper: SurfaceSnapper? = nil
    ) throws {
        let xyz: [Float] = [target.x, target.y, target.z]
        try check(cyber_retopo_tweak_vertex(handle, vertex, xyz, snapper?.handle))
    }

    /// Move with surface-geodesic falloff: displaces `seed` by
    /// `displacement` with a smooth falloff over geodesic (through-the-
    /// surface) distance up to `radius`. Disconnected components are never
    /// affected; pinned vertices resist; moved vertices reproject onto the
    /// Target when a snapper is given.
    public func moveWithGeodesicFalloff(
        seed: UInt32, displacement: SIMD3<Float>, radius: Float,
        pinned: [UInt32] = [], snapping snapper: SurfaceSnapper? = nil
    ) throws {
        let xyz: [Float] = [displacement.x, displacement.y, displacement.z]
        try pinned.withUnsafeBufferPointer { pins in
            try check(cyber_retopo_move(
                handle, seed, xyz, radius, pins.baseAddress, pins.count, snapper?.handle
            ))
        }
    }

    /// Relax: tangential Laplacian smoothing inside the brush (`radius` <= 0
    /// relaxes the whole mesh). Explicit pins are honored; `autoPinCorners`
    /// additionally pins low-valence grid corners so regular patch shapes
    /// survive. Vertices reproject onto the Target when a snapper is given.
    public func relax(
        around center: SIMD3<Float>, radius: Float, strength: Float = 0.5,
        iterations: Int = 1, autoPinCorners: Bool = true, pinned: [UInt32] = [],
        snapping snapper: SurfaceSnapper? = nil
    ) throws {
        let xyz: [Float] = [center.x, center.y, center.z]
        try pinned.withUnsafeBufferPointer { pins in
            try check(cyber_retopo_relax(
                handle, xyz, radius, strength, Int32(iterations),
                autoPinCorners ? 1 : 0, pins.baseAddress, pins.count, snapper?.handle
            ))
        }
    }

    /// Erase: removes every face whose centroid lies within the pressure-
    /// scaled radius of `center` (half the base radius at pressure 0 up to
    /// 1.5x at 1), then any vertices left isolated. Returns the number of
    /// faces removed.
    @discardableResult
    public func erase(
        around center: SIMD3<Float>, baseRadius: Float, pressure: Float
    ) throws -> Int {
        let xyz: [Float] = [center.x, center.y, center.z]
        var removed = 0
        try check(cyber_retopo_erase(handle, xyz, baseRadius, pressure, &removed))
        return removed
    }

    /// Deletes the listed faces (dead ids are skipped), then any vertices
    /// left isolated. Returns the number of faces actually removed.
    @discardableResult
    public func deleteFaces(_ faces: [UInt32]) throws -> Int {
        var removed = 0
        try faces.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_delete_faces(
                handle, buffer.baseAddress, faces.count, &removed
            ))
        }
        return removed
    }

    // MARK: - Gesture grammar ops (task 3.4)

    /// Creates a CONNECTED block of quads over a row-major lattice of
    /// `(rows+1) x (cols+1)` NEW vertices (the one-stroke grid gesture) —
    /// lattice points are shared between neighboring cells, unlike
    /// repeated `createFace` calls. Every point snaps to the Target first
    /// when a snapper is given. Returns the number of created faces.
    /// Throws `.invalidArgument` (mesh unchanged) on degenerate lattices.
    @discardableResult
    public func createGrid(
        lattice: [SIMD3<Float>], rows: Int, cols: Int,
        snapping snapper: SurfaceSnapper? = nil
    ) throws -> Int {
        guard rows >= 1, cols >= 1, lattice.count == (rows + 1) * (cols + 1) else {
            throw CyberKitError(
                code: .invalidArgument,
                message: "lattice must hold (rows+1)*(cols+1) points"
            )
        }
        var xyz: [Float] = []
        xyz.reserveCapacity(lattice.count * 3)
        for point in lattice {
            xyz.append(point.x)
            xyz.append(point.y)
            xyz.append(point.z)
        }
        var faces = 0
        try xyz.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_create_grid(
                handle, buffer.baseAddress, rows, cols, snapper?.handle, &faces
            ))
        }
        return faces
    }

    /// Inserts a COMPLETE edge loop around the quad ring through `edge`
    /// ("line across a face ring"): every ring edge splits at `t` and every
    /// ring quad splits between consecutive midpoints (engine loop walk —
    /// the single-quad case degenerates to a one-quad split). Returns the
    /// number of new faces. Throws `.invalidArgument` (mesh unchanged) when
    /// `edge` is dead or borders no quad.
    @discardableResult
    public func insertLoop(acrossEdge edge: UInt32, t: Float = 0.5) throws -> Int {
        var newFaces = 0
        try check(cyber_retopo_insert_loop(handle, edge, t, &newFaces))
        return newFaces
    }

    /// Dissolves interior edges ("scribble over an edge"): each edge with
    /// exactly two live faces is removed and its faces merged (a triangle
    /// pair becomes a quad). Dead/boundary/degenerate edges are skipped.
    /// Returns the number of edges actually dissolved.
    @discardableResult
    public func dissolveEdges(_ edges: [UInt32]) throws -> Int {
        var dissolved = 0
        try edges.withUnsafeBufferPointer { buffer in
            try check(cyber_retopo_dissolve_edges(
                handle, buffer.baseAddress, edges.count, &dissolved
            ))
        }
        return dissolved
    }

    /// Merges vertex `remove` into vertex `keep` ("vertex-to-vertex line":
    /// the stroke's start vertex snaps onto its end vertex). Faces
    /// degenerated by the merge are deleted; `atMidpoint` moves the
    /// survivor to the pair's midpoint instead of keeping `keep`'s
    /// position.
    public func mergeVertices(keep: UInt32, remove: UInt32, atMidpoint: Bool = false) throws {
        try check(cyber_retopo_merge_vertices(handle, keep, remove, atMidpoint ? 1 : 0))
    }

    /// Rotates an interior edge ("circle over an edge"): a triangle pair
    /// flips its diagonal, a quad pair turns its loop-flow direction.
    /// Throws `.invalidArgument` (mesh unchanged) when the edge cannot
    /// rotate.
    public func rotateEdge(_ edge: UInt32) throws {
        try check(cyber_retopo_rotate_edge(handle, edge))
    }
}

/// One journaled mesh edit: captured at stroke start, committed at stroke
/// end (task 3.3; spec: document-model / "Unbounded undo tree" — no tool may
/// mutate outside a journaled command).
///
/// Usage: create the transaction BEFORE mutating (it pins the exact
/// before-payload bytes), run any number of verb operations on the live
/// mesh, then `command(verb:)` — which serializes the after-state and
/// returns the journal-ready `DocumentCommand`, or nil when the stroke
/// changed nothing (no empty journal entries).
public struct MeshEditTransaction {
    private let object: DocumentManifest.Object
    private let mesh: Mesh
    private let before: Data

    /// - Parameters:
    ///   - object: manifest entry of the edited object.
    ///   - mesh: the LIVE engine mesh about to be mutated. Its current state
    ///     must correspond to `currentPayload` (the document invariant: the
    ///     live mesh is only mutated through journaled commands).
    ///   - currentPayload: the object's payload bytes as stored in the
    ///     document right now — pinned verbatim so revert is byte-exact.
    public init(object: DocumentManifest.Object, mesh: Mesh, currentPayload: Data) {
        self.object = object
        self.mesh = mesh
        self.before = currentPayload
    }

    /// Serializes the mutated mesh and builds the journal command. Returns
    /// nil when the mesh serializes identically to the before-state.
    ///
    /// ANNOTATION RECONCILIATION (the reason this can return a `compound`):
    /// serializing COMPACTS element ids — the payload's OBJ writer emits
    /// only live elements, renumbered from zero — and the viewport reloads
    /// the live handle from exactly these bytes. Any operation that retired
    /// an element therefore renumbers everything after it, while the
    /// document's `MeshAnnotations` still name the OLD ids. Left alone that
    /// silently re-points pins at different vertices (see
    /// `MeshIDCompaction`). So every mesh edit carries its annotations
    /// across the compaction here, and when they change, the geometry and
    /// the annotation edit journal as ONE compound entry — one undo
    /// restores both, which is the invariant the whole journal is built on.
    ///
    /// - Parameter survivingAnnotations: an EXTRA policy applied before the
    ///   compaction (the batch commands' `AnnotationIDPolicy`, which knows
    ///   about the full-rebuild ops the compaction map cannot describe).
    public func command(
        verb: String,
        survivingAnnotations: ((MeshAnnotations?) -> MeshAnnotations?)? = nil
    ) throws -> DocumentCommand? {
        let annotationsBefore = object.annotations
        // NOT `survivingAnnotations?(before) ?? before`: optional chaining
        // flattens a policy that returns nil (which is what "everything is
        // orphaned" MEANS) into the same nil as "no policy given", and the
        // `??` would then silently restore the annotations the policy just
        // said to drop.
        let annotationsAfter: MeshAnnotations?
        if annotationsBefore?.isEmpty ?? true {
            // Nothing to orphan: no scan, and above all no spurious
            // annotation edit turning an empty record into nil.
            annotationsAfter = annotationsBefore
        } else {
            let policyApplied: MeshAnnotations?
            if let survivingAnnotations {
                policyApplied = survivingAnnotations(annotationsBefore)
            } else {
                policyApplied = annotationsBefore
            }
            annotationsAfter =
                (policyApplied?.isEmpty ?? true)
                ? nil
                : policyApplied?.reconciled(through: mesh.payloadIDCompaction())
        }
        let after = try mesh.payloadData()
        guard after != before else { return nil }
        let meshCommand = DocumentCommand.meshEdit(DocumentCommand.MeshEdit(
            objectID: object.id,
            payloadFile: object.payloadFile,
            verb: verb,
            before: before,
            after: after,
            beforeCounts: object.counts,
            afterCounts: DocumentManifest.Object.Counts(
                vertices: mesh.vertexCount, faces: mesh.faceCount
            ),
            beforeRevision: object.revision,
            afterRevision: (object.revision ?? 0) + 1
        ))
        guard annotationsAfter != annotationsBefore else { return meshCommand }
        return .compound(verb: verb, commands: [
            meshCommand,
            .annotationEdit(DocumentCommand.AnnotationEdit(
                objectID: object.id, verb: "\(verb).annotations",
                before: annotationsBefore, after: annotationsAfter
            )),
        ])
    }
}
