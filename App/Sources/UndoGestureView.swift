import SwiftUI
import UIKit

/// Transparent multi-touch tap catcher: three-finger tap = undo, four-finger
/// tap = redo (spec: document-model / "Gesture undo/redo"). SwiftUI's tap
/// gestures cannot require touch counts, so this drops to UIKit recognizers.
struct UndoGestureView: UIViewRepresentable {
    let onUndo: @MainActor () -> Void
    let onRedo: @MainActor () -> Void

    func makeUIView(context: Context) -> UIView {
        Self.makeConfiguredView(coordinator: context.coordinator)
    }

    /// Split from `makeUIView` so tests can verify the recognizer setup
    /// (`Context` has no accessible initializer).
    static func makeConfiguredView(coordinator: Coordinator) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let undo = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.undoTap)
        )
        undo.numberOfTouchesRequired = 3
        view.addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.redoTap)
        )
        redo.numberOfTouchesRequired = 4
        view.addGestureRecognizer(redo)

        // No failure requirement between the two: a UITapGestureRecognizer
        // fails on its own when MORE touches land than it requires, so a
        // 4-finger tap cannot double-fire the 3-touch recognizer. Coupling
        // them via require(toFail:) left the 3-touch recognizer waiting on
        // a 4-touch recognizer that can linger in .possible, swallowing
        // legitimate undo taps.
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onUndo = onUndo
        context.coordinator.onRedo = onRedo
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onUndo: onUndo, onRedo: onRedo)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onUndo: @MainActor () -> Void
        var onRedo: @MainActor () -> Void

        init(onUndo: @escaping @MainActor () -> Void, onRedo: @escaping @MainActor () -> Void) {
            self.onUndo = onUndo
            self.onRedo = onRedo
        }

        @objc func undoTap() { onUndo() }
        @objc func redoTap() { onRedo() }
    }
}
