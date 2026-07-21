import Testing
import UIKit
@testable import CyberTopology

/// Render-on-demand frame pacing (task 2.5, spec: viewport-rendering /
/// "120 Hz interaction on ProMotion"). The scheduler and rate policy are
/// pure and tested exhaustively; the pacer is tested against a plain UIView
/// (no GPU needed). The actual 120 Hz timing measurement is device-only
/// territory (traceability: "Stroke latency" stays pending).
struct RedrawSchedulerTests {
    /// Draw decisions hoisted into locals: `#expect` cannot call mutating
    /// members on captured values.
    private func drainInitialDraw(_ scheduler: inout RedrawScheduler) -> Bool {
        scheduler.shouldDrawNow(isRendererAnimating: false)
    }

    @Test func firstFrameAlwaysDraws() {
        var scheduler = RedrawScheduler()
        #expect(scheduler.needsRedraw)
        let drewFirst = scheduler.shouldDrawNow(isRendererAnimating: false)
        #expect(drewFirst)
    }

    @Test func idleSchedulesNoDraws() {
        var scheduler = RedrawScheduler()
        _ = drainInitialDraw(&scheduler)
        // Battery contract: an idle viewport (no request, no interaction,
        // no animation) never draws and wants no display link.
        for _ in 0..<5 {
            let drew = scheduler.shouldDrawNow(isRendererAnimating: false)
            #expect(!drew)
        }
        #expect(!scheduler.wantsContinuousDrawing(isRendererAnimating: false))
    }

    @Test func requestRedrawIsOneShot() {
        var scheduler = RedrawScheduler()
        _ = drainInitialDraw(&scheduler)

        scheduler.requestRedraw()
        let drewRequested = scheduler.shouldDrawNow(isRendererAnimating: false)
        let drewAgain = scheduler.shouldDrawNow(isRendererAnimating: false)
        #expect(drewRequested)
        #expect(!drewAgain)
        // A one-shot request never starts continuous drawing.
        #expect(!scheduler.wantsContinuousDrawing(isRendererAnimating: false))
    }

    @Test func interactionDrivesContinuousDrawing() {
        var scheduler = RedrawScheduler()
        _ = drainInitialDraw(&scheduler)

        scheduler.beginInteraction()
        #expect(scheduler.isInteracting)
        #expect(scheduler.wantsContinuousDrawing(isRendererAnimating: false))
        // Draws on every tick while interacting, without new requests.
        let drewTick1 = scheduler.shouldDrawNow(isRendererAnimating: false)
        let drewTick2 = scheduler.shouldDrawNow(isRendererAnimating: false)
        #expect(drewTick1)
        #expect(drewTick2)

        scheduler.endInteraction()
        #expect(!scheduler.isInteracting)
        #expect(!scheduler.wantsContinuousDrawing(isRendererAnimating: false))
        // One trailing draw shows the final pose, then idle.
        let drewTrailing = scheduler.shouldDrawNow(isRendererAnimating: false)
        let drewIdle = scheduler.shouldDrawNow(isRendererAnimating: false)
        #expect(drewTrailing)
        #expect(!drewIdle)
    }

    /// Pinch + two-finger pan recognize simultaneously: the count must not
    /// drop to zero until BOTH end.
    @Test func nestedInteractionsAreCounted() {
        var scheduler = RedrawScheduler()
        scheduler.beginInteraction()
        scheduler.beginInteraction()
        scheduler.endInteraction()
        #expect(scheduler.isInteracting)
        scheduler.endInteraction()
        #expect(!scheduler.isInteracting)
    }

    /// Defensive: cancellation paths that double-end never underflow.
    @Test func endInteractionFloorsAtZero() {
        var scheduler = RedrawScheduler()
        scheduler.endInteraction()
        scheduler.endInteraction()
        #expect(scheduler.activeInteractionCount == 0)
        scheduler.beginInteraction()
        #expect(scheduler.isInteracting)
    }

    @Test func rendererAnimationDrivesContinuousDrawing() {
        var scheduler = RedrawScheduler()
        _ = drainInitialDraw(&scheduler)

        // Camera reframe / overlay sweep / ghost pulse: continuous while
        // animating, idle the moment the animation stops.
        #expect(scheduler.wantsContinuousDrawing(isRendererAnimating: true))
        let drewAnimating = scheduler.shouldDrawNow(isRendererAnimating: true)
        let drewAfter = scheduler.shouldDrawNow(isRendererAnimating: false)
        #expect(drewAnimating)
        #expect(!drewAfter)
    }
}

struct FramePacingPolicyTests {
    @Test func proMotionDisplayPrefers120() {
        let range = FramePacingPolicy.frameRateRange(displayMaxFPS: 120)
        #expect(range == .init(minimum: 60, preferred: 120, maximum: 120))
    }

    @Test func standardDisplayStaysAt60() {
        let range = FramePacingPolicy.frameRateRange(displayMaxFPS: 60)
        #expect(range == .init(minimum: 60, preferred: 60, maximum: 60))
    }

    @Test func exoticDisplaysAreClamped() {
        // Hypothetical 240 Hz external display: capped at the 120 ceiling.
        #expect(FramePacingPolicy.frameRateRange(displayMaxFPS: 240).maximum == 120)
        // Degenerate report: floored, and the range stays ordered.
        let low = FramePacingPolicy.frameRateRange(displayMaxFPS: 0)
        #expect(low.minimum <= low.preferred && low.preferred <= low.maximum)
        #expect(low.maximum == Float(FramePacingPolicy.minFrameRate))
    }
}

@MainActor
struct ViewportFramePacerTests {
    @Test func attachSchedulesInitialFrameThenIdles() {
        let pacer = ViewportFramePacer()
        let view = UIView()
        pacer.attach(to: view) { false }

        // The initial dirty flag produced exactly one scheduled draw and
        // the display link is parked (idle costs nothing).
        #expect(pacer.scheduledDrawCount == 1)
        #expect(pacer.isDisplayLinkPaused)
        pacer.detach()
    }

    @Test func invalidateSchedulesOneDrawWithoutContinuousMode() {
        let pacer = ViewportFramePacer()
        pacer.attach(to: UIView()) { false }
        let before = pacer.scheduledDrawCount

        pacer.invalidate()
        #expect(pacer.scheduledDrawCount == before + 1)
        #expect(pacer.isDisplayLinkPaused)
        pacer.detach()
    }

    @Test func interactionRunsDisplayLinkUntilEnded() {
        let pacer = ViewportFramePacer()
        pacer.attach(to: UIView()) { false }

        pacer.beginInteraction()
        #expect(!pacer.isDisplayLinkPaused)
        pacer.endInteraction()
        #expect(pacer.isDisplayLinkPaused)
        pacer.detach()
    }

    @Test func rendererAnimationRunsDisplayLink() {
        var animating = true
        let pacer = ViewportFramePacer()
        let view = UIView()
        pacer.attach(to: view) { animating }
        #expect(!pacer.isDisplayLinkPaused)

        // Animation finished: the next scheduling decision parks the link.
        animating = false
        pacer.invalidate()
        #expect(pacer.isDisplayLinkPaused)
        pacer.detach()
    }

    @Test func detachStopsPacing() {
        let pacer = ViewportFramePacer()
        pacer.attach(to: UIView()) { true }
        #expect(!pacer.isDisplayLinkPaused)
        pacer.detach()
        #expect(pacer.isDisplayLinkPaused)  // no link at all reads as paused
    }

    @Test func preferredFrameRateRangeAppliesWithoutCrash() {
        let pacer = ViewportFramePacer()
        pacer.attach(to: UIView()) { false }
        pacer.setPreferredFrameRateRange(displayMaxFPS: 120)
        pacer.setPreferredFrameRateRange(displayMaxFPS: 60)
        pacer.detach()
    }
}

/// Renderer-side pacing hooks: state changes fire `onNeedsDisplay`, and
/// `isAnimating` reports exactly the continuous phases.
@MainActor
struct RendererPacingTests {
    private func makeRenderer() throws -> ViewportRenderer {
        try #require(ViewportRenderer(), "Metal device unavailable")
    }

    @Test func cameraMutationsFireNeedsDisplay() throws {
        let renderer = try makeRenderer()
        var fired = 0
        renderer.onNeedsDisplay = { fired += 1 }

        renderer.orbit(byPoints: SIMD2(10, 5))
        renderer.zoom(byPinchScale: 1.5)
        renderer.pan(byPoints: SIMD2(4, 4))
        renderer.reframe(animated: false)
        #expect(fired == 4)
    }

    @Test func loadsAndSettingsFireNeedsDisplay() throws {
        let renderer = try makeRenderer()
        var fired = 0
        renderer.onNeedsDisplay = { fired += 1 }

        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: nil,
            indices: [0, 1, 2]
        )
        #expect(fired == 1)

        renderer.overlaySettings.opacity = 0.3
        #expect(fired == 2)
        // Unchanged settings do not fire (SwiftUI pushes them every update).
        let unchanged = renderer.overlaySettings
        renderer.overlaySettings = unchanged
        #expect(fired == 2)

        renderer.resolutionScale = 0.5
        #expect(fired == 3)
        renderer.resolutionScale = 0.5
        #expect(fired == 3)

        renderer.clearMesh()
        #expect(fired == 4)
    }

    @Test func isAnimatingTracksCameraOverlayAndGhost() throws {
        let renderer = try makeRenderer()
        #expect(!renderer.isAnimating(at: 100))

        // Camera reframe animation.
        renderer.loadGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            colors: nil,
            indices: [0, 1, 2]
        )
        renderer.reframe(animated: true, at: 100)
        #expect(renderer.isAnimating(at: 100.1))
        _ = renderer.stepAnimation(at: 200)
        #expect(!renderer.isAnimating(at: 200))

        // Overlay creation sweep: animating only until the sweep finishes.
        renderer.loadOverlayGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            edges: [0, 1, 1, 2],
            restartAnimation: true, at: 300
        )
        #expect(renderer.isAnimating(at: 300.1))
        #expect(!renderer.isAnimating(at: 300 + OverlayAnimation.duration + 1))

        // Ghost pulse animates for as long as a ghost is loaded.
        renderer.loadGhostGeometry(
            positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2]
        )
        #expect(renderer.isAnimating(at: 400))
        renderer.clearGhost()
        #expect(!renderer.isAnimating(at: 400))
    }
}
