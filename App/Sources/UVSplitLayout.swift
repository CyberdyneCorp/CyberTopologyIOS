import CoreGraphics
import Foundation

/// Split-view layout state and its gestures (openspec add-uv-only-projects, 6.1a; spec:
/// uv-workflow / "Split-view UV layout").
///
/// Pure: no SwiftUI, so every transition is testable headless.
///
/// Maximizing is done by SIZING, never by re-parenting. `DocumentEditorView` already documents
/// why: moving the viewport between containers gives it a new SwiftUI identity, which re-creates
/// `MetalViewport.Coordinator` — new MTKView and renderer, meshes reloaded, camera framing lost.
/// So both views stay in the same container and their widths change. A zero-width viewport is
/// safe: `ViewportRenderer.setViewportSize` ignores a non-positive size and keeps its last one.
enum UVSplitLayout: String, Equatable, CaseIterable {
    /// Both visible, side by side.
    case split
    /// The 3D viewport fills the workspace.
    case maximizedViewport
    /// The 2D UV panel fills the workspace.
    case maximizedPanel

    /// Fraction of the workspace width given to the 2D panel.
    ///
    /// Returned as a fraction rather than a point width so the caller can apply it to whatever
    /// space it actually has, and so the values are assertable without laying anything out.
    var panelWidthFraction: CGFloat {
        switch self {
        case .split: return Self.splitFraction
        case .maximizedViewport: return 0
        case .maximizedPanel: return 1
        }
    }

    /// The 2D panel's share when split. Under half: the 3D model is what an artist is looking at
    /// while judging a layout, and the panel is a reference beside it.
    static let splitFraction: CGFloat = 0.38

    /// Gestures the split layout responds to.
    enum Gesture: Equatable {
        /// A swipe inward from the trailing (2D-side) screen edge.
        case swipeFromPanelEdge
        /// A vertical line drawn down the middle, where the divider sits.
        case lineDownDivider
        /// A swipe OUTWARD, pushing the panel off toward the trailing edge.
        case swipePanelAway

        /// Every gesture, so a test can assert no layout state is a dead end.
        static let allPathsBackToSplit: [Gesture] = [
            .swipeFromPanelEdge, .lineDownDivider, .swipePanelAway,
        ]
    }

    /// The layout after `gesture`.
    ///
    /// The divider line always RESTORES rather than toggling: the spec's scenario is maximize,
    /// then re-split, and a toggle would make the same gesture undo itself when repeated, which
    /// is exactly the ambiguity a re-split gesture exists to remove.
    func applying(_ gesture: Gesture) -> UVSplitLayout {
        switch gesture {
        case .swipeFromPanelEdge:
            return .maximizedPanel
        case .lineDownDivider:
            return .split
        case .swipePanelAway:
            return .maximizedViewport
        }
    }

    /// Width of the grab strip the panel keeps when the viewport is maximized.
    ///
    /// The panel never collapses to nothing. A fully hidden panel would take its own gesture
    /// surface with it, leaving `maximizedViewport` a dead end recoverable only by leaving and
    /// re-entering the stage — a state the artist can enter with one swipe and not leave.
    static let grabStripWidth: CGFloat = 18

    // MARK: - Gesture classification

    /// How close to the middle a divider line must start, as a fraction of width.
    static let dividerBandFraction: CGFloat = 0.12

    /// Minimum travel, as a fraction of the relevant dimension, before either gesture fires.
    static let minimumTravelFraction: CGFloat = 0.15

    /// The gesture to apply from the CURRENT layout, or nil when the drag should be left to
    /// whatever else wants it.
    ///
    /// The gesture surface is the PANEL, never the viewport, which is what keeps this from
    /// fighting the camera: every touch that starts over the 3D view stays with the camera
    /// recognizers. Attaching it to a container above the viewport instead broke
    /// `testCameraGesturesDoNotConflictWithUndoTaps`, because a SwiftUI drag gesture on an
    /// ancestor competes with the representable's UIKit recognizers.
    ///
    /// A divider line is only claimed when there is a split to RESTORE, and a gesture that would
    /// not change the layout returns nil so it stays available to anything else.
    func gesture(from start: CGPoint, to end: CGPoint, in size: CGSize) -> Gesture? {
        guard let candidate = Self.classify(from: start, to: end, in: size) else { return nil }
        if candidate == .lineDownDivider, self == .split {
            return nil  // nothing to restore, and the middle is over the viewport
        }
        guard applying(candidate) != self else { return nil }
        return candidate
    }

    /// Classifies a completed drag, or nil when it is neither gesture.
    ///
    /// Both gestures require their travel to DOMINATE the other axis, so a diagonal smudge
    /// resolves to nothing rather than to whichever test ran first.
    static func classify(
        from start: CGPoint, to end: CGPoint, in size: CGSize
    ) -> Gesture? {
        guard size.width > 0, size.height > 0 else { return nil }
        let dx = end.x - start.x
        let dy = end.y - start.y

        // Horizontal swipes are measured against the panel's own width, and the direction is
        // what distinguishes them: pulling the panel IN maximizes it, pushing it AWAY maximizes
        // the viewport. Both are read in panel-local coordinates because the gesture lives on the
        // panel — see `DocumentEditorView.uvPanelIfNeeded`.
        if abs(dx) >= size.width * minimumTravelFraction, abs(dx) > abs(dy) {
            return dx < 0 ? .swipeFromPanelEdge : .swipePanelAway
        }

        // A vertical line down the middle, where the divider is.
        let middle = size.width / 2
        if abs(start.x - middle) <= size.width * dividerBandFraction,
            abs(dy) >= size.height * minimumTravelFraction,
            abs(dy) > abs(dx) {
            return .lineDownDivider
        }
        return nil
    }
}
