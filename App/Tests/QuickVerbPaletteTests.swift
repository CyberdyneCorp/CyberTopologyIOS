import Testing
@testable import CyberTopology

/// Task 3.7 (spec: pencil-interaction / "Pencil Pro and haptic feedback":
/// squeeze opens a radial gallery at the pen tip): the pure squeeze →
/// palette policy plus the model wiring down to the shared arbiter.
/// Squeeze DELIVERY is Pencil Pro hardware-only (`PencilProHardwareTests`);
/// everything below the `UIPencilInteraction` delegate callback is driven
/// directly here.
@MainActor
struct QuickVerbPaletteTests {
    // MARK: - Pure squeeze policy

    @Test func squeezeShowsThePaletteAtThePenLocation() throws {
        var state = QuickVerbPaletteState()
        let effects = state.squeezeEnded(action: .showPalette, at: SIMD2(0.3, 0.6))
        #expect(effects.isEmpty)
        let palette = try #require(state.palette)
        #expect(palette.location == SIMD2(0.3, 0.6))
        #expect(palette.verbs == InputArbiter.Verb.allCases)
    }

    @Test func unknownPoseFallsBackToTheViewportCenterAndEdgesClamp() {
        var state = QuickVerbPaletteState()
        _ = state.squeezeEnded(action: .showPalette, at: nil)
        #expect(state.palette?.location == QuickVerbPaletteState.defaultLocation)
        _ = state.squeezeEnded(action: .showPalette, at: nil)  // toggle off
        // A squeeze at the very edge keeps the ring on screen.
        _ = state.squeezeEnded(action: .showPalette, at: SIMD2(0.01, 0.99))
        let margin = QuickVerbPaletteState.edgeMargin
        #expect(state.palette?.location == SIMD2(margin, 1 - margin))
    }

    @Test func secondSqueezeTogglesThePaletteOff() {
        var state = QuickVerbPaletteState()
        _ = state.squeezeEnded(action: .showPalette, at: nil)
        #expect(state.palette != nil)
        #expect(state.squeezeEnded(action: .showPalette, at: nil).isEmpty)
        #expect(state.palette == nil)
    }

    @Test func eraserPreferenceSelectsEraseWithoutAPalette() {
        var state = QuickVerbPaletteState()
        #expect(state.squeezeEnded(action: .selectEraser, at: nil) == [
            .selectVerb(.erase)
        ])
        #expect(state.palette == nil)
    }

    @Test func ignoredPreferenceDoesNothing() {
        var state = QuickVerbPaletteState()
        #expect(state.squeezeEnded(action: .ignore, at: SIMD2(0.5, 0.5)).isEmpty)
        #expect(state.palette == nil)
    }

    @Test func choosingAVerbSelectsItAndDismisses() {
        var state = QuickVerbPaletteState()
        _ = state.squeezeEnded(action: .showPalette, at: nil)
        #expect(state.verbChosen(.relax) == [.selectVerb(.relax)])
        #expect(state.palette == nil)
        // Choosing without a palette (stale tap) selects nothing.
        #expect(state.verbChosen(.move).isEmpty)
    }

    @Test func strokeBeginDismissesThePalette() {
        var state = QuickVerbPaletteState()
        _ = state.squeezeEnded(action: .showPalette, at: nil)
        state.strokeBegan()
        #expect(state.palette == nil)
    }

    // MARK: - System squeeze-preference mapping

    @Test func systemPreferenceMapsToPalettePolicy() {
        typealias Action = QuickVerbPaletteState.SqueezeAction
        #expect(Action(systemPreference: .ignore) == .ignore)
        #expect(Action(systemPreference: .switchPrevious) == .ignore)
        #expect(Action(systemPreference: .switchEraser) == .selectEraser)
        #expect(Action(systemPreference: .showContextualPalette) == .showPalette)
        #expect(Action(systemPreference: .showColorPalette) == .showPalette)
        #expect(Action(systemPreference: .showInkAttributes) == .showPalette)
    }

    // MARK: - Model wiring (the entry the UIPencilInteraction delegate calls)

    @Test func modelPublishesThePaletteAndSelectionReachesTheArbiter() {
        let model = ViewportInputModel()
        model.pencilSqueezed(action: .showPalette, atNormalized: SIMD2(0.4, 0.4))
        #expect(model.quickVerbPalette != nil)
        model.chooseQuickVerb(.tweak)
        #expect(model.quickVerbPalette == nil)
        #expect(model.activeVerb == .tweak)
    }

    @Test func eraserSqueezeSelectsEraseDirectly() {
        let model = ViewportInputModel()
        model.pencilSqueezed(action: .selectEraser, atNormalized: nil)
        #expect(model.quickVerbPalette == nil)
        #expect(model.activeVerb == .erase)
    }

    @Test func beginningAStrokeDismissesThePublishedPalette() {
        let model = ViewportInputModel()
        model.pencilSqueezed(action: .showPalette, atNormalized: nil)
        #expect(model.quickVerbPalette != nil)
        model.controller.capture.begin(
            source: .pencil, verb: .pencil,
            sample: .init(time: 0, x: 0.5, y: 0.5, pressure: 0.5, type: .pencil)
        )
        #expect(model.quickVerbPalette == nil)
        model.controller.capture.cancel()
    }

    @Test func explicitDismissClosesThePalette() {
        let model = ViewportInputModel()
        model.pencilSqueezed(action: .showPalette, atNormalized: nil)
        model.dismissQuickVerbPalette()
        #expect(model.quickVerbPalette == nil)
        #expect(model.activeVerb == .pencil)  // dismissal selects nothing
    }

    // MARK: - Barrel-roll hook (task 3.7; first consumer is 4.2, see 3.7a)

    @Test func barrelRollUpdatesPublishTheAngleAndDedupe() {
        let model = ViewportInputModel()
        var received: [Float] = []
        model.onBarrelRollChanged = { received.append($0) }
        model.barrelRollChanged(0)  // pointer hardware: always 0, no spam
        model.barrelRollChanged(0.4)
        model.barrelRollChanged(0.4)
        model.barrelRollChanged(-0.2)
        #expect(received == [0.4, -0.2])
        #expect(model.barrelRollAngle == -0.2)
    }
}
