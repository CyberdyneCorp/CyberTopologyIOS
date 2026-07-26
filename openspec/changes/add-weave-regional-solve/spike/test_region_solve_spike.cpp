// SPIKE (openspec add-weave-regional-solve, task 0). Throwaway measurement, not
// a shipping test — it prints numbers rather than asserting the property under
// investigation.
//
// The question: with the region's complement frozen and the interface
// feature-tagged, does the existing pipeline (a) leave prescribed positions
// bitwise untouched, (b) leave frozen face rings identical, and (c) land every
// interface vertex at its prescribed valence?
//
// (c) is the falsifier. If it is routinely nonzero on the FLAT grid, the
// enforce-or-fail spine rejects ordinary selections and the narrower
// construct-correct design is the right answer instead.

#include <doctest.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <vector>

#include "cyber/core/isotropic.hpp"
#include "cyber/core/mesh.hpp"
#include "cyber/core/quadrangulate.hpp"
#include "cyber/core/reference_surface.hpp"
#include "cyber/core/region_solve.hpp"
#include "cyber/quadrangulate/field_quadrangulator.hpp"

using cyber::EdgeId;
using cyber::FaceId;
using cyber::Index;
using cyber::Mesh;
using cyber::Vec3;
using cyber::VertexId;
namespace remesh = cyber::remesh;

namespace {

constexpr std::size_t kN = 6;  // 6x6 quad grid

// Grid of N*N quads over [-1,1]^2, lifted by `height(u,v)`.
template <typename H>
Mesh makeGrid(std::size_t n, H height) {
    Mesh mesh;
    std::vector<std::vector<VertexId>> id(n + 1, std::vector<VertexId>(n + 1));
    for (std::size_t i = 0; i <= n; ++i) {
        for (std::size_t j = 0; j <= n; ++j) {
            const float u = 2.0f * static_cast<float>(i) / static_cast<float>(n) - 1.0f;
            const float v = 2.0f * static_cast<float>(j) / static_cast<float>(n) - 1.0f;
            id[i][j] = mesh.addVertex({u, v, height(u, v)});
        }
    }
    for (std::size_t i = 0; i < n; ++i) {
        for (std::size_t j = 0; j < n; ++j) {
            const VertexId ring[4] = {id[i][j], id[i + 1][j], id[i + 1][j + 1], id[i][j + 1]};
            mesh.addFace(ring);
        }
    }
    return mesh;
}

// Face id of grid cell (i,j) — addFace was called in row-major order.
FaceId cell(std::size_t n, std::size_t i, std::size_t j) {
    return FaceId{static_cast<Index>(i * n + j)};
}

bool bitwiseEqual(Vec3 a, Vec3 b) {
    auto same = [](float x, float y) {
        // Bit pattern, not an epsilon: the whole point is to distinguish
        // "never touched" from "moved and snapped back".
        return std::memcmp(&x, &y, sizeof(float)) == 0;
    };
    return same(a.x, b.x) && same(a.y, b.y) && same(a.z, b.z);
}

bool isHostBoundaryVertex(const Mesh& mesh, VertexId v) {
    for (const EdgeId e : mesh.vertexEdges(v)) {
        if (mesh.edgeFaces(e).size() == 1) {
            return true;
        }
    }
    return false;
}

struct SpikeResult {
    int pinnedMoved = 0;        // (a) — must be 0
    int frozenRingsChanged = 0; // (b) — must be 0
    int wrongValence = 0;       // (c) — THE FALSIFIER
    int interfaceVertices = 0;
    int interfaceEdgesLost = 0; // the SplitPass-guard witness
    int residualTriangles = 0;
    int ringMerges = 0;
    std::map<std::pair<int, int>, int> mismatch;  // (expected, actual) -> count
};

// --- minimal pairInterfaceRingFirst (design Stage 5 / task 6.3) -------------
// Merge each active-side interface triangle with its better non-interface
// neighbour BEFORE the global matching runs, so the ring closes into quads
// instead of being stranded by a greedy pass that has no interface awareness.

// Mesh exposes no faceEdges(); derive it from the ordered vertex ring.
std::vector<EdgeId> faceEdgesOf(const Mesh& mesh, FaceId f) {
    const std::vector<VertexId> ring = mesh.faceVertices(f);
    std::vector<EdgeId> edges;
    for (std::size_t i = 0; i < ring.size(); ++i) {
        const VertexId a = ring[i];
        const VertexId b = ring[(i + 1) % ring.size()];
        for (const EdgeId e : mesh.vertexEdges(a)) {
            const auto [x, y] = mesh.edgeVertices(e);
            if ((x.value == a.value && y.value == b.value) ||
                (x.value == b.value && y.value == a.value)) {
                edges.push_back(e);
                break;
            }
        }
    }
    return edges;
}

VertexId oppositeOf(const Mesh& mesh, FaceId f, VertexId a, VertexId b) {
    for (const VertexId v : mesh.faceVertices(f)) {
        if (v.value != a.value && v.value != b.value) {
            return v;
        }
    }
    return VertexId{};
}

// Squareness of the quad u,d,w,c in [0,1]; 1 = right angles everywhere.
float quadSquareness(const Mesh& mesh, VertexId u, VertexId d, VertexId w, VertexId c) {
    const VertexId ring[4] = {u, d, w, c};
    float score = 1.0f;
    for (int i = 0; i < 4; ++i) {
        const Vec3 p = mesh.position(ring[(i + 3) % 4]);
        const Vec3 q = mesh.position(ring[i]);
        const Vec3 r = mesh.position(ring[(i + 1) % 4]);
        const Vec3 e0 = p - q, e1 = r - q;
        const float l0 = length(e0), l1 = length(e1);
        if (l0 < 1e-12f || l1 < 1e-12f) {
            return 0.0f;
        }
        const float cosine = dot(e0, e1) / (l0 * l1);
        score *= (1.0f - std::fabs(cosine));
    }
    return score;
}

void mergePairSpike(Mesh& mesh, EdgeId e, FaceId f0, FaceId f1) {
    const auto [a, b] = mesh.edgeVertices(e);
    VertexId u = a, w = b;
    const std::vector<VertexId> ring = mesh.faceVertices(f0);
    for (std::size_t i = 0; i < ring.size(); ++i) {
        if (ring[i].value == b.value && ring[(i + 1) % ring.size()].value == a.value) {
            u = b;
            w = a;
            break;
        }
    }
    const VertexId c = oppositeOf(mesh, f0, a, b);
    const VertexId d = oppositeOf(mesh, f1, a, b);
    mesh.removeFace(f0);
    mesh.removeFace(f1);
    const VertexId quad[4] = {u, d, w, c};
    mesh.addFace(quad);
}

std::size_t pairInterfaceRingFirst(Mesh& mesh, const remesh::RegionSolve& region) {
    // Interface edges, and the active triangle on each one's active side.
    std::vector<char> isInterfaceEdge(mesh.edgeCapacity(), 0);
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {
        const EdgeId e{i};
        if (!mesh.isAlive(e)) {
            continue;
        }
        const auto faces = mesh.edgeFaces(e);
        if (faces.size() != 2) {
            continue;
        }
        const int activeCount = (region.frozen(faces[0]) ? 0 : 1) + (region.frozen(faces[1]) ? 0 : 1);
        if (activeCount == 1) {
            isInterfaceEdge[i] = 1;
        }
    }
    std::size_t merged = 0;
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {  // ascending EdgeId = deterministic
        if (isInterfaceEdge[i] == 0) {
            continue;
        }
        const EdgeId e{i};
        if (!mesh.isAlive(e)) {
            continue;
        }
        FaceId host{};
        bool haveHost = false;
        for (const FaceId f : mesh.edgeFaces(e)) {
            if (!region.frozen(f) && mesh.isAlive(f) && mesh.faceSize(f) == 3) {
                host = f;
                haveHost = true;
            }
        }
        if (!haveHost) {
            continue;  // already paired, or the active side is not a triangle
        }
        // Best non-interface, non-feature partner.
        float bestScore = -1.0f;
        EdgeId bestEdge{};
        FaceId bestPartner{};
        for (const EdgeId cand : faceEdgesOf(mesh, host)) {
            if (cand.value == e.value || isInterfaceEdge[cand.value] != 0 ||
                mesh.isFeatureEdge(cand)) {
                continue;
            }
            const auto candFaces = mesh.edgeFaces(cand);
            if (candFaces.size() != 2) {
                continue;
            }
            const FaceId other = candFaces[0].value == host.value ? candFaces[1] : candFaces[0];
            if (region.frozen(other) || !mesh.isAlive(other) || mesh.faceSize(other) != 3) {
                continue;
            }
            const auto [ca, cb] = mesh.edgeVertices(cand);
            const VertexId c = oppositeOf(mesh, host, ca, cb);
            const VertexId d = oppositeOf(mesh, other, ca, cb);
            const float score = quadSquareness(mesh, ca, d, cb, c);
            if (score > bestScore) {
                bestScore = score;
                bestEdge = cand;
                bestPartner = other;
            }
        }
        if (bestScore >= 0.0f) {
            mergePairSpike(mesh, bestEdge, host, bestPartner);
            ++merged;
        }
    }
    return merged;
}

SpikeResult runSpike(const char* label, Mesh mesh, const std::vector<FaceId>& regionFaces,
                     float densityFactor, bool enableSplitGuard, bool ringFirst = false) {
    SpikeResult out;

    // Prescribed edge spacing, measured before anything mutates.
    double sumLen = 0.0;
    int nLen = 0;
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {
        const EdgeId e{i};
        if (!mesh.isAlive(e)) {
            continue;
        }
        const auto [a, b] = mesh.edgeVertices(e);
        sumLen += static_cast<double>(length(mesh.position(a) - mesh.position(b)));
        ++nLen;
    }
    const float meanEdge = static_cast<float>(sumLen / static_cast<double>(nLen));

    remesh::RegionSolve region = remesh::buildRegionSolve(mesh, regionFaces, 30.0f);

    // Snapshot the prescription.
    std::map<Index, Vec3> prescribed;
    std::map<Index, std::vector<Index>> frozenRings;
    std::map<Index, int> qOut, targetTotal;
    std::vector<std::pair<Index, Index>> interfaceEdges;
    for (Index i = 0; i < mesh.vertexCapacity(); ++i) {
        const VertexId v{i};
        if (!mesh.isAlive(v) || !region.pinned(v)) {
            continue;
        }
        prescribed[i] = mesh.position(v);
        int frozenIncident = 0, activeIncident = 0;
        for (const FaceId f : mesh.vertexFaces(v)) {
            if (region.frozen(f)) {
                ++frozenIncident;
            } else {
                ++activeIncident;
            }
        }
        if (activeIncident > 0) {  // an INTERFACE vertex, not a deep-frozen one
            qOut[i] = frozenIncident;
            targetTotal[i] = isHostBoundaryVertex(mesh, v) ? 2 : 4;
            ++out.interfaceVertices;
        }
    }
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (!mesh.isAlive(f) || !region.frozen(f)) {
            continue;
        }
        std::vector<Index> ring;
        for (const VertexId v : mesh.faceVertices(f)) {
            ring.push_back(v.value);
        }
        frozenRings[i] = ring;
    }
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {
        const EdgeId e{i};
        if (!mesh.isAlive(e)) {
            continue;
        }
        // The REAL interface predicate (task 2.1's isRegionBoundaryEdge):
        // exactly one incident face in the region. "Both endpoints pinned" is
        // wrong — it also catches triangulation diagonals interior to a corner
        // region quad, which the quadrangulator is entitled to merge away.
        const auto faces = mesh.edgeFaces(e);
        int activeIncident = 0;
        for (const FaceId f : faces) {
            if (!region.frozen(f)) {
                ++activeIncident;
            }
        }
        if (activeIncident == 1 && faces.size() == 2) {
            const auto [a, b] = mesh.edgeVertices(e);
            interfaceEdges.push_back({std::min(a.value, b.value), std::max(a.value, b.value)});
        }
    }

    // Solve: isotropic + field-aligned quadrangulation, with islands / merge /
    // fillHoles / pureQuads bypassed by construction (we never enter pipeline.cpp).
    const float target = meanEdge / densityFactor;
    const remesh::ReferenceSurface reference(mesh, 0.0f);
    remesh::IsotropicOptions iso;
    iso.targetEdgeLength = target;
    iso.iterations = 3;
    iso.region = enableSplitGuard ? &region : nullptr;
    const remesh::IsotropicStatus status = remesh::isotropicRemesh(mesh, reference, iso);
    REQUIRE(status == remesh::IsotropicStatus::Success);

    std::size_t ringMerges = 0;
    if (ringFirst) {
        ringMerges = pairInterfaceRingFirst(mesh, region);
    }

    auto quad = remesh::makeFieldAlignedQuadrangulator();
    const auto outcome = quad->quadrangulate(mesh, target, nullptr, nullptr);
    REQUIRE(outcome.success);
    out.ringMerges = static_cast<int>(ringMerges);

    // (a) prescribed positions.
    for (const auto& [idx, pos] : prescribed) {
        const VertexId v{idx};
        if (!mesh.isAlive(v) || !bitwiseEqual(mesh.position(v), pos)) {
            ++out.pinnedMoved;
        }
    }
    // (b) frozen face rings.
    for (const auto& [idx, ring] : frozenRings) {
        const FaceId f{idx};
        if (!mesh.isAlive(f)) {
            ++out.frozenRingsChanged;
            continue;
        }
        std::vector<Index> now;
        for (const VertexId v : mesh.faceVertices(f)) {
            now.push_back(v.value);
        }
        if (now != ring) {
            ++out.frozenRingsChanged;
        }
    }
    // (c) interface valence — the falsifier.
    for (const auto& [idx, out_] : qOut) {
        const VertexId v{idx};
        if (!mesh.isAlive(v)) {
            ++out.wrongValence;
            continue;
        }
        int solved = 0;
        for (const FaceId f : mesh.vertexFaces(v)) {
            if (!region.frozen(f)) {
                ++solved;
            }
        }
        const int expected = targetTotal[idx] - out_;
        if (solved != expected) {
            ++out.wrongValence;
            ++out.mismatch[{expected, solved}];
        }
    }
    // interface edge survival (the SplitPass-guard witness).
    for (const auto& [a, b] : interfaceEdges) {
        bool found = false;
        for (const EdgeId e : mesh.vertexEdges(VertexId{a})) {
            const auto [x, y] = mesh.edgeVertices(e);
            if ((x.value == a && y.value == b) || (x.value == b && y.value == a)) {
                found = true;
                break;
            }
        }
        if (!found) {
            ++out.interfaceEdgesLost;
        }
    }
    // residual triangles touching the interface.
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (!mesh.isAlive(f) || region.frozen(f) || mesh.faceSize(f) == 4) {
            continue;
        }
        for (const VertexId v : mesh.faceVertices(f)) {
            if (region.pinned(v)) {
                ++out.residualTriangles;
                break;
            }
        }
    }

    std::printf(
        "[spike] %-16s density=%.1fx guard=%s ring1st=%s | (a) moved=%d (b) rings=%d "
        "(c) WRONG VALENCE=%d/%d | iface edges lost=%d residual tris=%d merges=%d\n",
        label, static_cast<double>(densityFactor), enableSplitGuard ? "on " : "off",
        ringFirst ? "on " : "off",
        out.pinnedMoved, out.frozenRingsChanged, out.wrongValence, out.interfaceVertices,
        out.interfaceEdgesLost, out.residualTriangles, out.ringMerges);
    if (!out.mismatch.empty()) {
        std::printf("[spike]     mismatch (expected->actual):");
        for (const auto& [key, count] : out.mismatch) {
            std::printf("  %d->%d x%d", key.first, key.second, count);
        }
        std::printf("\n");
    }
    return out;
}

std::vector<FaceId> centreBlock(std::size_t n, std::size_t lo, std::size_t hi) {
    std::vector<FaceId> faces;
    for (std::size_t i = lo; i <= hi; ++i) {
        for (std::size_t j = lo; j <= hi; ++j) {
            faces.push_back(cell(n, i, j));
        }
    }
    return faces;
}

// L-shaped region: the centre block minus its top-right quadrant, so the
// interface ring contains a reflex vertex.
std::vector<FaceId> lShape(std::size_t n) {
    std::vector<FaceId> faces;
    for (std::size_t i = 1; i <= 4; ++i) {
        for (std::size_t j = 1; j <= 4; ++j) {
            if (i >= 3 && j >= 3) {
                continue;
            }
            faces.push_back(cell(n, i, j));
        }
    }
    return faces;
}

}  // namespace

TEST_CASE("region-solve spike: flat grid, centre 4x4") {
    const auto flat = [](float, float) { return 0.0f; };
    const auto r1 = runSpike("grid66_center", makeGrid(kN, flat), centreBlock(kN, 1, 4), 1.0f, true);
    CHECK(r1.pinnedMoved == 0);
    CHECK(r1.frozenRingsChanged == 0);

    // 4x density is what actually exercises SplitPass.
    const auto r4 = runSpike("grid66_center", makeGrid(kN, flat), centreBlock(kN, 1, 4), 4.0f, true);
    CHECK(r4.pinnedMoved == 0);
    CHECK(r4.frozenRingsChanged == 0);
    CHECK(r4.interfaceEdgesLost == 0);  // guard witness: passes

    // Control: without the guard the interface edge set must degrade, or the
    // guard is not doing anything and the 4-line patch is unjustified.
    const auto rNoGuard =
        runSpike("grid66_center", makeGrid(kN, flat), centreBlock(kN, 1, 4), 4.0f, false);
    std::printf("[spike] guard witness: edges lost with guard=%d, without=%d\n",
                r4.interfaceEdgesLost, rNoGuard.interfaceEdgesLost);

    // Does the design's ring-first pairing actually close the ring?
    runSpike("grid66_center", makeGrid(kN, flat), centreBlock(kN, 1, 4), 1.0f, true, true);
    runSpike("grid66_center", makeGrid(kN, flat), centreBlock(kN, 1, 4), 4.0f, true, true);
}

TEST_CASE("region-solve spike: L-shaped region") {
    const auto flat = [](float, float) { return 0.0f; };
    const auto r = runSpike("lshape", makeGrid(kN, flat), lShape(kN), 1.0f, true);
    CHECK(r.pinnedMoved == 0);
    CHECK(r.frozenRingsChanged == 0);
    runSpike("lshape", makeGrid(kN, flat), lShape(kN), 4.0f, true);
    runSpike("lshape", makeGrid(kN, flat), lShape(kN), 1.0f, true, true);
    runSpike("lshape", makeGrid(kN, flat), lShape(kN), 4.0f, true, true);
}

TEST_CASE("region-solve spike: sphere cap (domed grid)") {
    const auto dome = [](float u, float v) {
        const float r2 = u * u + v * v;
        return 0.6f * std::sqrt(std::fmax(0.0f, 1.2f - r2));
    };
    const auto r = runSpike("sphere_cap", makeGrid(kN, dome), centreBlock(kN, 1, 4), 1.0f, true);
    CHECK(r.pinnedMoved == 0);
    CHECK(r.frozenRingsChanged == 0);
    runSpike("sphere_cap", makeGrid(kN, dome), centreBlock(kN, 1, 4), 4.0f, true);
    runSpike("sphere_cap", makeGrid(kN, dome), centreBlock(kN, 1, 4), 1.0f, true, true);
    runSpike("sphere_cap", makeGrid(kN, dome), centreBlock(kN, 1, 4), 4.0f, true, true);
}
