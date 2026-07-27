import Foundation

/// Resolves which objects a viewport should draw (openspec add-scene-outliner, 8.1;
/// spec: scene-pipeline).
///
/// Three inputs decide it, and only ONE of them is document state:
///
///   * `Object.isHidden` — persisted, journaled, per object.
///   * `soloed` — VIEW state. Soloing must not rewrite anybody's `isHidden`, or clearing
///     solo could not restore what the artist had configured. Storing solo as "hide
///     everything else" is the mistake this type exists to prevent.
///   * `hiddenGroups` — also view state, for the same reason: hiding a group must not
///     stamp `isHidden` onto each member, because un-hiding it has to restore each
///     member's own visibility rather than reveal something the artist had hidden alone.
///
/// Kept as a pure value beside the document model rather than inside the renderer so the
/// rules are testable without a Metal device — the renderer only consults it.
///
/// Per-FACE visibility (`MeshAnnotations.hiddenFaces`, the 3.4 lasso) is a separate axis
/// and is NOT resolved here. Composition is: geometry draws when this type says the object
/// is visible AND the face is not hidden. Object-level hiding therefore dominates, and it
/// never touches face state.
public struct SceneVisibility: Equatable, Sendable {
    /// The soloed object, or nil when solo is off.
    public var soloed: UUID?
    /// Group names hidden as a whole.
    public var hiddenGroups: Set<String>

    public init(soloed: UUID? = nil, hiddenGroups: Set<String> = []) {
        self.soloed = soloed
        self.hiddenGroups = hiddenGroups
    }

    /// Nothing soloed, no group hidden — the default, under which visibility is exactly
    /// each object's own `isHidden`.
    public static var everything: SceneVisibility { SceneVisibility() }

    /// Whether `object` contributes geometry.
    ///
    /// **Solo wins outright, including over the object's own `isHidden`.** Soloing an
    /// object the artist had hidden shows it: the request is "show me only this", and
    /// answering with an empty viewport would be obtuse. Clearing solo restores the
    /// stored `isHidden`, so nothing is lost by that reading.
    public func isVisible(_ object: DocumentManifest.Object) -> Bool {
        if let soloed { return object.id == soloed }
        if object.isHidden { return false }
        if let group = object.group, hiddenGroups.contains(group) { return false }
        return true
    }

    /// Toggles solo for `id`; soloing the already-soloed object clears it, so the same
    /// affordance turns it off.
    public mutating func toggleSolo(_ id: UUID) {
        soloed = (soloed == id) ? nil : id
    }

    /// Toggles a whole group's visibility.
    public mutating func toggleGroup(_ name: String) {
        if hiddenGroups.contains(name) {
            hiddenGroups.remove(name)
        } else {
            hiddenGroups.insert(name)
        }
    }
}

extension DocumentManifest {
    /// Objects a viewport should draw, in manifest order.
    public func visibleObjects(_ visibility: SceneVisibility = .everything) -> [Object] {
        objects.filter { visibility.isVisible($0) }
    }

    /// Group names present in the document, ordered by first appearance so the outliner's
    /// section order is stable rather than dependent on `Set` iteration.
    public var groupNames: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for object in objects {
            guard let group = object.group, seen.insert(group).inserted else { continue }
            ordered.append(group)
        }
        return ordered
    }
}
