import QuartzCore
import UIKit

// Frame pacing (task 2.5, spec: viewport-rendering / "120 Hz interaction on
// ProMotion", design D2: the shell owns the display link).
//
// Render-on-demand architecture: the MTKView is paused
// (`isPaused = true, enableSetNeedsDisplay = true`) and every draw is
// explicitly requested. A pure `RedrawScheduler` decides *when* frames are
// needed; `ViewportFramePacer` owns the CADisplayLink that paces continuous
// phases (camera animation, overlay/ghost animation, active interaction) at
// up to 120 Hz on ProMotion displays. Idle documents schedule no draws at
// all — zero GPU/CPU per frame is the battery contract.

/// Pure dirty-flag scheduler: tracks the one-shot redraw request and the
/// active interaction count, and decides draw/pacing behavior. No UIKit, no
/// Metal — fully unit-testable.
struct RedrawScheduler: Equatable, Sendable {
    /// One-shot dirty flag; starts true so the first frame always draws.
    private(set) var needsRedraw = true
    /// Number of interactions in flight (pinch + two-finger pan may run
    /// simultaneously, so this is a count, not a flag).
    private(set) var activeInteractionCount = 0

    var isInteracting: Bool { activeInteractionCount > 0 }

    /// Requests one redraw (content changed: mesh load, settings change,
    /// camera moved, viewport resized).
    mutating func requestRedraw() {
        needsRedraw = true
    }

    /// A continuous interaction (drag/pinch) began.
    mutating func beginInteraction() {
        activeInteractionCount += 1
        needsRedraw = true
    }

    /// An interaction ended/cancelled/failed. Defensive floor at zero:
    /// UIKit can report cancellation paths that double-end. One trailing
    /// redraw shows the final pose.
    mutating func endInteraction() {
        activeInteractionCount = max(0, activeInteractionCount - 1)
        needsRedraw = true
    }

    /// True while the display link should keep firing: an interaction is
    /// active or the renderer has time-driven animation (camera reframe,
    /// overlay creation sweep, ghost pulse).
    func wantsContinuousDrawing(isRendererAnimating: Bool) -> Bool {
        isInteracting || isRendererAnimating
    }

    /// Whether to draw now; consumes the one-shot dirty flag. Idle (no
    /// request, no interaction, no animation) never draws.
    mutating func shouldDrawNow(isRendererAnimating: Bool) -> Bool {
        let draw = needsRedraw || wantsContinuousDrawing(isRendererAnimating: isRendererAnimating)
        needsRedraw = false
        return draw
    }
}

/// Pure display-link rate policy (spec: up to 120 Hz where ProMotion
/// exists). The system still owns the final rate; this only expresses the
/// preference envelope.
enum FramePacingPolicy {
    /// Ceiling we ever ask for (ProMotion).
    static let maxFrameRate = 120
    /// Floor the system may drop continuous phases to under load.
    static let minFrameRate = 30

    struct FrameRateRange: Equatable {
        var minimum: Float
        var preferred: Float
        var maximum: Float
    }

    /// Preference envelope for a display reporting `displayMaxFPS`
    /// (`UIScreen.maximumFramesPerSecond`): prefer the display's native
    /// maximum capped at 120, allow the system to degrade to 60 (or the
    /// display max, whichever is lower) under thermal/load pressure.
    static func frameRateRange(displayMaxFPS: Int) -> FrameRateRange {
        let capped = min(max(displayMaxFPS, minFrameRate), maxFrameRate)
        return FrameRateRange(
            minimum: Float(min(60, capped)),
            preferred: Float(capped),
            maximum: Float(capped)
        )
    }
}

/// Owns the CADisplayLink driving the paused MTKView (render-on-demand).
///
/// One-shot invalidations mark the view dirty immediately; the link runs
/// only while `RedrawScheduler.wantsContinuousDrawing` is true and pauses
/// itself the first tick it is not — idle costs nothing.
@MainActor
final class ViewportFramePacer {
    private(set) var scheduler = RedrawScheduler()
    private weak var view: UIView?
    private var displayLink: CADisplayLink?
    private var isRendererAnimating: () -> Bool = { false }
    /// Total draws this pacer has scheduled (observable by tests; the
    /// idle-costs-nothing contract asserts this stays flat).
    private(set) var scheduledDrawCount = 0

    var isDisplayLinkPaused: Bool { displayLink?.isPaused ?? true }

    /// Wires the pacer to the view it paces. `isAnimating` reports whether
    /// the renderer has time-driven animation this instant (queried per
    /// tick, never cached).
    func attach(to view: UIView, isAnimating: @escaping () -> Bool) {
        detach()
        self.view = view
        isRendererAnimating = isAnimating

        // Weak proxy: CADisplayLink retains its target, so targeting self
        // would cycle pacer → link → pacer.
        let proxy = DisplayLinkProxy(pacer: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        link.isPaused = true
        // .common keeps ticks flowing during gesture tracking.
        link.add(to: .main, forMode: .common)
        displayLink = link

        pump()  // initial frame (scheduler starts dirty)
    }

    /// Applies the ProMotion-aware rate envelope; call when the view lands
    /// on a window/screen.
    func setPreferredFrameRateRange(displayMaxFPS: Int) {
        let range = FramePacingPolicy.frameRateRange(displayMaxFPS: displayMaxFPS)
        displayLink?.preferredFrameRateRange = CAFrameRateRange(
            minimum: range.minimum, maximum: range.maximum, preferred: range.preferred
        )
    }

    func detach() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One-shot redraw request (content/settings/camera changed).
    func invalidate() {
        scheduler.requestRedraw()
        pump()
    }

    func beginInteraction() {
        scheduler.beginInteraction()
        pump()
    }

    func endInteraction() {
        scheduler.endInteraction()
        pump()
    }

    /// One display-link tick during a continuous phase.
    fileprivate func tick() {
        scheduler.requestRedraw()
        pump()
    }

    /// Draws if the scheduler says so, then runs/pauses the link to match
    /// the continuous-drawing need. The paused MTKView renders on
    /// `setNeedsDisplay()` during the next run-loop turn.
    private func pump() {
        let animating = isRendererAnimating()
        if scheduler.shouldDrawNow(isRendererAnimating: animating) {
            scheduledDrawCount += 1
            view?.setNeedsDisplay()
        }
        displayLink?.isPaused =
            !scheduler.wantsContinuousDrawing(isRendererAnimating: animating)
    }
}

/// CADisplayLink target that does not retain the pacer.
@MainActor
private final class DisplayLinkProxy: NSObject {
    weak var pacer: ViewportFramePacer?

    init(pacer: ViewportFramePacer) {
        self.pacer = pacer
    }

    @objc func tick() {
        pacer?.tick()
    }
}
