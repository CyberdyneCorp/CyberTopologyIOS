import Foundation

/// A reversible document mutation (design D4; spec: document-model /
/// "Unbounded undo tree").
///
/// Every mutating operation on a document goes through a command so it can
/// be journaled: `apply` performs it, `revert` undoes it exactly. Commands
/// are self-contained (they carry the data needed for both directions), so
/// a persisted journal can replay in either direction after reopen.
///
/// Phase 2+ tools add cases here.
public enum DocumentCommand: Codable, Equatable, Sendable {
    /// Stage switch (RT / UV / BK).
    case setStage(from: DocumentManifest.Stage, to: DocumentManifest.Stage)
    /// Object import: carries the manifest entry and its payload bytes so
    /// undo can remove them and redo can restore them without the source
    /// file. TODO: move payload bytes to a content-addressed store if
    /// journal size becomes a problem for very large imports.
    case addObject(object: DocumentManifest.Object, payload: Data)
    /// Mesh-level edit of one object (task 3.3, the five RT verbs): carries
    /// the EXACT before/after payload bytes plus the manifest bookkeeping
    /// (counts, revision), so apply and revert are byte-exact in both
    /// directions regardless of engine element-id recycling.
    case meshEdit(MeshEdit)
    /// Annotation edit of one object (task 3.4: loop tags, partial
    /// visibility): carries the exact before/after annotation state, so
    /// apply and revert restore it verbatim. Topology and payload bytes
    /// are untouched.
    case annotationEdit(AnnotationEdit)

    /// Payload of a `meshEdit` command. `before`/`after` are complete
    /// engine payload snapshots of the edited object — exact revert data at
    /// EditMesh (low-poly cage) scale. TODO(upstream): switch to an
    /// engine-provided inverse changeset when the capi grows one, keeping
    /// this shape as the fallback for oversized edits.
    public struct MeshEdit: Codable, Equatable, Sendable {
        public let objectID: UUID
        public let payloadFile: String
        /// The verb that produced the edit (journal display / debugging).
        public let verb: String
        public let before: Data
        public let after: Data
        public let beforeCounts: DocumentManifest.Object.Counts?
        public let afterCounts: DocumentManifest.Object.Counts?
        /// Manifest revision bookkeeping: bumping `Object.revision` makes
        /// equal-count edits (a moved vertex) visible to manifest observers.
        public let beforeRevision: Int?
        public let afterRevision: Int

        public init(
            objectID: UUID, payloadFile: String, verb: String, before: Data, after: Data,
            beforeCounts: DocumentManifest.Object.Counts?,
            afterCounts: DocumentManifest.Object.Counts?,
            beforeRevision: Int?, afterRevision: Int
        ) {
            self.objectID = objectID
            self.payloadFile = payloadFile
            self.verb = verb
            self.before = before
            self.after = after
            self.beforeCounts = beforeCounts
            self.afterCounts = afterCounts
            self.beforeRevision = beforeRevision
            self.afterRevision = afterRevision
        }
    }

    /// Payload of an `annotationEdit` command.
    public struct AnnotationEdit: Codable, Equatable, Sendable {
        public let objectID: UUID
        /// The gesture that produced the edit (journal display / debugging).
        public let verb: String
        public let before: MeshAnnotations?
        public let after: MeshAnnotations?

        public init(
            objectID: UUID, verb: String, before: MeshAnnotations?, after: MeshAnnotations?
        ) {
            self.objectID = objectID
            self.verb = verb
            self.before = before
            self.after = after
        }
    }

    /// Performs the command on `bundle`.
    public func apply(to bundle: inout DocumentBundle) {
        switch self {
        case .setStage(_, let to):
            bundle.manifest.stage = to
        case .addObject(let object, let payload):
            bundle.payloads[object.payloadFile] = payload
            bundle.manifest.objects.append(object)
        case .meshEdit(let edit):
            bundle.payloads[edit.payloadFile] = edit.after
            bundle.updateObject(id: edit.objectID) { object in
                object.counts = edit.afterCounts
                object.revision = edit.afterRevision
            }
        case .annotationEdit(let edit):
            bundle.updateObject(id: edit.objectID) { object in
                object.annotations = edit.after
            }
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
        case .meshEdit(let edit):
            bundle.payloads[edit.payloadFile] = edit.before
            bundle.updateObject(id: edit.objectID) { object in
                object.counts = edit.beforeCounts
                object.revision = edit.beforeRevision
            }
        case .annotationEdit(let edit):
            bundle.updateObject(id: edit.objectID) { object in
                object.annotations = edit.before
            }
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

    /// Command at the current position (nil at the root). Lets callers
    /// verify what an in-place replacement would swap out (task 3.5 chip).
    public var currentCommand: DocumentCommand? {
        currentID.flatMap { nodes[$0]?.command }
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

    /// Replaces the CURRENT node's command in place (task 3.5, spec:
    /// pencil-interaction / "Post-stroke interpretation chip" — choosing an
    /// alternative replaces the applied result without requiring undo). The
    /// node keeps its id, parent, and children, so the history gains no
    /// extra entry and no extra undo step: after the swap exactly one
    /// journal entry stands for the stroke, and a single undo steps back
    /// over the replacement. Returns the replaced command (the caller must
    /// revert it before applying the replacement), or nil at the root.
    public mutating func replaceCurrent(with command: DocumentCommand) -> DocumentCommand? {
        guard let id = currentID, let node = nodes[id] else { return nil }
        nodes[id] = Node(id: id, parent: node.parent, command: command)
        return node.command
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
