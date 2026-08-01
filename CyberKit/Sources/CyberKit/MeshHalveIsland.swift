import Foundation

// Halving one island of a cage (openspec add-island-scoped-halve).
//
// Halve is otherwise whole-cage, and for a good reason: an edge loop does not
// stop at a patch boundary, so dissolving one partway leaves a hanging half-loop.
// An ISLAND is the case where that objection does not apply — its loops cannot
// leave it, because nothing outside it is attached. Reported from device: two
// patches, one selected, "it should work only on the selected one".
//
// Composed from operations that already exist rather than taught to the halving
// itself: duplicate, carve the copy down to the island, halve THAT, then splice
// it back. The halving therefore sees an ordinary whole cage and every rule it
// enforces — all-quad, rectangular, even spans — applies unchanged to the island.

extension Mesh {
    public enum IslandHalveFailure: Error, Equatable {
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

    /// Halves ONLY `faces`, which must be a self-contained island.
    ///
    /// Ordered so a refusal cannot leave a half-halved cage: the island is carved
    /// and halved on a COPY, and this mesh is not touched until that has
    /// succeeded. Every failure `halveDensity` can raise propagates unchanged, so
    /// an island that is not a rectangle refuses for the same reason a whole cage
    /// would.
    ///
    /// IDS ARE RENUMBERED, since the splice appends the halved island back. That is
    /// no worse than the whole-cage halve, which renumbers everything too.
    @discardableResult
    public func halveDensity(limitedTo faces: Set<UInt32>) throws -> HalvedDensity {
        guard !faces.isEmpty else { throw IslandHalveFailure.emptySelection }
        guard isSelfContainedIsland(faces) else { throw IslandHalveFailure.notAnIsland }

        // The island, alone, on a copy. `duplicated` preserves ids, so the
        // selection still names the same faces there.
        let island = try duplicated()
        let outside = island.liveFaceIDs().filter { !faces.contains($0) }.sorted()
        if !outside.isEmpty { try island.deleteFaces(outside) }

        // Throws before anything here is mutated.
        let report = try island.halveDensity()

        try deleteFaces(faces.sorted())
        try append(island)
        return report
    }
}
