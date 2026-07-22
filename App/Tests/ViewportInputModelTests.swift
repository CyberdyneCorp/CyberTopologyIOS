import SwiftUI
import Testing
import UIKit
@testable import CyberTopology

/// Verb toolbar model + view (task 3.1 item 3: spring-loaded hold-chords;
/// hosted by the task-3.8 customizable slot toolbar).
@MainActor
struct ViewportInputModelTests {
    @Test func tapSelectsAndHoldSpringLoads() {
        let model = ViewportInputModel()

        // Quick tap → persistent selection, mirrored for the UI.
        model.verbPressBegan(.relax, at: 0)
        model.verbPressEnded(.relax, at: 0.1)
        #expect(model.activeVerb == .relax)

        // Long hold → active only during the hold, then restored.
        model.verbPressBegan(.erase, at: 1.0)
        #expect(model.activeVerb == .erase)
        model.verbPressEnded(.erase, at: 2.0)
        #expect(model.activeVerb == .relax)
    }

    @Test func selectVerbMirrorsTheArbiter() {
        let model = ViewportInputModel()
        model.selectVerb(.tweak)
        #expect(model.activeVerb == .tweak)
        #expect(model.controller.activeVerb == .tweak)
    }

    @Test func finishedStrokesPublishAHUDSummary() {
        let model = ViewportInputModel()
        #expect(model.lastStrokeSummary == nil)
        model.controller.capture.begin(
            source: .finger, verb: .pencil,
            sample: .init(time: 100, x: 0.1, y: 0.1, type: .finger)
        )
        model.controller.capture.end()
        // Since task 3.2 the summary carries the engine interpretation: a
        // single stationary sample classifies as a hold with no applicable
        // action (stage-1 only — no mesh context installed here).
        #expect(model.lastStrokeSummary == "Stroke: 1 samples (finger, pencil) -> holdPoint none 0.20")
    }

    @Test func cancelledStrokesPublishNothing() {
        let model = ViewportInputModel()
        model.controller.capture.begin(
            source: .pencil, verb: .relax,
            sample: .init(time: 0, x: 0.5, y: 0.5)
        )
        model.controller.capture.cancel()
        #expect(model.lastStrokeSummary == nil)
        #expect(model.lastInterpretation == nil)
        #expect(model.lastStrokePolyline.isEmpty)
    }

    @Test func toolbarRendersAllVerbs() {
        let model = ViewportInputModel()
        // Default slot layout hosts the five verbs (task 3.8 toolbar).
        let toolbar = ToolbarModel(store: ToolbarStore(
            defaults: UserDefaults(suiteName: "input-model-toolbar-\(UUID())")!
        ))
        let host = UIHostingController(
            rootView: ActionToolbarView(model: model, toolbar: toolbar) { _ in }
        )
        host.view.frame = CGRect(x: 0, y: 0, width: 80, height: 400)
        host.view.layoutIfNeeded()
        #expect(host.sizeThatFits(in: CGSize(width: 80, height: 400)).height > 0)
    }

    @Test func everyVerbHasAToolbarGlyph() {
        for verb in InputArbiter.Verb.allCases {
            #expect(!verb.systemImage.isEmpty)
        }
    }
}
