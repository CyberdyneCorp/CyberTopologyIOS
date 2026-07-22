import Foundation
import Observation

// Customizable toolbar model (task 3.8, spec: pencil-interaction /
// "Customizable toolbar and Action Gallery").
//
// Slot scheme (documented here once, referenced by the views):
//   - The toolbar is a BOUNDED vertical strip of `ToolbarConfiguration
//     .slotCount` (= 6) slots, indexed 0 (top) … 5 (bottom), rendered by
//     `ActionToolbarView` above the viewport (leading edge, mirrored to
//     trailing in left-handed mode — the 3.1 option).
//   - A slot holds at most one `EditorAction`; `nil` is an empty slot and
//     renders as a dashed placeholder that opens the Action Gallery.
//   - An action appears in at most ONE slot: assigning it somewhere else
//     MOVES it (the old slot empties) — duplicates would make hold-chords
//     ambiguous.
//   - VERB actions behave exactly like the 3.1 minimal verb bar: quick tap
//     selects persistently, holding spring-loads for the duration of the
//     hold (the hold-chord state machine lives in `InputArbiter`).
//   - GESTURE actions are drawn on the mesh, not tapped; their slot is a
//     quick reference — tapping opens the Action Gallery focused on that
//     action's help panel.
//   - Default layout: the five verbs in slots 0–4, slot 5 empty.
//   - Assignment surfaces: drag an action from the gallery onto a slot
//     (empty = assign, occupied = replace), drag a slot's action off onto
//     the gallery's action area (remove), double-tap a gallery action
//     (quick-assign: first empty slot, else the last slot is replaced),
//     or the tap path (select an action, tap a slot) — which is also what
//     XCUITest drives, since it cannot synthesize drag-and-drop between
//     SwiftUI drop destinations.
//   - The configuration persists as versioned Codable JSON in
//     `UserDefaults` (`ToolbarStore`) and is restored on every launch
//     (spec scenario "Toolbar persistence").

/// Every action the toolbar and the Action Gallery know: the five verbs
/// (task 3.1/3.3) plus the task-3.4 gesture-grammar entries. Raw values are
/// the persistence and accessibility-identifier vocabulary — renaming one
/// is a persisted-data migration.
enum EditorAction: String, CaseIterable, Codable, Equatable, Sendable {
    // The five verbs (spec: "Five coherent verbs across stages").
    case pencil
    case relax
    case move
    case tweak
    case erase
    // The task-3.4 gesture grammar.
    case quadDraw
    case gridStroke
    case loopInsert
    case loopTag
    case scribbleDissolve
    case crossDelete
    case mergeLine
    case edgeRotate
    case doubleTapTweak
    case visibilityLasso
    case visibilityLines

    /// The verb a toolbar slot holding this action selects; nil for
    /// gesture-grammar actions (drawn, not tapped).
    var verb: InputArbiter.Verb? {
        switch self {
        case .pencil: .pencil
        case .relax: .relax
        case .move: .move
        case .tweak: .tweak
        case .erase: .erase
        default: nil
        }
    }
}

/// The bounded slot assignment. Pure value type — every mutation rule is
/// unit-testable headless (see the slot scheme above for the semantics).
struct ToolbarConfiguration: Equatable, Sendable {
    /// Bounded slot count (spec: "a bounded set of toolbar slots").
    static let slotCount = 6

    /// Persistence format version; bumping it invalidates stored data (the
    /// store falls back to `default`).
    static let version = 1

    /// `slots[i]` is the action in slot `i`, nil = empty. Always exactly
    /// `slotCount` entries.
    private(set) var slots: [EditorAction?]

    /// Five verbs in slots 0–4, slot 5 empty (the 3.1 verb bar, hosted).
    static let `default` = ToolbarConfiguration(
        slots: [.pencil, .relax, .move, .tweak, .erase, nil]
    )

    init(slots: [EditorAction?]) {
        // Normalize: exactly slotCount entries, no duplicate actions (first
        // occurrence wins — later duplicates would shadow the hold-chord).
        var seen = Set<EditorAction>()
        var normalized = slots.prefix(Self.slotCount).map { action -> EditorAction? in
            guard let action, seen.insert(action).inserted else { return nil }
            return action
        }
        normalized.append(
            contentsOf: [EditorAction?](
                repeating: nil, count: Self.slotCount - normalized.count
            )
        )
        self.slots = normalized
    }

    func action(at slot: Int) -> EditorAction? {
        guard slots.indices.contains(slot) else { return nil }
        return slots[slot]
    }

    /// The slot currently holding `action`, if any.
    func slot(of action: EditorAction) -> Int? {
        slots.firstIndex(of: action)
    }

    /// Drag-into-slot / drag-replace / tap-assign: puts `action` into
    /// `slot`, replacing any occupant. If the action already sits in
    /// another slot it MOVES (the old slot empties). Out-of-range slots
    /// are ignored.
    mutating func assign(_ action: EditorAction, to slot: Int) {
        guard slots.indices.contains(slot) else { return }
        if let previous = self.slot(of: action) {
            slots[previous] = nil
        }
        slots[slot] = action
    }

    /// Drag-off-remove / the slot's remove affordance.
    mutating func remove(at slot: Int) {
        guard slots.indices.contains(slot) else { return }
        slots[slot] = nil
    }

    /// Double-tap quick-assign: already placed → keep (returns its slot);
    /// else the first empty slot; a full toolbar replaces the LAST slot
    /// (the bottom one — furthest from the default verb block).
    @discardableResult
    mutating func quickAssign(_ action: EditorAction) -> Int {
        if let existing = slot(of: action) { return existing }
        let target = slots.firstIndex(of: nil) ?? Self.slotCount - 1
        assign(action, to: target)
        return target
    }
}

extension ToolbarConfiguration: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case slots
    }

    /// Forward-compatible decode: slot entries are raw strings so an
    /// action id from a NEWER build decodes to an empty slot instead of
    /// failing the whole configuration; a version bump fails the decode
    /// (the store falls back to the default layout).
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.version else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: container,
                debugDescription: "unsupported toolbar configuration version \(version)"
            )
        }
        let raw = try container.decode([String?].self, forKey: .slots)
        self.init(slots: raw.map { $0.flatMap(EditorAction.init(rawValue:)) })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.version, forKey: .version)
        try container.encode(slots.map { $0?.rawValue }, forKey: .slots)
    }
}

/// Codable persistence in `UserDefaults` (spec scenario "Toolbar
/// persistence"). Injected defaults keep the store unit-testable against a
/// scratch suite.
struct ToolbarStore {
    static let defaultsKey = "toolbarConfiguration"

    var defaults: UserDefaults = .standard

    /// The stored configuration; missing, corrupt, or version-mismatched
    /// data falls back to the default layout (never crashes a launch).
    func load() -> ToolbarConfiguration {
        guard
            let data = defaults.data(forKey: Self.defaultsKey),
            let configuration = try? JSONDecoder().decode(
                ToolbarConfiguration.self, from: data
            )
        else { return .default }
        return configuration
    }

    func save(_ configuration: ToolbarConfiguration) {
        // Encoding a Codable struct of strings cannot fail at runtime;
        // guard anyway so a future field never turns save into a crash.
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Drag payloads for the gallery/toolbar drop destinations, as plain
/// strings (`String` is natively Transferable). Two forms:
///   - "<action id>"        an action dragged out of the gallery list
///   - "slot:<index>"       a slot's occupant dragged off its slot
/// Parsing is pure so the drop-handler policy is unit-testable without
/// instantiating a drag session.
enum ToolbarDragPayload: Equatable {
    case action(EditorAction)
    case slot(Int)

    private static let slotPrefix = "slot:"

    init?(_ string: String) {
        if string.hasPrefix(Self.slotPrefix) {
            guard
                let index = Int(string.dropFirst(Self.slotPrefix.count)),
                (0..<ToolbarConfiguration.slotCount).contains(index)
            else { return nil }
            self = .slot(index)
        } else if let action = EditorAction(rawValue: string) {
            self = .action(action)
        } else {
            return nil
        }
    }

    var string: String {
        switch self {
        case .action(let action): action.rawValue
        case .slot(let index): "\(Self.slotPrefix)\(index)"
        }
    }
}

/// Observable owner of the live configuration: every mutation persists
/// immediately through the store, so a force-quit at any moment restores
/// the exact last state on relaunch.
@MainActor
@Observable
final class ToolbarModel {
    private(set) var configuration: ToolbarConfiguration
    @ObservationIgnored private let store: ToolbarStore

    init(store: ToolbarStore = ToolbarStore()) {
        self.store = store
        configuration = store.load()
    }

    func assign(_ action: EditorAction, to slot: Int) {
        configuration.assign(action, to: slot)
        store.save(configuration)
    }

    func remove(at slot: Int) {
        configuration.remove(at: slot)
        store.save(configuration)
    }

    @discardableResult
    func quickAssign(_ action: EditorAction) -> Int {
        let slot = configuration.quickAssign(action)
        store.save(configuration)
        return slot
    }

    /// One drop handler for every destination, policy in one testable
    /// place: dropping onto a slot assigns/moves, dropping a slot's
    /// occupant onto the gallery's action area removes it (`slot` nil).
    func handleDrop(_ payloadString: String, onSlot slot: Int?) {
        guard let payload = ToolbarDragPayload(payloadString) else { return }
        switch (payload, slot) {
        case (.action(let action), .some(let target)):
            assign(action, to: target)
        case (.slot(let source), .some(let target)):
            if let action = configuration.action(at: source) {
                assign(action, to: target)
            }
        case (.slot(let source), .none):
            remove(at: source)
        case (.action, .none):
            break  // A gallery action dropped back on the gallery: no-op.
        }
    }
}
