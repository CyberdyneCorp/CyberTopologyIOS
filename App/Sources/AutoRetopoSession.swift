import CyberKit
import Foundation

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
            syncAutoRetopoGhostState()
            return false
        }
        autoRetopoGhost = ghost
        syncAutoRetopoGhostState()
        return ghost != nil
    }

    /// The UI entry point: runs the solve OFF the main thread so a large Target
    /// does not freeze the app, then presents the ghost. Engine meshes are not
    /// `Sendable`, so the Target and the result cross the thread boundary as
    /// payload `Data` (which is), deserialized into a fresh mesh on each side —
    /// the `WeaveSolving` seam is preserved. Sets `autoRetopoSolving` for the
    /// duration so the viewport can show progress.
    @discardableResult
    func beginAutoRetopoAsync(parameters: SolverParameters = .autoRetopoDefault) async -> Bool {
        guard let target = currentTargetMesh() else { return false }
        let targetData: Data
        do { targetData = try target.payloadData() } catch { return false }

        // Honour the document's active symmetry (clip + mirror about the plane)
        // and any authored guide strokes (steer the cross field toward them).
        let constraints = WeaveConstraints(
            guideStrokes: meshEditor.authoredGuides.map { GuideStroke(points: $0) },
            symmetry: bundleProvider?().manifest.symmetry
        )

        inputModel.autoRetopoSolving = true
        defer { inputModel.autoRetopoSolving = false }

        let ghostData = await Self.solveOffMain(
            targetData: targetData, params: parameters, constraints: constraints,
            solver: weaveSolver
        )
        guard let ghostData else {
            autoRetopoGhost = nil
            syncAutoRetopoGhostState()
            return false
        }
        let ghostMesh: Mesh
        do { ghostMesh = try Mesh(payloadData: ghostData) } catch {
            autoRetopoGhost = nil
            syncAutoRetopoGhostState()
            return false
        }
        autoRetopoGhost = SolverGhost(mesh: ghostMesh, addedFaces: ghostMesh.liveFaceIDs())
        syncAutoRetopoGhostState()
        return true
    }

    /// Runs the solve OFF the main actor. Data in, Data out — the engine meshes
    /// are created and destroyed inside this call, so nothing non-`Sendable`
    /// crosses the boundary.
    private nonisolated static func solveOffMain(
        targetData: Data, params: SolverParameters, constraints: WeaveConstraints,
        solver: WeaveSolving
    ) async -> Data? {
        await Task.detached(priority: .userInitiated) { () -> Data? in
            let source: Mesh
            do { source = try Mesh(payloadData: targetData) } catch { return nil }
            let ghost: SolverGhost?
            do {
                ghost = try solver.solve(
                    source: source, region: .wholeMesh, constraints: constraints,
                    params: params, onProgress: nil, isCancelled: { false }
                )
            } catch { return nil }
            guard let ghost else { return nil }
            return try? ghost.mesh.payloadData()
        }.value
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
        syncAutoRetopoGhostState()
        onCommit?(command)
        return true
    }

    /// Discards the pending ghost with NO journal entry, leaving the document
    /// byte-unchanged. Drawing over the ghost routes here.
    func discardAutoRetopo() {
        autoRetopoGhost = nil
        syncAutoRetopoGhostState()
    }

    /// Reflects the pending ghost into the renderer (amber Weave proposal) and
    /// the input model (the accept/discard bar observes it). No-ops on the
    /// renderer headless (tests have no renderer); the state still updates.
    private func syncAutoRetopoGhostState() {
        inputModel.autoRetopoGhostPending = autoRetopoGhost != nil
        guard let renderer else { return }
        if let ghost = autoRetopoGhost {
            renderer.ghostStyle = .weaveProposal(sceneRadius: renderer.bounds.radius)
            renderer.loadGhost(mesh: ghost.mesh)
        } else {
            renderer.clearGhost()
        }
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
