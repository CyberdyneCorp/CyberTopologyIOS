import Foundation
import Testing

@testable import CyberTopology

/// Customizable-toolbar model (task 3.8, spec: pencil-interaction /
/// "Customizable toolbar and Action Gallery"): the bounded slot scheme,
/// assignment/replace/remove/quick-assign rules, drag-payload policy, the
/// versioned Codable persistence, and the Action Gallery catalog's
/// completeness. All headless — the drag/drop and tap UI surfaces route
/// into exactly these mutations.
struct ToolbarConfigurationTests {
    // MARK: - Slot scheme

    @Test func defaultLayoutHostsTheFiveVerbsWithOneEmptySlot() {
        let config = ToolbarConfiguration.default
        #expect(ToolbarConfiguration.slotCount == 6)
        #expect(config.slots == [.pencil, .relax, .move, .tweak, .erase, nil])
        // Every default occupant is a verb (the 3.1 bar, hosted).
        #expect(config.slots.compactMap { $0?.verb }.count == 5)
    }

    @Test func assignFillsEmptySlotAndReplaceOverwritesOccupant() {
        var config = ToolbarConfiguration.default
        config.assign(.loopInsert, to: 5)
        #expect(config.action(at: 5) == .loopInsert)

        // Drag-replace: dropping another action on the same slot.
        config.assign(.loopTag, to: 5)
        #expect(config.action(at: 5) == .loopTag)
        #expect(config.slot(of: .loopInsert) == nil)
    }

    @Test func assigningAPlacedActionMovesItInsteadOfDuplicating() {
        var config = ToolbarConfiguration.default
        config.assign(.relax, to: 5)
        #expect(config.action(at: 5) == .relax)
        #expect(config.action(at: 1) == nil, "the old Relax slot must empty")
        #expect(config.slots.compactMap { $0 }.count == 5)
    }

    @Test func removeEmptiesTheSlotIdempotently() {
        var config = ToolbarConfiguration.default
        config.remove(at: 0)
        #expect(config.action(at: 0) == nil)
        config.remove(at: 0)
        #expect(config.action(at: 0) == nil)
    }

    @Test func outOfRangeSlotsAreIgnored() {
        var config = ToolbarConfiguration.default
        config.assign(.loopInsert, to: ToolbarConfiguration.slotCount)
        config.assign(.loopInsert, to: -1)
        config.remove(at: 99)
        #expect(config == .default)
        #expect(config.action(at: 99) == nil)
    }

    @Test func quickAssignUsesFirstEmptySlotThenReplacesTheLast() {
        var config = ToolbarConfiguration.default
        #expect(config.quickAssign(.edgeRotate) == 5)
        #expect(config.action(at: 5) == .edgeRotate)

        // Already placed: keep the existing slot, change nothing.
        #expect(config.quickAssign(.edgeRotate) == 5)
        #expect(config.slots.compactMap { $0 }.count == 6)

        // Toolbar full: the LAST slot is replaced.
        #expect(config.quickAssign(.mergeLine) == 5)
        #expect(config.action(at: 5) == .mergeLine)
        #expect(config.slot(of: .edgeRotate) == nil)
    }

    @Test func initNormalizesDuplicatesAndLength() {
        let config = ToolbarConfiguration(slots: [.pencil, .pencil, .relax])
        #expect(config.slots.count == ToolbarConfiguration.slotCount)
        #expect(config.slots[0] == .pencil)
        #expect(config.slots[1] == nil, "duplicate must not survive init")
        #expect(config.slots[2] == .relax)

        let overlong = ToolbarConfiguration(
            slots: [EditorAction?](repeating: .erase, count: 10)
        )
        #expect(overlong.slots.count == ToolbarConfiguration.slotCount)
    }

    // MARK: - Codable persistence

    @Test func codableRoundTripIsExact() throws {
        var config = ToolbarConfiguration.default
        config.assign(.visibilityLasso, to: 2)
        config.remove(at: 0)
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ToolbarConfiguration.self, from: data)
        #expect(decoded == config)
    }

    @Test func unknownActionIDDecodesToAnEmptySlotNotAFailure() throws {
        // Forward compatibility: a NEWER build's action id must not nuke
        // the whole configuration.
        let json = """
        {"version": 1, "slots": ["pencil", "warpFuture", null, "loopTag", null, null]}
        """
        let decoded = try JSONDecoder().decode(
            ToolbarConfiguration.self, from: Data(json.utf8)
        )
        #expect(decoded.slots[0] == .pencil)
        #expect(decoded.slots[1] == nil)
        #expect(decoded.slots[3] == .loopTag)
    }

    @Test func versionMismatchFailsDecode() {
        let json = """
        {"version": 99, "slots": []}
        """
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(
                ToolbarConfiguration.self, from: Data(json.utf8)
            )
        }
    }

    @Test func storeRoundTripAndCorruptDataFallBackToDefault() throws {
        try withScratchDefaults { defaults in
            let store = ToolbarStore(defaults: defaults)

            // Missing data → default.
            #expect(store.load() == .default)

            var config = ToolbarConfiguration.default
            config.assign(.gridStroke, to: 5)
            store.save(config)
            #expect(store.load() == config)

            // A second store over the same defaults sees the same bytes
            // (the relaunch path, headless).
            #expect(ToolbarStore(defaults: defaults).load() == config)

            // Corrupt data → default, no crash.
            defaults.set(Data("not json".utf8), forKey: ToolbarStore.defaultsKey)
            #expect(store.load() == .default)
        }
    }

    // MARK: - Drag payloads

    @Test func dragPayloadRoundTripAndRejection() {
        #expect(
            ToolbarDragPayload(ToolbarDragPayload.action(.loopTag).string)
                == .action(.loopTag)
        )
        #expect(ToolbarDragPayload(ToolbarDragPayload.slot(3).string) == .slot(3))
        #expect(ToolbarDragPayload("slot:99") == nil)
        #expect(ToolbarDragPayload("slot:x") == nil)
        #expect(ToolbarDragPayload("notAnAction") == nil)
    }

    // MARK: - ToolbarModel (mutation + persistence + drop policy)

    @Test @MainActor
    func modelPersistsEveryMutationAndRestoresAcrossInstances() throws {
        try withScratchDefaults { defaults in
            let store = ToolbarStore(defaults: defaults)
            let model = ToolbarModel(store: store)
            #expect(model.configuration == .default)

            model.assign(.crossDelete, to: 5)
            model.remove(at: 0)
            model.quickAssign(.scribbleDissolve)  // → the freed slot 0

            #expect(model.configuration.action(at: 5) == .crossDelete)
            #expect(model.configuration.action(at: 0) == .scribbleDissolve)

            // A fresh model over the same store is the relaunch: restored
            // exactly (spec scenario "Toolbar persistence", model half).
            let relaunched = ToolbarModel(store: store)
            #expect(relaunched.configuration == model.configuration)
        }
    }

    @Test @MainActor
    func dropPolicyAssignsMovesAndRemoves() throws {
        try withScratchDefaults { defaults in
            let model = ToolbarModel(store: ToolbarStore(defaults: defaults))

            // Gallery action dropped on a slot: assign.
            model.handleDrop(ToolbarDragPayload.action(.loopInsert).string, onSlot: 5)
            #expect(model.configuration.action(at: 5) == .loopInsert)

            // Slot occupant dropped on another slot: move (source empties).
            model.handleDrop(ToolbarDragPayload.slot(5).string, onSlot: 0)
            #expect(model.configuration.action(at: 0) == .loopInsert)
            #expect(model.configuration.action(at: 5) == nil)

            // Slot occupant dropped off the strip: remove.
            model.handleDrop(ToolbarDragPayload.slot(0).string, onSlot: nil)
            #expect(model.configuration.slot(of: .loopInsert) == nil)

            // No-ops: gallery action dropped outside a slot, garbage
            // payload, and an EMPTY slot dragged anywhere.
            let before = model.configuration
            model.handleDrop(ToolbarDragPayload.action(.loopTag).string, onSlot: nil)
            model.handleDrop("garbage", onSlot: 3)
            model.handleDrop(ToolbarDragPayload.slot(5).string, onSlot: 2)
            #expect(model.configuration == before)
        }
    }

    // MARK: - Action Gallery catalog

    @Test func everyActionHasACompleteGalleryEntry() {
        // The gallery SHALL list every action (verbs + 3.4 grammar) with
        // help content and a demo-media slot; an empty field here would
        // render as a blank help panel.
        #expect(EditorAction.allCases.count == 16)
        for action in EditorAction.allCases {
            let entry = action.gallery
            #expect(!entry.title.isEmpty, "\(action) title")
            #expect(!entry.symbol.isEmpty, "\(action) symbol")
            #expect(!entry.gesture.isEmpty, "\(action) gesture")
            #expect(!entry.notes.isEmpty, "\(action) notes")
            #expect(
                entry.demoFrames.count >= 2,
                "\(action) demo loop needs at least two frames"
            )
        }
        // Titles are unique — two actions must not be indistinguishable
        // in the gallery.
        let titles = EditorAction.allCases.map { $0.gallery.title }
        #expect(Set(titles).count == titles.count)
    }

    @Test func verbActionsMapBothWays() {
        for verb in InputArbiter.Verb.allCases {
            #expect(verb.editorAction.verb == verb)
            #expect(verb.systemImage == verb.editorAction.gallery.symbol)
        }
        // Gesture actions carry no verb.
        #expect(EditorAction.loopInsert.verb == nil)
        #expect(EditorAction.visibilityLines.verb == nil)
    }

    // MARK: - Helpers

    /// Fresh, isolated UserDefaults, cleaned up after the body runs.
    private func withScratchDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "toolbar-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }
}
