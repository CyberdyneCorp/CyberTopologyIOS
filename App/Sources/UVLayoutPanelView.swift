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
    /// What the fill shades by. Held by the caller so the choice survives a body pass.
    @Binding var mode: UVLayoutGeometry.HeatmapMode
    /// The texture size texel density is expressed against. A density figure is meaningless
    /// without it, so it is shown alongside rather than assumed.
    let textureSize: Int

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
        .accessibilityIdentifier("uv-canvas")
        .accessibilityLabel(
            "UV layout, \(layout.ringCount) faces"
                + (layout.overflowCorners > 0
                    ? ", \(layout.overflowCorners) corners outside the square" : "")
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
