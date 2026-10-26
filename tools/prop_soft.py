#!/usr/bin/env python3
"""Remodel a prop that is not round (a couch, a chair, a desk) from its extracted OBJ
(tools/mdl_extract.py): every triangle the original shades smoothly bent into the curved
patch its normals describe (a PN triangle: each edge a cubic leaving its ends at right
angles to their normals), split finely enough to follow it, while edges the original
shades hard (its normals differ either side) stay straight and sharp. Each new point takes
its UV and normal from where it lies in the original's triangle, so the texture lands
exactly where it did.

    python3 tools/prop_soft.py tools/props/leathercouch.json

A recipe names the model and the tolerance:
    {"model": "models/scenery/furniture/couch/leathercouch.mdl", "method": "soft",
     "tolerance": 0.1}
"tolerance" is how far the new surface may stray from the curved patches, in the model's
units: each edge is split into the fewest pieces (at most 4) that keep it within it, a
triangle as finely as its most split edge, its points on less split edges laid along
their straight pieces (so neighbours meet without cracks). Triangles with no split edge are kept whole.

Writes build/props/<model>/<name>_remodel.obj next to the extracted one, using its .mtl.
"""
import argparse
import json
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from prop_revolve import read_obj  # noqa: E402

MAX_STEPS = 4


def key(p):
    return tuple(np.round(p, 3))


def bezier(c, t):
    """The cubic with control points c at t."""
    s = 1 - t
    return s ** 3 * c[0] + 3 * s * s * t * c[1] + 3 * s * t * t * c[2] + t ** 3 * c[3]


def controls(pa, na, pb, nb, smooth, ra=1.0, rb=1.0):
    """An edge's cubic: leaving each end square to its normal if smooth, else straight.
    ra and rb (at most 1) scale how far each end's turn reaches along the edge: a corner
    is rounded over the length of the edge beyond it, not the whole of a long edge."""
    if not smooth:
        return [pa, (2 * pa + pb) / 3, (pa + 2 * pb) / 3, pb]
    return [pa, (2 * pa + pb - ra * ((pb - pa) @ na) * na) / 3,
            (2 * pb + pa - rb * ((pa - pb) @ nb) * nb) / 3, pb]


def beyond(pos, near, ka, kb):
    """How far the surface runs on past ka away from kb, as a share of the edge (at most
    1): the length of ka's edge leading most nearly straight on, if one does. The end
    normal's lean along the edge is the turn into that edge; across a thin part's end or
    a bevel it is short, and the turn must be made within it, or the edge balloons."""
    d = pos[kb] - pos[ka]
    L = np.linalg.norm(d)
    best, reach = 0.5, L  # leading on within 60 degrees of straight
    for kc in near[ka]:
        if kc == kb:
            continue
        c = pos[kc] - pos[ka]
        lc = np.linalg.norm(c)
        on = -(c @ d) / (lc * L)
        if on > best:
            best, reach = on, lc
    return min(1.0, reach / L)


def steps(c, tol):
    """The fewest straight pieces along the cubic c that keep within tol of it."""
    fine_t = np.linspace(0, 1, 33)
    fine = np.array([bezier(c, t) for t in fine_t])
    for k in range(1, MAX_STEPS + 1):
        knots = np.array([bezier(c, i / k) for i in range(k + 1)])
        seg = np.clip((fine_t * k).astype(int), 0, k - 1)
        q0, d = knots[seg], knots[seg + 1] - knots[seg]
        w = np.clip(((fine - q0) * d).sum(1) / np.maximum((d * d).sum(1), 1e-12), 0, 1)
        if np.linalg.norm(fine - (q0 + d * w[:, None]), axis=1).max() <= tol:
            return k
    return MAX_STEPS


def patches(faces, v, vn, vt, curve, ke):
    """Each face as its PN patch, split as finely as its most split edge (whole if none
    is), as triangles of (position, normal, UV); and the edges of faces any of whose
    pieces turned over (faced away from the original triangle)."""
    def edge_point(ka, kb, s):
        """The point at s (0 at ka, 1 at kb) along the edge, the same floats from either side."""
        e = (ka, kb) if ka < kb else (kb, ka)
        return bezier(curve[e], s if ka < kb else 1 - s)

    out, folded = [], set()
    for f in faces:
        P = [v[c[0]] for c in f]
        N = [vn[c[2]] for c in f]
        T = [vt[c[1]] for c in f]
        K = [key(p) for p in P]
        es = [tuple(sorted((K[a], K[(a + 1) % 3]))) for a in range(3)]
        k = max(ke.get(e, 1) for e in es)
        if k == 1:
            out.append([(P[a], N[a], T[a]) for a in range(3)])
            continue
        # the PN patch: edge cubics, and a middle control point lifted as theirs are
        ctrl = {}
        for a in range(3):
            b = (a + 1) % 3
            c = curve[es[a]] if K[a] < K[b] else curve[es[a]][::-1]
            ctrl[a, b], ctrl[b, a] = c[1], c[2]
        E = sum(ctrl.values()) / 6
        mid = E + (E - sum(P) / 3) / 2
        grid = {}
        for i in range(k + 1):
            for j in range(k + 1 - i):
                w = np.array([i, j, k - i - j], float) / k
                on = [x for x in range(3) if w[x] > 0]
                if len(on) == 1:  # a corner
                    p = P[on[0]]
                elif len(on) == 2:  # on an edge: on the straight pieces its neighbour has
                    a, b = on
                    n_e = ke.get(es[a] if (a + 1) % 3 == b else es[b], 1)
                    x = min(int(w[b] * n_e), n_e - 1)
                    q0, q1 = edge_point(K[a], K[b], x / n_e), edge_point(K[a], K[b], (x + 1) / n_e)
                    p = q0 + (w[b] * n_e - x) * (q1 - q0)
                else:
                    u0, u1, u2 = w
                    p = (u0 ** 3 * P[0] + u1 ** 3 * P[1] + u2 ** 3 * P[2]
                         + 3 * u0 * u0 * u1 * ctrl[0, 1] + 3 * u0 * u1 * u1 * ctrl[1, 0]
                         + 3 * u1 * u1 * u2 * ctrl[1, 2] + 3 * u1 * u2 * u2 * ctrl[2, 1]
                         + 3 * u2 * u2 * u0 * ctrl[2, 0] + 3 * u2 * u0 * u0 * ctrl[0, 2]
                         + 6 * u0 * u1 * u2 * mid)
                grid[i, j] = (p, w @ np.array(N), w @ np.array(T))
        face = np.cross(P[1] - P[0], P[2] - P[0])
        # which way the original faces its normals (the game winds against them), if clearly
        side = face / (np.linalg.norm(face) or 1) @ sum(N)
        side = np.sign(side) if abs(side) > 0.2 * np.linalg.norm(sum(N)) else 0
        tris = []
        for i in range(k):
            for j in range(k - i):
                tris.append([grid[i, j], grid[i + 1, j], grid[i, j + 1]])
                if i + j < k - 1:
                    tris.append([grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]])

        def turned(t):
            """Facing away from the original triangle, or the other way round to its normals."""
            g = np.cross(t[1][0] - t[0][0], t[2][0] - t[0][0])
            n = sum(c[1] for c in t)
            return g @ face < 0 or side * (g @ n) < -0.2 * np.linalg.norm(g) * np.linalg.norm(n)
        if any(turned(t) for t in tris):
            folded |= {e for e in es if ke.get(e, 1) > 1}
        out += tris
    return out, folded


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe")
    ap.add_argument("--props", default=os.path.join(HERE, "..", "build", "props"))
    args = ap.parse_args()
    recipe = json.load(open(args.recipe))
    model = recipe["model"].lower()
    folder = os.path.join(args.props, model[len("models/"):-4])
    stem = os.path.basename(folder)
    src = os.path.join(folder, stem + ".obj")
    if not os.path.exists(src):
        print(f"{src} not found: run tools/mdl_extract.py {model} first", file=sys.stderr)
        return 1
    v, vt, vn, groups, order = read_obj(src)
    vn = vn / np.maximum(np.linalg.norm(vn, axis=1, keepdims=True), 1e-12)
    tol = float(recipe["tolerance"])
    print(model)
    out_v, out_n, out_t, out_f = [], [], [], []
    ntri = 0
    for mat in order:
        faces = [f for f in groups[mat] if len(f) == 3]
        # each edge, by its ends' positions: the normals every face gives its ends
        edges = {}
        for f in faces:
            for a in range(3):
                ca, cb = f[a], f[(a + 1) % 3]
                ka, kb = key(v[ca[0]]), key(v[cb[0]])
                if ka == kb:
                    continue
                e = (ka, kb) if ka < kb else (kb, ka)
                na, nb = (vn[ca[2]], vn[cb[2]]) if ka < kb else (vn[cb[2]], vn[ca[2]])
                edges.setdefault(e, []).append((na, nb))
        pos = {}
        for f in faces:
            for c in f:
                pos.setdefault(key(v[c[0]]), v[c[0]])

        def rises(e, na, nb):
            """How steeply the edge leaves the planes square to its end normals; an arc
            between them leaves at no more than half the angle they turn through."""
            d = pos[e[1]] - pos[e[0]]
            d = d / (np.linalg.norm(d) or 1)
            return max(abs(d @ na), abs(d @ nb))

        # smooth: shaded smoothly on both faces (one normal each end), bent by less than
        # 45 degrees, and leaving its normals' planes no more steeply than such a bend
        # (else the original smoothed over a fold, which would curve into a spike)
        smooth = {e: len(ns) == 2 and ns[0][0] @ ns[0][1] > 0.7 and rises(e, *ns[0]) < 0.4 and
                  all(np.abs(n[0] - ns[0][0]).max() < 0.02 and np.abs(n[1] - ns[0][1]).max() < 0.02 for n in ns)
                  for e, ns in edges.items()}
        near = {}
        for a, b in edges:
            near.setdefault(a, set()).add(b)
            near.setdefault(b, set()).add(a)
        reach = {e: (beyond(pos, near, *e), beyond(pos, near, e[1], e[0])) for e in edges}
        straight = set()  # smooth edges left straight: curving them turned a piece over
        while True:
            curve = {}
            for e, ns in edges.items():
                na, nb = ns[0]
                curve[e] = controls(pos[e[0]], na, pos[e[1]], nb, smooth[e] and e not in straight, *reach[e])
            ke = {e: steps(curve[e], tol) if smooth[e] and e not in straight else 1 for e in edges}
            pieces, folded = patches(faces, v, vn, vt, curve, ke)
            if not folded:
                break
            straight |= folded
        tris = []
        for tri in pieces:
            ids = []
            for p, n, uv in tri:
                out_v.append(p), out_n.append(n / (np.linalg.norm(n) or 1)), out_t.append(uv)
                ids.append(len(out_v) - 1)
            tris.append(ids)
        print(f"  {mat}: {sum(smooth.values())} of {len(edges)} edges smooth"
              + (f" ({len(straight)} left straight, else they fold)" if straight else "")
              + f", {sum(x > 1 for x in ke.values())} split, {len(tris)} triangles from {len(faces)}")
        out_f.append((mat, tris))
        ntri += len(tris)
    dst = os.path.join(folder, stem + "_remodel.obj")
    with open(dst, "w") as f:
        f.write(f"# {model} remodelled by tools/prop_soft.py from {os.path.basename(args.recipe)}\n")
        f.write(f"mtllib {stem}.mtl\n")
        for p in out_v:
            f.write("v {:.6f} {:.6f} {:.6f}\n".format(*p))
        for t in out_t:
            f.write("vt {:.6f} {:.6f}\n".format(*t))
        for n in out_n:
            f.write("vn {:.6f} {:.6f} {:.6f}\n".format(*n))
        for mat, tris in out_f:
            f.write(f"usemtl {mat}\n")
            for tri in tris:
                f.write("f " + " ".join(f"{i + 1}/{i + 1}/{i + 1}" for i in tri) + "\n")
    print(f"{ntri} triangles (the original {sum(len(g) for g in groups.values())}) -> {os.path.abspath(dst)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
