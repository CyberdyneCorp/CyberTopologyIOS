// SPIKE for task 5.4b task 0. Standalone against the built host libs so the engine's
// patch stack stays untouched until the approach is justified.
//
// Question: a region solve builds its ReferenceSurface from the mesh it rewrites. For a
// fill that is cage + seed, so Target detail FINER than the seed band cannot be seen.
// The deviation was measured at 0.031 quads on a SMOOTH fixture -- which by construction
// cannot exhibit the failure mode. Does it generalise, or was it an artifact?
#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>

#include "cyber/core/isotropic.hpp"
#include "cyber/core/mesh.hpp"
#include "cyber/core/reference_surface.hpp"
#include "cyber/core/region_solve.hpp"
#include "cyber/quadrangulate/field_quadrangulator.hpp"

using cyber::EdgeId; using cyber::FaceId; using cyber::Index;
using cyber::Mesh; using cyber::VertexId; using cyber::Vec3;
namespace remesh = cyber::remesh;

// A grid whose height has HIGH-FREQUENCY detail: ripples far finer than a coarse
// seed band. This is the geometry the smooth fixture could not represent.
template <typename H> static Mesh makeGrid(std::size_t n, H height) {
    Mesh mesh;
    std::vector<std::vector<VertexId>> id(n + 1, std::vector<VertexId>(n + 1));
    for (std::size_t i = 0; i <= n; ++i)
        for (std::size_t j = 0; j <= n; ++j) {
            const float u = 2.0f * (float)i / (float)n - 1.0f;
            const float v = 2.0f * (float)j / (float)n - 1.0f;
            id[i][j] = mesh.addVertex({u, v, height(u, v)});
        }
    for (std::size_t i = 0; i < n; ++i)
        for (std::size_t j = 0; j < n; ++j) {
            const VertexId ring[4] = {id[i][j], id[i+1][j], id[i+1][j+1], id[i][j+1]};
            mesh.addFace(ring);
        }
    return mesh;
}
static float smoothH(float u, float v) {
    return 0.6f * std::sqrt(std::fmax(0.0f, 1.2f - (u * u + v * v)));
}
static float rippleH(float u, float v) {
    // ~6 periods across the patch: detail well below a coarse seed band's spacing.
    return 0.12f * std::sin(9.0f * u) * std::cos(9.0f * v);
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

struct Dev { double mean = 0.0, max = 0.0; std::size_t n = 0; };

// Deviation of the solved INTERIOR vertices from the true Target surface.
static Dev deviation(const Mesh& solved, const remesh::RegionSolve& region,
                     const remesh::ReferenceSurface& truth) {
    Dev d;
    for (Index i = 0; i < solved.vertexCapacity(); ++i) {
        const VertexId v{i};
        if (!solved.isAlive(v) || region.pinned(v)) continue;  // interior only
        const Vec3 p = solved.position(v);
        const double e = (double)length(p - truth.project(p));
        d.mean += e; d.max = std::fmax(d.max, e); ++d.n;
    }
    if (d.n) d.mean /= (double)d.n;
    return d;
}

int main() {
    constexpr std::size_t kN = 6;
    // The dense Target the fill should follow.
    for (const char* which : {"smooth", "ripple"}) {
        const bool ripple = which[0] == 'r';
        // A DENSE target: this is the real scan the cage approximates.
        Mesh target = ripple ? makeGrid(96, rippleH) : makeGrid(96, smoothH);
        const auto t0 = std::chrono::steady_clock::now();
        const remesh::ReferenceSurface targetRef(target, 0.0f);
        const double buildMs =
            std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();

        // A COARSE cage over the same shape, with a centre block as the solved region.
        Mesh cage = ripple ? makeGrid(kN, rippleH) : makeGrid(kN, smoothH);
        std::vector<FaceId> faces;
        for (std::size_t i = 1; i <= 4; ++i)
            for (std::size_t j = 1; j <= 4; ++j) faces.push_back(FaceId{(Index)(i * kN + j)});

        const float baseEdge = meanEdgeLength(cage);
        auto built = remesh::buildRegionSolve(cage, faces, 0.0f, {});
        if (built.status != remesh::RegionSolveStatus::Ok) { std::printf("%s: region refused\n", which); continue; }
        const remesh::RegionSolve& region = built.region;
        const float targetEdge = baseEdge / 4.0f;  // 4x: the interior gets real freedom

        // (a) TODAY: reference built from the working mesh (cage) itself.
        Mesh a = cage;
        {
            const remesh::ReferenceSurface selfRef(a, 0.0f);
            remesh::IsotropicOptions iso;
            iso.targetEdgeLength = targetEdge; iso.iterations = 3; iso.region = &region;
            remesh::isotropicRemesh(a, selfRef, iso);
            auto q = remesh::makeFieldAlignedQuadrangulator();
            q->quadrangulate(a, targetEdge, nullptr, nullptr);
        }
        // (b) PROPOSED: reference is the dense Target.
        Mesh b = cage;
        {
            remesh::IsotropicOptions iso;
            iso.targetEdgeLength = targetEdge; iso.iterations = 3; iso.region = &region;
            remesh::isotropicRemesh(b, targetRef, iso);
            auto q = remesh::makeFieldAlignedQuadrangulator();
            q->quadrangulate(b, targetEdge, nullptr, nullptr);
        }

        const Dev da = deviation(a, region, targetRef);
        const Dev db = deviation(b, region, targetRef);
        // Express in QUADS, the unit 5.4b's 0.031 figure used.
        std::printf("%-7s | target BVH build %6.1f ms (%zu faces) | quad=%.4f\n",
                    which, buildMs, (std::size_t)target.faceCount(), (double)targetEdge);
        std::printf("        | SELF-ref  mean %.4f q  max %.4f q  (n=%zu)\n",
                    da.mean / targetEdge, da.max / targetEdge, da.n);
        std::printf("        | TARGET-ref mean %.4f q  max %.4f q  (n=%zu)\n",
                    db.mean / targetEdge, db.max / targetEdge, db.n);
    }
    return 0;
}
