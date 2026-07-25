import CyberKit

/// Auto-Retopo session (Phase 5, add-weave-solver-pipeline): runs the Weave
/// solver over the Target and holds the proposed EditMesh as a ghost the user
/// accepts (commits) or discards. The solver backend is the engine
/// auto-remesher today (`EngineRemeshSolver`); the constraint-aware solver
/// swaps in later behind the same `WeaveSolving` seam with no change here.
///
/// The begin → ghost → accept/discard state machine mirrors the camera-tool
/// sessions: it is driven programmatically (tests call these directly, exactly
/// as `commitCameraToolSession` is driven), so the pipeline's guarantees —
/// accept journals exactly once and undoes cleanly, discard changes nothing,
/// opt-in — are testable without the Metal ghost rendering or gesture routing.
extension MetalViewport.Coordinator {
    /// True while an Auto-Retopo ghost is pending accept/discard.
    var hasAutoRetopoGhost: Bool { autoRetopoGhost != nil }

    /// Runs the Weave solver over the current Target and holds the result as a
    /// pending ghost. NO document change yet. Returns false (inert) when there
    /// is no Target, when the solve produced nothing, or when it was cancelled.
    /// Any pending ghost is replaced.
    @discardableResult
    func beginAutoRetopo(
        parameters: SolverParameters = SolverParameters(),
        onProgress: ((SolverProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        guard let target = currentTargetMesh() else { return false }
        let ghost: SolverGhost?
        do {
            ghost = try weaveSolver.solve(
                source: target, region: .wholeMesh, constraints: WeaveConstraints(),
                params: parameters, onProgress: onProgress, isCancelled: isCancelled
            )
        } catch {
            autoRetopoGhost = nil
            return false
        }
        autoRetopoGhost = ghost
        return ghost != nil
    }

    /// Accepts the pending ghost as the EditMesh in ONE journal entry
    /// (create-or-replace, so a single undo restores the prior document
    /// exactly). No-op returning false when nothing is pending or the command
    /// cannot be built. Clears the pending ghost.
    @discardableResult
    func acceptAutoRetopo() -> Bool {
        guard let ghost = autoRetopoGhost, let bundle = bundleProvider?() else { return false }
        guard let command = try? bundle.objectCommand(
            for: ghost.mesh, name: "EditMesh", role: .editMesh, verb: "autoRetopo.accept"
        ) else { return false }
        autoRetopoGhost = nil
        onCommit?(command)
        return true
    }

    /// Discards the pending ghost with NO journal entry, leaving the document
    /// byte-unchanged. Drawing over the ghost routes here.
    func discardAutoRetopo() {
        autoRetopoGhost = nil
    }

    /// The live Target mesh from the current document bundle, or nil when the
    /// document has no Target to retopologize.
    private func currentTargetMesh() -> Mesh? {
        guard let bundle = bundleProvider?() else { return nil }
        guard let target = bundle.manifest.objects.first(where: { $0.role == .target }) else {
            return nil
        }
        return try? bundle.mesh(for: target)
    }
}
