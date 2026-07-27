// SPIKE for task 5.3a, task 0. Standalone: links the built engine libs so the
// submodule's patch stack is untouched until the approach is proven.
#include <cmath>
#include <cstdio>
#include <vector>

#include "cyber/core/interface_conformance.hpp"
#include "cyber/core/isotropic.hpp"
#include "cyber/core/mesh.hpp"
#include "cyber/core/reference_surface.hpp"
#include "cyber/core/region_solve.hpp"
#include "cyber/quadrangulate/field_quadrangulator.hpp"

using cyber::EdgeId; using cyber::FaceId; using cyber::Index;
using cyber::Mesh; using cyber::VertexId;
namespace remesh = cyber::remesh;

static constexpr std::size_t kN = 6;

template <typename H> static Mesh makeGrid(H height) {
    Mesh mesh;
    std::vector<std::vector<VertexId>> id(kN + 1, std::vector<VertexId>(kN + 1));
    for (std::size_t i = 0; i <= kN; ++i)
        for (std::size_t j = 0; j <= kN; ++j) {
            const float u = 2.0f * (float)i / (float)kN - 1.0f;
            const float v = 2.0f * (float)j / (float)kN - 1.0f;
            id[i][j] = mesh.addVertex({u, v, height(u, v)});
        }
    for (std::size_t i = 0; i < kN; ++i)
        for (std::size_t j = 0; j < kN; ++j) {
            const VertexId ring[4] = {id[i][j], id[i+1][j], id[i+1][j+1], id[i][j+1]};
            mesh.addFace(ring);
        }
    return mesh;
}
static Mesh flatGrid() { return makeGrid([](float, float) { return 0.0f; }); }
static Mesh domedGrid() {
    return makeGrid([](float u, float v) {
        return 0.6f * std::sqrt(std::fmax(0.0f, 1.2f - (u * u + v * v)));
    });
}
static FaceId cell(std::size_t i, std::size_t j) { return FaceId{(Index)(i * kN + j)}; }
static std::vector<FaceId> centreBlock() {
    std::vector<FaceId> f;
    for (std::size_t i = 1; i <= 4; ++i) for (std::size_t j = 1; j <= 4; ++j) f.push_back(cell(i,j));
    return f;
}
static std::vector<FaceId> lShape() {
    return {cell(1,1), cell(2,1), cell(3,1), cell(4,1), cell(1,2), cell(1,3)};
}
static std::vector<FaceId> crossShape() {
    return {cell(2,1), cell(2,2), cell(2,3), cell(1,2), cell(3,2)};
}
static float meanEdgeLength(const Mesh& mesh) {
    double sum = 0.0; int n = 0;
    for (Index i = 0; i < mesh.edgeCapacity(); ++i) {
        const EdgeId e{i};
        if (!mesh.isAlive(e)) continue;
        const auto [a, b] = mesh.edgeVertices(e);
        sum += (double)length(mesh.position(a) - mesh.position(b)); ++n;
    }
    return (float)(sum / (double)n);
}

struct M {
    std::size_t iface=0, irr=0, triAtIface=0, locked=0, quads=0, tris=0;
    bool exact=false, ok=true;
};

static M run(Mesh mesh, const std::vector<FaceId>& faces, float density, bool lock) {
    M m;
    const float baseEdge = meanEdgeLength(mesh);
    auto built = remesh::buildRegionSolve(mesh, faces, 0.0f, {});
    if (built.status != remesh::RegionSolveStatus::Ok) { m.ok = false; return m; }
    const remesh::RegionSolve& region = built.region;
    m.iface = region.requiredInRegion.size();
    const auto snapshot = remesh::captureInterface(mesh, region);
    const float target = baseEdge / density;
    const remesh::ReferenceSurface reference(mesh, 0.0f);
    remesh::IsotropicOptions iso;
    iso.targetEdgeLength = target; iso.iterations = 3; iso.region = &region;
    if (remesh::isotropicRemesh(mesh, reference, iso) != remesh::IsotropicStatus::Success) {
        m.ok = false; return m;
    }
    if (lock) {
        for (const auto& entry : region.requiredInRegion) {
            const VertexId v{entry.first};
            if (!mesh.isAlive(v)) continue;
            for (const EdgeId e : mesh.vertexEdges(v))
                if (mesh.isAlive(e) && !mesh.isFeatureEdge(e)) { mesh.setFeatureEdge(e, true); ++m.locked; }
        }
    }
    auto quad = remesh::makeFieldAlignedQuadrangulator();
    if (!quad->quadrangulate(mesh, target, nullptr, nullptr).success) { m.ok = false; return m; }
    const auto conf = remesh::verifyInterfaceConformance(mesh, region, snapshot);
    m.exact = conf.exact();
    m.irr = conf.irregularInterface.size();
    m.triAtIface = conf.interfaceTriangles;
    for (Index i = 0; i < mesh.faceCapacity(); ++i) {
        const FaceId f{i};
        if (!mesh.isAlive(f) || region.frozen(f)) continue;
        if (mesh.faceSize(f) == 4) ++m.quads; else if (mesh.faceSize(f) == 3) ++m.tris;
    }
    return m;
}

int main() {
    struct C { const char* name; Mesh (*mk)(); std::vector<FaceId> faces; };
    const std::vector<C> cases = {
        {"grid66_center", flatGrid, centreBlock()},
        {"lshape",        flatGrid, lShape()},
        {"cross",         flatGrid, crossShape()},
        {"sphere_cap",    domedGrid, centreBlock()},
    };
    for (const float d : {1.0f, 4.0f}) {
        std::printf("---- density %.0fx ----\n", (double)d);
        for (const C& c : cases) {
            const M b = run(c.mk(), c.faces, d, false);
            const M l = run(c.mk(), c.faces, d, true);
            if (!b.ok || !l.ok) { std::printf("%-14s SOLVE FAILED\n", c.name); continue; }
            std::printf("%-14s iface=%2zu | BASE irr=%2zu triIface=%2zu q=%3zu t=%3zu"
                        " | LOCKED irr=%2zu triIface=%2zu q=%3zu t=%3zu locked=%zu%s\n",
                        c.name, b.iface, b.irr, b.triAtIface, b.quads, b.tris,
                        l.irr, l.triAtIface, l.quads, l.tris, l.locked,
                        l.exact ? "" : "  [EXACT LANDING BROKEN]");
        }
    }
    return 0;
}
