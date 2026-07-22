import CyberRemesherC
import Foundation

// EditMesh batch commands (task 4.5; spec: retopology-tools / "EditMesh
// batch commands"): whole-mesh operations exposed as thin typed facades
// over the engine's capi (design D1 — no mesh algorithm runs in Swift).
//
// **Element-id stability is the load-bearing contract here** (mirrored from
// the ELEMENT-ID STABILITY block in `cyber_capi.h`, engine patch 0022), and
// `AnnotationIDPolicy` below is the single place the app reads it from:
//
//   * `snapAllToTarget` / `relaxAll` only move positions — every vertex,
//     edge and face id survives, so pins, loop tags and hidden faces stay
//     valid (`.preserved`).
//   * `subdivide` REBUILDS the mesh (`Mesh::linearSubdivide` returns a new
//     mesh): EVERY id is reassigned, so every annotation is orphaned
//     (`.rebuilt`).
//   * `triangulate` mutates in place: only VERTEX ids survive the trip into
//     the document, so only pins do (`.pinsOnly`). The engine handle keeps
//     edge ids too, but the document payload does NOT — see the note below.
//
// **Why triangulate clears loop tags even though the engine keeps edge ids.**
// The capi's stability block describes the LIVE HANDLE. The document layer
// re-serializes through `Mesh.payloadData()`, and the payload (OBJ) stores
// no edges at all: the loader rebuilds every edge id from FACE-CONSTRUCTION
// ORDER (see `MeshIDCompaction`). Triangulate reshuffles that stream — each
// n-gon's split face keeps its slot while the extra triangles append at the
// end, plus every diagonal is a brand-new edge — so the rebuilt numbering
// does not match the handle's. It retires nothing, so `payloadIDCompaction()`
// legitimately reports `.identity` on the vertex and face spaces it CAN
// describe, and would pass tags through untouched. The edge answer therefore
// has to come from here, and it is the same conservative one as everywhere
// else in this file: clear, never remap.
//
// The document layer pairs the geometry edit with the annotation edit this
// policy demands, in ONE compound journal entry (`DocumentCommand.compound`)
// so a single undo restores geometry AND annotations together.

/// What a batch operation does to the stable element ids the document's
/// `MeshAnnotations` are keyed on.
public enum AnnotationIDPolicy: String, Equatable, Sendable {
    /// All ids survive: annotations stay exactly as they are.
    case preserved
    /// Only VERTEX ids survive into the document: pins keep their meaning,
    /// hidden faces and loop tags do not. Face ids are partially reassigned,
    /// and the face-stream reshuffle renumbers the edge ids the payload
    /// loader rebuilds (see the note at the top of this file) — so tags go
    /// with the hidden faces even though the live handle kept its edge ids.
    case pinsOnly
    /// Every id is reassigned: no annotation can be carried across.
    case rebuilt

    /// This policy applied to an annotation state: the exact annotations
    /// that remain meaningful after the operation.
    ///
    /// CONVENTION (documented once, tested in both layers): orphaned
    /// annotations are **cleared, never remapped**. The engine hands back
    /// no old→new id map, and reconstructing one from positions would
    /// silently re-attach a pin to the wrong vertex on any mesh with
    /// coincident or near-coincident vertices — a wrong pin is worse than
    /// no pin, because Relax then quietly refuses to move geometry the
    /// user never froze.
    public func surviving(_ annotations: MeshAnnotations?) -> MeshAnnotations? {
        guard let annotations else { return nil }
        switch self {
        case .preserved:
            return annotations
        case .pinsOnly:
            let kept = annotations.showingAll().clearingAllTags()
            return kept.isEmpty ? nil : kept
        case .rebuilt:
            return nil
        }
    }
}

extension Mesh {
    /// Snap-all to Target: projects every live vertex onto the Target
    /// surface, leaving `pinned` vertices exactly where they are (spec:
    /// pinned vertices are immune to the smoothing commands). Returns how
    /// many vertices moved and the largest displacement. Throws
    /// `.invalidArgument` (mesh unchanged) without a usable Target.
    @discardableResult
    public func snapAllToTarget(
        _ snapper: SurfaceSnapper?, pinned: [UInt32] = []
    ) throws -> ResnapReport {
        var moved = 0
        var maxDistance: Float = 0
        try pinned.withUnsafeBufferPointer { pins in
            try check(cyber_retopo_snap_all(
                handle, snapper?.handle, pins.baseAddress, pins.count,
                &moved, &maxDistance
            ))
        }
        return ResnapReport(resnapped: moved, maxDistance: maxDistance)
    }

    /// Relax-all: one whole-mesh tangential smoothing sweep honoring pins
    /// (radius <= 0 is the engine's whole-mesh mask — no new entry point is
    /// needed). Vertices reproject onto the Target when a snapper is given.
    public func relaxAll(
        strength: Float = 0.5, iterations: Int = 1, pinned: [UInt32] = [],
        snapping snapper: SurfaceSnapper? = nil
    ) throws {
        try relax(
            around: .zero, radius: 0, strength: strength, iterations: iterations,
            autoPinCorners: true, pinned: pinned, snapping: snapper
        )
    }

    /// Subdivide (optionally reprojecting): one level of LINEAR
    /// (Catmull-Clark topology, no smoothing) subdivision into quads. With
    /// a snapper every vertex of the result is projected onto the Target —
    /// that is the spec's "subdivide+reproject", and the reprojection is
    /// what recovers curvature, since linear subdivision alone only adds
    /// vertices along the existing facets.
    ///
    /// **Reassigns every element id** — see `AnnotationIDPolicy.rebuilt`.
    /// Returns the resulting face count.
    @discardableResult
    public func subdivide(reprojectingOnto snapper: SurfaceSnapper? = nil) throws -> Int {
        var faces = 0
        try check(cyber_retopo_subdivide(handle, snapper?.handle, &faces))
        return faces
    }

    /// Triangulate: fan-triangulates every face with more than three sides.
    /// Vertex ids survive; face ids partially do, and the payload's rebuilt
    /// EDGE ids do not — see `AnnotationIDPolicy.pinsOnly`. Returns the
    /// resulting face count.
    @discardableResult
    public func triangulate() throws -> Int {
        var faces = 0
        try check(cyber_retopo_triangulate(handle, &faces))
        return faces
    }
}
