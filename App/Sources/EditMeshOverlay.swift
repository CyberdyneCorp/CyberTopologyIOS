import CyberKit
import Metal
import simd

// EditMesh overlay pipeline (task 2.3, spec: viewport-rendering / "Animated
// EditMesh overlay pipeline" + "X-ray and occlusion control", design D2:
// dedicated overlay pipeline — the "feel" is a first-class deliverable).
//
// v1 renders the wireframe as an indexed line list over the engine's unique
// face-edge buffer (authored topology: a quad draws 4 edges, never its fan
// diagonal) plus vertex dots as point primitives. This is a plain vertex
// pipeline on purpose: it needs no GPU capability gating and is exactly what
// simulator tests exercise.
//
// Barycentric upgrade path: replace the line list with the solid EditMesh
// triangles carrying per-corner barycentric coordinates (or
// `[[barycentric_coord]]` on Apple7+), and derive the edge mask in the
// fragment shader from the barycentric distance-to-edge. That gives
// resolution-independent stroke width, interior-edge masking and per-edge
// styling (pins/tags/boundaries) in one draw — slot it in behind
// `EditMeshOverlayPath.encode` without touching the renderer.

/// User-facing overlay state (view-options popover; persisted app-side).
struct OverlaySettings: Equatable {
    /// Wireframe opacity, 0...1. 0 hides the overlay entirely.
    var opacity: Float = Float(ViewportSettings.defaultOverlayOpacity)
    /// True x-ray mode: far-side wireframe rendered depth-attenuated
    /// (spec scenario "X-ray mode").
    var xrayEnabled = false
    /// Occlusion depth threshold in NDC depth units: how far behind the
    /// Target surface edges stay visible before they are occluded.
    var occlusionBias: Float = Float(ViewportSettings.defaultOcclusionBias)
    /// Translucent face fill under the wireframe, 0...1. 0 = wireframe
    /// only (the pre-fill behaviour). Independent of `opacity`: the fill
    /// and the wire are separate reads — you can want a solid-looking face
    /// with a faint wire, or the reverse.
    var fillOpacity: Float = Float(ViewportSettings.defaultFillOpacity)
}

/// Creation micro-animation timing: a pure time→progress mapping so the
/// GPU work is one uniform per frame (no geometry churn, no frame drops).
enum OverlayAnimation {
    /// Sweep+fade duration in seconds (subtle by design).
    static let duration: Double = 0.45

    /// Progress in [0, 1] of the creation animation started at
    /// `creationTime`; 1 when no animation is running.
    static func progress(creationTime: Double?, now: Double) -> Float {
        guard let creationTime else { return 1 }
        let elapsed = (now - creationTime) / duration
        return Float(min(max(elapsed, 0), 1))
    }
}

/// Screen metrics the overlay needs to size features in POINTS rather than
/// drawable pixels.
///
/// Edge width and vertex-dot diameter are screen-space quantities, and the
/// GPU only speaks pixels. Authoring them in pixels made the wire render
/// three times thinner on a 3x iPad than the same number suggested — the
/// wire was a hairline on exactly the devices this app targets. Authoring
/// in points and converting here keeps a "1.5pt edge" 1.5pt at any
/// `contentScale`, including the reduced ones the resolution-scale control
/// selects.
struct OverlayViewport: Equatable {
    /// Drawable size in pixels.
    var sizePixels = SIMD2<Float>(1, 1)
    /// Drawable pixels per point (the view's `contentScaleFactor`).
    var scale: Float = 1

    func pixels(_ points: Float) -> Float { points * max(scale, 1e-3) }
}

/// Per-draw overlay uniforms. Layout must match the MSL `OverlayUniforms`
/// struct: float4x4 then four float4s.
struct OverlayUniforms: Equatable {
    var mvp: simd_float4x4
    /// Theme color (rgb) and effective opacity (a).
    var color: SIMD4<Float>
    /// x: animation progress, y: NDC occlusion depth bias,
    /// z: x-ray attenuation floor, w: vertex count (sweep normalization).
    var params: SIMD4<Float>
    /// x: point size in pixels, y: 1 on the x-ray (far-side) pass else 0,
    /// z,w: reserved.
    var misc: SIMD4<Float>
    /// x: line width in pixels, y,z: drawable size in pixels (the
    /// screen-space ribbon expansion needs it), w: reserved.
    var line: SIMD4<Float>
}

/// Pure uniform construction, unit-tested without a GPU.
enum OverlayUniformsFactory {
    /// Distinct overlay theme (RT-stage cyan; per-stage themes extend here).
    static let wireColor = SIMD3<Float>(0.30, 0.85, 1.0)
    /// Loop-tag pass color (task 3.4 minimal colored-line render; the full
    /// per-tag style set arrives with 4.3): green, clearly distinct from
    /// the cyan wire.
    static let tagColor = SIMD3<Float>(0.35, 1.0, 0.45)
    /// Hover-preview highlight color (task 3.6): warm yellow, distinct from
    /// both the cyan wire and the green tag pass.
    static let hoverColor = SIMD3<Float>(1.0, 0.85, 0.25)
    /// Pin-marker color (task 4.3, docs/COZYBLANKET_REFERENCE §4.1: pins
    /// render as yellow circles). Saturated yellow — deliberately the
    /// hover family, since both mean "this element is special right now",
    /// but at full alpha and a larger dot so pins read at a glance.
    static let pinColor = SIMD3<Float>(1.0, 0.92, 0.15)
    /// Pin-marker dot diameter in POINTS — larger than both the wire's
    /// vertex dots and the snap highlight so a pinned vertex is
    /// unmistakable.
    static let pinPointSize: Float = 8
    /// Hover highlight opacity — independent of the user's wireframe
    /// opacity (a preview must stay readable at any wire setting).
    static let hoverAlpha: Float = 0.95
    /// Snap-target dot diameter in POINTS (larger than the wire's vertex
    /// dots so the merge target reads as THE highlighted element).
    static let hoverPointSize: Float = 7
    /// Alpha floor multiplier for the far-side x-ray pass.
    static let xrayAttenuation: Float = 0.45

    // Screen-space feature sizes, all in POINTS (see `OverlayViewport`).
    //
    // The retopology reference (docs/COZYBLANKET_REFERENCE §4.1) renders
    // the working cage as a substantial wire — chunky round vertices on
    // visibly weighted edges — because the cage IS the artifact being
    // authored, not an annotation over one. A hairline is legible on a
    // dense import and useless on the handful of quads a user has just
    // drawn: at 4-6 quads there is nothing to read but the wire itself.

    /// Vertex dot diameter in POINTS.
    static let pointSize: Float = 4.5
    /// Wireframe edge width in POINTS.
    static let edgeWidth: Float = 1.6
    /// Tagged-loop and symmetry-rim width in POINTS — heavier than the
    /// base wire, since those passes redraw edges the wire already covered
    /// and must read as a deliberate marking on top of it.
    static let tagEdgeWidth: Float = 2.4
    /// Hover-preview segment width in POINTS.
    static let hoverEdgeWidth: Float = 2.6

    /// Screen-space sizes for one pass, resolved to pixels.
    private static func screen(
        _ viewport: OverlayViewport, points: Float, edge: Float
    ) -> (misc: SIMD4<Float>, line: SIMD4<Float>) {
        (
            misc: SIMD4(viewport.pixels(points), 0, 0, 0),
            line: SIMD4(
                viewport.pixels(edge), viewport.sizePixels.x, viewport.sizePixels.y, 0
            )
        )
    }

    /// Uniforms for the front (depth-tested, bias-forgiving) pass.
    static func main(
        mvp: simd_float4x4, settings: OverlaySettings,
        animationProgress: Float, vertexCount: Int,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        let sizes = screen(viewport, points: pointSize, edge: edgeWidth)
        return OverlayUniforms(
            mvp: mvp,
            color: SIMD4(wireColor, settings.opacity),
            params: SIMD4(
                animationProgress, settings.occlusionBias,
                xrayAttenuation, Float(vertexCount)
            ),
            misc: sizes.misc,
            line: sizes.line
        )
    }

    /// Uniforms for the x-ray (far-side, depth-attenuated) pass.
    static func xray(
        mvp: simd_float4x4, settings: OverlaySettings,
        animationProgress: Float, vertexCount: Int,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        var uniforms = main(
            mvp: mvp, settings: settings,
            animationProgress: animationProgress, vertexCount: vertexCount,
            viewport: viewport
        )
        uniforms.misc.y = 1
        return uniforms
    }

    /// Uniforms for the loop-tag pass (task 3.4): the main pass recolored,
    /// slightly boosted so tags read over the base wire.
    static func tagged(
        mvp: simd_float4x4, settings: OverlaySettings,
        animationProgress: Float, vertexCount: Int,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        var uniforms = main(
            mvp: mvp, settings: settings,
            animationProgress: animationProgress, vertexCount: vertexCount,
            viewport: viewport
        )
        uniforms.color = SIMD4(tagColor, min(1, settings.opacity * 1.2))
        uniforms.line.x = viewport.pixels(tagEdgeWidth)
        return uniforms
    }

    /// Uniforms for the hover-preview highlight pass (task 3.6): warm
    /// yellow — distinct from the cyan wire AND the green tag pass — at
    /// near-full alpha, with a larger dot for the snap-target vertex.
    /// The creation-sweep reveal is forced fully open (progress 1, vertex
    /// count 0) so a hover highlight never inherits a mid-animation fade,
    /// and the occlusion bias is kept so the highlight matches the wire's
    /// visibility rules.
    static func hover(
        mvp: simd_float4x4, settings: OverlaySettings,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        let sizes = screen(viewport, points: hoverPointSize, edge: hoverEdgeWidth)
        return OverlayUniforms(
            mvp: mvp,
            color: SIMD4(hoverColor, hoverAlpha),
            params: SIMD4(1, settings.occlusionBias, xrayAttenuation, 0),
            misc: sizes.misc,
            line: sizes.line
        )
    }

    /// Uniforms for a per-tag COLOUR loop pass (task 4.3): the palette
    /// colour at the wire's opacity boosted like the 3.4 tag pass, with
    /// the creation sweep forced fully open (an annotation is document
    /// state — it must not fade in with a geometry animation).
    static func tagColor(
        _ color: SIMD3<Float>, mvp: simd_float4x4, settings: OverlaySettings,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        let sizes = screen(viewport, points: pointSize, edge: tagEdgeWidth)
        return OverlayUniforms(
            mvp: mvp,
            color: SIMD4(color, min(1, settings.opacity * 1.2)),
            params: SIMD4(1, settings.occlusionBias, xrayAttenuation, 0),
            misc: sizes.misc,
            line: sizes.line
        )
    }

    /// Uniforms for the pin-marker pass (task 4.3): yellow dots at full
    /// alpha, independent of the wireframe opacity — pins stay visible
    /// even with the wire turned down, because they change what the NEXT
    /// Relax will do.
    static func pins(
        mvp: simd_float4x4, settings: OverlaySettings,
        viewport: OverlayViewport = OverlayViewport()
    ) -> OverlayUniforms {
        let sizes = screen(viewport, points: pinPointSize, edge: tagEdgeWidth)
        return OverlayUniforms(
            mvp: mvp,
            color: SIMD4(pinColor, 1),
            params: SIMD4(1, settings.occlusionBias, xrayAttenuation, 0),
            misc: sizes.misc,
            line: sizes.line
        )
    }
}

/// GPU-ready annotation overlay state (task 4.3): pin marker points and
/// per-palette-colour tagged-loop line segments, in WORLD space.
///
/// Standalone world-space geometry (the task-3.6 hover-highlight
/// precedent) rather than indices into the compacted render stream: stable
/// element ids never need mapping to render indices, and the buffer is
/// rebuilt only when the ANNOTATIONS change — never at frame time.
struct AnnotationRenderState: Equatable {
    /// One colour group: the palette index's colour and its line-list
    /// vertices (consecutive pairs = one edge).
    struct TagGroup: Equatable {
        var color: SIMD3<Float>
        var segments: [Float]
    }

    /// Pin markers as point-primitive vertices (x,y,z each).
    var pinPoints: [Float] = []
    /// Tagged loops grouped by palette colour, ordered by palette index so
    /// the draw order (and therefore the golden screenshots) is stable.
    var tagGroups: [TagGroup] = []
    /// Symmetry-plane rims (task 4.4): one line-list group per enabled
    /// mirror plane, built by `SymmetryRimGeometry`. Kept separate from
    /// the tag groups because they are VIEW state derived from the
    /// document's symmetry settings, not per-element annotations — but
    /// they ride the same world-space buffer and pass.
    var symmetryRims: [TagGroup] = []

    /// Every line-list group in draw order: tags first, rims on top (the
    /// rim must stay readable where it crosses a tagged loop).
    var lineGroups: [TagGroup] { tagGroups + symmetryRims }

    var isEmpty: Bool { pinPoints.isEmpty && lineGroups.allSatisfy { $0.segments.isEmpty } }

    /// Builds the render state from document annotations plus element
    /// accessors. Pure — the accessors are the only engine contact, so the
    /// whole builder is unit-testable headless.
    ///
    /// Stale ids (retired by a later topology edit) are skipped exactly
    /// like the engine-side render filters do: an annotation that outlived
    /// its element renders as nothing, never as a crash.
    static func build(
        annotations: MeshAnnotations,
        edgeEndpoints: (UInt32) -> (UInt32, UInt32)?,
        vertexPosition: (UInt32) -> SIMD3<Float>?,
        color: (UInt8) -> SIMD3<Float> = LoopTagPalette.color
    ) -> AnnotationRenderState {
        var state = AnnotationRenderState()
        for vertex in annotations.pinnedVertices {
            guard let position = vertexPosition(vertex) else { continue }
            state.pinPoints.append(contentsOf: [position.x, position.y, position.z])
        }
        let groups = annotations.taggedEdgesByColor()
        for index in groups.keys.sorted() {
            var segments: [Float] = []
            for edge in groups[index] ?? [] {
                guard
                    let (a, b) = edgeEndpoints(edge),
                    let start = vertexPosition(a), let end = vertexPosition(b)
                else { continue }
                segments.append(contentsOf: [start.x, start.y, start.z])
                segments.append(contentsOf: [end.x, end.y, end.z])
            }
            guard !segments.isEmpty else { continue }
            state.tagGroups.append(TagGroup(color: color(index), segments: segments))
        }
        return state
    }
}

/// Dedicated overlay pipeline for EditMesh wireframes: edges as an indexed
/// line list, vertices as points, alpha-blended over the Target with two
/// depth strategies:
///
///  * occluded pass — depth compare ≤ against the Target's depth with a
///    configurable NDC bias applied in the vertex shader, so edges up to
///    the occlusion threshold behind the surface stay visible;
///  * x-ray pass (optional) — depth compare > (only fragments the Target
///    hides) with depth-attenuated alpha, making far-side topology
///    readable without flattening the model (spec scenario "X-ray mode").
///
/// Geometry lives in its own `GeometryBufferPool` (positions + edge
/// indices; same no-per-frame-allocation contract as the target pool).
@MainActor
final class EditMeshOverlayPath {
    /// Six vertices per edge: the two triangles of its screen-space ribbon.
    private static let verticesPerSegment = 6
    /// Stride of one `packed_float3` position, in bytes. NOT
    /// `MemoryLayout<SIMD3<Float>>.size` — Swift pads that to 16, which
    /// would offset every sequential ribbon group into the wrong vertices.
    private static let positionStride = MemoryLayout<Float>.stride * 3

    let bufferPool: GeometryBufferPool
    /// Round vertex/pin dots (point primitives).
    private let pointPipelineState: MTLRenderPipelineState
    /// Thick edges expanded from an INDEXED line list (the wire, tagged
    /// edges) into screen-space ribbons.
    private let indexedLinePipelineState: MTLRenderPipelineState
    /// Thick edges expanded from CONSECUTIVE vertex pairs (hover segments,
    /// annotation groups), which carry no index buffer.
    private let sequentialLinePipelineState: MTLRenderPipelineState
    /// Depth compare ≤, writes off: overlay never disturbs Target depth.
    private let occludedDepthState: MTLDepthStencilState
    /// Depth compare >, writes off: draws only what the Target hides.
    private let xrayDepthState: MTLDepthStencilState

    private(set) var edgeIndexCount = 0
    private(set) var vertexCount = 0
    /// Loop-tag pass (task 3.4): indices into the same position stream.
    /// Kept out of the pool (its streams are the hot per-frame geometry);
    /// allocated only when tags change, never at frame time.
    private(set) var taggedIndexCount = 0
    private var taggedIndexBuffer: MTLBuffer?
    /// Hover-preview highlight pass (task 3.6): standalone world-space
    /// vertices (line-list segments, then point primitives) so the
    /// highlight is independent of the compacted render streams — element
    /// ids never need mapping to render indices. Allocated only when the
    /// PREVIEW changes (`HoverPreviewState` dedupes identical resolutions),
    /// never at frame time.
    private(set) var hoverSegmentVertexCount = 0
    private(set) var hoverPointVertexCount = 0
    private var hoverVertexBuffer: MTLBuffer?
    /// Annotation pass (task 4.3): pin markers + per-colour tagged loops,
    /// standalone world-space vertices in ONE buffer (pins first, then
    /// each colour group). Rebuilt only when the annotations change.
    private(set) var pinPointCount = 0
    private(set) var tagColorGroups: [(color: SIMD3<Float>, vertexStart: Int, vertexCount: Int)] =
        []
    private var annotationVertexBuffer: MTLBuffer?
    private let device: MTLDevice

    var hasGeometry: Bool { edgeIndexCount > 0 }
    var hasHoverHighlight: Bool { hoverSegmentVertexCount + hoverPointVertexCount > 0 }
    var hasAnnotations: Bool { pinPointCount > 0 || !tagColorGroups.isEmpty }

    /// Fails only when the embedded shader does not compile or a pipeline/
    /// depth state cannot be built (programmer error, surfaced by tests).
    init?(device: MTLDevice, commandQueue: MTLCommandQueue, preferPrivateStorage: Bool) {
        guard let library = try? device.makeLibrary(source: Self.shaderSource, options: nil)
        else { return nil }

        // Three pipelines over one shader source: points, indexed ribbons
        // and sequential ribbons differ only in their vertex function, but
        // a fragment shader may only read `[[point_coord]]` when the
        // primitive really is a point — which is why the round dots need a
        // pipeline (and a fragment function) of their own.
        func pipeline(vertex: String, fragment: String, label: String)
            -> MTLRenderPipelineState?
        {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = label
            descriptor.vertexFunction = library.makeFunction(name: vertex)
            descriptor.fragmentFunction = library.makeFunction(name: fragment)
            descriptor.colorAttachments[0].pixelFormat = ViewportRenderer.colorPixelFormat
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            descriptor.depthAttachmentPixelFormat = ViewportRenderer.depthPixelFormat
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let occluded = MTLDepthStencilDescriptor()
        occluded.depthCompareFunction = .lessEqual
        occluded.isDepthWriteEnabled = false

        let xray = MTLDepthStencilDescriptor()
        xray.depthCompareFunction = .greater
        xray.isDepthWriteEnabled = false

        guard
            let points = pipeline(
                vertex: "overlay_vertex", fragment: "overlay_point_fragment",
                label: "editmesh-overlay-points"
            ),
            let indexedLines = pipeline(
                vertex: "overlay_line_indexed_vertex", fragment: "overlay_line_fragment",
                label: "editmesh-overlay-lines-indexed"
            ),
            let sequentialLines = pipeline(
                vertex: "overlay_line_sequential_vertex", fragment: "overlay_line_fragment",
                label: "editmesh-overlay-lines-sequential"
            ),
            let occludedState = device.makeDepthStencilState(descriptor: occluded),
            let xrayState = device.makeDepthStencilState(descriptor: xray)
        else { return nil }

        self.device = device
        self.pointPipelineState = points
        self.indexedLinePipelineState = indexedLines
        self.sequentialLinePipelineState = sequentialLines
        self.occludedDepthState = occludedState
        self.xrayDepthState = xrayState
        self.bufferPool = GeometryBufferPool(
            device: device, commandQueue: commandQueue,
            preferPrivateStorage: preferPrivateStorage
        )
    }

    /// Uploads EditMesh wireframe geometry (engine-compacted positions +
    /// unique face-edge indices), plus the optional loop-tag index pairs
    /// (task 3.4) into the same position stream. Returns false and clears
    /// on undrawable input or allocation failure.
    @discardableResult
    func load(
        positions: UnsafeBufferPointer<Float>, edges: UnsafeBufferPointer<UInt32>,
        taggedEdges: UnsafeBufferPointer<UInt32>? = nil
    ) -> Bool {
        guard !positions.isEmpty, !edges.isEmpty else {
            clear()
            return false
        }
        guard
            bufferPool.upload(floats: positions, to: .position) != nil,
            bufferPool.upload(indices: edges) != nil
        else {
            clear()
            return false
        }
        vertexCount = positions.count / 3
        edgeIndexCount = edges.count
        if let taggedEdges, !taggedEdges.isEmpty,
            let buffer = device.makeBuffer(
                bytes: taggedEdges.baseAddress!,
                length: taggedEdges.count * MemoryLayout<UInt32>.stride
            ) {
            buffer.label = "overlay-tagged-edges"
            taggedIndexBuffer = buffer
            taggedIndexCount = taggedEdges.count
        } else {
            taggedIndexBuffer = nil
            taggedIndexCount = 0
        }
        return true
    }

    func clear() {
        edgeIndexCount = 0
        vertexCount = 0
        taggedIndexCount = 0
        taggedIndexBuffer = nil
        clearHoverHighlight()
        clearAnnotations()
        bufferPool.clear()
    }

    /// Uploads the hover-preview highlight (task 3.6): `segments` are
    /// line-list vertices (x,y,z each, consecutive pairs), `points` are
    /// point-primitive vertices (the snap-target dot). Both live in ONE
    /// small buffer — segments first, points appended — replaced only when
    /// the preview changes. Empty input clears the pass.
    func setHoverHighlight(segments: [Float], points: [Float]) {
        let floats = segments + points
        guard
            !floats.isEmpty,
            let buffer = device.makeBuffer(
                bytes: floats, length: floats.count * MemoryLayout<Float>.stride
            )
        else {
            clearHoverHighlight()
            return
        }
        buffer.label = "overlay-hover-highlight"
        hoverVertexBuffer = buffer
        hoverSegmentVertexCount = segments.count / 3
        hoverPointVertexCount = points.count / 3
    }

    func clearHoverHighlight() {
        hoverSegmentVertexCount = 0
        hoverPointVertexCount = 0
        hoverVertexBuffer = nil
    }

    /// Uploads the annotation pass (task 4.3): pin marker points followed
    /// by each tag colour group's line-list segments, all in ONE buffer
    /// laid out in draw order. Replaced only when the ANNOTATIONS change
    /// (a journaled pin/tag edit), never at frame time. Empty state
    /// clears the pass.
    func setAnnotations(_ state: AnnotationRenderState) {
        var floats = state.pinPoints
        var groups: [(color: SIMD3<Float>, vertexStart: Int, vertexCount: Int)] = []
        for group in state.lineGroups where !group.segments.isEmpty {
            groups.append(
                (
                    color: group.color, vertexStart: floats.count / 3,
                    vertexCount: group.segments.count / 3
                ))
            floats.append(contentsOf: group.segments)
        }
        guard
            !floats.isEmpty,
            let buffer = device.makeBuffer(
                bytes: floats, length: floats.count * MemoryLayout<Float>.stride
            )
        else {
            clearAnnotations()
            return
        }
        buffer.label = "overlay-annotations"
        annotationVertexBuffer = buffer
        pinPointCount = state.pinPoints.count / 3
        tagColorGroups = groups
    }

    func clearAnnotations() {
        pinPointCount = 0
        tagColorGroups = []
        annotationVertexBuffer = nil
    }

    /// Encodes the overlay over an already-encoded Target. Binds pooled
    /// buffers only (never allocates at frame time). The hover highlight
    /// (task 3.6) draws AFTER the wire so it reads on top, and outside the
    /// wire guards so a preview stays visible at wireframe opacity 0.
    func encode(
        into encoder: MTLRenderCommandEncoder,
        mvp: simd_float4x4,
        settings: OverlaySettings,
        viewport: OverlayViewport = OverlayViewport(),
        animationProgress: Float
    ) {
        encodeWire(
            into: encoder, mvp: mvp, settings: settings,
            animationProgress: animationProgress, viewport: viewport
        )
        encodeAnnotations(into: encoder, mvp: mvp, settings: settings, viewport: viewport)
        encodeHoverHighlight(into: encoder, mvp: mvp, settings: settings, viewport: viewport)
    }

    /// Annotation pass (task 4.3): each tag colour group as a line list in
    /// its palette colour, then the pin markers as large yellow points on
    /// top (a pinned vertex ON a tagged loop must still read as pinned).
    /// Drawn outside the wire's opacity guard — annotations are document
    /// state, not wireframe decoration, so turning the wire down must not
    /// hide what the next Relax will refuse to move.
    private func encodeAnnotations(
        into encoder: MTLRenderCommandEncoder,
        mvp: simd_float4x4,
        settings: OverlaySettings,
        viewport: OverlayViewport
    ) {
        guard hasAnnotations, let buffer = annotationVertexBuffer else { return }
        encoder.setDepthStencilState(occludedDepthState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        for group in tagColorGroups {
            var uniforms = OverlayUniformsFactory.tagColor(
                group.color, mvp: mvp, settings: settings, viewport: viewport
            )
            bind(&uniforms, into: encoder)
            encodeRibbons(
                sequentialIn: buffer, vertexStart: group.vertexStart,
                vertexCount: group.vertexCount, into: encoder
            )
        }
        if pinPointCount > 0 {
            var uniforms = OverlayUniformsFactory.pins(
                mvp: mvp, settings: settings, viewport: viewport
            )
            bind(&uniforms, into: encoder)
            // The ribbon groups above rebased the position buffer; pins
            // live at the head of the same buffer.
            encoder.setVertexBufferOffset(0, index: 0)
            encoder.setRenderPipelineState(pointPipelineState)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: pinPointCount)
        }
    }

    private func encodeWire(
        into encoder: MTLRenderCommandEncoder,
        mvp: simd_float4x4,
        settings: OverlaySettings,
        animationProgress: Float,
        viewport: OverlayViewport
    ) {
        guard
            hasGeometry,
            settings.opacity > 0,
            animationProgress > 0,
            let positions = bufferPool.buffer(for: .position),
            let edges = bufferPool.buffer(for: .index)
        else { return }

        encoder.setVertexBuffer(positions, offset: 0, index: 0)

        var uniforms = OverlayUniformsFactory.main(
            mvp: mvp, settings: settings,
            animationProgress: animationProgress, vertexCount: vertexCount,
            viewport: viewport
        )
        encoder.setDepthStencilState(occludedDepthState)
        draw(edges: edges, uniforms: &uniforms, into: encoder)

        // Loop-tag pass (task 3.4): tagged edges re-drawn in the tag color
        // over the base wire (minimal colored-line render; styles in 4.3).
        // Task 4.3 supersedes this flat pass with the per-colour
        // annotation pass; it stays as the fallback for overlays loaded
        // without annotation state (engine-filtered tagged edges only).
        if taggedIndexCount > 0, tagColorGroups.isEmpty, let taggedBuffer = taggedIndexBuffer {
            var tagUniforms = OverlayUniformsFactory.tagged(
                mvp: mvp, settings: settings,
                animationProgress: animationProgress, vertexCount: vertexCount,
                viewport: viewport
            )
            bind(&tagUniforms, into: encoder)
            encodeRibbons(indexedBy: taggedBuffer, indexCount: taggedIndexCount, into: encoder)
        }

        if settings.xrayEnabled {
            var xrayUniforms = OverlayUniformsFactory.xray(
                mvp: mvp, settings: settings,
                animationProgress: animationProgress, vertexCount: vertexCount,
                viewport: viewport
            )
            encoder.setDepthStencilState(xrayDepthState)
            draw(edges: edges, uniforms: &xrayUniforms, into: encoder)
        }
    }

    /// Hover-preview highlight pass (task 3.6): loop segments as a line
    /// list, the snap-target vertex as a large point, both from the
    /// standalone hover buffer. Same occluded depth strategy as the wire
    /// (compare ≤ with the configurable bias, writes off).
    private func encodeHoverHighlight(
        into encoder: MTLRenderCommandEncoder,
        mvp: simd_float4x4,
        settings: OverlaySettings,
        viewport: OverlayViewport
    ) {
        guard hasHoverHighlight, let buffer = hoverVertexBuffer else { return }
        var uniforms = OverlayUniformsFactory.hover(
            mvp: mvp, settings: settings, viewport: viewport
        )
        encoder.setDepthStencilState(occludedDepthState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        bind(&uniforms, into: encoder)
        encodeRibbons(
            sequentialIn: buffer, vertexStart: 0,
            vertexCount: hoverSegmentVertexCount, into: encoder
        )
        if hoverPointVertexCount > 0 {
            // Rebased by the ribbon draw above; the points are absolute
            // offsets into the same buffer.
            encoder.setVertexBufferOffset(0, index: 0)
            encoder.setRenderPipelineState(pointPipelineState)
            encoder.drawPrimitives(
                type: .point, vertexStart: hoverSegmentVertexCount,
                vertexCount: hoverPointVertexCount
            )
        }
    }

    private func draw(
        edges: MTLBuffer, uniforms: inout OverlayUniforms,
        into encoder: MTLRenderCommandEncoder
    ) {
        bind(&uniforms, into: encoder)
        encodeRibbons(indexedBy: edges, indexCount: edgeIndexCount, into: encoder)
        // Vertex dots reuse the same bound buffers/uniforms as points.
        encoder.setRenderPipelineState(pointPipelineState)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: vertexCount)
    }

    private func bind(
        _ uniforms: inout OverlayUniforms, into encoder: MTLRenderCommandEncoder
    ) {
        encoder.setVertexBytes(
            &uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 1
        )
        encoder.setFragmentBytes(
            &uniforms, length: MemoryLayout<OverlayUniforms>.stride, index: 0
        )
    }

    /// Draws an indexed line list as screen-space ribbons: six vertices per
    /// edge, expanded in the vertex shader. Metal has no line width — a
    /// `.line` primitive is always one pixel, which on a 3x display is a
    /// third of a point.
    private func encodeRibbons(
        indexedBy indices: MTLBuffer, indexCount: Int,
        into encoder: MTLRenderCommandEncoder
    ) {
        guard indexCount >= 2 else { return }
        encoder.setRenderPipelineState(indexedLinePipelineState)
        encoder.setVertexBuffer(indices, offset: 0, index: 2)
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0,
            vertexCount: (indexCount / 2) * Self.verticesPerSegment
        )
    }

    /// Same, for vertex ranges that ARE the line list (consecutive pairs,
    /// no index buffer). The group's start becomes a buffer offset so the
    /// shader can index from zero — no per-group index buffer, no extra
    /// uniform, and nothing allocated at frame time.
    private func encodeRibbons(
        sequentialIn positions: MTLBuffer, vertexStart: Int, vertexCount: Int,
        into encoder: MTLRenderCommandEncoder
    ) {
        guard vertexCount >= 2 else { return }
        encoder.setRenderPipelineState(sequentialLinePipelineState)
        encoder.setVertexBufferOffset(vertexStart * Self.positionStride, index: 0)
        encoder.drawPrimitives(
            type: .triangle, vertexStart: 0,
            vertexCount: (vertexCount / 2) * Self.verticesPerSegment
        )
    }

    // MARK: - Shader

    /// Line/point overlay shader. Compiled at runtime like the target
    /// pipeline (works identically in app bundle and unit tests).
    ///
    /// Edges are drawn as screen-space RIBBONS, not `.line` primitives:
    /// Metal exposes no line width, so a line list is always exactly one
    /// pixel wide — a third of a point on the 3x displays this app targets,
    /// and a hairline the user cannot judge topology by. Each edge is
    /// expanded in the vertex shader into two triangles of a fixed pixel
    /// width, with analytic edge antialiasing in the fragment shader.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct OverlayUniforms {
        float4x4 mvp;
        float4   color;   // rgb theme, a = opacity
        float4   params;  // x anim progress, y NDC depth bias,
                          // z x-ray attenuation, w vertex count
        float4   misc;    // x point size (px), y x-ray pass flag
        float4   line;    // x line width (px), yz drawable size (px)
    };

    struct OverlayVertexOut {
        float4 position [[position]];
        float  pointSize [[point_size]];
        float  sweep;   // per-vertex sweep coordinate for the creation anim
    };

    struct OverlayLineVertexOut {
        float4 position [[position]];
        float  sweep;
        float  edgePixels;  // signed distance from the ribbon's centerline
    };

    // Sweep coordinate: vertex order fraction (engine-compacted order is
    // spatially coherent for imports). Time only moves the uniform.
    static inline float overlay_sweep(uint vid, constant OverlayUniforms& u) {
        return u.params.w > 0.0 ? float(vid) / u.params.w : 0.0;
    }

    // Occlusion threshold: pull the overlay toward the camera by a
    // configurable NDC depth bias so edges slightly behind the Target
    // surface stay visible (spec: occlusion depth threshold).
    static inline float4 overlay_clip(float3 p, constant OverlayUniforms& u) {
        float4 clip = u.mvp * float4(p, 1.0);
        clip.z -= u.params.y * clip.w;
        return clip;
    }

    // Expands one edge into a screen-space ribbon `u.line.x` pixels wide.
    // `corner` is 0...5 over two triangles of the quad whose corners are
    // (endpoint a | b) x (side - | +).
    static OverlayLineVertexOut overlay_ribbon(
        float3 pa, float3 pb, float sweepA, float sweepB,
        uint corner, constant OverlayUniforms& u)
    {
        OverlayLineVertexOut out;
        float4 ca = overlay_clip(pa, u);
        float4 cb = overlay_clip(pb, u);

        // Screen-space expansion is only meaningful in front of the eye.
        // Line primitives got near-plane clipping from the hardware for
        // free; ribbons must do it themselves, or an edge crossing behind
        // the camera (routine — the user can orbit inside the mesh) smears
        // across the viewport.
        const float kNear = 1e-4;
        if (ca.w < kNear && cb.w < kNear) {
            // Wholly behind the eye: collapse outside NDC, rasterize nothing.
            out.position = float4(0.0, 0.0, 2.0, 1.0);
            out.sweep = 0.0;
            out.edgePixels = 0.0;
            return out;
        }
        if (ca.w < kNear) {
            float t = (kNear - ca.w) / (cb.w - ca.w);
            ca = mix(ca, cb, t);
            sweepA = mix(sweepA, sweepB, t);
        } else if (cb.w < kNear) {
            float t = (kNear - cb.w) / (ca.w - cb.w);
            cb = mix(cb, ca, t);
            sweepB = mix(sweepB, sweepA, t);
        }

        float2 halfViewport = max(u.line.yz, float2(1.0)) * 0.5;
        float2 screenA = (ca.xy / ca.w) * halfViewport;
        float2 screenB = (cb.xy / cb.w) * halfViewport;
        float2 delta = screenB - screenA;
        float span = length(delta);
        float2 direction = span > 1e-6 ? delta / span : float2(1.0, 0.0);
        float2 sideways = float2(-direction.y, direction.x);

        // Half a pixel of padding on each side is what the fragment
        // shader's analytic antialiasing feathers across.
        float reach = u.line.x * 0.5 + 0.5;
        // Two triangles over quad corners (a-, a+, b-, b+) = (0, 1, 2, 3).
        const uint kQuadCorner[6] = {0u, 1u, 2u, 2u, 1u, 3u};
        uint quadCorner = kQuadCorner[corner];
        bool atB = quadCorner >= 2u;
        float side = (quadCorner & 1u) != 0u ? 1.0 : -1.0;

        float4 clip = atB ? cb : ca;
        clip.xy += (sideways * side * reach / halfViewport) * clip.w;
        out.position = clip;
        out.sweep = atB ? sweepB : sweepA;
        out.edgePixels = side * reach;
        return out;
    }

    // Ribbons over an INDEXED line list (the wireframe, tagged edges).
    vertex OverlayLineVertexOut overlay_line_indexed_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        constant OverlayUniforms& u           [[buffer(1)]],
        const device uint* lineIndices        [[buffer(2)]])
    {
        uint segment = vid / 6u;
        uint ia = lineIndices[segment * 2u];
        uint ib = lineIndices[segment * 2u + 1u];
        return overlay_ribbon(
            float3(positions[ia]), float3(positions[ib]),
            overlay_sweep(ia, u), overlay_sweep(ib, u), vid % 6u, u);
    }

    // Ribbons over CONSECUTIVE vertex pairs (hover segments, annotation
    // groups). The caller rebases the position buffer so segment 0 starts
    // at vertex 0.
    vertex OverlayLineVertexOut overlay_line_sequential_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        constant OverlayUniforms& u           [[buffer(1)]])
    {
        uint segment = vid / 6u;
        uint ia = segment * 2u;
        uint ib = ia + 1u;
        return overlay_ribbon(
            float3(positions[ia]), float3(positions[ib]),
            overlay_sweep(ia, u), overlay_sweep(ib, u), vid % 6u, u);
    }

    vertex OverlayVertexOut overlay_vertex(
        uint vid [[vertex_id]],
        const device packed_float3* positions [[buffer(0)]],
        constant OverlayUniforms& u           [[buffer(1)]])
    {
        OverlayVertexOut out;
        out.position = overlay_clip(float3(positions[vid]), u);
        out.pointSize = u.misc.x;
        out.sweep = overlay_sweep(vid, u);
        return out;
    }

    // Creation micro-animation: index-ordered sweep with a soft fade
    // front, fully revealed at progress 1.
    static inline float overlay_alpha(float sweep, float depth,
                                      constant OverlayUniforms& u) {
        float reveal = clamp((u.params.x * 1.2 - sweep) / 0.2, 0.0, 1.0);
        float alpha = u.color.a * reveal;
        if (u.misc.y > 0.5) {
            // X-ray pass: far-side wireframe, depth-attenuated (farther
            // fragments fade toward the attenuation floor).
            alpha *= u.params.z * (1.0 - 0.5 * depth);
        }
        return alpha;
    }

    fragment float4 overlay_line_fragment(
        OverlayLineVertexOut in [[stage_in]],
        constant OverlayUniforms& u [[buffer(0)]])
    {
        float alpha = overlay_alpha(in.sweep, in.position.z, u);
        // Analytic antialiasing across the half pixel of padding the
        // ribbon was expanded by: full alpha inside the nominal width,
        // ramping to zero over the last pixel of the edge.
        alpha *= saturate(u.line.x * 0.5 + 0.5 - abs(in.edgePixels));
        return float4(u.color.rgb, alpha);
    }

    fragment float4 overlay_point_fragment(
        OverlayVertexOut in [[stage_in]],
        float2 pointCoord [[point_coord]],
        constant OverlayUniforms& u [[buffer(0)]])
    {
        // Round dots. Square points read as blocky pixels beside an
        // antialiased wire, and the reference app's vertices are circles.
        float radius = length(pointCoord - 0.5) * 2.0;
        if (radius > 1.0) { discard_fragment(); }
        float alpha = overlay_alpha(in.sweep, in.position.z, u);
        // Feather the outermost pixel of the dot (radius spans half the
        // point size in pixels).
        alpha *= saturate((1.0 - radius) * max(u.misc.x, 1.0) * 0.5);
        return float4(u.color.rgb, alpha);
    }
    """
}
