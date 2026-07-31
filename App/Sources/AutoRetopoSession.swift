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
        region: SolveRegion = .wholeMesh,
        constraints: WeaveConstraints = WeaveConstraints(),
        onProgress: ((SolverProgress) -> Void)? = nil,
        isCancelled: () -> Bool = { false }
    ) -> Bool {
        guard let target = currentTargetMesh() else { return false }
        let ghost: SolverGhost?
        do {
            ghost = try weaveSolver.solve(
                source: target, region: region, constraints: constraints,
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
    func beginAutoRetopoAsync(
        parameters: SolverParameters = .autoRetopoDefault,
        region: SolveRegion = .wholeMesh
    ) async -> Bool {
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

        let solved = await Self.solveOffMain(
            targetData: targetData, params: parameters, constraints: constraints,
            region: region, solver: weaveSolver
        )
        let ghostData = solved?.payload
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
        // Remembered because ACCEPT behaves differently for a region patch: it
        // merges into the existing cage instead of replacing it (openspec
        // add-painted-region-retopo).
        autoRetopoGhostIsRegional = { if case .faces = region { return true } else { return false } }()
        autoRetopoGhost = SolverGhost(
            mesh: ghostMesh,
            addedFaces: ghostMesh.liveFaceIDs(),
            interfaceVertices: solved?.interfaceVertices ?? [],
            interfaceIrregular: solved?.interfaceIrregular ?? [],
            residualTriangles: solved?.residualTriangles ?? 0,
            interiorIndexBudget: solved?.interiorIndexBudget ?? 0
        )
        // 13.3: surface what the solve reported rather than swallowing it. An
        // irregular interface is NOT a failure — the guarantee is exact landing,
        // and regularity is measured, not enforced (task 5.3a) — but the user
        // should be told before they accept a patch with a pole welded into it.
        syncAutoRetopoGhostState()
        inputModel.autoRetopoNotice = Self.notice(for: autoRetopoGhost)
        return true
    }

    /// A short, honest summary of a region proposal, or nil when there is
    /// nothing worth saying.
    static func notice(for ghost: SolverGhost?) -> String? {
        guard let ghost, !ghost.interfaceVertices.isEmpty else { return nil }
        var parts: [String] = []
        if !ghost.interfaceIrregular.isEmpty {
            parts.append("\(ghost.interfaceIrregular.count) irregular interface "
                + (ghost.interfaceIrregular.count == 1 ? "vertex" : "vertices"))
        }
        if ghost.residualTriangles > 0 {
            parts.append("\(ghost.residualTriangles) triangles at the seam")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// Runs the solve OFF the main actor. Data in, Data out — the engine meshes
    /// are created and destroyed inside this call, so nothing non-`Sendable`
    /// crosses the boundary.
    /// The ghost's payload plus the region report, which cannot ride the mesh
    /// across the boundary because the mesh itself is not `Sendable`.
    struct SolvedGhost: Sendable {
        var payload: Data
        var interfaceVertices: [UInt32] = []
        var interfaceIrregular: [UInt32] = []
        var residualTriangles: Int = 0
        var interiorIndexBudget: Int = 0
    }

    private nonisolated static func solveOffMain(
        targetData: Data, params: SolverParameters, constraints: WeaveConstraints,
        region: SolveRegion, solver: WeaveSolving
    ) async -> SolvedGhost? {
        await Task.detached(priority: .userInitiated) { () -> SolvedGhost? in
            let source: Mesh
            do { source = try Mesh(payloadData: targetData) } catch { return nil }
            let ghost: SolverGhost?
            do {
                ghost = try solver.solve(
                    source: source, region: region, constraints: constraints,
                    params: params, onProgress: nil, isCancelled: { false }
                )
            } catch { return nil }
            guard let ghost, let payload = try? ghost.mesh.payloadData() else { return nil }
            return SolvedGhost(
                payload: payload,
                interfaceVertices: ghost.interfaceVertices,
                interfaceIrregular: ghost.interfaceIrregular,
                residualTriangles: ghost.residualTriangles,
                interiorIndexBudget: ghost.interiorIndexBudget
            )
        }.value
    }

    /// Accepts the pending ghost as the EditMesh in ONE journal entry
    /// (create-or-replace, so a single undo restores the prior document
    /// exactly). No-op returning false when nothing is pending or the command
    /// cannot be built. Clears the pending ghost.
    ///
    /// **A REGION accept still replaces the whole EditMesh**, exactly as a
    /// whole-mesh accept does, so every face id changes and any face-keyed
    /// annotation (hidden faces, tagged edges) is invalidated. That is far more
    /// surprising for an edit the user perceives as touching sixteen faces than
    /// for one they know rebuilt the model. Making a region accept a local
    /// splice is a separate change; until then this is a known sharp edge and
    /// is deliberately not papered over here (task 13.2).
    @discardableResult
    func acceptAutoRetopo() -> Bool {
        guard let ghost = autoRetopoGhost, let bundle = bundleProvider?() else { return false }
        // A REGION patch merges into the cage the artist is building; a whole-mesh
        // solve replaces it, as before. Merging keeps one cage, which is what
        // filling a hole in one means (spec: "An accepted region patch merges into
        // the existing cage"). With no cage yet, the patch simply becomes it.
        let command: DocumentCommand?
        if autoRetopoGhostIsRegional, let merge = Self.mergeCommand(ghost.mesh, into: bundle) {
            command = merge
        } else {
            command = try? bundle.objectCommand(
                for: ghost.mesh, name: Self.acceptedEditMeshName(in: bundle),
                role: .editMesh, verb: "autoRetopo.accept"
            )
        }
        guard let command else { return false }
        autoRetopoGhost = nil
        weaveFillBasePayload = nil
        syncAutoRetopoGhostState()
        onCommit?(command)
        return true
    }

    /// Discards the pending ghost with NO journal entry, leaving the document
    /// byte-unchanged. Drawing over the ghost routes here.
    func discardAutoRetopo() {
        autoRetopoGhost = nil
        weaveFillBasePayload = nil
        syncAutoRetopoGhostState()
    }

    /// Reflects the pending ghost into the renderer (amber Weave proposal) and
    /// the input model (the accept/discard bar observes it). No-ops on the
    /// renderer headless (tests have no renderer); the state still updates.
    /// Internal (not private) so the Weave Fill session in
    /// `WeaveFillSession.swift` can publish through the same path — a fill
    /// proposal IS an Auto-Retopo proposal as far as presentation goes.
    func syncAutoRetopoGhostState() {
        inputModel.autoRetopoGhostPending = autoRetopoGhost != nil
        // The notice belongs to the pending ghost. Clearing it HERE rather than
        // at each call site means every teardown path — accept, discard,
        // replace, a failed solve — drops it together with the ghost, so a
        // stale warning cannot outlive the proposal it described.
        if autoRetopoGhost == nil { inputModel.autoRetopoNotice = nil }
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
    /// The name an accepted proposal should carry: the EXISTING EditMesh's, when
    /// there is one.
    ///
    /// `objectCommand` mints a fresh object and replaces the one holding that role, so
    /// passing a literal renamed the user's object — visible in the outliner, and
    /// plainly wrong for a Weave FILL, which extends the cage rather than replacing
    /// it. Caught by the fill UI test, whose row identifier is derived from the name.
    /// (The object's UUID still changes, and with it every face id; that is the
    /// separate sharp edge documented on `acceptAutoRetopo`.)
    /// Appends `patch` to the document's existing EditMesh as ONE journaled
    /// entry, or nil when there is no cage to merge into (the caller then falls
    /// back to creating one).
    ///
    /// The patch's border is NOT welded to the cage: coincident vertices stay
    /// separate until the artist merges them deliberately. A silent weld would
    /// move hand-placed vertices without being asked.
    static func mergeCommand(_ patch: Mesh, into bundle: DocumentBundle) -> DocumentCommand? {
        guard let object = bundle.manifest.objects.first(where: { $0.role == .editMesh }),
            let payload = bundle.payloads[object.payloadFile],
            let cage = try? bundle.mesh(for: object)
        else { return nil }
        let transaction = MeshEditTransaction(
            object: object, mesh: cage, currentPayload: payload
        )
        guard (try? cage.append(patch)) != nil else { return nil }
        return try? transaction.command(verb: "autoRetopo.acceptRegion")
    }

    static func acceptedEditMeshName(in bundle: DocumentBundle) -> String {
        bundle.manifest.objects.first { $0.role == .editMesh }?.name ?? "EditMesh"
    }

    func currentTargetMesh() -> Mesh? {
        guard let bundle = bundleProvider?() else { return nil }
        guard let target = bundle.manifest.objects.first(where: { $0.role == .target }) else {
            return nil
        }
        return try? bundle.mesh(for: target)
    }
}
