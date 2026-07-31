import Foundation
import simd

// Dropping vertices that belong to no face (openspec fix-faceless-cage-vertices).
//
// MEASURED: a whole-mesh solve on the Stanford bunny returned a 1108-face cage
// carrying 1186 vertices, 91 of which belonged to no face at all — 41% of them
// clustered in the ears, where the cross field is most singular. They are not
// harmless clutter. The engine's Relax builds each vertex's one-ring from its
// edges, so a vertex with no faces has nothing to smooth toward and Relax skips
// it: measured, 130 relax passes at the app's brush radius over an ear tip moved
// ZERO of the 15 vertices under the brush, with the Target snapper and without,
// while the same relax with no mask moved 1084 of 1186. From the artist's side
// the tool simply did nothing.

extension Mesh {
    /// What a prune removed.
    public struct PruneReport: Equatable, Sendable {
        public let verticesDropped: Int
        public let facesKept: Int
        /// Faces the rebuild could not reproduce. Zero for any mesh a solver
        /// produced; reported rather than thrown, for the same reason `append`
        /// reports skips — losing one face is not worth discarding a cage.
        public let facesSkipped: Int

        public var droppedAnything: Bool { verticesDropped > 0 }
    }

    /// A copy carrying every face of this mesh and only the vertices those faces
    /// use.
    ///
    /// Built by appending into a fresh mesh rather than deleting in place: the C
    /// API prunes isolated vertices only as a side effect of removing the faces
    /// that orphaned them (`cyber_retopo_delete_faces`), and there is no entry
    /// point for "drop this vertex", so there is nothing to call. `append`
    /// already preserves the source's vertex sharing exactly, which is the whole
    /// job here.
    ///
    /// IDS ARE RENUMBERED, so this is for a mesh whose ids nothing has recorded
    /// yet — a fresh solver result. Handing it a mesh whose vertex or face ids
    /// are already referenced (a prescribed-boundary region report, a document's
    /// annotations) silently re-points them, which is the bug that made region
    /// solves do nothing before the carve moved on-actor.
    public func prunedOfFacelessVertices() throws -> (mesh: Mesh, report: PruneReport) {
        let rebuilt = try Mesh()
        let appended = try rebuilt.append(self)
        return (
            rebuilt,
            PruneReport(
                verticesDropped: vertexCount - appended.verticesAdded,
                facesKept: appended.facesAdded,
                facesSkipped: appended.facesSkipped
            )
        )
    }

    /// Vertices belonging to no live face — what `prunedOfFacelessVertices`
    /// drops. Exposed for diagnostics and tests; the prune does not use it (it
    /// works from the faces, so it never needs the complement).
    public func facelessVertexIDs() -> Set<UInt32> {
        var used: Set<UInt32> = []
        for face in liveFaceIDs() {
            used.formUnion(faceVertices(face))
        }
        return liveVertexIDs().subtracting(used)
    }
}
