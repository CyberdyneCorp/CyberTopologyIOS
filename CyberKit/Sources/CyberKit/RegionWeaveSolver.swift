import Foundation
import simd

/// The region backend for the Weave solver seam (openspec add-weave-regional-solve,
/// task 12).
///
/// `EngineRemeshSolver` deliberately keeps its `.wholeMesh`-only guard; this is a
/// SECOND conformance beside it rather than a replacement. That is what makes a
/// whole-mesh regression structurally impossible: the existing backend's code path
/// is not touched, so it cannot change behaviour.
///
/// What a region solve guarantees, and what it does not:
///
/// - **Exact landing IS guaranteed.** Interface vertices keep their ids and
///   bitwise positions, the interface edge set is preserved, and frozen faces keep
///   their rings. The engine refuses to publish a solve that would break any of it.
/// - **Interface regularity is NOT guaranteed** — it is measured and reported on
///   the ghost. See `SolverGhost.interfaceIrregular`.
public struct RegionWeaveSolver: WeaveSolving {
    public init() {}

    public func solve(
        source: Mesh,
        region: SolveRegion,
        constraints: WeaveConstraints,
        params: SolverParameters,
        onProgress: ((SolverProgress) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> SolverGhost? {
        guard case let .faces(requested) = region else {
            throw CyberKitError(
                code: .invalidArgument, message: "RegionWeaveSolver supports only .faces"
            )
        }

        // Frozen patches are EXCLUDED from the region rather than merely passed
        // along: this is where `WeaveConstraints.frozenFaces` stops being stored
        // and never read. A face the caller froze must end up on the prescribed
        // side of the interface, not inside the solved patch.
        let frozen = Set(constraints.frozenFaces)
        let regionFaces = requested.filter { !frozen.contains($0) }
        guard !regionFaces.isEmpty else {
            throw CyberKitError(
                code: .invalidArgument,
                message: "region is empty after removing frozen faces"
            )
        }

        // Density from the PRESCRIPTION, not from a global preset. Without this
        // the region inherits the whole-mesh quad budget (50 000 by default) and
        // the requested density fights the pinned interface — a conflict nothing
        // downstream detects, and one that shows up as a wildly over-fine patch
        // welded onto a coarse cage.
        var parameters = params.remesh
        if let derived = Self.prescribedQuadBudget(source: source, regionFaces: regionFaces) {
            parameters.targetQuads = derived
        }
        if let density = constraints.density, density.targetEdgeLength > 0 {
            parameters.edgeScale = min(max(parameters.edgeScale * density.targetEdgeLength, 0.05), 100)
        }

        // Guide strokes steer the cross field exactly as they do whole-mesh; the
        // engine filters any guide that would overwrite an interface pin.
        let (points, directions) = Self.orientationGuides(from: constraints, source: source)
        try source.setOrientationGuides(points: points, directions: directions)

        let solved = try withoutActuallyEscaping(isCancelled) { cancel -> Mesh? in
            try source.remeshedRegion(
                faces: regionFaces,
                parameters: parameters,
                valenceOverrides: constraints.interfaceValence,
                onProgress: onProgress.map { report in
                    { fraction, stage in
                        report(SolverProgress(fraction: Double(fraction), stage: stage))
                    }
                },
                isCancelled: cancel
            )
        }
        guard let solved else { return nil }  // cancelled

        let report = solved.regionReport()
        return SolverGhost(
            mesh: solved,
            addedFaces: solved.solvedFaceIDs() ?? solved.liveFaceIDs(),
            interfaceVertices: report?.interfaceVertices ?? [],
            interfaceIrregular: report?.interfaceIrregular ?? [],
            residualTriangles: report?.interfaceTriangles ?? 0,
            interiorIndexBudget: report?.interiorIndexBudget ?? 0
        )
    }

    /// A quad budget derived from the region's own area and the spacing of the
    /// boundary it must land on, so the solved patch matches the cage it welds to.
    ///
    /// The interface edges are found without any adjacency query: an edge of a
    /// region face is on the interface exactly when no OTHER region face shares
    /// it, so counting undirected vertex pairs across the region's rings is
    /// sufficient (and correct on a manifold).
    /// Public because it is most of task 5.5a's implicit sizing: a caller that
    /// wants to show the user the density a region WOULD get needs the same
    /// number the solve will use.
    public static func prescribedQuadBudget(source: Mesh, regionFaces: [UInt32]) -> Int? {
        var pairCount: [UInt64: Int] = [:]
        var area = 0.0
        for face in regionFaces {
            let ring = source.faceVertices(face)
            guard ring.count >= 3 else { continue }
            let positions = ring.compactMap { source.vertexPosition($0) }
            guard positions.count == ring.count else { continue }
            for i in 2..<positions.count {
                let a = positions[0], b = positions[i - 1], c = positions[i]
                area += Double(simd_length(simd_cross(b - a, c - a))) * 0.5
            }
            for i in 0..<ring.count {
                let a = ring[i], b = ring[(i + 1) % ring.count]
                let key = (UInt64(min(a, b)) << 32) | UInt64(max(a, b))
                pairCount[key, default: 0] += 1
            }
        }
        var total = 0.0
        var count = 0
        for (key, uses) in pairCount where uses == 1 {
            let a = UInt32(key >> 32), b = UInt32(key & 0xFFFF_FFFF)
            guard let pa = source.vertexPosition(a), let pb = source.vertexPosition(b) else {
                continue
            }
            total += Double(simd_length(pa - pb))
            count += 1
        }
        guard count > 0, area > 0 else { return nil }
        let mean = total / Double(count)
        guard mean > 0 else { return nil }
        return max(4, Int((area / (mean * mean)).rounded()))
    }

    /// Same mapping `EngineRemeshSolver` uses: guide strokes carry world points
    /// directly, tagged loops resolve through the source's edges.
    private static func orientationGuides(
        from constraints: WeaveConstraints, source: Mesh
    ) -> (points: [SIMD3<Float>], directions: [SIMD3<Float>]) {
        var points: [SIMD3<Float>] = []
        var directions: [SIMD3<Float>] = []
        func addSegment(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let d = b - a
            let len = simd_length(d)
            guard len > 1e-9 else { return }
            points.append((a + b) * 0.5)
            directions.append(d / len)
        }
        for stroke in constraints.guideStrokes where stroke.points.count >= 2 {
            for i in 0..<(stroke.points.count - 1) {
                addSegment(stroke.points[i], stroke.points[i + 1])
            }
        }
        for loop in constraints.taggedLoops {
            for edge in loop.edges {
                guard let ends = source.edgeEndpoints(of: edge),
                    let a = source.vertexPosition(ends.0),
                    let b = source.vertexPosition(ends.1)
                else { continue }
                addSegment(a, b)
            }
        }
        return (points, directions)
    }
}

/// Routes a solve to the backend that handles its region: `.wholeMesh` to the
/// auto-remesher, `.faces` to the region solver. This is the solver an app should
/// inject; the two backends stay independent behind it.
public struct CompositeWeaveSolver: WeaveSolving {
    private let wholeMesh: any WeaveSolving
    private let region: any WeaveSolving

    public init(
        wholeMesh: any WeaveSolving = EngineRemeshSolver(),
        region: any WeaveSolving = RegionWeaveSolver()
    ) {
        self.wholeMesh = wholeMesh
        self.region = region
    }

    public func solve(
        source: Mesh,
        region requested: SolveRegion,
        constraints: WeaveConstraints,
        params: SolverParameters,
        onProgress: ((SolverProgress) -> Void)?,
        isCancelled: () -> Bool
    ) throws -> SolverGhost? {
        let backend: any WeaveSolving = {
            if case .faces = requested { return region }
            return wholeMesh
        }()
        return try backend.solve(
            source: source, region: requested, constraints: constraints, params: params,
            onProgress: onProgress, isCancelled: isCancelled
        )
    }
}
