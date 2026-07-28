import CyberRemesherC
import Foundation
import simd

/// UV unwrapping and readback (openspec add-uv-stage-foundation, 6.1; spec: uv-workflow).
///
/// The engine's atlas seams a mesh into normal-coherent charts, LSCM-unwraps each, packs
/// them into the unit square and writes per-corner UVs. This is the Swift face of that,
/// plus the readback the 2D UV view needs — which did not exist before 6.1, so nothing
/// outside the OBJ exporter could see a layout.
extension Mesh {

    /// Atlas parameters. Defaults come from the engine, so the Swift layer never invents
    /// its own and drift between the two is impossible.
    public struct AtlasParameters: Equatable, Sendable {
        /// Normal-coherence bound for chart growth, in degrees.
        public var maxChartAngleDegrees: Float
        /// Gap left around each island, in UV units.
        public var packMargin: Float
        /// Resolution the texel-density readout is expressed against.
        public var textureSize: Int
        /// Rotate each chart to its minimum-area bounding box before packing.
        public var reorientCharts: Bool
        /// Merge adjacent charts that share a normal cone — fewer seams, same flatness.
        public var mergeCharts: Bool
        /// Looser merge cap: keep merging while the union's max conformal error stays
        /// within this. Zero disables the second pass.
        public var maxChartDistortion: Float

        public init() {
            var raw = CyberAtlasParams()
            cyber_default_atlas_params(&raw)
            maxChartAngleDegrees = raw.maxChartAngleDegrees
            packMargin = raw.packMargin
            textureSize = Int(raw.textureSize)
            reorientCharts = raw.reorientCharts != 0
            mergeCharts = raw.mergeCharts != 0
            maxChartDistortion = raw.maxChartDistortion
        }

        var raw: CyberAtlasParams {
            CyberAtlasParams(
                maxChartAngleDegrees: maxChartAngleDegrees,
                packMargin: packMargin,
                textureSize: Int32(textureSize),
                reorientCharts: reorientCharts ? 1 : 0,
                mergeCharts: mergeCharts ? 1 : 0,
                maxChartDistortion: maxChartDistortion
            )
        }
    }

    /// What an unwrap produced.
    ///
    /// Reported rather than swallowed: chart count, seam count, distortion and packed area
    /// are what tell an artist whether a layout is usable, and an unwrap that silently
    /// "succeeded" says nothing about whether the result is worth keeping.
    public struct AtlasReport: Equatable, Sendable {
        /// Charts (islands) the mesh was cut into.
        public var chartCount: Int
        /// Edges cut to form those charts.
        public var seamEdges: Int
        /// Worst conformal (angle) error across charts, in [0, 1).
        public var maxAngleDistortion: Float
        /// RMS conformal error across charts.
        public var rmsAngleDistortion: Float
        /// Charts whose net UV winding came out mirrored — a defect, not a style.
        public var flippedCharts: Int
        /// Charts the LSCM solve gave up on and planar-projected instead.
        public var fallbackCharts: Int
        /// Fraction of the unit square covered.
        public var packedArea: Float
        /// Texels per UV unit at the packed scale, against `textureSize`.
        public var texelDensity: Float

        init(_ raw: CyberAtlasResult) {
            chartCount = Int(raw.chartCount)
            seamEdges = raw.seamEdges
            maxAngleDistortion = raw.maxAngleDistortion
            rmsAngleDistortion = raw.rmsAngleDistortion
            flippedCharts = Int(raw.flippedCharts)
            fallbackCharts = Int(raw.fallbackCharts)
            packedArea = raw.packedArea
            texelDensity = raw.texelDensity
        }

        /// A one-line summary for the UI. States the things that make a layout unusable —
        /// flipped and fallback charts — rather than only the flattering numbers.
        public var summary: String {
            var parts = [
                "\(chartCount) chart\(chartCount == 1 ? "" : "s")",
                "\(seamEdges) seam edge\(seamEdges == 1 ? "" : "s")",
                String(format: "%.0f%% packed", packedArea * 100),
                String(format: "distortion %.3f max / %.3f rms",
                       maxAngleDistortion, rmsAngleDistortion),
            ]
            if flippedCharts > 0 { parts.append("\(flippedCharts) FLIPPED") }
            if fallbackCharts > 0 { parts.append("\(fallbackCharts) planar fallback") }
            return parts.joined(separator: " · ")
        }
    }

    /// An unwrapped COPY of this mesh, plus what the atlas produced.
    ///
    /// `self` is never modified, matching `remeshed` and `remeshedRegion`: a refused
    /// unwrap must leave the caller's mesh exactly as it was, and the caller decides
    /// whether to keep the result.
    ///
    /// Throws when the atlas cannot produce a layout, or when the engine was built
    /// without the UV module.
    public func unwrapped(
        parameters: AtlasParameters = AtlasParameters(),
        seams: [UInt32] = []
    ) throws -> (mesh: Mesh, report: AtlasReport) {
        let copy = try duplicated()
        return (copy, try copy.unwrapInPlace(parameters: parameters, seams: seams))
    }

    /// Unwraps THIS mesh in place, returning what the atlas produced.
    ///
    /// The in-place primitive, because that is what the engine does and what a journaled
    /// whole-mesh command needs: `runBatchMeshEdit` and the brushes mutate the live mesh
    /// handle and let a `MeshEditTransaction` capture the before/after payloads around it.
    /// A copy-returning-only API could not participate in that — the transaction pairs the
    /// geometry change with the annotations it orphaned into ONE undo step, and it has to
    /// wrap the mutation, not receive a replacement object.
    ///
    /// `unwrapped(parameters:)` is the non-mutating convenience over this, for callers
    /// previewing a layout rather than committing one.
    ///
    /// On failure the engine leaves the mesh alone and this throws, so a refused unwrap
    /// does not half-apply.
    @discardableResult
    public func unwrapInPlace(
        parameters: AtlasParameters = AtlasParameters(),
        seams: [UInt32] = []
    ) throws -> AtlasReport {
        // Seams ride the handle like the solve region and density scales. Set
        // unconditionally — including to empty — so an unwrap cannot inherit a seam set
        // left behind by a previous one.
        try setSeamEdges(seams)
        var raw = parameters.raw
        var result = CyberAtlasResult()
        try check(cyber_uv_atlas(handle, &raw, &result))
        return AtlasReport(result)
    }

    /// What a single-island re-unwrap did.
    public struct ReunwrapOutcome: Equatable, Sendable {
        /// Faces in the island that was re-unwrapped; 0 when nothing was.
        public let faces: Int
        /// The mesh carries no UVs at all, so there was no island layout to redo. NOT a
        /// failure: the caller is expected to run a whole-mesh unwrap instead. Kept separate
        /// from a thrown error because "you have not unwrapped yet" and "that face is not
        /// valid" need different answers, and one boolean for both would make them
        /// indistinguishable.
        public let needsWholeMeshUnwrap: Bool

        public var didUnwrap: Bool { faces > 0 && !needsWholeMeshUnwrap }
    }

    /// Re-unwraps only the island containing `face`, in place.
    ///
    /// The localized counterpart to `unwrapInPlace`, which re-charts and REPACKS the whole
    /// mesh — using that to service a gesture aimed at one region would re-lay-out the entire
    /// model. The island keeps the UV footprint it already occupied (uniformly fitted and
    /// centred, so the conformal solve is not sheared to fill the box) and every other
    /// island's UVs are left untouched.
    ///
    /// `seams` and `parameters` MUST match what the mesh was unwrapped with: the island
    /// partition is derived from the same seam source, and a different partition means the
    /// island re-unwrapped is not the one the caller pointed at.
    ///
    /// Throws for a dead face or a face in no island. Any failure leaves every UV as it was.
    @discardableResult
    public func reunwrapIsland(
        containing face: UInt32,
        parameters: AtlasParameters = AtlasParameters(),
        seams: [UInt32] = []
    ) throws -> ReunwrapOutcome {
        // Set unconditionally, including to empty, for the same reason `unwrapInPlace` does:
        // otherwise the partition could inherit a seam set left behind by a previous call and
        // silently re-unwrap a different island than the caller asked for.
        try setSeamEdges(seams)
        var raw = parameters.raw
        var result = CyberReunwrapResult()
        try check(cyber_uv_reunwrap_island(handle, face, &raw, &result))
        return ReunwrapOutcome(
            faces: result.faces, needsWholeMeshUnwrap: result.needsWholeMeshUnwrap != 0
        )
    }

    /// Hand-drawn UV seam edges for the next unwrap. Empty clears.
    ///
    /// The atlas cuts along exactly these instead of generating its own. Authored seams
    /// REPLACE the automatic ones rather than adding to them: cutting where the artist did
    /// not ask is a worse failure than an under-cut layout, and the distortion report plus
    /// the per-face heatmap already surface the latter.
    ///
    /// Every id is validated by the engine before anything is stored, so a rejected call
    /// leaves the mesh untouched.
    public func setSeamEdges(_ edges: [UInt32]) throws {
        if edges.isEmpty {
            try check(cyber_mesh_set_seam_edges(handle, nil, 0))
            return
        }
        try edges.withUnsafeBufferPointer { buffer in
            try check(cyber_mesh_set_seam_edges(handle, buffer.baseAddress, edges.count))
        }
    }

    /// Per-corner UV coordinates over the same triangulation `withRenderBuffers`'
    /// `triangleIndices` describes — one pair per emitted triangle corner, so three per
    /// triangle.
    ///
    /// **nil, not empty, when the mesh has never been unwrapped.** That distinction is the
    /// point: a mesh with no layout is not a mesh whose layout collapsed onto the origin,
    /// and a view given zeros for both would draw the second as a catastrophic result
    /// instead of saying there is nothing here yet.
    ///
    /// Copies out rather than exposing a pointer view: a UV layout is small next to the
    /// position stream (a 2D view is drawn from the EditMesh cage, not a multi-million
    /// triangle Target), and a value is far harder to misuse than a buffer whose lifetime
    /// ends with the next mutating call.
    public func uvCoordinates() -> [SIMD2<Float>]? {
        withExtendedLifetime(self) {
            var count = 0
            guard let raw = cyber_mesh_uvs_ptr(handle, &count), count >= 2 else { return nil }
            return (0..<(count / 2)).map { SIMD2(raw[$0 * 2], raw[$0 * 2 + 1]) }
        }
    }

    /// Per-face UV distortion, or nil when the mesh has no layout.
    ///
    /// **nil rather than an array of zeros**, for the same reason `uvCoordinates()` returns
    /// nil: no layout and a perfect layout are different states, and zeros for both would
    /// render a never-unwrapped mesh as flawless.
    ///
    /// One entry per live face, in the engine's live-face order — the same order
    /// `liveFaceIDs()` walks — so a caller can index it against face rings it reconstructed
    /// itself without a second mapping to keep in sync.
    public struct FaceDistortion: Equatable, Sendable {
        /// Conformal (angle) error in [0, 1). 0 is angle-preserving.
        public var angle: Float
        /// |uvArea| / surfaceArea, unnormalised. 0 for a collapsed face.
        public var area: Float
        /// The face's UV winding is reversed. A DEFECT, not a point on a scale — a mirrored
        /// face bakes inverted detail — so callers should call it out rather than shade it.
        public var flipped: Bool

        /// Public so a caller can construct one — a heatmap's colour mapping is worth
        /// testing against specific values, and without this every test would have to
        /// unwrap a real mesh and hope it happened to contain the case it needed.
        public init(angle: Float, area: Float, flipped: Bool) {
            self.angle = angle
            self.area = area
            self.flipped = flipped
        }

        /// Texels per unit surface area at `textureSize`.
        ///
        /// Takes the size as a PARAMETER rather than baking one in: a texel density is
        /// meaningless without the resolution it is expressed against, and hiding a default
        /// would let two parts of the UI quote different numbers for the same face.
        public func texelDensity(textureSize: Int) -> Float {
            let side = Float(max(textureSize, 0))
            return area * side * side
        }
    }

    public func uvDistortion() -> [FaceDistortion]? {
        withExtendedLifetime(self) {
            var count = 0
            guard let raw = cyber_mesh_uv_distortion_ptr(handle, &count), count > 0 else {
                return nil
            }
            return (0..<count).map {
                FaceDistortion(
                    angle: raw[$0].angle, area: raw[$0].area, flipped: raw[$0].flipped != 0
                )
            }
        }
    }

    /// The seams chart growth would choose, treating this mesh's authored seams as edges it
    /// will NOT cut across and which are always included in the result.
    ///
    /// So the answer is "given the artist's cuts, where ELSE would I cut" rather than a
    /// fresh opinion on the whole mesh, and accepting a proposal can only ever ADD — never
    /// delete a seam they drew. Ascending ids, so the same mesh with the same authored seams
    /// proposes the same thing.
    ///
    /// PROPOSES only: the mesh is not modified, and the caller decides whether to keep it.
    ///
    /// Known limitation, inherited from the engine and stated rather than hidden: the
    /// chart-MERGE passes are not barrier-aware, so two charts an authored seam separates can
    /// still merge. The authored set is unioned into the result, so the outcome is correct,
    /// but auto seams near a manual cut may be placed as if it were absent.
    public func proposedSeams(respecting authored: [UInt32] = []) throws -> [UInt32] {
        // The barrier rides the handle, so it has to be set before asking.
        try setSeamEdges(authored)
        var count = 0
        try check(cyber_mesh_propose_seams(handle, nil, 0, &count))
        guard count > 0 else { return [] }
        var ids = [UInt32](repeating: 0, count: count)
        var written = 0
        try ids.withUnsafeMutableBufferPointer { buffer in
            try check(cyber_mesh_propose_seams(handle, buffer.baseAddress, count, &written))
        }
        return Array(ids.prefix(written))
    }

    /// Whether this mesh carries a UV layout at all — the cheap question, without
    /// materialising the coordinates.
    public var hasUVLayout: Bool {
        withExtendedLifetime(self) {
            var count = 0
            return cyber_mesh_uvs_ptr(handle, &count) != nil && count > 0
        }
    }
}
