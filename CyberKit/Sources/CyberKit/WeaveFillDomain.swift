import Foundation
import simd

/// Builds the solve domain for a Weave fill (openspec add-weave-region-selection,
/// task 1).
///
/// Weave fills BARE TARGET with quads that meet the existing cage's open boundary
/// exactly. The region solver rewrites faces in place, so a domain has to exist
/// before it can run — and bare Target has no cage faces on it. This GROWS one:
/// quad rows stepped off the cage's free edge and snapped onto the Target, which the
/// region solve then rewrites into clean quads with the cage frozen.
///
/// Why grown rather than carved out of the Target: carving needs a curved surface cut
/// (the shipped knife is straight-only — a 4.1a remainder) plus a weld between cage
/// vertices and Target triangle interiors. Growing needs no new engine op, and the
/// seed does not have to be good — only a topologically correct, roughly-placed
/// cover, because the solve replaces it.
///
/// Measured viability (the change's task-0 spike): cage vertices bitwise unmoved,
/// manifold across the seam, and the solved band lands within ~3% of a quad of the
/// Target.
public enum WeaveFillDomain {

    public enum Failure: Error, Equatable {
        /// The cage has no free edge — nothing to grow from. Growing cannot fill an
        /// island of bare Target that touches no boundary; that would need carving.
        case noOpenBoundary
        /// A fill direction is required to choose WHICH part of the boundary to grow,
        /// and none could be derived (no tap point, no painted extent).
        case noFillDirection
        /// The selected run is shorter than one edge.
        case runTooShort
        /// The outward step collapsed (a degenerate or symmetric chain).
        case degenerateStep
    }

    /// A grown solve domain. `mesh` is a COPY — the caller's cage is never touched,
    /// so a discarded proposal leaves no seed rows in the document. The copy is
    /// id-preserving (`Mesh.duplicated`), which is what lets `chain` and the frozen
    /// face ids mean the same thing in both meshes.
    public struct Seed {
        public let mesh: Mesh
        /// The faces a region solve must rewrite.
        public let seedFaces: [UInt32]
        /// The prescribed boundary the fill must land on, in walk order.
        public let chain: [UInt32]
        public let rows: Int
        /// One row's world displacement.
        public let step: SIMD3<Float>
    }

    /// Grows `rows` snapped quad rows off the part of the cage's boundary that faces
    /// `towards`, on a copy of `cage`.
    ///
    /// `towards` is where the user asked to fill — a tap point on bare Target, or the
    /// centroid of a painted extent. It selects which stretch of boundary to grow
    /// from, so it is required: a cage patch's boundary is a CLOSED loop, and without
    /// a direction there is no non-arbitrary answer.
    public static func grow(
        cage: Mesh,
        snapper: SurfaceSnapper,
        towards: SIMD3<Float>,
        rows: Int = 2,
        maximumRows: Int = 12
    ) throws -> Seed {
        let boundary = openBoundaryEdges(of: cage)
        guard !boundary.isEmpty else { throw Failure.noOpenBoundary }

        // Grow from the boundary stretch nearest the fill point.
        let seedEdge = try nearestEdge(in: boundary, of: cage, to: towards)
        guard let walked = cage.boundaryChain(through: seedEdge), walked.vertices.count >= 2 else {
            throw Failure.runTooShort
        }

        let run = try facingRun(walked, of: cage, towards: towards)
        guard run.count >= 2 else { throw Failure.runTooShort }

        let step = try outwardStep(run: run, of: cage, towards: towards)
        let clamped = max(1, min(rows, maximumRows))

        // The seed is scratch. Build it on an ID-PRESERVING copy so the live cage is
        // untouched: a discarded proposal must leave nothing behind, and a payload
        // round-trip would renumber the very ids `chain` refers to.
        let scratch = try cage.duplicated()
        let before = Set(scratch.liveFaceIDs())
        _ = try scratch.extendBoundary(
            chain: run, closed: false, offset: step, rings: clamped, snapping: snapper
        )
        let seedFaces = scratch.liveFaceIDs().filter { !before.contains($0) }
        guard !seedFaces.isEmpty else { throw Failure.degenerateStep }

        return Seed(mesh: scratch, seedFaces: seedFaces, chain: run, rows: clamped, step: step)
    }

    /// How many rows are needed to reach the furthest painted point, measured along
    /// the step direction from the boundary run. Clamped to `maximumRows` — a runaway
    /// row count is a per-frame ghost ring and a sequential engine extrusion each,
    /// the hazard task 4.2 already had to bound.
    public static func rows(
        toCover extent: [SIMD3<Float>], from chain: [UInt32], of cage: Mesh,
        step: SIMD3<Float>, maximumRows: Int = 12
    ) -> Int {
        let length = simd_length(step)
        guard length > 1e-9, !extent.isEmpty else { return 1 }
        let direction = step / length
        let origin = centroid(of: chain, in: cage) ?? .zero
        let furthest = extent.map { simd_dot($0 - origin, direction) }.max() ?? 0
        guard furthest > 0 else { return 1 }
        return max(1, min(Int((furthest / length).rounded(.up)), maximumRows))
    }

    // MARK: - Pieces

    /// Live edges with exactly one incident face. Edge ids are sparse, so this probes
    /// past the live count the way `liveVertexIDs` does rather than assuming density.
    static func openBoundaryEdges(of mesh: Mesh) -> [UInt32] {
        let live = mesh.edgeCount
        guard live > 0 else { return [] }
        var found: [UInt32] = []
        var seen = 0
        var id: UInt32 = 0
        let limit = live * 2 + 64
        while seen < live, Int(id) < limit {
            let faces = mesh.edgeFaces(of: id)
            if !faces.isEmpty {
                seen += 1
                if faces.count == 1 { found.append(id) }
            }
            id += 1
        }
        return found
    }

    private static func nearestEdge(
        in edges: [UInt32], of mesh: Mesh, to point: SIMD3<Float>
    ) throws -> UInt32 {
        var best: UInt32?
        var bestDistance = Float.greatestFiniteMagnitude
        for edge in edges {
            guard let ends = mesh.edgeEndpoints(of: edge),
                let a = mesh.vertexPosition(ends.0), let b = mesh.vertexPosition(ends.1)
            else { continue }
            let distance = simd_length((a + b) * 0.5 - point)
            if distance < bestDistance {
                bestDistance = distance
                best = edge
            }
        }
        guard let best else { throw Failure.noOpenBoundary }
        return best
    }

    /// The contiguous stretch of `walked` that faces `towards`.
    ///
    /// A cage patch's boundary is a CLOSED loop, and `extendBoundary` steps the whole
    /// chain by one translation — so handing it a closed ring would SHIFT the ring
    /// rather than extend it outward. Selecting the run whose vertices lie on the
    /// fill side of the ring's centroid is what makes a single translation the right
    /// operation. An open chain is already a run and is returned whole.
    static func facingRun(
        _ walked: Mesh.BoundaryChain, of mesh: Mesh, towards: SIMD3<Float>
    ) throws -> [UInt32] {
        guard walked.closed else { return walked.vertices }
        let ring = walked.vertices
        guard let hub = centroid(of: ring, in: mesh) else { throw Failure.runTooShort }
        let fill = towards - hub
        guard simd_length(fill) > 1e-9 else { throw Failure.noFillDirection }
        let direction = simd_normalize(fill)

        let facing = ring.map { vertex -> Bool in
            guard let p = mesh.vertexPosition(vertex) else { return false }
            return simd_dot(p - hub, direction) > 0
        }
        guard facing.contains(true) else { throw Failure.noFillDirection }

        // Longest cyclic run of facing vertices.
        var bestStart = 0, bestLength = 0
        var start = 0
        while start < ring.count {
            guard facing[start] else { start += 1; continue }
            var length = 0
            while length < ring.count, facing[(start + length) % ring.count] { length += 1 }
            if length > bestLength {
                bestLength = length
                bestStart = start
            }
            start += max(length, 1)
        }
        guard bestLength >= 2 else { throw Failure.runTooShort }
        return (0..<bestLength).map { ring[(bestStart + $0) % ring.count] }
    }

    /// One row's displacement: outward from the run, one mean run-edge long, so the
    /// seed rows are roughly cage-quad sized and the prescribed-boundary density
    /// derivation has something sane to read.
    static func outwardStep(
        run: [UInt32], of mesh: Mesh, towards: SIMD3<Float>
    ) throws -> SIMD3<Float> {
        guard let hub = centroid(of: run, in: mesh) else { throw Failure.degenerateStep }
        let fill = towards - hub
        guard simd_length(fill) > 1e-9 else { throw Failure.noFillDirection }

        var total: Float = 0
        var count = 0
        for i in 0..<(run.count - 1) {
            guard let a = mesh.vertexPosition(run[i]), let b = mesh.vertexPosition(run[i + 1])
            else { continue }
            total += simd_length(b - a)
            count += 1
        }
        guard count > 0, total > 0 else { throw Failure.degenerateStep }
        let spacing = total / Float(count)
        return simd_normalize(fill) * spacing
    }

    private static func centroid(of vertices: [UInt32], in mesh: Mesh) -> SIMD3<Float>? {
        var sum = SIMD3<Float>.zero
        var count = 0
        for v in vertices {
            guard let p = mesh.vertexPosition(v) else { continue }
            sum += p
            count += 1
        }
        return count > 0 ? sum / Float(count) : nil
    }
}
