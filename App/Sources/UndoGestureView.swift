import SwiftUI
import UIKit

/// Transparent multi-touch tap catcher: two-finger tap = undo, three-finger
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
        undo.numberOfTouchesRequired = 2
        view.addGestureRecognizer(undo)

        let redo = UITapGestureRecognizer(
            target: coordinator, action: #selector(Coordinator.redoTap)
        )
        redo.numberOfTouchesRequired = 3
        view.addGestureRecognizer(redo)

        // Two fingers must not fire when three land: require 2-touch to
        // wait for 3-touch to fail.
        undo.require(toFail: redo)
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
