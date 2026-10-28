#!/usr/bin/env python3
"""Ribbed cuffs where a character's socks (or sleeves, gloves...) end, built as real
bands round the limb where the texture only paints the edge.

    build_cuffs.py CHAR.json SRC.npz NAME OUT.npz --body BODY.npz

The config's "cuffs" entry NAME gives:
    "texture": the body texture the painted edge is found on;
    "min_bright": the sock's brightness (0-255; the skin above is darker);
    "z": the height range the edge lies in; "sides": [1, -1] for both legs (the sign of x);
    "height", "thickness": the cuff's height and how far it stands off;
    "ribs": how many ribs go round it.
On each limb, round its axis in 48 directions, the edge is the highest point up the
rebuilt body (BODY.npz, fit_body.py) whose texture is the sock's colour; that line,
evened out, is the cuff's top. The cuff is built from rays out of the limb's axis onto the body:
ribbed up its height, rounded over at the top and tucked back onto the skin. Its UVs
are the body's where it lies, so it shows the painted band. Each vertex is bound to the
game's body triangles as build_garment.py binds. OUT.npz is laid out as build_garment.py's
(with mat_name, without hide).
"""
import argparse
import os

import numpy as np
import trimesh
from garments import load_config
from PIL import Image
from scipy.spatial import cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("config")
ap.add_argument("src")
ap.add_argument("name")
ap.add_argument("out")
ap.add_argument("--body", required=True)
args = ap.parse_args()

cfg = load_config(args.config)
spec = cfg["cuffs"][args.name]
J = np.load(args.src)
co = J["co"].astype(np.float64)
B = np.load(args.body)
V, F, FUV = B["verts"].astype(np.float64), B["tris"], B["uvs"].astype(np.float64)
body = trimesh.Trimesh(V, F, process=False)  # its face normals
vuv = np.zeros((len(V), 2))
for k in range(3):
    vuv[F[:, k]] = FUV[:, k]
tex = np.asarray(Image.open(os.path.join(cfg["textures"], spec["texture"])).convert("RGB")).astype(float)
h_px, w_px, _ = tex.shape
bright = tex[((1 - vuv[:, 1]) * h_px).astype(int).clip(0, h_px - 1), (vuv[:, 0] * w_px).astype(int).clip(0, w_px - 1)].mean(1)
z0, z1 = spec["z"]
height, thick, ribs = spec.get("height", 0.025), spec.get("thickness", 0.0015), spec.get("ribs", 44)
DIRS = 48
# Height fraction of the cuff (1 = its top), offset (of the thickness), ribbed?
PROFILE = [(0.0, 0.05, 0), (0.06, 0.6, 0), (0.15, 1.0, 1), (0.3, 1.0, 1), (0.45, 1.0, 1), (0.6, 1.0, 1), (0.75, 1.0, 1),
           (0.86, 1.15, 0), (0.95, 1.25, 0), (1.0, 0.95, 0), (1.025, 0.45, 0), (1.035, 0.05, 0)]

bname = cfg["body"]
bi = list(J["mat_names"]).index(bname)
game_tris = J["tris"][J["mats"] == bi]
game_pos = co[game_tris]



def first_hits(origin, d, tris):
    """Each ray's nearest crossing of the given triangles (Moller-Trumbore):
    (points, triangle indices into F, found)."""
    a, b, c = V[F[tris, 0]], V[F[tris, 1]], V[F[tris, 2]]
    e1, e2 = b - a, c - a
    p = np.cross(d[:, None, :], e2[None])
    det = (e1[None] * p).sum(2)
    inv = 1.0 / np.where(np.abs(det) < 1e-14, np.inf, det)
    s_ = origin[:, None, :] - a[None]
    u = (s_ * p).sum(2) * inv
    q = np.cross(s_, e1[None])
    v = (d[:, None, :] * q).sum(2) * inv
    t = (e2[None] * q).sum(2) * inv
    ok = (u >= 0) & (v >= 0) & (u + v <= 1) & (t > 1e-9)
    t = np.where(ok, t, np.inf)
    k = np.argmin(t, 1)
    tk = t[np.arange(len(origin)), k]
    found = np.isfinite(tk)
    return origin + d * np.where(found, tk, 0)[:, None], tris[k], found


verts, faces, fuv = [], [], []
for side in spec.get("sides", [1, -1]):
    on_limb = (np.sign(V[:, 0]) == side) & (np.abs(V[:, 0]) > 0.01) & (V[:, 2] > z0) & (V[:, 2] < z1)
    sock = on_limb & (bright >= spec["min_bright"])
    zmid = np.median(V[sock, 2])
    ring = on_limb & (np.abs(V[:, 2] - zmid) < 0.02)
    axis = V[ring, :2].mean(0)
    theta = (np.arange(DIRS) + 0.5) / DIRS * 2 * np.pi - np.pi
    cz = V[F].mean(1)
    limb_tris = np.where((np.sign(cz[:, 0]) == side) & (cz[:, 2] > z0 - height - 0.02) & (cz[:, 2] < z1 + 0.02))[0]
    d = np.stack([np.cos(theta), np.sin(theta), np.zeros(DIRS)], 1)

    def colour_at(z):
        """The texture's brightness where each direction's ray meets the body at height z."""
        org = np.stack([np.full(DIRS, axis[0]), np.full(DIRS, axis[1]), np.full(DIRS, z)], 1)
        hit, th, found = first_hits(org, d, limb_tris)
        bary = trimesh.triangles.points_to_barycentric(V[F[th]], hit)
        uv = (FUV[th] * bary[:, :, None]).sum(1)
        px = tex[((1 - uv[:, 1]) * h_px).astype(int).clip(0, h_px - 1), (uv[:, 0] * w_px).astype(int).clip(0, w_px - 1)]
        return np.where(found, px.mean(1), 0)

    # Up each direction: the sock's top is where its colour ends for good.
    zs = np.arange(z0, z1, 0.002)
    col = np.array([colour_at(z) for z in zs])  # heights x directions
    is_sock = col >= spec["min_bright"]
    top = np.array([zs[np.where(is_sock[:, k])[0].max()] if is_sock[:, k].any() else np.nan for k in range(DIRS)])
    top = np.where(np.isnan(top), np.nanmedian(top), top)
    # Evened out: only its slow changes round the limb (the first three harmonics).
    spec_f = np.fft.rfft(top)
    spec_f[4:] = 0
    top = np.fft.irfft(spec_f, DIRS) + 0.002
    pts = np.zeros((len(PROFILE), DIRS, 3))
    uvs = np.zeros((len(PROFILE), DIRS, 2))
    for r, (frac, off, ribbed) in enumerate(PROFILE):
        z = top - height * (1 - frac)
        origin = np.stack([np.full(DIRS, axis[0]), np.full(DIRS, axis[1]), z], 1)
        hit, tri_hit, found = first_hits(origin, d, limb_tris)
        missing = np.where(~found)[0]
        if len(missing):
            raise SystemExit(f"[cuffs] {len(missing)} rays found no body at height {z.mean():.3f}: check \"z\"")
        n = body.face_normals[tri_hit]
        o = off * thick
        if ribbed:
            o = o + 0.35 * thick * (0.5 + 0.5 * np.cos(ribs * theta))
        pts[r] = hit + n * np.broadcast_to(o, (DIRS,))[:, None]
        bary = trimesh.triangles.points_to_barycentric(V[F[tri_hit]], hit)
        uvs[r] = (FUV[tri_hit] * bary[:, :, None]).sum(1)
    base = sum(len(v) for v in verts)
    verts.append(pts.reshape(-1, 3))
    U = uvs.reshape(-1, 2)
    idx = np.arange(len(PROFILE) * DIRS).reshape(len(PROFILE), DIRS) + base
    for r in range(len(PROFILE) - 1):
        for c in range(DIRS):
            c2 = (c + 1) % DIRS
            q = [idx[r, c], idx[r, c2], idx[r + 1, c2], idx[r + 1, c]]  # outward by the angle's direction
            for tri in ((q[0], q[1], q[2]), (q[0], q[2], q[3])):
                faces.append(tri)
                fuv.append([U[i - base] for i in tri])
    print(f"[cuffs] side {side:+d}: top at {top.min():.3f}-{top.max():.3f}, axis {axis.round(3)}")

Vc = np.vstack(verts)
Fc = np.array(faces, np.int64)
UVc = np.array(fuv, np.float64)

cand = cKDTree(game_pos.mean(1)).query(Vc, k=16)[1]
best_d = np.full(len(Vc), np.inf)
best_p = np.zeros_like(Vc)
best_t = np.zeros(len(Vc), np.int64)
for j in range(cand.shape[1]):
    q = trimesh.triangles.closest_point(game_pos[cand[:, j]], Vc)
    d = np.linalg.norm(q - Vc, axis=1)
    better = d < best_d
    best_d[better], best_p[better], best_t[better] = d[better], q[better], cand[better, j]
bary = trimesh.triangles.points_to_barycentric(game_pos[best_t], best_p)
tp = game_pos[best_t]
e1 = tp[:, 1] - tp[:, 0]
nrm = np.cross(e1, tp[:, 2] - tp[:, 0])
e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
Fr = np.stack([e1, np.cross(nrm, e1), nrm], 1)
offset = np.einsum("nij,nj->ni", Fr, Vc - best_p)
back = (tp * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", Fr, offset)
err = np.linalg.norm(back - Vc, axis=1)
print(f"[cuffs] {args.name}: {len(Vc)} vertices, {len(Fc)} triangles; binding error max {err.max():.2e}")
np.savez_compressed(args.out, verts=Vc.astype(np.float32), tris=Fc.astype(np.int32), uvs=UVc.astype(np.float32),
                    bind_tri=game_tris[best_t].astype(np.int32), bind_bary=bary.astype(np.float32),
                    bind_off=offset.astype(np.float32), bind_err=err.astype(np.float32), mat_name=np.array(bname))
print(f"[cuffs] -> {args.out}")
