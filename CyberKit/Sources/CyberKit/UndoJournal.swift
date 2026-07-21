import Foundation

/// A reversible document mutation (design D4; spec: document-model /
/// "Unbounded undo tree").
///
/// Every mutating operation on a document goes through a command so it can
/// be journaled: `apply` performs it, `revert` undoes it exactly. Commands
/// are self-contained (they carry the data needed for both directions), so
/// a persisted journal can replay in either direction after reopen.
///
/// Phase 2+ tools add cases here. TODO(upstream): mesh-editing commands
/// need persistent element IDs from the engine capi; until then commands
/// operate at object/manifest granularity.
public enum DocumentCommand: Codable, Equatable, Sendable {
    /// Stage switch (RT / UV / BK).
    case setStage(from: DocumentManifest.Stage, to: DocumentManifest.Stage)
    /// Object import: carries the manifest entry and its payload bytes so
    /// undo can remove them and redo can restore them without the source
    /// file. TODO: move payload bytes to a content-addressed store if
    /// journal size becomes a problem for very large imports.
    case addObject(object: DocumentManifest.Object, payload: Data)

    /// Performs the command on `bundle`.
    public func apply(to bundle: inout DocumentBundle) {
        switch self {
        case .setStage(_, let to):
            bundle.manifest.stage = to
        case .addObject(let object, let payload):
            bundle.payloads[object.payloadFile] = payload
            bundle.manifest.objects.append(object)
        }
    }

    /// Exactly undoes the command on `bundle`.
    public func revert(on bundle: inout DocumentBundle) {
        switch self {
        case .setStage(let from, _):
            bundle.manifest.stage = from
        case .addObject(let object, _):
            bundle.manifest.objects.removeAll { $0.id == object.id }
            bundle.payloads.removeValue(forKey: object.payloadFile)
        }
    }
}

/// Branch-preserving undo tree (spec: document-model / "Unbounded undo
/// tree"): bounded only by storage, and redoing after divergent edits does
/// not discard the abandoned branch — it stays reachable via `children(of:)`
/// for the session (and across reopens, since the journal persists in the
/// document bundle as `journal.json`).
///
/// The tree records commands; the document applies/reverts them. `current`
/// identifies the node whose command was applied last (nil = pristine
/// initial state). Redo follows the *preferred* child: the most recently
/// recorded or redone branch at each node.
public struct UndoJournal: Codable, Equatable, Sendable {
    public struct Node: Codable, Equatable, Sendable, Identifiable {
        public let id: UUID
        /// nil parent = child of the root (initial document state).
        public let parent: UUID?
        public let command: DocumentCommand
    }

    /// Key used for the root in `preferredChild` (a UUID that cannot
    /// collide with node ids, which are always random v4).
    private static let rootKey = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

    private(set) var nodes: [UUID: Node]
    private(set) var currentID: UUID?
    /// parent (or root key) → child on the active redo path.
    private var preferredChild: [UUID: UUID]

    public init() {
        nodes = [:]
        currentID = nil
        preferredChild = [:]
    }

    // MARK: - State

    public var canUndo: Bool { currentID != nil }

    public var canRedo: Bool {
        preferredChild[currentID ?? Self.rootKey] != nil
    }

    /// Number of commands on the path from the root to `current`.
    public var depth: Int {
        var count = 0
        var cursor = currentID
        while let id = cursor {
            count += 1
            cursor = nodes[id]?.parent
        }
        return count
    }

    /// All recorded branches under a node (nil = root), most recent last.
    /// The abandoned side of a divergence stays listed here.
    public func children(of id: UUID?) -> [Node] {
        nodes.values
            .filter { $0.parent == id }
            .sorted { first, second in
                // Preferred child last, otherwise stable by id for determinism.
                if preferredChild[id ?? Self.rootKey] == first.id { return false }
                if preferredChild[id ?? Self.rootKey] == second.id { return true }
                return first.id.uuidString < second.id.uuidString
            }
    }

    // MARK: - Mutation

    /// Appends a command as a new branch at the current position and moves
    /// onto it. An existing redo branch is kept, not discarded.
    public mutating func record(_ command: DocumentCommand) {
        let node = Node(id: UUID(), parent: currentID, command: command)
        nodes[node.id] = node
        preferredChild[currentID ?? Self.rootKey] = node.id
        currentID = node.id
    }

    /// Steps back one command; returns the command to revert, or nil at the
    /// root.
    public mutating func undo() -> DocumentCommand? {
        guard let id = currentID, let node = nodes[id] else { return nil }
        currentID = node.parent
        return node.command
    }

    /// Steps forward along the preferred branch; returns the command to
    /// apply, or nil when there is nothing to redo.
    public mutating func redo() -> DocumentCommand? {
        guard let childID = preferredChild[currentID ?? Self.rootKey],
            let node = nodes[childID]
        else { return nil }
        currentID = childID
        return node.command
    }
}
