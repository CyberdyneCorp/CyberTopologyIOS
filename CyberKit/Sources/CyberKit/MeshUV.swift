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
        parameters: AtlasParameters = AtlasParameters()
    ) throws -> (mesh: Mesh, report: AtlasReport) {
        let copy = try duplicated()
        return (copy, try copy.unwrapInPlace(parameters: parameters))
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
        parameters: AtlasParameters = AtlasParameters()
    ) throws -> AtlasReport {
        var raw = parameters.raw
        var result = CyberAtlasResult()
        try check(cyber_uv_atlas(handle, &raw, &result))
        return AtlasReport(result)
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

    /// Whether this mesh carries a UV layout at all — the cheap question, without
    /// materialising the coordinates.
    public var hasUVLayout: Bool {
        withExtendedLifetime(self) {
            var count = 0
            return cyber_mesh_uvs_ptr(handle, &count) != nil && count > 0
        }
    }
}
