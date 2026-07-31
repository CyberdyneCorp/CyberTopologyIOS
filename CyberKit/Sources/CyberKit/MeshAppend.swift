import Foundation
import simd

// Appending one mesh's geometry into another (openspec add-painted-region-retopo).
//
// Composed from `buildFace` rather than added to the engine, the same way
// `MeshRimBridge` and `MeshHalveDensity` are: the only mutation is a face build,
// and the engine has no notion of "another mesh's faces" to teach it.

extension Mesh {
    /// What an append moved across.
    public struct AppendReport: Equatable, Sendable {
        public let facesAdded: Int
        public let verticesAdded: Int
        /// Faces skipped because their ring could not be built (a degenerate
        /// ring in the source). Reported rather than thrown: losing one face of
        /// a solver patch is not worth discarding the rest.
        public let facesSkipped: Int
    }

    /// Copies every live face of `other` into this mesh, preserving the source's
    /// vertex sharing but NOT welding anything onto this mesh's existing
    /// geometry.
    ///
    /// Not welding is the point, and it is a deliberate choice recorded in the
    /// spec: the receiving cage is hand-authored, and a silent weld would move
    /// vertices the artist placed. A patch's border sits coincident with the
    /// cage until the artist merges it with the tools that exist for that.
    ///
    /// Positions are copied EXACTLY — no snapper — because the source is a
    /// solver result that already lies on the Target; re-snapping would move it.
    @discardableResult
    public func append(_ other: Mesh) throws -> AppendReport {
        var mapped: [UInt32: UInt32] = [:]
        var facesAdded = 0
        var skipped = 0
        for face in other.liveFaceIDs().sorted() {
            let ring = other.faceVertices(face)
            guard ring.count >= 3 else {
                skipped += 1
                continue
            }
            // Slots: a source vertex already copied is REUSED (so the patch keeps
            // its own shared edges), otherwise a new point is created here.
            var slots: [BuildRingSlot] = []
            slots.reserveCapacity(ring.count)
            var pending: [Int: UInt32] = [:]
            for (index, vertex) in ring.enumerated() {
                if let existing = mapped[vertex] {
                    slots.append(.existing(existing))
                } else {
                    guard let position = other.vertexPosition(vertex) else {
                        slots.removeAll()
                        break
                    }
                    slots.append(.point(position))
                    pending[index] = vertex
                }
            }
            guard slots.count == ring.count else {
                skipped += 1
                continue
            }
            do {
                let built = try buildFace(ring: slots)
                // Record what the new points became, so the next face that uses
                // the same source vertex shares it rather than duplicating it.
                for (index, sourceVertex) in pending where index < built.ringVertices.count {
                    mapped[sourceVertex] = built.ringVertices[index]
                }
                facesAdded += 1
            } catch {
                skipped += 1
            }
        }
        return AppendReport(
            facesAdded: facesAdded, verticesAdded: mapped.count, facesSkipped: skipped
        )
    }
}
