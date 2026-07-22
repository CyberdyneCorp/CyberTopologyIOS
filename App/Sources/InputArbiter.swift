import Foundation

/// Pure touch/Pencil arbitration state machine (design D5: ONE arbiter owns
/// all viewport input; spec: pencil-interaction / "Input division of labor"
/// + "Hold-chord spring-loaded modifiers").
///
/// Events in (touch began/moved/ended/cancelled, verb presses), decisions
/// out — no UIKit types anywhere, so every transition combination is
/// unit-testable headless. The thin UIKit layer
/// (`ViewportInputController` + `TouchObserverRecognizer`) converts touches
/// into these events and enforces the routing verdicts:
///
///   - Pencil touches author (stroke capture → the 3.2 recognizer).
///   - Finger touches NEVER author: they always navigate (existing camera
///     recognizers; spec scenario "Finger strokes never author" — authoring
///     is Pencil-only by policy, spec change 2026-07-21).
///   - 3/4-finger taps stay with the undo/redo overlay recognizers.
///   - While the pen is down every new touch is rejected (palm rejection,
///     spec scenario "Palm rejection during pen stroke"), and camera
///     gestures already in flight are cancelled (pen priority).
///   - A 3rd+ simultaneous finger is never admitted to camera gestures, so
///     >2 touches cannot cause erratic camera motion.
struct InputArbiter {
    typealias TouchID = Int

    enum TouchKind: Equatable {
        case pencil
        case finger
    }

    /// What produced an authoring stroke (feeds `StrokeSample.type`). The
    /// arbiter only ever begins `.pencil` strokes; `.finger` remains for
    /// the capture pipeline's fixture-injection hooks, which replay
    /// finger-recorded fixtures below the touch layer.
    enum StrokeSource: String, Equatable {
        case pencil
        case finger
    }

    /// The five primary verbs (spec: "Five coherent verbs across stages").
    /// Task 3.1 lands only the selection/hold state machine; verb behavior
    /// on the mesh is task 3.3.
    enum Verb: String, CaseIterable, Equatable, Sendable {
        case pencil
        case relax
        case move
        case tweak
        case erase
    }

    /// Routing verdicts. The UIKit layer applies them in order.
    enum Decision: Equatable {
        case beginStroke(TouchID, source: StrokeSource, verb: Verb)
        case appendToStroke(TouchID)
        case endStroke(TouchID)
        case cancelStroke(TouchID)
        case rejectTouch(TouchID)
        /// Pen priority: the UIKit layer must reset the camera/undo
        /// recognizers so a resting palm cannot keep steering the camera.
        /// Emitted when the pen lands over camera gestures in flight AND
        /// whenever a finger is palm-rejected while the pen is down — the
        /// UIKit `shouldReceive` gate runs BEFORE the observer recognizer
        /// sees the batch, so a palm delivered in the same event batch as
        /// the pen-down is admitted to the camera/undo recognizers before
        /// the arbiter knows the pen is down; only this decision can evict
        /// it afterwards.
        case cancelCameraGestures
    }

    // MARK: - Touch state

    private enum Role {
        case authoring
        case camera
        case rejected
    }

    private struct TrackedTouch {
        var kind: TouchKind
        var role: Role
    }

    private var touches: [TouchID: TrackedTouch] = [:]
    /// The pencil touch currently authoring, if any.
    private(set) var penStrokeTouch: TouchID?

    var isPenDown: Bool { penStrokeTouch != nil }
    var activeTouchCount: Int { touches.count }

    /// Active NON-REJECTED finger touches, optionally excluding one id —
    /// gating queries exclude the touch being asked about so the answer
    /// does not depend on whether that touch was already registered by the
    /// observer. Rejected touches (a palm that landed during a pen stroke,
    /// demoted camera fingers) are inert for their entire lifetime; counting
    /// them would let a still-resting palm consume the two-finger camera
    /// budget after the pen lifts.
    func fingerCount(excluding excluded: TouchID? = nil) -> Int {
        touches.count { id, touch in
            touch.kind == .finger && touch.role != .rejected && id != excluded
        }
    }

    // MARK: - Verb state (spring-loaded hold-chords)

    /// Press-and-release faster than this selects the verb persistently;
    /// anything longer is a spring-loaded hold that restores on release.
    static let tapSelectThreshold: TimeInterval = 0.35

    private(set) var persistentVerb: Verb = .pencil
    private(set) var heldVerb: Verb?
    private var pressStart: [Verb: TimeInterval] = [:]

    /// The verb a stroke beginning right now would use.
    var activeVerb: Verb { heldVerb ?? persistentVerb }

    /// Direct persistent selection (e.g. hardware keyboard chord).
    mutating func selectVerb(_ verb: Verb) {
        persistentVerb = verb
    }

    /// A toolbar verb button went down: spring-load it immediately so a
    /// stroke started during the hold uses it (spec scenario "Spring-loaded
    /// Relax").
    mutating func verbPressBegan(_ verb: Verb, at time: TimeInterval) {
        pressStart[verb] = time
        heldVerb = verb
    }

    /// The button was released: a quick tap selects persistently, a hold
    /// restores the previous tool immediately. With overlapping holds
    /// (several buttons physically down), releasing the current hold falls
    /// back to the most recently pressed button that is STILL held —
    /// `pressStart` contains exactly the held buttons — so a hold-chord
    /// never silently stops applying while its finger is still down.
    /// Returns whether the release TAP-SELECTED the verb persistently —
    /// the task-4.1 tool layer disarms the active tool exactly then (a
    /// spring-loaded hold must not kick the user out of a tool).
    @discardableResult
    mutating func verbPressEnded(_ verb: Verb, at time: TimeInterval) -> Bool {
        let start = pressStart.removeValue(forKey: verb)
        if heldVerb == verb {
            heldVerb = pressStart.max { $0.value < $1.value }?.key
        }
        if let start, time - start < Self.tapSelectThreshold {
            persistentVerb = verb
            return true
        }
        return false
    }

    // MARK: - Camera-as-manipulator sessions (task 4.2)

    /// True while a camera-as-manipulator tool session is armed (Patch
    /// Clone placing, Extend Boundary extruding, Transform Vertices
    /// moving). Set by the input model when a session begins/ends.
    private(set) var isCameraToolSessionArmed = false

    mutating func setCameraToolSessionArmed(_ armed: Bool) {
        isCameraToolSessionArmed = armed
    }

    /// The camera→tool routing verdict (design D5: the arbiter owns ALL
    /// viewport input routing — the camera-as-manipulator tools
    /// deliberately blur pen-authors/fingers-navigate, so the blurring is
    /// decided HERE, never ad hoc in the UIKit layer): while a session is
    /// armed, applied camera gestures ALSO feed the tool. Never while the
    /// pen is down — palm rejection already blocks camera gestures then,
    /// and a stray demoted touch must not steer a placement.
    var cameraFeedsArmedTool: Bool {
        isCameraToolSessionArmed && !isPenDown
    }

    // MARK: - Touch events

    mutating func touchBegan(_ id: TouchID, kind: TouchKind) -> [Decision] {
        guard touches[id] == nil else { return [] }
        switch kind {
        case .pencil: return penBegan(id)
        case .finger: return fingerBegan(id)
        }
    }

    mutating func touchMoved(_ id: TouchID) -> [Decision] {
        guard let touch = touches[id], touch.role == .authoring else { return [] }
        return [.appendToStroke(id)]
    }

    mutating func touchEnded(_ id: TouchID) -> [Decision] {
        guard let touch = touches.removeValue(forKey: id) else { return [] }
        clearStrokePointer(id)
        return touch.role == .authoring ? [.endStroke(id)] : []
    }

    mutating func touchCancelled(_ id: TouchID) -> [Decision] {
        guard let touch = touches.removeValue(forKey: id) else { return [] }
        clearStrokePointer(id)
        return touch.role == .authoring ? [.cancelStroke(id)] : []
    }

    // MARK: - Recognizer gating (queried from `shouldReceive touch`)

    /// May a camera recognizer receive this touch? Pencil never drives the
    /// camera; while the pen is down nothing does (palm rejection); and a
    /// 3rd+ simultaneous finger is never admitted.
    func allowsCameraTouch(kind: TouchKind, excluding id: TouchID? = nil) -> Bool {
        guard kind == .finger, !isPenDown else { return false }
        return fingerCount(excluding: id) < 2
    }

    /// May the undo/redo tap overlay receive this touch? Fingers only, and
    /// never while the pen is down (a palm must not fire undo).
    func allowsUndoTap(kind: TouchKind) -> Bool {
        kind == .finger && !isPenDown
    }

    // MARK: - Private transitions

    private mutating func penBegan(_ id: TouchID) -> [Decision] {
        // Only one pencil can author; a second pencil contact is stray.
        guard penStrokeTouch == nil else {
            touches[id] = TrackedTouch(kind: .pencil, role: .rejected)
            return [.rejectTouch(id)]
        }
        var decisions: [Decision] = []
        // Pen priority over camera gestures in flight: demote every
        // camera-routed finger and have the UIKit layer reset its
        // recognizers.
        if demoteCameraTouches() {
            decisions.append(.cancelCameraGestures)
        }
        touches[id] = TrackedTouch(kind: .pencil, role: .authoring)
        penStrokeTouch = id
        decisions.append(.beginStroke(id, source: .pencil, verb: activeVerb))
        return decisions
    }

    private mutating func fingerBegan(_ id: TouchID) -> [Decision] {
        // Palm rejection: while the pen is down every new finger is inert
        // for its entire lifetime. The rejection also resets the camera/
        // undo recognizers: UIKit evaluates `shouldReceive` before the
        // observer's `touchesBegan`, so a palm landing in the SAME delivery
        // batch as the pen-down was admitted while `isPenDown` was still
        // false — without the reset it would keep steering the camera (or
        // complete an undo tap) for the whole pen stroke. While the pen is
        // down no recognizer may legitimately track anything (penBegan
        // already demoted in-flight camera fingers), so the reset is a
        // no-op in every other case.
        guard penStrokeTouch == nil else {
            touches[id] = TrackedTouch(kind: .finger, role: .rejected)
            return [.rejectTouch(id), .cancelCameraGestures]
        }
        // Fingers never author (spec scenario "Finger strokes never
        // author"): every admitted finger is camera-owned; the camera
        // recognizers decide orbit vs pinch/pan/tap from there.
        touches[id] = TrackedTouch(kind: .finger, role: .camera)
        return []
    }

    /// Flips every camera-routed touch to rejected; returns whether any was.
    private mutating func demoteCameraTouches() -> Bool {
        var demoted = false
        for (id, touch) in touches where touch.role == .camera {
            touches[id]?.role = .rejected
            demoted = true
        }
        return demoted
    }

    private mutating func clearStrokePointer(_ id: TouchID) {
        if penStrokeTouch == id { penStrokeTouch = nil }
    }
}
