#pragma once
#include <vector>

#include "cyber/core/mesh.hpp"

namespace cyber::remesh {

// SPIKE SCAFFOLD (openspec add-weave-regional-solve, task 0).
//
// The minimum needed to answer the falsification question: when the region's
// complement is frozen and the interface is feature-tagged, does the existing
// pipeline leave the prescribed boundary alone, and do interface vertices land
// at their prescribed valence?
//
// Deliberately NOT the shipping shape. Task 1 adds interfaceLoops,
// targetValence, indexBudget, the up-front hostile-input refusals, and moves
// the builder into region_solve.cpp.
//
// Two invariants make the masks safe to hold across a whole solve:
//
//   Invariant F — a frozen face is never removed by any pass, so its id never
//   enters m_freeFaces (mesh.cpp:86-90) and can never be recycled
//   (mesh.cpp:44-46). `active(f)` therefore stays correct for the entire run
//   even while region face ids churn freely.
//
//   Invariant P — a pinned vertex has at least one incident feature edge,
//   hence isFeatureVertex is true for it (isotropic.cpp:31-38), hence it is
//   never collapsed, dissolved, rotation-eligible or smoothed. It is never
//   freed, so its id is never recycled and the mask stays valid.
struct RegionSolve {
    std::vector<char> frozenFace;    // indexed by FaceId::value
    std::vector<char> vertexPinned;  // indexed by VertexId::value

    [[nodiscard]] bool empty() const { return frozenFace.empty(); }

    // Faces created DURING the solve are past the mask's end and are region
    // faces by construction, so an out-of-range id is active, not frozen.
    [[nodiscard]] bool frozen(FaceId f) const {
        return f.value < frozenFace.size() && frozenFace[f.value] != 0;
    }
    [[nodiscard]] bool active(FaceId f) const { return !frozen(f); }

    // Vertices created during the solve are likewise past the end and unpinned.
    [[nodiscard]] bool pinned(VertexId v) const {
        return v.value < vertexPinned.size() && vertexPinned[v.value] != 0;
    }
};

// Builds the mask pair for `regionFaces` and prepares `mesh` for a region
// solve. Mutates `mesh`: triangulates the ACTIVE faces only (the frozen
// complement keeps its quads and n-gons) and rewrites feature flags.
//
// Step order is load-bearing: tagFeatureEdges rewrites `feature` on EVERY
// alive edge (mesh_diagnostics.cpp:182-203), so the interface tagging must
// follow it, not precede it.
inline RegionSolve buildRegionSolve(Mesh& mesh, const std::vector<FaceId>& regionFaces,
                                    float sharpEdgeDegrees) {
    RegionSolve region;
    if (regionFaces.empty()) {
        return region;  // empty() short-circuits every caller; whole-mesh path
    }

    // (c) frozen mask: every alive face NOT named by the caller.
    std::vector<char> inRegion(mesh.faceCapacity(), 0);
    for (const FaceId f : regionFaces) {
        if (f.value < inRegion.size()) {
            inRegion[f.value] = 1;
        }
    }
    region.frozenFace.assign(mesh.faceCapacity(), 0);
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (mesh.isAlive(f) && inRegion[i] == 0) {
            region.frozenFace[i] = 1;
        }
    }

    // (d) region-scoped triangulation. triangulateFace only calls splitFace
    // (mesh_ops.cpp:353-364) — it never touches m_vertices, so no prescribed
    // position can move here. The whole-mesh work.triangulate() is skipped.
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (mesh.isAlive(f) && region.active(f) && mesh.faceSize(f) > 3) {
            mesh.triangulateFace(f);
        }
    }

    // (e) feature tagging, in this order.
    mesh.tagFeatureEdges(sharpEdgeDegrees);
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {
        const EdgeId e{i};
        if (!mesh.isAlive(e)) {
            continue;
        }
        for (const FaceId f : mesh.edgeFaces(e)) {
            if (region.frozen(f)) {
                // Covers both the interface (one active + one frozen face, so
                // edgeFaceCount == 2 and isBoundaryEdge is FALSE — which is
                // exactly why boundaryChain cannot see it) and every interior
                // edge of the complement.
                mesh.setFeatureEdge(e, true);
                break;
            }
        }
    }

    // (f) pinned mask: every vertex incident to at least one frozen face.
    region.vertexPinned.assign(mesh.vertexCapacity(), 0);
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (!mesh.isAlive(f) || !region.frozen(f)) {
            continue;
        }
        for (const VertexId v : mesh.faceVertices(f)) {
            if (v.value < region.vertexPinned.size()) {
                region.vertexPinned[v.value] = 1;
            }
        }
    }
    return region;
}

}  // namespace cyber::remesh
