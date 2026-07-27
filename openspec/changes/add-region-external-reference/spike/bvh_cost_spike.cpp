#include <chrono>
#include <cmath>
#include <cstdio>
#include <vector>
#include "cyber/core/mesh.hpp"
#include "cyber/core/reference_surface.hpp"
using cyber::Mesh; using cyber::VertexId;
namespace remesh = cyber::remesh;
int main() {
    for (std::size_t n : {96, 256, 512, 800, 1100}) {
        Mesh mesh;
        std::vector<std::vector<VertexId>> id(n + 1, std::vector<VertexId>(n + 1));
        for (std::size_t i = 0; i <= n; ++i)
            for (std::size_t j = 0; j <= n; ++j) {
                const float u = 2.0f * (float)i / (float)n - 1.0f;
                const float v = 2.0f * (float)j / (float)n - 1.0f;
                id[i][j] = mesh.addVertex({u, v, 0.12f * std::sin(9*u) * std::cos(9*v)});
            }
        for (std::size_t i = 0; i < n; ++i)
            for (std::size_t j = 0; j < n; ++j) {
                const VertexId r[4] = {id[i][j], id[i+1][j], id[i+1][j+1], id[i][j+1]};
                mesh.addFace(r);
            }
        auto t0 = std::chrono::steady_clock::now();
        const remesh::ReferenceSurface ref(mesh, 0.0f);
        double ms = std::chrono::duration<double, std::milli>(
            std::chrono::steady_clock::now() - t0).count();
        std::printf("%8zu faces  BVH build %8.1f ms  (%.2f us/1k faces)\n",
                    (std::size_t)mesh.faceCount(), ms, ms * 1000.0 / (mesh.faceCount() / 1000.0));
        std::fflush(stdout);
    }
    return 0;
}
