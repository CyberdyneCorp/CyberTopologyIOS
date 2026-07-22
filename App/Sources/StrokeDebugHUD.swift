#if DEBUG
    import CyberKit
    import SwiftUI

    /// DEBUG-build recognizer HUD (task 3.2; design D5: "interpretation
    /// records + debug HUD from day one"). Overlays the viewport with the
    /// last completed stroke's polyline (normalized viewport coordinates,
    /// re-projected to the current size) and the full interpretation record:
    /// classified shape + confidence, resolved mesh context, and every
    /// ranked candidate with the engine element ids it would touch.
    ///
    /// Toggled from the viewport settings popover
    /// (`ViewportSettings.strokeDebugHUDKey`); compiled out of Release.
    /// Never hit-testable — it must not eat viewport touches.
    struct StrokeDebugHUD: View {
        /// Normalized viewport polyline of the last stroke (origin top-left).
        let polyline: [CGPoint]
        /// Interpretation record of the last stroke, nil before the first
        /// stroke or when the recognizer rejected the samples.
        let interpretation: StrokeInterpretation?

        var body: some View {
            ZStack(alignment: .topTrailing) {
                GeometryReader { proxy in
                    Self.strokePath(for: polyline, in: proxy.size)
                        .stroke(
                            Color.orange.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                        )
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(
                        Array(Self.recordLines(for: interpretation).enumerated()),
                        id: \.offset
                    ) { _, line in
                        Text(line)
                    }
                }
                .font(.caption2.monospaced())
                .foregroundStyle(.orange)
                .padding(8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("stroke-debug-record")
                .padding(10)
            }
            .allowsHitTesting(false)
        }

        /// The polyline scaled from normalized viewport coordinates into
        /// `size`. Static and pure so tests pin the mapping.
        static func strokePath(for polyline: [CGPoint], in size: CGSize) -> Path {
            var path = Path()
            guard polyline.count > 1 else { return path }
            let points = polyline.map {
                CGPoint(x: $0.x * size.width, y: $0.y * size.height)
            }
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
            return path
        }

        /// Human-readable interpretation record, one line per candidate.
        /// Confidences use two decimals like `StrokeInterpretation.summary`.
        static func recordLines(for interpretation: StrokeInterpretation?) -> [String] {
            guard let interpretation else { return ["no interpretation"] }
            var lines = [
                String(
                    format: "%@ %.2f on %@",
                    interpretation.shape.rawValue,
                    interpretation.shapeConfidence,
                    interpretation.context.rawValue
                )
            ]
            for (rank, candidate) in interpretation.candidates.enumerated() {
                let elements = candidate.elements
                    .map { "\($0.kind.rawValue):\($0.id)" }
                    .joined(separator: ",")
                lines.append(String(
                    format: "%d. %@ %.2f%@",
                    rank + 1, candidate.action.rawValue, candidate.confidence,
                    elements.isEmpty ? "" : " [\(elements)]"
                ))
            }
            return lines
        }
    }
#endif
