import CyberKitTesting
import UIKit
import os

/// Thin UIKit layer over the pure `InputArbiter` (design D5): converts
/// `UITouch`es into arbiter events, applies the arbiter's decisions to the
/// stroke capture, and answers `shouldReceive touch` for every recognizer
/// in the viewport (camera + undo overlay). All routing POLICY lives in the
/// arbiter; this class only translates.
@MainActor
final class ViewportInputController {
    /// Recognizer classes the delegate gate distinguishes.
    enum RecognizerGate {
        /// The observing recognizer feeding this controller — always allowed.
        case observer
        /// Camera recognizers: orbit drag, double-tap reframe, pinch zoom,
        /// two-finger pan (fingers always navigate — authoring is
        /// Pencil-only, spec scenario "Finger strokes never author").
        case camera
        /// Three/four-finger tap undo/redo overlay.
        case undoTap
    }

    private(set) var arbiter = InputArbiter()
    let capture: ViewportStrokeCapture
    /// View whose bounds normalize sample coordinates (the viewport).
    weak var referenceView: UIView?
    /// Set by the viewport coordinator: resets camera/undo recognizers when
    /// the pen takes priority over gestures already in flight.
    var onCancelCameraGestures: (() -> Void)?

    private static let log = Logger(
        subsystem: "com.cyberdynecorp.cybertopology", category: "input"
    )
    /// How many touches have been released by the sweep rather than by a UIKit
    /// end/cancel. Non-zero means the leak that kills finger navigation happened
    /// and was recovered from — worth knowing, since the trigger is still not
    /// reproduced (openspec fix-lost-finger-navigation).
    private(set) var recoveredLeakedTouches = 0

    private var idsByTouch: [ObjectIdentifier: InputArbiter.TouchID] = [:]
    /// Weak handles to the touches behind `idsByTouch`, so a touch whose end was
    /// never delivered can still be recognised as dead from its own `phase`
    /// (openspec fix-lost-finger-navigation). Weak because UIKit owns them.
    private var trackedTouches: [ObjectIdentifier: WeakTouch] = [:]
    private var nextTouchID: InputArbiter.TouchID = 0

    private struct WeakTouch {
        weak var touch: UITouch?
        /// Dead once UIKit has ended or cancelled it, or once it is gone.
        var isFinished: Bool {
            guard let touch else { return true }
            return touch.phase == .ended || touch.phase == .cancelled
        }
    }

    init(capture: ViewportStrokeCapture = ViewportStrokeCapture()) {
        self.capture = capture
    }

    // MARK: - Configuration forwarding

    func selectVerb(_ verb: InputArbiter.Verb) {
        arbiter.selectVerb(verb)
    }

    func verbPressBegan(_ verb: InputArbiter.Verb, at time: TimeInterval) {
        arbiter.verbPressBegan(verb, at: time)
    }

    /// Returns whether the release tap-selected the verb persistently
    /// (see `InputArbiter.verbPressEnded`).
    @discardableResult
    func verbPressEnded(_ verb: InputArbiter.Verb, at time: TimeInterval) -> Bool {
        arbiter.verbPressEnded(verb, at: time)
    }

    var activeVerb: InputArbiter.Verb { arbiter.activeVerb }

    /// Camera-as-manipulator session gate (task 4.2): the input model
    /// arms it when a session begins; the coordinator asks
    /// `cameraFeedsArmedTool` before feeding an applied camera gesture
    /// into the tool session (the arbiter owns the routing, design D5).
    func setCameraToolSessionArmed(_ armed: Bool) {
        arbiter.setCameraToolSessionArmed(armed)
    }

    var cameraFeedsArmedTool: Bool { arbiter.cameraFeedsArmedTool }

    // MARK: - Touch events (from TouchObserverRecognizer)

    /// Releases every tracked touch UIKit has already finished.
    ///
    /// This is the recovery for the reported failure — finger navigation dying
    /// while the toolbar and the pen keep working. Camera gestures are refused
    /// once two fingers are tracked, and tracked touches were only ever released
    /// by `touchesEnded`/`touchesCancelled`; a single undelivered end therefore
    /// disabled orbit, pinch and pan for the rest of the session. Sweeping on
    /// every touch event heals it at the next thing the user does.
    private func sweepFinishedTouches() {
        let dead = trackedTouches.filter { $0.value.isFinished }.map(\.key)
        guard !dead.isEmpty else { return }
        var ids: [InputArbiter.TouchID] = []
        for key in dead {
            trackedTouches.removeValue(forKey: key)
            if let id = idsByTouch.removeValue(forKey: key) { ids.append(id) }
        }
        recoveredLeakedTouches += ids.count
        Self.log.notice(
            "released \(ids.count, privacy: .public) touch(es) UIKit finished without telling us"
        )
        for decision in arbiter.forget(ids) {
            if case .cancelStroke = decision { capture.cancel() }
        }
    }

    func touchesBegan(_ touches: Set<UITouch>) {
        sweepFinishedTouches()
        // Pencil first so a palm landing in the same event batch is already
        // rejected; then by timestamp for determinism.
        for touch in touches.sorted(by: Self.arbitrationOrder) {
            apply(arbiter.touchBegan(register(touch), kind: kind(of: touch)), touch: touch)
        }
    }

    /// `event` carries the coalesced touches: on 120–240 Hz digitizer
    /// hardware with display-rate event delivery, each delivered move
    /// bundles the intermediate samples in `event.coalescedTouches(for:)`.
    /// Authoring strokes append EVERY coalesced sample so Pencil capture
    /// keeps full density (sharp corners survive the 64-point resampling
    /// the recognizer applies — the fixture corpus was recorded at full
    /// density). Predicted touches are deliberately NOT captured: they are
    /// provisional and the capture pipeline has no rollback.
    func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent? = nil) {
        sweepFinishedTouches()
        for touch in touches {
            guard let id = idsByTouch[ObjectIdentifier(touch)] else { continue }
            for decision in arbiter.touchMoved(id) {
                switch decision {
                case .appendToStroke:
                    let detail = (event?.coalescedTouches(for: touch))
                        .flatMap { $0.isEmpty ? nil : $0 } ?? [touch]
                    for coalesced in detail {
                        capture.append(sample: absoluteSample(from: coalesced))
                    }
                default:
                    apply([decision], touch: touch)
                }
            }
        }
    }

    func touchesEnded(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let id = unregister(touch) else { continue }
            apply(arbiter.touchEnded(id), touch: touch)
        }
    }

    func touchesCancelled(_ touches: Set<UITouch>) {
        for touch in touches {
            guard let id = unregister(touch) else { continue }
            apply(arbiter.touchCancelled(id), touch: touch)
        }
    }

    /// UIKit finished the touch sequence (`UIGestureRecognizer.reset`): reconcile
    /// against the truth that nothing is on the glass.
    ///
    /// The id map is cleared for its own reason — `UITouch` objects are RECYCLED
    /// by UIKit, so a stale `ObjectIdentifier` entry would hand a brand-new touch
    /// the id of a dead one, and `register` returns the existing id when the key
    /// is already present.
    func allTouchesFinished() {
        let decisions = arbiter.allTouchesFinished()
        idsByTouch.removeAll()
        trackedTouches.removeAll()
        for decision in decisions {
            if case .cancelStroke = decision { capture.cancel() }
        }
    }

    // MARK: - Recognizer gating

    func shouldReceive(_ touch: UITouch, for gate: RecognizerGate) -> Bool {
        // The gate is asked before every gesture; reconciling here is what makes
        // a leaked touch cost one gesture rather than the rest of the session.
        sweepFinishedTouches()
        let kind = kind(of: touch)
        let id = idsByTouch[ObjectIdentifier(touch)]
        switch gate {
        case .observer:
            return true
        case .undoTap:
            return arbiter.allowsUndoTap(kind: kind)
        case .camera:
            return arbiter.allowsCameraTouch(kind: kind, excluding: id)
        }
    }

    // MARK: - Sample conversion

    /// UITouch → task-1.1b `StrokeSample` with viewport-normalized
    /// coordinates and an ABSOLUTE timestamp (the capture rebases).
    func absoluteSample(from touch: UITouch) -> StrokeSample {
        let view = referenceView
        let bounds = view?.bounds.size ?? .zero
        let location = touch.location(in: view)
        let isPencil = touch.type == .pencil
        let maxForce = touch.maximumPossibleForce
        return StrokeSample(
            time: touch.timestamp,
            x: bounds.width > 0 ? location.x / bounds.width : 0,
            y: bounds.height > 0 ? location.y / bounds.height : 0,
            pressure: maxForce > 0 ? touch.force / maxForce : 0,
            azimuth: isPencil ? touch.azimuthAngle(in: view) : 0,
            altitude: isPencil ? Double(touch.altitudeAngle) : 0,
            type: isPencil ? .pencil : .finger
        )
    }

    // MARK: - Private

    private func kind(of touch: UITouch) -> InputArbiter.TouchKind {
        touch.type == .pencil ? .pencil : .finger
    }

    private static func arbitrationOrder(_ lhs: UITouch, _ rhs: UITouch) -> Bool {
        if (lhs.type == .pencil) != (rhs.type == .pencil) {
            return lhs.type == .pencil
        }
        return lhs.timestamp < rhs.timestamp
    }

    private func register(_ touch: UITouch) -> InputArbiter.TouchID {
        let key = ObjectIdentifier(touch)
        if let id = idsByTouch[key] {
            // UIKit RECYCLES `UITouch` objects, so a matching address on a touch
            // that is beginning means the old entry is stale — handing the new
            // touch a dead id would leak the old one forever.
            if touch.phase == .began {
                for decision in arbiter.forget([id]) {
                    if case .cancelStroke = decision { capture.cancel() }
                }
            } else {
                return id
            }
        }
        nextTouchID += 1
        idsByTouch[key] = nextTouchID
        trackedTouches[key] = WeakTouch(touch: touch)
        return nextTouchID
    }

    private func unregister(_ touch: UITouch) -> InputArbiter.TouchID? {
        trackedTouches.removeValue(forKey: ObjectIdentifier(touch))
        return idsByTouch.removeValue(forKey: ObjectIdentifier(touch))
    }

    private func apply(_ decisions: [InputArbiter.Decision], touch: UITouch) {
        for decision in decisions {
            switch decision {
            case .beginStroke(_, let source, let verb):
                capture.begin(source: source, verb: verb, sample: absoluteSample(from: touch))
            case .appendToStroke:
                capture.append(sample: absoluteSample(from: touch))
            case .endStroke:
                capture.end(sample: absoluteSample(from: touch))
            case .cancelStroke:
                capture.cancel()
            case .rejectTouch:
                break
            case .cancelCameraGestures:
                onCancelCameraGestures?()
            }
        }
    }
}

/// Observing recognizer: sees every touch in the viewport subtree (it never
/// leaves `.possible`, so it recognizes nothing and blocks nobody) and
/// forwards the raw stream to the controller. The viewport coordinator's
/// delegate lets it run simultaneously with every other recognizer so it is
/// never force-failed mid-gesture.
final class TouchObserverRecognizer: UIGestureRecognizer {
    private weak var controller: ViewportInputController?

    init(controller: ViewportInputController) {
        self.controller = controller
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        controller?.touchesBegan(touches)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        // The event rides along so authoring strokes can pull the full
        // coalesced sample stream (120–240 Hz on Pencil hardware).
        controller?.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        controller?.touchesEnded(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        controller?.touchesCancelled(touches)
    }

    /// UIKit calls this when the recognition attempt finishes — i.e. when every
    /// touch of the sequence has ended or been cancelled. It is the one callback
    /// that is guaranteed to arrive, which makes it the place to reconcile
    /// against a lost `touchesEnded` (openspec fix-lost-finger-navigation).
    override func reset() {
        super.reset()
        controller?.allTouchesFinished()
    }
}
