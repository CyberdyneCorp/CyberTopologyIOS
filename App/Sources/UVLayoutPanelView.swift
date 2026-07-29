import CyberKit
import SwiftUI

/// The 2D UV view (openspec add-uv-stage-foundation, 6.1 task 3.2; spec: uv-workflow).
///
/// A SwiftUI `Canvas`, not a Metal render path. Every existing pass — Target, meshlet,
/// ghost, guide-line, EditMesh overlay — is world-space 3D: each takes an MVP, depth-tests
/// against the Target's depth buffer and is encoded into one render pass against one
/// camera. There is no 2D or screen-space pass to extend, so a Metal route means a second
/// MTKView host, a second renderer with its own resize and frame pacing, an ortho
/// transform, a pipeline and shader pair, and its own offscreen test harness: several
/// hundred lines of machinery to draw a few thousand static line segments that change only
/// on unwrap, undo or import. At EditMesh cage scale that is not a trade worth making.
///
/// The objection recorded against `Canvas` in `LiveStrokeInk` does not apply here: that
/// rejects Canvas for Pencil ink at 120–240 samples/second. A UV layout changes when
/// someone unwraps.
///
/// It also keeps 6.4's per-face distortion heatmap a fill rather than a new shader, and
/// leaves the geometry headless-testable as pure functions.
struct UVLayoutPanelView: View {
    let state: UVLayoutGeometry.State
    /// The report from the last unwrap this session, when there was one.
    let report: Mesh.AtlasReport?
    /// Why the last unwrap attempt did not commit — including the honest "already
    /// unwrapped" case, which is not an error.
    let notice: String?
    let onUnwrap: () -> Void
    /// A pending seam proposal (task 6.5), or empty when none is on offer. View state, so an
    /// artist can review before it becomes a document change — proposing is not accepting.
    var proposedSeamCount: Int = 0
    var onAcceptSeams: () -> Void = {}
    var onDiscardSeams: () -> Void = {}
    /// Packing aids (6.6). Mirrored islands are passed as representative FACE ids, so the
    /// panel can offer a flip without reproducing the engine's island partition itself.
    var flippedIslandFaces: [UInt32] = []
    var onPack: () -> Void = {}
    var onDistribute: () -> Void = {}
    var onFlipIsland: (UInt32) -> Void = { _ in }
    /// 6.7: occupied UDIM tiles and islands spanning more than one of them.
    var udimTiles: [Int32] = []
    var straddlingIslandCount: Int = 0
    var onStackMirrored: () -> Void = {}
    /// 6.3: a completed 2D island gesture — the representative face plus the transform.
    var onTransformIsland: (UInt32, UVIslandGesture.Transform) -> Void = { _, _ in }
    var onGridStraighten: (UInt32) -> Void = { _ in }
    /// 6.3d: a completed per-VERTEX drag — face, the UV grabbed, and the delta.
    var onMoveUVVertex: (UInt32, SIMD2<Float>, SIMD2<Float>) -> Void = { _, _, _ in }
    /// 6.2 (2D half): toggle the seam on a picked mesh edge.
    var onToggleSeam: (UInt32) -> Void = { _ in }
    @Binding var editTarget: UVIslandGesture.EditTarget
    /// 6.3d: whether an imported preview image is available, and whether to show it.
    var previewImageLoaded: Bool = false
    @Binding var showsImportedImage: Bool
    /// Live drag state, held by the caller so it survives a body pass. nil when no drag is active.
    @Binding var activeDrag: UVLayoutPanelView.DragState?
    /// What the fill shades by. Held by the caller so the choice survives a body pass.
    @Binding var mode: UVLayoutGeometry.HeatmapMode
    /// The texture size texel density is expressed against. A density figure is meaningless
    /// without it, so it is shown alongside rather than assumed.
    let textureSize: Int

    /// An in-progress 2D island drag.
    ///
    /// The MODE is captured at the drag's START and never recomputed: reclassifying mid-drag
    /// would let a rotation turn into a scale as the finger crosses a zone boundary, which is
    /// exactly the kind of surprise a direct-manipulation gesture must not produce.
    struct DragState: Equatable {
        var ringIndex: Int
        var face: UInt32
        var mode: UVIslandGesture.Mode
        var start: SIMD2<Float>
        var current: SIMD2<Float>
        var centre: SIMD2<Float>
        /// Captured at drag start along with the mode, so switching the mode mid-drag cannot change
        /// what the drag in flight is doing.
        var target: UVIslandGesture.EditTarget = .island

        var transform: UVIslandGesture.Transform {
            UVIslandGesture.transform(mode: mode, from: start, to: current, about: centre)
        }

        /// The per-vertex delta: a plain translation, because moving one vertex has no pivot to
        /// rotate or scale about.
        var vertexDelta: SIMD2<Float> { current - start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("UV Layout")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            switch state {
            case .laidOut(let layout):
                if !layout.distortion.isEmpty {
                    Picker("Shade by", selection: $mode) {
                        ForEach(UVLayoutGeometry.HeatmapMode.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("uv-heatmap-mode")
                }
                layoutCanvas(layout)
                footer(layout)
            case .notUnwrapped(let faceCount):
                // Never an empty square: an empty square reads as a broken view, and the
                // spec requires this to say there is no layout yet AND offer to unwrap.
                empty(
                    title: "No UV layout yet",
                    message: "\(faceCount) face\(faceCount == 1 ? "" : "s") ready to unwrap.",
                    symbol: "square.dashed",
                    showsUnwrap: true
                )
            case .noEditMesh:
                empty(
                    title: "No EditMesh",
                    message: "Retopologize first — UVs are laid out on the clean cage, "
                        + "not on the Target.",
                    symbol: "square.on.square.dashed",
                    showsUnwrap: false
                )
            case .unreadable(let reason):
                // Surfaced, not drawn. A sheared layout looks plausible and would be
                // believed, which is worse than showing nothing.
                empty(
                    title: "UV layout unreadable",
                    message: reason,
                    symbol: "exclamationmark.triangle",
                    showsUnwrap: false
                )
            }

            if proposedSeamCount > 0 {
                seamProposalBar
            }

            if case .laidOut = state {
                Picker("Edit", selection: $editTarget) {
                    Text("Island").tag(UVIslandGesture.EditTarget.island)
                    Text("Vertex").tag(UVIslandGesture.EditTarget.vertex)
                    Text("Seam").tag(UVIslandGesture.EditTarget.seam)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("uv-edit-target")
                // Offered only once an image is loaded: a toggle that cannot do anything reads as
                // broken, and the checker is what shows without one.
                if previewImageLoaded {
                    Toggle("Show imported image", isOn: $showsImportedImage)
                        .font(.caption)
                        .accessibilityIdentifier("uv-show-imported-image")
                }
                packingAids
            }

            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("uv-notice")
            }
        }
        .padding(12)
        .frame(minWidth: 260)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    /// Packing aids: repack, distribute, and a per-island flip for mirrored shells (6.6).
    ///
    /// The flip is offered ONE island at a time rather than as a "fix all" button. A mirrored
    /// island is sometimes deliberate — a stacked mirror pair shares UV space on purpose — so
    /// flipping every one of them could undo an intentional layout. Naming them and letting the
    /// artist choose is the difference between a report and an opinion.
    private var packingAids: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Pack", action: onPack)
                    .accessibilityIdentifier("uv-pack")
                Button("Distribute", action: onDistribute)
                    .accessibilityIdentifier("uv-distribute")
                Button("Stack mirrored", action: onStackMirrored)
                    .accessibilityIdentifier("uv-stack-mirrored")
            }
            .buttonStyle(.bordered)
            .font(.caption)

            udimRow

            if !flippedIslandFaces.isEmpty {
                Text(
                    "\(flippedIslandFaces.count) mirrored island"
                        + (flippedIslandFaces.count == 1 ? "" : "s")
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
                Text("A mirrored island bakes inverted detail. Flip one back:")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                // Wrapped so a layout with many mirrored islands does not run off the panel.
                HStack(spacing: 6) {
                    ForEach(flippedIslandFaces.prefix(6), id: \.self) { face in
                        Button {
                            onFlipIsland(face)
                        } label: {
                            Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                                .labelStyle(.iconOnly)
                        }
                        .accessibilityLabel("Flip mirrored island \(face)")
                    }
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("uv-flip-islands")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("uv-packing-aids")
    }

    /// UDIM readout (6.7).
    ///
    /// Shown only once the layout uses more than one tile, because "tile 1001" is the default
    /// every single-tile layout sits in and stating it would be noise. A STRADDLING island is
    /// always called out: it is split across texture files on export, which is almost never
    /// intended and is invisible in the 2D view without being named.
    @ViewBuilder
    private var udimRow: some View {
        if udimTiles.count > 1 {
            Text("UDIM tiles: " + udimTiles.map(String.init).joined(separator: ", "))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("uv-udim-tiles")
        }
        if straddlingIslandCount > 0 {
            Text(
                "\(straddlingIslandCount) island\(straddlingIslandCount == 1 ? "" : "s") "
                    + "cross a tile border — each will be split across texture files"
            )
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityIdentifier("uv-udim-straddle")
        }
    }

    /// Accept / Discard for a pending proposal.
    ///
    /// Both are offered explicitly. A proposal that could only be accepted — or that applied
    /// itself and relied on undo — would make "propose" a synonym for "do it", and the spec's
    /// guarantee is that discarding leaves NO trace, which a journaled-then-undone edit does
    /// not satisfy.
    private var seamProposalBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(proposedSeamCount) seam\(proposedSeamCount == 1 ? "" : "s") proposed")
                .font(.caption.weight(.medium))
                // The amber the viewport draws them in, so the panel and the overlay are
                // obviously talking about the same edges.
                .foregroundStyle(.orange)
            Text("Shown in amber on the cage. Accepting only ADDS — it never removes a seam "
                + "you drew.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Accept", action: onAcceptSeams)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("uv-accept-seams")
                Button("Discard", action: onDiscardSeams)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("uv-discard-seams")
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("uv-seam-proposal")
    }

    private func layoutCanvas(_ layout: UVLayoutGeometry.Layout) -> some View {
        Canvas { context, size in
            let rect = Self.squareRect(in: size)
            // The unit tile, so an artist can see where the packing boundary is and
            // whether anything crossed it.
            context.stroke(
                Path(rect), with: .color(.secondary.opacity(0.6)), lineWidth: 1
            )
            // FILL first, then stroke: the fill answers "where is the distortion" and the
            // stroke keeps face boundaries legible on top of it. Filling per ring rather
            // than one merged path because each face carries its own measurement.
            if !layout.distortion.isEmpty {
                for (index, ring) in layout.rings.enumerated()
                where index < layout.distortion.count {
                    let face = layout.distortion[index]
                    context.fill(
                        Self.path(for: [ring], in: rect),
                        with: .color(
                            Self.color(
                                for: face, mode: mode, textureSize: textureSize,
                                reference: layout.referenceDensity(textureSize: textureSize)
                            )
                        )
                    )
                }
            }
            context.stroke(
                Self.path(for: layout.rings, in: rect),
                with: .color(Color(rgb: OverlayUniformsFactory.wireColor)),
                lineWidth: 1
            )
        }
        .aspectRatio(1, contentMode: .fit)
        // The gesture goes on a transparent overlay rather than the Canvas itself so it can be
        // given the canvas's real size: the drag has to convert view points into UV space, and
        // the Canvas's own `size` is only available inside its draw closure.
        .overlay {
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(islandDrag(layout, in: geometry.size))
            }
        }
        .accessibilityIdentifier("uv-canvas")
        .accessibilityLabel(
            "UV layout, \(layout.ringCount) faces"
                + (layout.overflowCorners > 0
                    ? ", \(layout.overflowCorners) corners outside the square" : "")
        )
    }

    /// The 2D island grammar: where a drag STARTS decides what it does (6.3).
    ///
    /// A drag rather than a tap-then-mode: the spec's grammar is positional, so the artist aims
    /// instead of selecting a tool first. The transform is applied on RELEASE as one journaled
    /// step; nothing is committed while the finger is down, so a drag can be abandoned by
    /// dragging back.
    private func islandDrag(
        _ layout: UVLayoutGeometry.Layout, in size: CGSize
    ) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .local)
            .onChanged { value in
                let rect = Self.squareRect(in: size)
                guard rect.width > 0 else { return }
                let start = Self.uv(at: value.startLocation, in: rect)
                let current = Self.uv(at: value.location, in: rect)
                if var drag = activeDrag {
                    drag.current = current
                    activeDrag = drag
                    return
                }
                // Seam mode resolves on the FIRST sample and consumes the drag: a seam toggle has no
                // continuous magnitude, so waiting for release would leave the artist watching
                // nothing happen while their finger moved.
                if editTarget == .seam {
                    if let pick = layout.nearestSegment(
                        to: start, maxDistance: UVIslandGesture.seamPickDistance
                    ), let edge = layout.edgeID(ring: pick.ring, segment: pick.segment) {
                        onToggleSeam(edge)
                    }
                    // Marked handled either way, so a missed pick does not fall through and start an
                    // island transform the artist never asked for.
                    activeDrag = DragState(
                        ringIndex: 0, face: 0, mode: .move, start: start, current: start,
                        centre: start, target: .seam
                    )
                    return
                }
                guard let index = layout.ringIndex(at: start),
                    index < layout.faceIDs.count
                else { return }
                let box = UVLayoutGeometry.Layout.bounds(layout.rings[index])
                activeDrag = DragState(
                    ringIndex: index,
                    face: layout.faceIDs[index],
                    mode: UVIslandGesture.mode(forStartingAt: start, in: box),
                    start: start,
                    current: current,
                    centre: (box.min + box.max) * 0.5,
                    target: editTarget
                )
            }
            .onEnded { _ in
                guard let drag = activeDrag else { return }
                activeDrag = nil
                switch drag.target {
                case .island:
                    onTransformIsland(drag.face, drag.transform)
                case .vertex:
                    // `start` is where the artist grabbed, which is the UV the engine matches
                    // against — not the island centre and not the current position.
                    onMoveUVVertex(drag.face, drag.start, drag.vertexDelta)
                case .seam:
                    break  // already applied on the first sample
                }
            }
    }

    /// UV coordinates for a point in the canvas, undoing the v flip `path` applies.
    static func uv(at point: CGPoint, in rect: CGRect) -> SIMD2<Float> {
        guard rect.width > 0, rect.height > 0 else { return .zero }
        return SIMD2(
            Float((point.x - rect.minX) / rect.width),
            Float(1 - (point.y - rect.minY) / rect.height)
        )
    }

    private func footer(_ layout: UVLayoutGeometry.Layout) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            // Only what is honestly computable from the geometry in hand. Chart counts and
            // distortion come from the engine's report and are shown ONLY when an unwrap
            // happened this session — inventing them from the rings would be a second,
            // weaker source of truth for the same question.
            Text("\(layout.ringCount) faces · \(layout.cornerCount) corners")
            if layout.overflowCorners > 0 {
                Text("\(layout.overflowCorners) corners outside the unit square")
                    .foregroundStyle(.orange)
            }
            // Flipped faces are NAMED, not merely shaded: a mirrored face bakes inverted
            // detail, so it is a defect rather than a point on the scale.
            if layout.flippedFaces > 0 {
                Text("\(layout.flippedFaces) FLIPPED face\(layout.flippedFaces == 1 ? "" : "s")")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("uv-flipped")
            }
            if mode == .texelDensity, !layout.distortion.isEmpty {
                // The size the figure is expressed against, stated rather than implied.
                Text("density at \(textureSize)px")
            }
            if let worst = layout.worstAngle {
                Text(String(format: "worst angle error %.3f", worst))
            }
            if let report {
                Text(report.summary)
                    .accessibilityIdentifier("uv-report")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("uv-status")
    }

    private func empty(
        title: String, message: String, symbol: String, showsUnwrap: Bool
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title).font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if showsUnwrap {
                // A real offer, not a disabled control: the spec's scenario is that the
                // view "SHALL state that there is no UV layout yet AND OFFER TO UNWRAP".
                Button("Unwrap", action: onUnwrap)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("uv-unwrap")
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .accessibilityIdentifier("uv-empty-state")
    }

    // MARK: - Pure geometry (testable without a GPU or a view)

    /// The largest centred square inside `size`, so the unit UV square is never stretched —
    /// a non-square aspect would misrepresent distortion, which is the thing this view
    /// exists to let someone judge.
    static func squareRect(in size: CGSize) -> CGRect {
        let side = max(0, min(size.width, size.height))
        return CGRect(
            x: (size.width - side) / 2, y: (size.height - side) / 2,
            width: side, height: side
        )
    }

    /// Heat colour for one face.
    ///
    /// Angle error is already normalised to [0, 1) by definition, so it maps directly.
    /// Texel density has no natural ceiling, so it is shown RELATIVE to the layout's own
    /// median — an absolute scale would need a target density nobody has specified, and
    /// inventing one would make the colours mean something the artist never asked for.
    /// Relative shading answers the question density is actually asked for: which faces get
    /// fewer texels than the rest.
    ///
    /// A flipped face is red regardless of mode, because it is a defect rather than a
    /// magnitude.
    static func color(
        for face: Mesh.FaceDistortion, mode: UVLayoutGeometry.HeatmapMode,
        textureSize: Int, reference: Float
    ) -> Color {
        if face.flipped { return .red.opacity(0.55) }
        let t: Float
        switch mode {
        case .angle:
            t = min(max(face.angle, 0), 1)
        case .texelDensity:
            guard reference > 0 else { return .clear }
            // Below reference is under-sampled and is what needs attention, so LOW density
            // reads as hot. Clamped at twice the reference: beyond that the difference stops
            // being actionable and a longer tail would flatten everything else.
            let ratio = face.texelDensity(textureSize: textureSize) / reference
            t = min(max(1 - ratio, 0), 1)
        }
        // Cool (fine) to warm (bad). Kept deliberately plain: a ramp is presentation, and
        // this change does not pretend to have measured which one reads best.
        return Color(hue: Double(0.58 - 0.58 * Double(t)), saturation: 0.85, brightness: 0.9)
            .opacity(0.45)
    }

    /// Closed polygons for each ring, mapped into `rect`.
    ///
    /// v is FLIPPED: UV origin is bottom-left and view coordinates are top-left, so drawing
    /// v directly would render every layout upside down against every other tool.
    static func path(for rings: [[SIMD2<Float>]], in rect: CGRect) -> Path {
        var path = Path()
        for ring in rings where ring.count >= 2 {
            let points = ring.map { uv in
                CGPoint(
                    x: rect.minX + CGFloat(uv.x) * rect.width,
                    y: rect.minY + CGFloat(1 - uv.y) * rect.height
                )
            }
            path.addLines(points)
            path.closeSubpath()
        }
        return path
    }
}
