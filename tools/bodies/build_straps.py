#!/usr/bin/env python3
"""Straps and buckles a character's texture only paints, built as real ones.

    build_straps.py CHAR.json SRC.npz NAME OUT.npz --surface PART.npz

The config's "straps" entry NAME gives, on the texture of "material":
    "lines": each strap's centre line as UV points, traced from the texture;
    "width": the straps' width in UV; "thickness": how far they stand off;
    "buckles": each buckle's UV centre and half size (along and across its strap);
    "wire": the buckle frames' wire radius;
    "on": the garment the straps lie on (PART.npz, from build_garment.py).
A UV point is found on every one of the game's triangles of that garment whose UVs hold
it (both boots share one texture, so each strap is built on each), then put on the
rebuilt garment's outer surface. A strap is a band across its painted width, with
rounded edges and a stitch groove along each; a buckle is a wire frame round its painted
outline, square to its strap, with a bar and a prong. Their UVs are where they are
painted. Each vertex is bound to the game's triangles as build_garment.py binds. OUT.npz
is laid out as build_garment.py's (with mat_name, without hide).
"""
import argparse

import numpy as np
import trimesh
from garments import garment_mask, load_config
from scipy.spatial import cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("config")
ap.add_argument("src")
ap.add_argument("name")
ap.add_argument("out")
ap.add_argument("--surface", required=True)
args = ap.parse_args()

cfg = load_config(args.config)
spec = cfg["straps"][args.name]
J = np.load(args.src)
co = J["co"].astype(np.float64)
gt = np.where(garment_mask(J, cfg["garments"][spec["on"]], cfg["textures"]))[0]
T = J["tris"][gt]
TU = J["uvs"][gt].astype(np.float64)
tri_pos = co[T]
tn = np.cross(tri_pos[:, 1] - tri_pos[:, 0], tri_pos[:, 2] - tri_pos[:, 0])
tn /= np.linalg.norm(tn, axis=1, keepdims=True) + 1e-12
S = np.load(args.surface)
SV, SF = S["verts"].astype(np.float64), S["tris"]
sn = np.cross(SV[SF[:, 1]] - SV[SF[:, 0]], SV[SF[:, 2]] - SV[SF[:, 0]])
sn /= np.linalg.norm(sn, axis=1, keepdims=True) + 1e-12
s_tree = cKDTree(SV[SF].mean(1))
uv_tree = cKDTree(TU.mean(1))
thick, width, wire = spec.get("thickness", 0.0012), spec.get("width", 0.015), spec.get("wire", 0.0008)

# The garment's separate pieces (each boot): a UV point is found once on each.
_, weld = np.unique(np.round(co / 2e-4).astype(np.int64), axis=0, return_inverse=True)
weld = weld.ravel()
wc = np.arange(weld.max() + 1)


def wroot(i):
    while wc[i] != i:
        wc[i] = wc[wc[i]]
        i = wc[i]
    return i


for t in weld[T]:
    for v in t[1:]:
        wc[wroot(t[0])] = wroot(v)
tri_piece = np.array([wroot(weld[t[0]]) for t in T])
piece_ids = list(np.unique(tri_piece))


def on_surface(uvs):
    """3D points for UV points, one array per garment piece: (points, normals, ok)."""
    uvs = np.atleast_2d(uvs)
    _, cand = uv_tree.query(uvs, k=min(40, len(T)))
    out = []
    for pid in piece_ids:
        P = np.zeros((len(uvs), 3))
        N = np.zeros((len(uvs), 3))
        ok = np.zeros(len(uvs), bool)
        for i, cs in enumerate(cand):
            for t in cs:
                if tri_piece[t] != pid:
                    continue
                a, b, c = TU[t]
                m = np.array([b - a, c - a]).T
                if abs(np.linalg.det(m)) < 1e-12:
                    continue
                l1, l2 = np.linalg.solve(m, uvs[i] - a)
                if l1 >= -1e-4 and l2 >= -1e-4 and l1 + l2 <= 1 + 1e-4:
                    P[i] = tri_pos[t, 0] + l1 * (tri_pos[t, 1] - tri_pos[t, 0]) + l2 * (tri_pos[t, 2] - tri_pos[t, 0])
                    N[i] = tn[t]
                    ok[i] = True
                    break
        # Onto the rebuilt garment's outer side: the nearest of its triangles facing the same way.
        if ok.any():
            _, sc = s_tree.query(P[ok], k=24)
            best = np.full(ok.sum(), np.inf)
            bp, bn = P[ok].copy(), N[ok].copy()
            for j in range(sc.shape[1]):
                t = sc[:, j]
                q = trimesh.triangles.closest_point(SV[SF[t]], P[ok])
                d = np.linalg.norm(q - P[ok], axis=1)
                better = (d < best) & ((sn[t] * N[ok]).sum(1) > 0.5)
                best[better], bp[better], bn[better] = d[better], q[better], sn[t][better]
            P[ok], N[ok] = bp, bn
        out.append((P, N, ok))
    return out


verts, faces, fuv = [], [], []


def add_grid(pts, uvs, closed=False):
    """A quad grid (rows x cols of points, each with a UV) as triangles."""
    rows, cols = pts.shape[:2]
    base = sum(len(v) for v in verts)
    verts.append(pts.reshape(-1, 3))
    U = uvs.reshape(-1, 2)
    idx = np.arange(rows * cols).reshape(rows, cols) + base
    for r in range(rows - 1):
        for c in range(cols - (0 if closed else 1)):
            c2 = (c + 1) % cols
            q = [idx[r, c], idx[r + 1, c], idx[r + 1, c2], idx[r, c2]]
            for tri in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
                faces.append(tri)
                fuv.append([U[i - base] for i in tri])


# --- straps -------------------------------------------------------------------------
PROFILE = [(-1.0, 0.1), (-0.92, 0.7), (-0.8, 1.0), (-0.7, 0.8), (-0.6, 1.0), (0.6, 1.0), (0.7, 0.8),
           (0.8, 1.0), (0.92, 0.7), (1.0, 0.1)]  # across (of half the width), height (of the thickness)
STEP = 0.0015  # along the strap, in UV
tangents = []  # (uv point, uv direction) along every strap, for squaring the buckles
for line in spec["lines"]:
    L = np.array(line, np.float64)
    seg = np.linalg.norm(np.diff(L, axis=0), axis=1)
    s = np.r_[0, np.cumsum(seg)]
    n_s = max(2, int(s[-1] / STEP) + 1)
    ss = np.linspace(0, s[-1], n_s)
    C = np.stack([np.interp(ss, s, L[:, k]) for k in range(2)], 1)
    D = np.gradient(C, axis=0)
    D /= np.linalg.norm(D, axis=1, keepdims=True) + 1e-12
    side = np.stack([-D[:, 1], D[:, 0]], 1)
    tangents += list(zip(C, D))
    taper = np.ones(n_s)
    taper[-3:] = [0.85, 0.65, 0.4]  # the strap's free end, rounded off
    across = np.array([a for a, _ in PROFILE])
    height = np.array([h for _, h in PROFILE])
    grid_uv = C[:, None, :] + side[:, None, :] * (across[None, :, None] * width / 2 * taper[:, None, None])
    placed = on_surface(grid_uv.reshape(-1, 2))
    for P, N, ok in placed:
        P, N, ok = P.reshape(n_s, len(PROFILE), 3), N.reshape(n_s, len(PROFILE), 3), ok.reshape(n_s, len(PROFILE))
        row_ok = ok.all(1)
        # Each run of rows found whole on this piece is one strip.
        r = 0
        while r < n_s:
            if not row_ok[r]:
                r += 1
                continue
            e = r
            while e < n_s and row_ok[e]:
                e += 1
            if e - r >= 2:
                pts = P[r:e] + N[r:e] * (height[None, :, None] * thick + 0.0002)
                add_grid(pts, grid_uv[r:e])
            r = e
n_strap_tris = len(faces)

# --- buckles ------------------------------------------------------------------------
RING = 8


def tube(centre_uv, closed):
    """A wire along UV points, lifted over the straps."""
    for P, N, ok in on_surface(centre_uv):
        if not ok.all():
            continue
        P = P + N * (thick + wire + 0.0002)
        t = np.roll(P, -1, 0) - np.roll(P, 1, 0) if closed else np.gradient(P, axis=0)
        t /= np.linalg.norm(t, axis=1, keepdims=True) + 1e-12
        b = np.cross(N, t)
        b /= np.linalg.norm(b, axis=1, keepdims=True) + 1e-12
        n2 = np.cross(t, b)
        a = np.linspace(0, 2 * np.pi, RING, endpoint=False)
        pts = P[:, None, :] + wire * (np.cos(a)[None, :, None] * n2[:, None, :] + np.sin(a)[None, :, None] * b[:, None, :])
        uvs = np.repeat(np.atleast_2d(centre_uv)[:, None, :], RING, 1)
        if closed:
            pts = np.concatenate([pts, pts[:1]], 0)
            uvs = np.concatenate([uvs, uvs[:1]], 0)
        add_grid(pts, uvs, closed=True)


tan_pts = np.array([p for p, _ in tangents])
tan_dir = np.array([d for _, d in tangents])
for bk in spec.get("buckles", []):
    c = np.array(bk["uv"], np.float64)
    ha, hb = bk["size"]
    k = np.argmin(np.linalg.norm(tan_pts - c, axis=1))
    along = tan_dir[k] if np.linalg.norm(tan_pts[k] - c) < width else np.array([1.0, 0.0])
    across = np.array([-along[1], along[0]])
    # A rounded rectangle round the painted frame.
    a = np.linspace(0, 2 * np.pi, 48, endpoint=False)
    ca, sa = np.cos(a), np.sin(a)
    sq = 6.0  # superellipse exponent: square with rounded corners
    x = np.sign(ca) * np.abs(ca) ** (2 / sq) * ha
    y = np.sign(sa) * np.abs(sa) ** (2 / sq) * hb
    tube(c + x[:, None] * along + y[:, None] * across, closed=True)
    bar = np.linspace(-hb, hb, 12)
    tube(c + 0.0 * along + bar[:, None] * across, closed=False)  # the bar the prong turns on
    prong = np.linspace(0, ha, 8)
    tube(c + prong[:, None] * along, closed=False)

V = np.vstack(verts)
F = np.array(faces, np.int64)
FUV = np.array(fuv, np.float64)

# --- bound to the garment's game triangles, at rest -----------------------------------------
cand = cKDTree(tri_pos.mean(1)).query(V, k=min(16, len(T)))[1]
best_d = np.full(len(V), np.inf)
best_p = np.zeros_like(V)
best_t = np.zeros(len(V), np.int64)
for j in range(cand.shape[1]):
    q = trimesh.triangles.closest_point(tri_pos[cand[:, j]], V)
    d = np.linalg.norm(q - V, axis=1)
    better = d < best_d
    best_d[better], best_p[better], best_t[better] = d[better], q[better], cand[better, j]
bary = trimesh.triangles.points_to_barycentric(tri_pos[best_t], best_p)
tp = tri_pos[best_t]
e1 = tp[:, 1] - tp[:, 0]
nrm = np.cross(e1, tp[:, 2] - tp[:, 0])
e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
Fr = np.stack([e1, np.cross(nrm, e1), nrm], 1)
offset = np.einsum("nij,nj->ni", Fr, V - best_p)
back = (tp * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", Fr, offset)
err = np.linalg.norm(back - V, axis=1)
print(f"[straps] {args.name}: {len(spec['lines'])} straps and {len(spec.get('buckles', []))} buckles on each of "
      f"{len(piece_ids)} pieces -> {len(V)} vertices, {len(F)} triangles ({n_strap_tris} in straps)")
np.savez_compressed(args.out, verts=V.astype(np.float32), tris=F.astype(np.int32), uvs=FUV.astype(np.float32),
                    bind_tri=T[best_t].astype(np.int32), bind_bary=bary.astype(np.float32), bind_off=offset.astype(np.float32),
                    bind_err=err.astype(np.float32), mat_name=np.array(spec["material"]))
print(f"[straps] -> {args.out}")
