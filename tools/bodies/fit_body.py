#!/usr/bin/env python3
"""A character's body rebuilt on MakeHuman's base body (CC0), fitted to the game's body.

    fit_body.py SRC.npz BASE.obj OUT.npz [--config CHAR.json] [--body MATERIAL] [--stiff S]

SRC.npz comes from export_body.py; BASE.obj is MakeHuman's base mesh. The base body is
 1. turned into the game's axes and size, and the game's body posed like it: each arm,
    hand, finger and leg bone turned to the base body's own (the game's own skin weights
    move the mesh), so the two stand alike;
 2. warped onto the posed game skeleton by its joints (a thin-plate spline), which gives
    it the character's proportions;
 3. cut: the head (the game's face and hair stay), the feet (inside the boots) and
    anything else not over the game's body;
 4. pulled onto the game's body surface as fit_head.py pulls the head (nearest points,
    each edge kept close to its own direction and length, weight lowered to --stiff),
    taking only points whose surface faces the same way (fingers stay apart). The
    garments in --config (garments.py) are not pulled onto: under them the base body
    keeps its own shape, and build_garment.py makes them as separate pieces.
Each vertex is then bound to the game's body (in the posed shape, where the fit was
made): a triangle, a place in it and an offset in its own axes, so it follows the
game's bones. Its rest position is worked out again from that binding. OUT.npz is laid
out as fit_head.py's: verts, tris, bind_tri, bind_bary, bind_off, bind_err, uvs.
"""
import argparse
from collections import defaultdict

import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spl
import trimesh
from garments import garment_mask, load_config
from scipy.interpolate import RBFInterpolator
from scipy.spatial import cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("src")
ap.add_argument("base")
ap.add_argument("out")
ap.add_argument("--config", default=None)
ap.add_argument("--body", default=None, help="the body material (default: the one ending in '_body')")
ap.add_argument("--stiff", type=float, default=0.5)
args = ap.parse_args()

# --- the game's model ----------------------------------------------------------------------
J = np.load(args.src)
names = list(J["mat_names"])
body_name = args.body or next(n for n in names if n.lower().endswith("_body"))
bi = names.index(body_name)
co = J["co"].astype(np.float64)
bones = list(J["bones"])
bhead = J["bone_head"].astype(np.float64)
btail = J["bone_tail"].astype(np.float64)
bparent = J["bone_parent"]


def jb(name):
    return bones.index(name)


# --- MakeHuman's base body ---------------------------------------------------------------
V, groups, cur = [], defaultdict(list), None
for line in open(args.base):
    if line.startswith("v "):
        V.append([float(x) for x in line.split()[1:4]])
    elif line.startswith("g "):
        cur = line.split()[1]
    elif line.startswith("f "):
        groups[cur].append([int(t.split("/")[0]) - 1 for t in line.split()[1:]])
V = np.array(V)
R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], np.float64)  # MakeHuman y up facing +z; the game z up facing -y
mj = {g[6:]: V[np.unique([i for f in groups[g] for i in f])].mean(0) @ R.T for g in groups if g.startswith("joint-")}
Vg = V @ R.T


def side_pairs(s, S):
    """(game bone, the game's point it points at, MakeHuman joint from, joint to)."""
    out = [(f"Bip01 {S} UpperArm", f"Bip01 {S} Forearm", f"{s}-shoulder", f"{s}-elbow"),
           (f"Bip01 {S} Forearm", f"Bip01 {S} Hand", f"{s}-elbow", f"{s}-hand"),
           (f"Bip01 {S} Thigh", f"Bip01 {S} Calf", f"{s}-upper-leg", f"{s}-knee"),
           (f"Bip01 {S} Calf", f"Bip01 {S} Foot", f"{s}-knee", f"{s}-ankle")]
    for n in range(5):
        f = f"Bip01 {S} Finger{n}"
        out += [(f, f + "1", f"{s}-finger-{n + 1}-1", f"{s}-finger-{n + 1}-2"),
                (f + "1", f + "2", f"{s}-finger-{n + 1}-2", f"{s}-finger-{n + 1}-3"),
                (f + "2", None, f"{s}-finger-{n + 1}-3", f"{s}-finger-{n + 1}-4")]
    return out


PAIRS = side_pairs("l", "L") + side_pairs("r", "R")
# Joints that are the same place on both skeletons: (game bone head, MakeHuman joint).
JOINTS = [("Bip01 Pelvis", "pelvis"), ("Bip01 Neck", "neck"), ("Bip01 Head", "head")]
for s, S in (("l", "L"), ("r", "R")):
    JOINTS += [(f"Bip01 {S} UpperArm", f"{s}-shoulder"), (f"Bip01 {S} Forearm", f"{s}-elbow"),
               (f"Bip01 {S} Hand", f"{s}-hand"), (f"Bip01 {S} Thigh", f"{s}-upper-leg"),
               (f"Bip01 {S} Calf", f"{s}-knee"), (f"Bip01 {S} Foot", f"{s}-ankle")]
    for n in range(5):
        f = f"Bip01 {S} Finger{n}"
        JOINTS += [(f, f"{s}-finger-{n + 1}-1"), (f + "1", f"{s}-finger-{n + 1}-2"), (f + "2", f"{s}-finger-{n + 1}-3")]


def game_end(bone, end):
    return bhead[jb(end)] if end else btail[jb(bone)]


# Size and place: the base body's neck-to-ankles height to the game's, pelvis on pelvis.
def height(p_neck, p_ank_l, p_ank_r):
    return p_neck[2] - (p_ank_l[2] + p_ank_r[2]) / 2


sc = height(bhead[jb("Bip01 Neck")], bhead[jb("Bip01 L Foot")], bhead[jb("Bip01 R Foot")]) / \
    height(mj["neck"], mj["l-ankle"], mj["r-ankle"])
t = bhead[jb("Bip01 Pelvis")] - sc * mj["pelvis"]
mj = {k: sc * v + t for k, v in mj.items()}
Vg = sc * Vg + t


# --- the game's body posed like the base body --------------------------------------------
def rot_between(a, b):
    a, b = a / np.linalg.norm(a), b / np.linalg.norm(b)
    v, c = np.cross(a, b), float(a @ b)
    if np.linalg.norm(v) < 1e-9:
        return np.eye(3)
    K = np.array([[0, -v[2], v[1]], [v[2], 0, -v[0]], [-v[1], v[0], 0]])
    return np.eye(3) + K + K @ K / (1 + c)


aim = {p[0]: p for p in PAIRS}
Rg = [np.eye(3)] * len(bones)
new_head = bhead.copy()


def depth(b):
    d = 0
    while bparent[b] >= 0:
        b, d = bparent[b], d + 1
    return d


for b in sorted(range(len(bones)), key=depth):  # parents first
    p = bparent[b]
    Rp = Rg[p] if p >= 0 else np.eye(3)
    if p >= 0:
        new_head[b] = Rp @ (bhead[b] - bhead[p]) + new_head[p]
    Rg[b] = Rp
    if bones[b] in aim:
        _, end, ma, mb = aim[bones[b]]
        d = Rp @ (game_end(bones[b], end) - bhead[b])
        Rg[b] = rot_between(d, mj[mb] - mj[ma]) @ Rp
W, WB = J["weights"].astype(np.float64), J["weight_bones"]
posed = np.zeros_like(co)
for k in range(4):
    Rk = np.array(Rg)[WB[:, k]]
    posed += W[:, k:k + 1] * (np.einsum("nij,nj->ni", Rk, co - bhead[WB[:, k]]) + new_head[WB[:, k]])
print(f"[fit] {body_name}: game skeleton posed like the base body (scale {sc:.5f})")

# --- the base body warped onto the posed skeleton -----------------------------------------
src = np.array([mj[m] for _, m in JOINTS])
dst = np.array([new_head[jb(g)] for g, _ in JOINTS])
warp = RBFInterpolator(src, dst - src, kernel="thin_plate_spline", smoothing=1e-6)
Vw = Vg + warp(Vg)
print(f"[fit] base joints moved by up to {np.linalg.norm(dst - src, axis=1).max():.4f} onto the game's")

# --- the target: the game's body, welded, posed ----------------------------------------
btris = J["tris"][J["mats"] == bi]
in_garment = np.zeros(len(J["tris"]), bool)
if args.config:
    cfg = load_config(args.config)
    for gname, spec in cfg["garments"].items():
        if spec["material"] == body_name:
            in_garment |= garment_mask(J, spec, cfg["textures"])
fit_tris = np.where((J["mats"] == bi) & ~in_garment)[0]
_, weld = np.unique(np.round(co / 2e-4).astype(np.int64), axis=0, return_inverse=True)
weld = weld.ravel()
first = np.zeros(weld.max() + 1, np.int64)
first[weld[::-1]] = np.arange(len(weld))[::-1]
wtris = weld[btris]
wpos = posed[first]
target = trimesh.Trimesh(wpos, wtris, process=False)
tnorm = target.face_normals
ftris = weld[J["tris"][fit_tris]]  # what the base body is pulled onto
garment_tri = in_garment[J["mats"] == bi]
fnorm = trimesh.Trimesh(wpos, ftris, process=False).face_normals
# Everything else the game draws (the face, the hair, the skirt), posed, for the cut.
others = J["tris"][J["mats"] != bi]
other_mat = J["mats"][J["mats"] != bi]


def closest_on(verts, tris, pts, k=24, normals=None, tri_normals=None):
    """Nearest points on a triangle mesh: (points, distances, triangles), checking the k
    triangles whose centres are nearest. With normals, a triangle facing away from a
    point's normal (more than 70 degrees) is not taken."""
    tri_pts = verts[tris]
    _, cand = cKDTree(tri_pts.mean(1)).query(pts, k=min(k, len(tris)))
    cand = cand.reshape(len(pts), -1)
    best_d = np.full(len(pts), np.inf)
    best_p = pts.copy()
    best_t = np.zeros(len(pts), np.int64)
    for j in range(cand.shape[1]):
        t_ = cand[:, j]
        q = trimesh.triangles.closest_point(tri_pts[t_], pts)
        d = np.linalg.norm(q - pts, axis=1)
        better = d < best_d
        if normals is not None:
            better &= (normals * tri_normals[t_]).sum(1) > 0.35
        best_d[better], best_p[better], best_t[better] = d[better], q[better], t_[better]
    return best_p, best_d, best_t


# --- the cut ---------------------------------------------------------------------------
faces = groups["body"]
cent = np.array([Vw[f].mean(0) for f in faces])
_, d_body, _ = closest_on(wpos, wtris, cent)
_, d_other, t_other = closest_on(posed, others, cent)
ankle_z = max(new_head[jb("Bip01 L Foot")][2], new_head[jb("Bip01 R Foot")][2])
neck_z = new_head[jb("Bip01 Neck")][2]
head_mats = {i for i, n in enumerate(names) if "face" in n.lower() or "hair" in n.lower() or "eye" in n.lower()
             or n.lower() in ("mouth", "upperteeth", "lowerteeth", "molar", "tongue")}
# The boots: the game's body below the top of the boot shafts (the feet are inside).
boot_top = ankle_z + 0.06
keep = []
for k, f in enumerate(faces):
    c = cent[k]
    if c[2] < boot_top:
        continue
    if c[2] > neck_z - 0.02 and other_mat[t_other[k]] in head_mats and d_other[k] < d_body[k]:
        continue
    keep.append(k)
mfaces = [faces[k] for k in keep]
# Only the largest connected piece (cuts can leave islands).
adj = defaultdict(set)
for f in mfaces:
    for a, b in zip(f, f[1:] + f[:1]):
        adj[a].add(b), adj[b].add(a)
best = set()
seen = set()
for s0 in adj:
    if s0 in seen:
        continue
    comp, stack = {s0}, [s0]
    while stack:
        for n_ in adj[stack.pop()]:
            if n_ not in comp:
                comp.add(n_), stack.append(n_)
    seen |= comp
    if len(comp) > len(best):
        best = comp
mfaces = [f for f in mfaces if f[0] in best]
used = np.unique([i for f in mfaces for i in f])
remap = -np.ones(len(V), np.int64)
remap[used] = np.arange(len(used))
mfaces = [[int(remap[i]) for i in f] for f in mfaces]
X = Vw[used].copy()
n = len(X)
print(f"[fit] base body cut to {n} vertices, {len(mfaces)} faces")

# --- the fit ---------------------------------------------------------------------------
edges = set()
for f in mfaces:
    for a, b in zip(f, f[1:] + f[:1]):
        edges.add((min(a, b), max(a, b)))
edges = np.array(sorted(edges))
ne = len(edges)
D = sp.csr_matrix((np.r_[np.ones(ne), -np.ones(ne)], (np.r_[np.arange(ne), np.arange(ne)], np.r_[edges[:, 0], edges[:, 1]])),
                  shape=(ne, n))
rest_edges = D @ X
tri_faces = np.array([[f[0], f[i], f[i + 1]] for f in mfaces for i in range(1, len(f) - 1)])


def vertex_normals(P):
    fn = np.cross(P[tri_faces[:, 1]] - P[tri_faces[:, 0]], P[tri_faces[:, 2]] - P[tri_faces[:, 0]])
    vn = np.zeros_like(P)
    for c in range(3):
        np.add.at(vn, tri_faces[:, c], fn)
    return vn / (np.linalg.norm(vn, axis=1, keepdims=True) + 1e-12)


scale = np.ptp(wpos, axis=0).max()
near = 0.008 * scale
for stiff in [8.0, 4.0, 2.0, 1.0, args.stiff]:
    for _ in range(3):
        vn = vertex_normals(X)
        cp, dist, _ = closest_on(wpos, ftris, X, normals=vn, tri_normals=fnorm)
        # Under a garment (nearest to it on the whole body) nothing pulls: the base body's own shape.
        _, _, tall = closest_on(wpos, wtris, X, normals=vn, tri_normals=tnorm)
        free = garment_tri[tall]
        w = np.where(np.isfinite(dist) & ~free, 1.0 / (1.0 + (np.nan_to_num(dist, posinf=1e9) / near) ** 2), 0.0)
        A = sp.vstack([np.sqrt(stiff) * D, sp.diags(np.sqrt(w))]).tocsc()
        solve = spl.factorized((A.T @ A).tocsc())
        for k in range(3):
            X[:, k] = solve(A.T @ np.r_[np.sqrt(stiff) * rest_edges[:, k], np.sqrt(w) * cp[:, k]])
    ok = np.isfinite(dist) & ~free
    print(f"[fit] stiffness {stiff}: distance to the body median {np.median(dist[ok]) / scale * 1000:.2f}, "
          f"90% {np.percentile(dist[ok], 90) / scale * 1000:.2f} (thousandths of the height); under garments {free.sum()}")

# The boots stay the game's: the body's separate pieces wholly below the knees.
comp = np.arange(len(wpos))


def croot(i):
    while comp[i] != i:
        comp[i] = comp[comp[i]]
        i = comp[i]
    return i


for tt in wtris:
    for v in tt[1:]:
        comp[croot(tt[0])] = croot(v)
tri_comp = np.array([croot(tt[0]) for tt in wtris])
knee_z = min(new_head[jb("Bip01 L Calf")][2], new_head[jb("Bip01 R Calf")][2])
comp_top = {c: wpos[wtris[tri_comp == c]][..., 2].max() for c in np.unique(tri_comp)}
is_boot = np.array([comp_top[c] < knee_z for c in tri_comp])

# --- bound to the game's body ------------------------------------------------------------
# Not to the boots: the legs end inside them.
legs_and_up = np.where(~is_boot)[0]
cp, dist, tri = closest_on(wpos, wtris[legs_and_up], X)
tri = legs_and_up[tri]
bary = trimesh.triangles.points_to_barycentric(wpos[wtris[tri]], cp)


def frames(tp):
    e1 = tp[:, 1] - tp[:, 0]
    nrm = np.cross(e1, tp[:, 2] - tp[:, 0])
    e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    return np.stack([e1, np.cross(nrm, e1), nrm], 1)


offset = np.einsum("nij,nj->ni", frames(wpos[wtris[tri]]), X - cp)
# The rest position: the same binding on the game's body at rest.
rest = co[first]
Xr = (rest[wtris[tri]] * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", frames(rest[wtris[tri]]), offset)
back = (wpos[wtris[tri]] * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", frames(wpos[wtris[tri]]), offset)
err = np.linalg.norm(back - X, axis=1)

# UVs per corner on the body's texture, one texture piece per triangle (as fit_head.py).
body_uvs = J["uvs"][J["mats"] == bi].astype(np.float64)
parent = np.arange(len(co))


def root(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i


for tt in btris:
    for v in tt[1:]:
        a, b = root(tt[0]), root(v)
        parent[a] = b
piece = np.array([root(tt[0]) for tt in btris])
# Colour from skin only: a vertex bound to a garment's triangle (it lies under the
# garment, or beside its edge) takes its UV from the nearest skin instead, so no
# garment's colour shows on the body where the two meet.
skin = np.where(~garment_tri & ~is_boot)[0]
uv_tri, uv_bary = tri.copy(), bary.copy()
on_garment = garment_tri[tri]
if on_garment.any():
    q, _, t2 = closest_on(wpos, wtris[skin], X[on_garment])
    uv_tri[on_garment] = skin[t2]
    uv_bary[on_garment] = trimesh.triangles.points_to_barycentric(wpos[wtris[skin[t2]]], q)
tri_b, bary_b = tri, bary
tri, bary = uv_tri, uv_bary
uvs = np.zeros((len(tri_faces), 3, 2))
for k, f in enumerate(tri_faces):
    ps = piece[tri[f]]
    vals, counts = np.unique(ps, return_counts=True)
    own = vals[np.argmax(counts)]
    for c, v in enumerate(f):
        tt, bb = tri[v], bary[v]
        if piece[tt] != own:
            sel = np.where((piece == own) & ~is_boot & ~garment_tri)[0]
            q, _, t2 = closest_on(wpos, wtris[sel], X[v][None])
            tt = sel[t2[0]]
            bb = trimesh.triangles.points_to_barycentric(wpos[wtris[tt]][None], q)[0]
        uvs[k, c] = bb @ body_uvs[tt]
tri, bary = tri_b, bary_b
print(f"[fit] rebuilt body: {len(Xr)} vertices, {len(tri_faces)} triangles (the game's body: "
      f"{len(wpos)}, {len(wtris)}); binding error max {err.max() / scale * 1000:.4f}")
np.savez_compressed(args.out, verts=Xr.astype(np.float32), tris=tri_faces.astype(np.int32),
                    bind_tri=btris[tri].astype(np.int32), uvs=uvs.astype(np.float32), bind_bary=bary.astype(np.float32),
                    bind_off=offset.astype(np.float32), bind_err=err.astype(np.float32),
                    posed=X.astype(np.float32), game_posed=posed.astype(np.float32),
                    hide=np.where(J["mats"] == bi)[0][~is_boot].astype(np.int32))
print(f"[fit] -> {args.out}")
