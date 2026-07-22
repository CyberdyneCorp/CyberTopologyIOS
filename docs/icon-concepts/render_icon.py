"""CyberTopology app icon v4 — final.

Two-mesh story: a smooth sculpt (Target) with a quad cage (EditMesh) drawn
over part of it. The cage's true topological boundary — edges belonging to
exactly one cage quad — glows gold as "the loop you just drew".
"""
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

SS, SIZE = 4, 1024
R = SIZE * SS

SURF_LIT = np.array([86, 112, 156], float)
SURF_DARK = np.array([26, 38, 66], float)
CAGE_LIT = np.array([122, 208, 255], float)
CAGE_DARK = np.array([24, 72, 146], float)
WIRE = (244, 252, 255)
GOLD = (255, 192, 84)
BG_IN = np.array([22, 34, 62], np.float32)
BG_OUT = np.array([6, 9, 18], np.float32)

LIGHT = np.array([-0.40, 0.68, 0.62])
LIGHT /= np.linalg.norm(LIGHT)
SHAPE = np.array([0.95, 1.05, 0.95])


def cube_sphere(n):
    quads, axes = [], [(0, 1, 2), (1, 2, 0), (2, 0, 1)]
    for ax in axes:
        for sign in (1, -1):
            for i in range(n):
                for j in range(n):
                    c = []
                    for du, dv in ((0, 0), (1, 0), (1, 1), (0, 1)):
                        u = -1 + 2 * (i + du) / n
                        v = -1 + 2 * (j + dv) / n
                        p = np.zeros(3)
                        p[ax[0]], p[ax[1]], p[ax[2]] = u, v, sign
                        c.append(p / np.linalg.norm(p))
                    q = np.array(c)
                    quads.append(q[::-1] if sign < 0 else q)
    return quads


def rot(yaw, pitch):
    cy, sy, cp, sp = np.cos(yaw), np.sin(yaw), np.cos(pitch), np.sin(pitch)
    return (np.array([[cy, 0, -sy], [0, 1, 0], [sy, 0, cy]])
            @ np.array([[1, 0, 0], [0, cp, sp], [0, -sp, cp]]))


def background():
    y, x = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    d = np.clip(np.sqrt((x - SIZE / 2) ** 2 + (y - SIZE / 2) ** 2) / (SIZE * 0.72), 0, 1) ** 1.25
    g = BG_IN[None, None, :] * (1 - d)[..., None] + BG_OUT[None, None, :] * d[..., None]
    return Image.fromarray(g.astype(np.uint8), "RGB").resize((R, R), Image.BILINEAR)


def shade(nrm, lit, dark, spec_k=0.38, spec_p=26):
    lam = max(0.0, float(np.dot(nrm, LIGHT)))
    col = dark + (lit - dark) * (lam ** 0.70)
    half = LIGHT + np.array([0, 0, 1.0])
    half /= np.linalg.norm(half)
    col = col + 255 * (max(0.0, float(np.dot(nrm, half))) ** spec_p) * spec_k
    rim = (1.0 - max(0.0, nrm[2])) ** 3.0
    col = col + np.array([80, 160, 250]) * rim * 0.40
    return tuple(int(np.clip(c, 0, 255)) for c in col)


def key(p):
    return tuple(np.round(p, 4))


def render(n=4, yaw=0.60, pitch=-0.34, cap_axis=(-0.30, 0.42, 0.86),
           cap_cos=0.12, out="icon.png", wire_scale=1.0, gold=True):
    img = background()
    M = rot(yaw, pitch)
    scale, cx, cy = R * 0.352, R / 2, R / 2
    cap = np.array(cap_axis, float)
    cap /= np.linalg.norm(cap)

    def project(p):
        v = M @ (p * SHAPE)
        f = 1.0 / (1.0 - 0.15 * v[2])
        return (cx + v[0] * scale * f, cy - v[1] * scale * f, float(v[2]))

    def normal_of(u):
        nr = M @ (u / SHAPE)
        return nr / np.linalg.norm(nr)

    halo = Image.new("L", (R, R), 0)
    ImageDraw.Draw(halo).ellipse([cx - scale * 1.10, cy - scale * 1.16,
                                  cx + scale * 1.10, cy + scale * 1.16], fill=255)
    halo = halo.filter(ImageFilter.GaussianBlur(R * 0.05))
    glow = Image.new("RGB", (R, R), (26, 96, 190))
    img = Image.composite(Image.blend(img, glow, 0.5), img, halo.point(lambda v: int(v * 0.7)))
    draw = ImageDraw.Draw(img, "RGBA")

    # 1) smooth sculpt
    fine = []
    for q in cube_sphere(24):
        c = q.sum(axis=0) / 4
        c /= np.linalg.norm(c)
        nrm = normal_of(c)
        if nrm[2] <= 0.0:
            continue
        pts = [project(p) for p in q]
        fine.append((float(np.mean([p[2] for p in pts])), [(p[0], p[1]) for p in pts], nrm))
    fine.sort(key=lambda f: f[0])
    for _, pts, nrm in fine:
        col = shade(nrm, SURF_LIT, SURF_DARK, spec_k=0.26, spec_p=30)
        draw.polygon(pts, fill=col, outline=col)

    # 2) cage quads (all cage quads, incl. back-facing, so the boundary is
    #    topologically complete; only front ones are drawn)
    all_quads = cube_sphere(n)
    cage = [q for q in all_quads
            if float(np.dot(q.sum(axis=0) / 4 / np.linalg.norm(q.sum(axis=0) / 4), cap)) > cap_cos]

    edge_count = {}
    for q in cage:
        for a in range(4):
            e = tuple(sorted([key(q[a]), key(q[(a + 1) % 4])]))
            edge_count[e] = edge_count.get(e, 0) + 1
    boundary = {e for e, c in edge_count.items() if c == 1}

    drawn = []
    for q in cage:
        c = q.sum(axis=0) / 4
        c /= np.linalg.norm(c)
        nrm = normal_of(c)
        if nrm[2] <= 0.02:
            continue
        pts = [project(p) for p in q]
        drawn.append((float(np.mean([p[2] for p in pts])),
                      [(p[0], p[1]) for p in pts], nrm, q))
    drawn.sort(key=lambda f: f[0])

    for _, pts, nrm, _ in drawn:
        draw.polygon(pts, fill=shade(nrm, CAGE_LIT, CAGE_DARK))

    lw = max(3, int(R * 0.0072 * wire_scale))
    for _, pts, nrm, _ in drawn:
        facing = max(0.0, float(nrm[2]))
        draw.line(pts + [pts[0]], fill=WIRE + (int(135 + 120 * facing ** 0.6),),
                  width=lw, joint="curve")

    # 3) the true cage boundary: one continuous chain of edges, in gold
    if gold:
        for e in boundary:
            a, b = np.array(e[0]), np.array(e[1])
            mid = (a + b) / 2
            mid = mid / np.linalg.norm(mid)
            if normal_of(mid)[2] <= 0.0:
                continue
            pa, pb = project(a), project(b)
            draw.line([(pa[0], pa[1]), (pb[0], pb[1])],
                      fill=(90, 50, 10, 230), width=int(lw * 2.4))
            draw.line([(pa[0], pa[1]), (pb[0], pb[1])],
                      fill=GOLD + (255,), width=int(lw * 1.45))

    img = img.resize((SIZE, SIZE), Image.LANCZOS)
    img.save(out)
    return out


if __name__ == "__main__":
    import sys
    b = sys.argv[1]
    outs = [
        ("v4-a", render(n=4, out=f"{b}/v4-a.png")),
        ("v4-b-half", render(n=4, cap_cos=-0.05, out=f"{b}/v4-b-half.png")),
        ("v4-c-n5", render(n=5, cap_cos=0.0, wire_scale=0.9, out=f"{b}/v4-c-n5.png")),
        ("v4-d-n3", render(n=3, cap_cos=0.0, wire_scale=1.2, out=f"{b}/v4-d-n3.png")),
    ]
    sheet = Image.new("RGB", (4 * 200, 200), (18, 18, 22))
    for i, (nm, path) in enumerate(outs):
        s = Image.open(path).resize((40, 40), Image.LANCZOS)
        sheet.paste(s.resize((180, 180), Image.NEAREST), (i * 200 + 10, 10))
    sheet.save(f"{b}/v4-squint.png")
    print("ok")
