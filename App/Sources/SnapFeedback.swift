import CoreHaptics
import UIKit
import simd

// Snap feedback (task 3.7, spec: pencil-interaction / "Pencil Pro and haptic
// feedback", scenario "Snap feedback"): while a Tweak/Move drag holds a
// vertex within merge range of another vertex, the snap target highlights
// BEFORE anything commits; a haptic tick fires when the merge (Tweak) /
// exact vertex snap (Move) actually reaches the journal.
//
// Split exactly like the arbiter and the hover preview (design D5/D9):
// `SnapFeedbackState` is the PURE event→feedback mapping — every transition
// is unit-tested headless against the `SnapHapticsPlaying` seam — and
// `SnapHapticsEngine` is the capability-gated hardware glue (Core Haptics
// where a Taptic Engine exists, `UICanvasFeedbackGenerator` so the system
// can route ticks to the Pencil Pro's own actuator). On the simulator and
// on haptics-less hardware every play call is a graceful no-op; actual
// actuation is device-only territory (`PencilProHardwareTests`, task 9.6).

/// Pure event → feedback mapping for vertex merge-snap during a drag.
/// Events (drag candidate updates, stroke end/cancel) in, effects
/// (highlight changes + haptic ticks) out — no UIKit, no engine.
struct SnapFeedbackState: Equatable {
    /// Haptic tick classes the seam can play.
    enum Tick: Equatable {
        /// The dragged vertex ENTERED merge range of a new target
        /// (the spec's "vertex snap" event — feedback before commit).
        case snapEngaged
        /// The merge / exact vertex snap reached the journal
        /// (the scenario's "haptic tick SHALL fire when the merge
        /// happens" — never on a failed or no-op commit).
        case commit
    }

    enum Effect: Equatable {
        case showHighlight(HoverPreviewState.SnapTarget)
        case clearHighlight
        case tick(Tick)
    }

    /// User-disableable haptics (spec: "haptics SHALL be user-disableable").
    /// Disabling drops ONLY the tick effects: the pre-commit highlight is
    /// visual feedback and stays, and the merge itself is a mesh-editing
    /// behavior haptics settings must never change.
    var hapticsEnabled = true

    /// The snap target the drag currently holds (pre-commit).
    private(set) var candidate: HoverPreviewState.SnapTarget?

    /// The dragged vertex moved: `target` is the vertex now within merge
    /// range (nil = none). Dedupes by target vertex, so a drag hovering
    /// inside the same vertex's range emits nothing new.
    mutating func dragUpdated(candidate target: HoverPreviewState.SnapTarget?) -> [Effect] {
        guard target?.vertex != candidate?.vertex else { return [] }
        let hadCandidate = candidate != nil
        candidate = target
        guard let target else {
            return hadCandidate ? [.clearHighlight] : []
        }
        var effects: [Effect] = [.showHighlight(target)]
        if hapticsEnabled {
            effects.append(.tick(.snapEngaged))
        }
        return effects
    }

    /// The stroke finished. `committed` reports whether the merge/snap
    /// actually reached the journal — the commit tick fires exactly then
    /// (highlight BEFORE commit, tick ON commit).
    mutating func strokeEnded(committed: Bool) -> [Effect] {
        let hadCandidate = candidate != nil
        candidate = nil
        var effects: [Effect] = hadCandidate ? [.clearHighlight] : []
        if committed && hapticsEnabled {
            effects.append(.tick(.commit))
        }
        return effects
    }

    /// The stroke was cancelled (or a new one began): nothing committed,
    /// any highlight clears silently.
    mutating func strokeCancelled() -> [Effect] {
        let hadCandidate = candidate != nil
        candidate = nil
        return hadCandidate ? [.clearHighlight] : []
    }
}

/// Injected haptic seam (design D9): the event→feedback mapping is
/// unit-tested against this protocol with a recording fake; the production
/// implementation below is capability-gated hardware glue. `location` is
/// the tick's NORMALIZED viewport position (0...1, origin top-left — the
/// system uses the resolved screen point when routing canvas feedback to
/// the Pencil Pro), nil when unknown.
@MainActor
protocol SnapHapticsPlaying: AnyObject {
    func play(_ tick: SnapFeedbackState.Tick, atNormalized location: CGPoint?)
}

/// Production haptics, capability-gated everywhere (graceful no-ops on the
/// simulator and on hardware without the corresponding actuator):
///
///   - `UICanvasFeedbackGenerator` (iPadOS 17.5+): `alignmentOccurred` for
///     the snap-engaged tick, `pathCompleted` for the commit tick. The
///     SYSTEM decides the actuator — the Pencil Pro's own haptics when the
///     interaction is Pencil-driven, the device's otherwise, nothing when
///     neither exists. Safe by construction off-hardware.
///   - Core Haptics transient events, only where
///     `CHHapticEngine.capabilitiesForHardware().supportsHaptics` says a
///     Taptic Engine exists (false on the simulator and on all current
///     iPads — the canvas generator is the primary path there; the engine
///     covers haptics-capable hardware without double-driving Pencil Pro).
@MainActor
final class SnapHapticsEngine: SnapHapticsPlaying {
    /// The view feedback is anchored to (the viewport).
    private weak var view: UIView?
    private var canvasGenerator: UICanvasFeedbackGenerator?
    /// Whether this hardware has a Taptic Engine (false on simulator).
    let supportsCoreHaptics: Bool
    private var hapticEngine: CHHapticEngine?

    init(view: UIView) {
        self.view = view
        canvasGenerator = UICanvasFeedbackGenerator(view: view)
        supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    }

    func play(_ tick: SnapFeedbackState.Tick, atNormalized location: CGPoint?) {
        if let view {
            let anchor = location.map {
                CGPoint(x: $0.x * view.bounds.width, y: $0.y * view.bounds.height)
            } ?? CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            switch tick {
            case .snapEngaged:
                canvasGenerator?.alignmentOccurred(at: anchor)
            case .commit:
                canvasGenerator?.pathCompleted(at: anchor)
            }
        }
        playCoreHapticsTick(tick)
    }

    /// Transient Core Haptics tick — no-op unless the hardware has a
    /// Taptic Engine. Failures degrade silently to no feedback: haptics
    /// are garnish, never load-bearing.
    private func playCoreHapticsTick(_ tick: SnapFeedbackState.Tick) {
        guard supportsCoreHaptics else { return }
        if hapticEngine == nil {
            hapticEngine = try? CHHapticEngine()
            hapticEngine?.resetHandler = { [weak self] in
                // The system reclaimed the engine (backgrounding etc.):
                // recreate lazily on the next tick.
                Task { @MainActor [weak self] in self?.hapticEngine = nil }
            }
        }
        guard let engine = hapticEngine else { return }
        let (intensity, sharpness): (Float, Float) = switch tick {
        case .snapEngaged: (0.5, 0.6)
        case .commit: (1.0, 0.4)
        }
        let event = CHHapticEvent(
            eventType: .hapticTransient,
            parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
            ],
            relativeTime: 0
        )
        do {
            try engine.start()
            let player = try engine.makePlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            hapticEngine = nil
        }
    }
}
