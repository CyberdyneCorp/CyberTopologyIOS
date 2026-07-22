import CoreGraphics
import QuartzCore
import UIKit

/// Live ink trail drawn under the Pencil while a stroke is in progress
/// (spec: pencil-interaction / "Live stroke feedback").
///
/// Deliberately NOT a Metal pass and NOT a SwiftUI overlay. Ink latency is
/// the core feel of a drawing tool, and both alternatives add a hop the
/// samples do not otherwise take: the Metal view is render-on-demand
/// (`isPaused = true`), so ink would have to mark the whole viewport dirty
/// and wait for the next paced frame, and a SwiftUI `Canvas` would rebuild
/// through the view graph on every one of the 120-240 samples per second
/// the Pencil delivers. A `CAShapeLayer` sitting on the Metal view is
/// updated synchronously on the same turn the sample arrives, and Core
/// Animation composites it without involving the renderer at all.
///
/// The path is rebuilt rather than appended to because `CGMutablePath` has
/// no cheap "copy with one more point" and `CAShapeLayer` requires a new
/// immutable `CGPath` per update anyway; the cost is bounded by
/// `maximumPoints`.
@MainActor
final class LiveStrokeInk {
    /// Ink styling. Matches the overlay's authored-geometry palette rather
    /// than the wireframe cyan: the ink is the user's gesture, not
    /// committed topology, and reads over both light Targets and the dark
    /// viewport background.
    struct Style {
        var color: UIColor = .white
        var width: CGFloat = 3
        var opacity: Float = 0.95

        static let `default` = Style()
    }

    /// Hard cap on retained samples. A slow deliberate stroke at 240 Hz can
    /// run for many seconds; without a cap the path grows unbounded and
    /// each rebuild walks it. Oldest points drop first — the tail of a long
    /// stroke is what the user is watching.
    static let maximumPoints = 2048

    private let layer = CAShapeLayer()
    private var points: [CGPoint] = []
    private(set) var isActive = false

    var style: Style = .default {
        didSet { applyStyle() }
    }

    init() {
        layer.fillColor = nil
        layer.lineJoin = .round
        layer.lineCap = .round
        layer.isHidden = true
        // Ink must not animate: implicit CA animations would smear the
        // trail behind the pen by the animation duration, which is exactly
        // the lag this class exists to avoid.
        layer.actions = [
            "path": NSNull(), "hidden": NSNull(),
            "strokeColor": NSNull(), "lineWidth": NSNull(),
        ]
        applyStyle()
    }

    /// Installs the ink layer above `view`'s content.
    func attach(to view: UIView) {
        layer.frame = view.bounds
        view.layer.addSublayer(layer)
    }

    /// Keeps the layer aligned when the host view resizes (rotation, split
    /// view). Called from the host's layout pass.
    func layoutIfNeeded(in view: UIView) {
        guard layer.frame != view.bounds else { return }
        layer.frame = view.bounds
        rebuildPath()
    }

    /// Starts a new trail. `point` is in NORMALIZED viewport coordinates
    /// (the `StrokeSample` space), converted here against the layer bounds.
    func begin(at point: CGPoint) {
        points = [point]
        isActive = true
        layer.isHidden = false
        rebuildPath()
    }

    /// Appends one live sample.
    func append(_ point: CGPoint) {
        guard isActive else { return }
        points.append(point)
        if points.count > Self.maximumPoints {
            points.removeFirst(points.count - Self.maximumPoints)
        }
        rebuildPath()
    }

    /// Ends the trail and clears it. The committed result (a quad, a loop,
    /// a brush edit) is what the user should see next — leaving ink on
    /// screen would double-draw the gesture.
    func end() {
        guard isActive || !points.isEmpty else { return }
        points.removeAll(keepingCapacity: true)
        isActive = false
        layer.isHidden = true
        layer.path = nil
    }

    /// Current sample count, for tests.
    var pointCount: Int { points.count }

    /// Whether anything is currently drawn.
    var isVisible: Bool { !layer.isHidden && layer.path != nil }

    private func applyStyle() {
        layer.strokeColor = style.color.cgColor
        layer.lineWidth = style.width
        layer.opacity = style.opacity
    }

    private func rebuildPath() {
        guard points.count > 1 else {
            // A single sample has no segment to stroke; a dot would read as
            // a committed vertex, so draw nothing until the pen moves.
            layer.path = nil
            return
        }
        let size = layer.bounds.size
        guard size.width > 0, size.height > 0 else {
            layer.path = nil
            return
        }
        let path = CGMutablePath()
        path.move(to: viewPoint(points[0], in: size))
        for point in points.dropFirst() {
            path.addLine(to: viewPoint(point, in: size))
        }
        layer.path = path
    }

    /// Normalized viewport space -> layer space.
    private func viewPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
}
