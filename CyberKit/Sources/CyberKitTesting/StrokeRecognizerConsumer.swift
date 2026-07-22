import CyberKit
import Foundation

/// `StrokeConsumer` adapter that feeds completed strokes through the ENGINE
/// two-stage recognizer (task 3.2, design D5). This is the bridge between
/// the task-1.1b fixture/replay format and `CyberKit.StrokeInterpreter`:
/// the live capture pipeline and the regression suite drive the exact same
/// object, so a fixture replay exercises the identical code path as a real
/// Pencil stroke.
///
/// Cancelled strokes are discarded without interpretation (palm rejection
/// and pen-priority aborts must never reach the recognizer).
public final class StrokeRecognizerConsumer: StrokeConsumer {
    /// Mesh context for stage 2, fetched at stroke end so the recognizer
    /// always resolves against the CURRENT EditMesh and camera. Return
    /// `(nil, nil, 1)` for stage-1-only interpretation.
    public typealias ContextProvider = () -> (
        editMesh: Mesh?, viewProjection: [Float]?, aspect: Float
    )

    public var contextProvider: ContextProvider?
    /// Fires after every successfully interpreted stroke.
    public var onInterpretation: ((StrokeInterpretation, [StrokeSample]) -> Void)?

    public private(set) var lastInterpretation: StrokeInterpretation?
    public private(set) var lastError: Error?
    private var samples: [StrokeSample] = []
    private var active = false

    public init(contextProvider: ContextProvider? = nil) {
        self.contextProvider = contextProvider
    }

    public func strokeBegan() {
        samples.removeAll(keepingCapacity: true)
        active = true
    }

    public func consume(_ sample: StrokeSample) {
        guard active else { return }
        samples.append(sample)
    }

    public func strokeEnded() {
        guard active else { return }
        active = false
        guard !samples.isEmpty else { return }
        // The recognizer is touch-type agnostic by design: finger-typed
        // fixture replays (the injection test hooks) classify identically
        // to live Pencil strokes.
        let inputs = samples.map {
            StrokeInterpreter.Sample(x: $0.x, y: $0.y, time: $0.time)
        }
        let context = contextProvider?() ?? (editMesh: nil, viewProjection: nil, aspect: 1)
        do {
            let interpretation = try StrokeInterpreter.interpret(
                samples: inputs,
                editMesh: context.editMesh,
                viewProjection: context.viewProjection,
                aspect: context.aspect
            )
            lastInterpretation = interpretation
            lastError = nil
            onInterpretation?(interpretation, samples)
        } catch {
            lastError = error
        }
    }

    public func strokeCancelled() {
        // Aborted strokes are never interpreted.
        samples.removeAll(keepingCapacity: true)
        active = false
    }
}
