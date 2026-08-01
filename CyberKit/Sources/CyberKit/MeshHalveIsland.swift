import Foundation

// Running a whole-cage operation on ONE island of a cage (openspec
// add-island-scoped-halve, extended by add-island-scoped-subdivide).
//
// Halve and Subdivide are otherwise whole-cage, each for a good reason: an edge
// loop does not stop at a patch boundary, so dissolving one partway leaves a
// hanging half-loop; and subdividing one patch splits the edges it shares with its
// neighbours, so they become n-gons. An ISLAND is the case where NEITHER objection
// applies — nothing outside it is attached, so no loop can leave and there is no
// shared edge to split. Reported from device: two patches, one selected, "the batch
// operation should work only on the selected faces".
//
// Composed from operations that already exist rather than taught to each op:
// duplicate, carve the copy down to the island, run the ordinary whole-cage
// operation THERE, then splice it back. Each operation therefore sees a normal
// cage, and every rule it enforces applies to the island unchanged — with no second
// implementation to keep in agreement.

extension Mesh {
    public enum IslandFailure: Error, Equatable {
        /// The faces are attached to geometry outside them, so their loops run
        /// past the selection and halving would leave a hanging half-loop.
        case notAnIsland
        /// No faces given.
        case emptySelection
    }

    /// Whether `faces` are a self-contained island: nothing outside them touches
    /// them at all.
    ///
    /// Judged by VERTICES, not edges. Two patches meeting at a single vertex share
    /// no edge, yet splicing one back after halving would duplicate that vertex and
    /// tear them apart — a defect that would not surface until someone dragged the
    /// seam.
    public func isSelfContainedIsland(_ faces: Set<UInt32>) -> Bool {
        guard !faces.isEmpty else { return false }
        var inside: Set<UInt32> = []
        for face in faces { inside.formUnion(faceVertices(face)) }
        guard !inside.isEmpty else { return false }
        for face in liveFaceIDs() where !faces.contains(face) {
            if faceVertices(face).contains(where: { inside.contains($0) }) { return false }
        }
        return true
    }

    /// Runs `body` on `faces` alone — they must be a self-contained island — and
    /// splices the result back into this mesh.
    ///
    /// Ordered so a refusal cannot half-apply: the island is carved and operated on
    /// a COPY, and this mesh is not touched until `body` has succeeded. Every
    /// failure the operation can raise propagates unchanged, so an island that
    /// cannot be halved refuses for the same reason a whole cage would.
    ///
    /// IDS ARE RENUMBERED, since the splice appends the island back. That is no
    /// worse than the whole-cage form of these operations, which renumber
    /// everything.
    public func withIsland<T>(_ faces: Set<UInt32>, _ body: (Mesh) throws -> T) throws -> T {
        guard !faces.isEmpty else { throw IslandFailure.emptySelection }
        guard isSelfContainedIsland(faces) else { throw IslandFailure.notAnIsland }

        // The island, alone, on a copy. `duplicated` preserves ids, so the
        // selection still names the same faces there.
        let island = try duplicated()
        let outside = island.liveFaceIDs().filter { !faces.contains($0) }.sorted()
        if !outside.isEmpty { try island.deleteFaces(outside) }

        let result = try body(island)  // throws before anything here is mutated

        try deleteFaces(faces.sorted())
        try append(island)
        return result
    }

    /// Halves ONLY `faces`.
    @discardableResult
    public func halveDensity(limitedTo faces: Set<UInt32>) throws -> HalvedDensity {
        try withIsland(faces) { try $0.halveDensity() }
    }

    /// Subdivides ONLY `faces`, optionally reprojecting onto the Target.
    ///
    /// Sound on an island for the reason the whole-cage restriction exists: a
    /// subdivided patch splits the edges it SHARES with its neighbours, and an
    /// island shares none, so nothing outside it becomes an n-gon.
    @discardableResult
    public func subdivide(
        limitedTo faces: Set<UInt32>, reprojectingOnto snapper: SurfaceSnapper? = nil
    ) throws -> Int {
        try withIsland(faces) { try $0.subdivide(reprojectingOnto: snapper) }
    }
}
