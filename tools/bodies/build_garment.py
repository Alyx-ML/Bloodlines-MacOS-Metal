#!/usr/bin/env python3
"""One garment of a character rebuilt as its own piece of cloth, with real thickness.

    build_garment.py CHAR.json SRC.npz NAME OUT.npz [--level L] [--body BODY.npz]
        [--dump-base BASE.npz] [--folds SIM.npz]

The garment's triangles (garments.py, from CHAR.json) are
 1. cut finer (each triangle into 4^L, default 2, on the game's texture exactly), and
    their facets evened out (Taubin smoothing, which keeps the volume; the openings'
    edges only along themselves);
 2. given thickness: an outer side (out by "thickness") and an inner one, joined at
    every opening by a rolled edge;
 3. given hems: the outer side raised by half its thickness within "hem" of each
    opening (the folded-over band of a hemmed edge);
 4. given seams: a raised ridge with a stitch line down its middle wherever two of the
    game's texture pieces meet inside the garment (where the pattern pieces are sewn).
Each new vertex is bound to the garment's own triangles at rest (a triangle, a place in
it and an offset in its axes), so it follows the game's bones as fit_body.py's do; the
UVs stay on the game's texture. OUT.npz: verts, tris, uvs, bind_tri, bind_bary,
bind_off, bind_err, hide (the game's triangles it replaces), mat_name, layer (each
triangle's: 0 outer side, 1 inner, 2 rolled edge, 3 seam) and open_dist (each vertex's
distance from the nearest opening).

Folds: --dump-base writes the garment's surface after step 1 (positions, triangles and
how firmly each vertex is held: its openings and a band along them, as hems and
seams hold cloth, and small separate pieces such as a knot, whole) for
sim_folds.py, which lets the cloth settle on the body with more cloth than room so it
buckles into folds. --folds takes that settled surface in place of step 1's (its
movement averaged "fold_smooth" times over neighbours first, default 12, which keeps
the folds and drops the crumple), and the thickness, hems and seams are built on it.

With --body, the rebuilt body (fit_body.py) is pushed in under the garment wherever it
would show through it, and BODY.npz rewritten.
"""
import argparse
from collections import defaultdict

import numpy as np
import trimesh
from garments import garment_mask, load_config, pieces
from scipy.spatial import cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("config")
ap.add_argument("src")
ap.add_argument("name")
ap.add_argument("out")
ap.add_argument("--level", type=int, default=2)
ap.add_argument("--body", default=None)
ap.add_argument("--dump-base", default=None)
ap.add_argument("--folds", default=None)
args = ap.parse_args()

cfg = load_config(args.config)
spec = cfg["garments"][args.name]
J = np.load(args.src)
co = J["co"].astype(np.float64)
mask = garment_mask(J, spec, cfg["textures"])
gt = np.where(mask)[0]  # the garment's triangles, as indices into the game's
T = J["tris"][gt]
UV = J["uvs"][gt].astype(np.float64)
thick = spec.get("thickness", 0.0025)
hem = spec.get("hem", 0.0)
_, weld = np.unique(np.round(co / 2e-4).astype(np.int64), axis=0, return_inverse=True)
weld = weld.ravel()
WT = weld[T]
wpos = np.zeros((weld.max() + 1, 3))
wpos[weld] = co
_, piece_all = pieces(J, list(J["mat_names"]).index(spec["material"]))
sel_all = np.where(J["mats"] == list(J["mat_names"]).index(spec["material"]))[0]
piece_of = dict(zip(sel_all, piece_all))
tpiece = np.array([piece_of[t] for t in gt])

# --- 1. finer -------------------------------------------------------------------------
n = 2 ** args.level
keys, P, src_tri, src_bary = {}, [], [], []


def vid(t, i, j):
    """The vertex at barycentric (i, j, n-i-j)/n of garment triangle t, shared with the
    neighbours along edges and corners."""
    w = (i, j, n - i - j)
    ids = WT[t]
    nz = [k for k in range(3) if w[k]]
    if len(nz) == 1:
        key = ("c", ids[nz[0]])
    elif len(nz) == 2:
        a, b = nz
        if ids[a] < ids[b]:
            key = ("e", ids[a], ids[b], w[a])
        else:
            key = ("e", ids[b], ids[a], w[b])
    else:
        key = ("i", t, i, j)
    if key not in keys:
        keys[key] = len(P)
        bary = np.array(w, np.float64) / n
        P.append(bary @ wpos[WT[t]])
        src_tri.append(t)
        src_bary.append(bary)
    return keys[key]


F, Fuv, Fsrc = [], [], []
for t in range(len(T)):
    for i in range(n):
        for j in range(n - i):
            tri_sets = [((i, j), (i + 1, j), (i, j + 1))]
            if i + j < n - 1:
                tri_sets.append(((i + 1, j), (i + 1, j + 1), (i, j + 1)))
            for corners in tri_sets:
                F.append([vid(t, a, b) for a, b in corners])
                Fuv.append([np.array((a, b, n - a - b)) / n @ UV[t] for a, b in corners])
                Fsrc.append(t)
P = np.array(P)
F = np.array(F)
Fuv = np.array(Fuv)
Fsrc = np.array(Fsrc)
nv = len(P)

edge_faces = defaultdict(list)
for k, f in enumerate(F):
    for a, b in ((f[0], f[1]), (f[1], f[2]), (f[2], f[0])):
        edge_faces[(min(a, b), max(a, b))].append(k)
boundary = [e for e, fs in edge_faces.items() if len(fs) == 1]
on_boundary = np.zeros(nv, bool)
for a, b in boundary:
    on_boundary[a] = on_boundary[b] = True
# Sharp edges ("crease": the angle in degrees between the game's two triangles beyond
# which their shared edge stays sharp, as a sole's or heel's), found on the game's mesh.
sharp_src = set()
if "crease" in spec:
    src_edge = defaultdict(list)
    for t in range(len(T)):
        for a, b in ((0, 1), (1, 2), (2, 0)):
            ia, ib = WT[t][a], WT[t][b]
            src_edge[(min(ia, ib), max(ia, ib))].append(t)
    fn_src = np.cross(wpos[WT[:, 1]] - wpos[WT[:, 0]], wpos[WT[:, 2]] - wpos[WT[:, 0]])
    fn_src /= np.linalg.norm(fn_src, axis=1, keepdims=True) + 1e-12
    cos_lim = np.cos(np.radians(spec["crease"]))
    sharp_src = {e for e, ts in src_edge.items() if len(ts) == 2 and fn_src[ts[0]] @ fn_src[ts[1]] < cos_lim}
key_of = {v: k for k, v in keys.items()}


def on_src_edge(v, e):
    k = key_of[v]
    return (k[0] == "e" and (k[1], k[2]) == e) or (k[0] == "c" and k[1] in e)


sharp = set()
if sharp_src:
    for (a, b) in edge_faces:
        ka, kb = key_of[a], key_of[b]
        cand = set()
        for k in (ka, kb):
            if k[0] == "e":
                cand.add((k[1], k[2]))
        if ka[0] == "c" and kb[0] == "c":
            cand.add((min(ka[1], kb[1]), max(ka[1], kb[1])))
        if any(e in sharp_src and on_src_edge(a, e) and on_src_edge(b, e) for e in cand):
            sharp.add((a, b))
on_sharp = np.zeros(nv, bool)
for a, b in sharp:
    on_sharp[a] = on_sharp[b] = True
# A boundary or sharp-edge vertex is smoothed only along its boundary or sharp edges.
bset = set(boundary) | sharp
held_line = on_boundary | on_sharp
nbr = defaultdict(list)
for (a, b) in edge_faces:
    along = (a, b) in bset
    if not held_line[a] or along:
        nbr[a].append(b)
    if not held_line[b] or along:
        nbr[b].append(a)
for v in range(nv):
    if on_sharp[v] and len(nbr[v]) > 2:
        nbr[v] = []  # where sharp edges meet: a corner, kept
for _ in range(8):  # Taubin: shrink then grow, so the shape keeps its size
    for lam in (0.5, -0.53):
        avg = np.array([P[nbr[v]].mean(0) if nbr[v] else P[v] for v in range(nv)])
        P = P + lam * (avg - P)
# The openings' edges follow the game's coarse triangles in a zigzag: evened out further
# along themselves (the cloth next to them follows).
bidx = np.where(on_boundary)[0]
for _ in range(25):
    P[bidx] += 0.5 * (np.array([P[nbr[v]].mean(0) if nbr[v] else P[v] for v in bidx]) - P[bidx])
    inner_v = np.where(~on_boundary)[0]
    P[inner_v] += 0.25 * (np.array([P[nbr[v]].mean(0) if nbr[v] else P[v] for v in inner_v]) - P[inner_v]) * (
        cKDTree(P[bidx]).query(P[inner_v])[0] < spec.get("hem", 0.004) + 0.004)[:, None]

if args.dump_base:
    bv = np.where(on_boundary)[0]
    d_open = cKDTree(P[bv]).query(P)[0] if len(bv) else np.full(nv, np.inf)
    band = spec.get("pin_band", 0.008)
    pin = np.clip(1.0 - d_open / band, 0.0, 1.0)
    # Small separate pieces (a knot, a bow) are held whole.
    comp = np.arange(nv)

    def croot(i):
        while comp[i] != i:
            comp[i] = comp[comp[i]]
            i = comp[i]
        return i

    for a, b in edge_faces:
        comp[croot(a)] = croot(b)
    roots = np.array([croot(v) for v in range(nv)])
    ru, rc = np.unique(roots, return_counts=True)
    small = set(ru[rc < 0.15 * nv])
    pin[[r in small for r in roots]] = 1.0
    np.savez_compressed(args.dump_base, verts=P.astype(np.float32), tris=F.astype(np.int32), pin=pin.astype(np.float32))
    print(f"[garment] base surface: {nv} vertices, {len(F)} triangles, {int((pin > 0.99).sum())} held -> {args.dump_base}")
if args.folds:
    S = np.load(args.folds)["verts"].astype(np.float64)
    assert len(S) == nv, "the settled surface is not this garment's (rebuild the base with --dump-base)"
    # The simulation's movement without its crumple (ripples a few triangles across):
    # averaged over each vertex's neighbours, the folds' broad shapes stay.
    Dm = S - P
    for _ in range(int(spec.get("fold_smooth", 12))):
        Dm = 0.5 * Dm + 0.5 * np.array([Dm[nbr[v]].mean(0) if nbr[v] else Dm[v] for v in range(nv)])
    print(f"[garment] folds: moved by up to {np.linalg.norm(Dm, axis=1).max():.4f} (median {np.median(np.linalg.norm(Dm, axis=1)):.4f})")
    P = P + Dm


def vertex_normals(Pts, Fc):
    fn = np.cross(Pts[Fc[:, 1]] - Pts[Fc[:, 0]], Pts[Fc[:, 2]] - Pts[Fc[:, 0]])
    vn = np.zeros_like(Pts)
    for c in range(3):
        np.add.at(vn, Fc[:, c], fn)
    return vn / (np.linalg.norm(vn, axis=1, keepdims=True) + 1e-12)


N = vertex_normals(P, F)

# --- 3. hems: distance from the nearest opening ------------------------------------------
bverts = np.where(on_boundary)[0]
dist_b = cKDTree(P[bverts]).query(P)[0] if len(bverts) else np.full(nv, np.inf)
raise_ = np.zeros(nv)
if hem > 0:
    s = np.clip(1.0 - (dist_b - hem * 0.75) / (hem * 0.25 + 1e-9), 0, 1)
    raise_ = 0.5 * thick * s * s * (3 - 2 * s)

# --- 2. thickness: outer and inner sides ----------------------------------------------------
outer = P + N * (thick + raise_[:, None])
inner = P.copy()
verts = [outer, inner]
faces = [F, F[:, ::-1] + nv]
layers = [np.zeros(len(F), np.int8), np.ones(len(F), np.int8)]  # 0 outer side, 1 inner, 2 rolled edges, 3 seams
uv_faces = [Fuv, Fuv[:, ::-1]]
vert_uv = np.zeros((nv, 2))
for k in range(3):
    vert_uv[F[:, k]] = Fuv[:, k]

# Rolled edges: a half round from the outer side's edge to the inner side's, outward.
loops_next = {}
for a, b in boundary:
    k = edge_faces[(a, b)][0]
    f = list(F[k])
    ia = f.index(a)
    if f[(ia + 1) % 3] != b:
        a, b = b, a
    loops_next[a] = b  # boundary edges in the faces' own winding
ROLL = 5
base = 2 * nv
roll_pts, roll_uv = [], []
order = list(loops_next)
index_of = {v: i for i, v in enumerate(order)}
for v in order:
    t_dir = P[loops_next[v]] - P[v]
    prev = [u for u, w in loops_next.items() if w == v]
    if prev:
        t_dir = t_dir + (P[v] - P[prev[0]])
    t_dir /= np.linalg.norm(t_dir) + 1e-12
    out_dir = np.cross(t_dir, N[v])  # away from the cloth, in its surface
    out_dir /= np.linalg.norm(out_dir) + 1e-12
    h = thick + raise_[v]
    c = P[v] + N[v] * h / 2
    for r in range(1, ROLL):
        a = np.pi * r / ROLL
        roll_pts.append(c + N[v] * (h / 2) * np.cos(a) + out_dir * (h / 2) * np.sin(a) * 1.4)
        roll_uv.append(vert_uv[v])
roll_pts = np.array(roll_pts).reshape(-1, ROLL - 1, 3) if roll_pts else np.zeros((0, ROLL - 1, 3))
roll_uv = np.array(roll_uv).reshape(-1, ROLL - 1, 2) if roll_uv else np.zeros((0, ROLL - 1, 2))
roll_faces, roll_fuv = [], []


def ring(v, r):
    """The r-th point round the rolled edge at boundary vertex v (0 outer, ROLL inner)."""
    if r == 0:
        return v
    if r == ROLL:
        return v + nv
    return base + index_of[v] * (ROLL - 1) + (r - 1)


for a, b in loops_next.items():
    for r in range(ROLL):
        q = [ring(a, r), ring(b, r), ring(b, r + 1), ring(a, r + 1)]
        roll_faces += [[q[0], q[2], q[1]], [q[0], q[3], q[2]]]
        roll_fuv += [[vert_uv[a], vert_uv[b], vert_uv[a]], [vert_uv[a], vert_uv[a], vert_uv[b]]]
verts.append(roll_pts.reshape(-1, 3))
if roll_faces:
    faces.append(np.array(roll_faces))
    layers.append(np.full(len(roll_faces), 2, np.int8))
    uv_faces.append(np.array(roll_fuv))

# --- 4. seams where two texture pieces meet -----------------------------------------------
seam_edges = [e for e, fs in edge_faces.items() if len(fs) == 2 and tpiece[Fsrc[fs[0]]] != tpiece[Fsrc[fs[1]]]]
# A sewn seam runs smoothly; where a texture piece's edge zigzags along the game's
# triangles it is only where the texture was cut, and gets no ridge.
seam_adj = defaultdict(list)
for a, b in seam_edges:
    seam_adj[a].append(b), seam_adj[b].append(a)
chain_of, chains = {}, []
for s0 in seam_adj:
    if s0 in chain_of:
        continue
    comp, stack = [s0], [s0]
    chain_of[s0] = len(chains)
    while stack:
        for w in seam_adj[stack.pop()]:
            if w not in chain_of:
                chain_of[w] = len(chains)
                comp.append(w), stack.append(w)
    chains.append(comp)


is_corner = np.zeros(nv, bool)  # the game's own vertices (the finer ones lie on straight edges)
is_corner[[v for k, v in keys.items() if k[0] == "c"]] = True


def walk(v, frm):
    """From v away from frm along the chain to the next of the game's own vertices."""
    while not is_corner[v] and len(seam_adj[v]) == 2:
        v, frm = next(w for w in seam_adj[v] if w != frm), v
    return v


def turning(vs):
    """Mean angle (degrees) between a chain's consecutive edges, at the game's own
    vertices with two seam neighbours."""
    angles = []
    for v in vs:
        if is_corner[v] and len(seam_adj[v]) == 2:
            a, b = (walk(w, v) for w in seam_adj[v])
            d1, d2 = P[v] - P[a], P[b] - P[v]
            c = d1 @ d2 / (np.linalg.norm(d1) * np.linalg.norm(d2) + 1e-12)
            angles.append(np.degrees(np.arccos(np.clip(c, -1, 1))))
    return np.mean(angles) if angles else 0.0


smooth_chain = [turning(c) < 20.0 for c in chains]
seam_edges = [e for e in seam_edges if smooth_chain[chain_of[e[0]]]]
print(f"[garment] seams: {sum(smooth_chain)} of {len(chains)} piece edges run smoothly enough to be sewn "
      f"(mean turn {[round(turning(c)) for c in chains]} degrees)")
sv = sorted({v for e in seam_edges for v in e})
if sv:
    W_SEAM = 0.0016
    PROFILE = [(-1.0, 0.05), (-0.5, 0.55), (0.0, 0.3), (0.5, 0.55), (1.0, 0.05)]  # across, height (of the thickness)
    tang = defaultdict(lambda: np.zeros(3))
    for a, b in seam_edges:
        d = P[b] - P[a]
        d /= np.linalg.norm(d) + 1e-12
        # One direction for all of a vertex's seam edges.
        if tang[a] @ d < 0:
            d = -d
        tang[a] += d
        tang[b] += d if tang[b] @ d >= 0 else -d
    sidx = {v: i for i, v in enumerate(sv)}
    sbase = sum(len(x) for x in verts)
    spts = []
    for v in sv:
        side = np.cross(N[v], tang[v])
        side /= np.linalg.norm(side) + 1e-12
        for across, height in PROFILE:
            spts.append(outer[v] + side * across * W_SEAM + N[v] * height * thick)
    verts.append(np.array(spts))
    sf, suv = [], []
    for a, b in seam_edges:
        ia, ib = sidx[a], sidx[b]
        flip = tang[a] @ (P[b] - P[a]) < 0
        for c in range(len(PROFILE) - 1):
            pa0, pa1 = sbase + ia * len(PROFILE) + c, sbase + ia * len(PROFILE) + c + 1
            pb0, pb1 = sbase + ib * len(PROFILE) + c, sbase + ib * len(PROFILE) + c + 1
            q = [[pa0, pb0, pb1], [pa0, pb1, pa1]]
            if flip:
                q = [x[::-1] for x in q]
            sf += q
            suv += [[vert_uv[a], vert_uv[b], vert_uv[b]], [vert_uv[a], vert_uv[b], vert_uv[a]]]
    faces.append(np.array(sf))
    layers.append(np.full(len(sf), 3, np.int8))
    uv_faces.append(np.array(suv))

V_all = np.vstack(verts)
F_all = np.vstack(faces)
layer = np.concatenate(layers)
# How far each vertex is from the nearest opening (make_lod.py drops the inner side far from them).
open_dist = cKDTree(P[bverts]).query(V_all)[0] if len(bverts) else np.full(len(V_all), np.inf)
UV_all = np.vstack(uv_faces)

# --- bound to the garment's own triangles, at rest ----------------------------------------
src = wpos[WT]
cand = cKDTree(src.mean(1)).query(V_all, k=min(16, len(T)))[1].reshape(len(V_all), -1)
best_d = np.full(len(V_all), np.inf)
best_p = np.zeros_like(V_all)
best_t = np.zeros(len(V_all), np.int64)
for j in range(cand.shape[1]):
    q = trimesh.triangles.closest_point(src[cand[:, j]], V_all)
    d = np.linalg.norm(q - V_all, axis=1)
    better = d < best_d
    best_d[better], best_p[better], best_t[better] = d[better], q[better], cand[better, j]
bary = trimesh.triangles.points_to_barycentric(src[best_t], best_p)


def frames(tp):
    e1 = tp[:, 1] - tp[:, 0]
    nrm = np.cross(e1, tp[:, 2] - tp[:, 0])
    e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    return np.stack([e1, np.cross(nrm, e1), nrm], 1)


Fr = frames(src[best_t])
offset = np.einsum("nij,nj->ni", Fr, V_all - best_p)
back = (src[best_t] * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", Fr, offset)
err = np.linalg.norm(back - V_all, axis=1)
print(f"[garment] {args.name}: {len(T)} game triangles -> {len(V_all)} vertices, {len(F_all)} triangles "
      f"({len(seam_edges)} seam edges, {len(loops_next)} edge vertices); binding error max {err.max():.2e}")
np.savez_compressed(args.out, verts=V_all.astype(np.float32), tris=F_all.astype(np.int32), uvs=UV_all.astype(np.float32),
                    layer=layer, open_dist=open_dist.astype(np.float32),
                    bind_tri=T[best_t].astype(np.int32), bind_bary=bary.astype(np.float32), bind_off=offset.astype(np.float32),
                    bind_err=err.astype(np.float32), hide=gt.astype(np.int32), mat_name=np.array(spec["material"]))
print(f"[garment] -> {args.out}")

# --- the body pushed in under the garment ---------------------------------------------------
if args.body:
    B = dict(np.load(args.body))
    X = B["verts"].astype(np.float64)
    tree = cKDTree(P)
    d, near = tree.query(X)
    # Only body vertices over the garment's area (not beside its edges).
    under = (d < 0.03) & ~on_boundary[near] & (dist_b[near] > 0.002)
    depth = ((X - P[near]) * N[near]).sum(1)
    gap = 0.0015
    push = under & (depth > -gap)
    X[push] -= N[near[push]] * (depth[push] + gap)[:, None]
    bt = co[B["bind_tri"]]
    Fb = frames(bt)
    cpb = (bt * B["bind_bary"][:, :, None]).sum(1)
    B["bind_off"] = np.einsum("nij,nj->ni", Fb, X - cpb).astype(np.float32)
    B["verts"] = X.astype(np.float32)
    np.savez_compressed(args.body, **B)
    print(f"[garment] body: {push.sum()} vertices pushed in under the {args.name}")
