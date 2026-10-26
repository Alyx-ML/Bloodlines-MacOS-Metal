#!/usr/bin/env python3
"""A character's head rebuilt on MakeHuman's base head (CC0), fitted to the game's face.

    fit_head.py SRC.npz BASE.obj OUT.npz [--face MATERIAL] [--stiff S]

SRC.npz comes from export_head.py; BASE.obj is MakeHuman's base mesh
(makehuman/data/3dobjs/base.obj). The base head is
 1. cut from the body above the neck, with openings where its eyeballs and mouth are
    (it is closed there),
 2. moved onto the game's head by its eyes and mouth (a similarity),
 3. pulled onto the game's face surface: each round every vertex goes to its nearest
    point on the face, the openings' edges to the game's eye and mouth openings, while
    each edge keeps close to its own direction and length in the base head (weight S,
    lowered round by round to --stiff, default 0.5: lower follows the game's shape
    closer, higher keeps more of the base head's own detail),
 4. trimmed to the part of the head the game's face covers (the rest lies under the
    hair or the body), its new edge moved onto the face's edge.
Each vertex is then bound to the game's face: a triangle, a place in it and an offset
in the triangle's own axes, so it follows the face through every bone and flex, as the hair
strips do. OUT.npz: verts, tris, bind_tri (the game's vertex indices), bind_bary,
bind_off, the binding's error per vertex (how far the rest pose moves), and uvs per
triangle corner on the game's face texture.
"""
import argparse
from collections import defaultdict

import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spl
import trimesh
from scipy.spatial import cKDTree

ap = argparse.ArgumentParser()
ap.add_argument("src")
ap.add_argument("base")
ap.add_argument("out")
ap.add_argument("--face", default=None, help="the face material (default: the one with 'face' in its name)")
ap.add_argument("--stiff", type=float, default=0.5)
args = ap.parse_args()

# --- the game's face ---------------------------------------------------------------
J = np.load(args.src)
names = list(J["mat_names"])
face_name = args.face or next(n for n in names if "face" in n.lower())
fi = names.index(face_name)
co = J["co"].astype(np.float64)
ftris = J["tris"][J["mats"] == fi]
# The import splits vertices along UV seams: welded, the face is one surface.
_, weld = np.unique(np.round(co / 2e-4).astype(np.int64), axis=0, return_inverse=True)
weld = weld.ravel()
first = np.zeros(weld.max() + 1, np.int64)
first[weld[::-1]] = np.arange(len(weld))[::-1]  # a game vertex for each welded one
wtris = weld[ftris]
wco = co[first]
face = trimesh.Trimesh(wco, wtris, process=False)


def closest_on(verts, tris, pts, k=24):
    """Nearest points on a triangle mesh: (points, distances, triangles), checking the k
    triangles whose centres are nearest (the face's triangles are small and even)."""
    tri_pts = verts[tris]
    _, cand = cKDTree(tri_pts.mean(1)).query(pts, k=min(k, len(tris)))
    cand = cand.reshape(len(pts), -1)
    best_d = np.full(len(pts), np.inf)
    best_p = np.zeros_like(pts)
    best_t = np.zeros(len(pts), np.int64)
    for j in range(cand.shape[1]):
        t = cand[:, j]
        q = trimesh.triangles.closest_point(tri_pts[t], pts)
        d = np.linalg.norm(q - pts, axis=1)
        better = d < best_d
        best_d[better], best_p[better], best_t[better] = d[better], q[better], t[better]
    return best_p, best_d, best_t


class _Face:
    def __call__(self, pts):
        return closest_on(wco, wtris, pts)


face_closest = _Face()


def material_centre(name):
    i = names.index(name)
    return co[np.unique(J["tris"][J["mats"] == i])].mean(0)


def boundary_loops(faces):
    count = defaultdict(int)
    for f in faces:
        for a, b in zip(f, list(f[1:]) + [f[0]]):
            count[(min(a, b), max(a, b))] += 1
    adj = defaultdict(list)
    for (a, b), c in count.items():
        if c == 1:
            adj[a].append(b), adj[b].append(a)
    seen, out = set(), []
    for s in adj:
        if s in seen:
            continue
        loop, prev, cur = [s], None, s
        seen.add(s)
        while True:
            nxt = [n for n in adj[cur] if n != prev and n not in seen]
            if not nxt:
                break
            prev, cur = cur, nxt[0]
            loop.append(cur), seen.add(cur)
        out.append(loop)
    return out


eye_names = [n for n in names if n.lower().startswith("eyeball")]
j_eye = {n: material_centre(n) for n in eye_names}
j_eye_l = max(j_eye.values(), key=lambda c: c[0])
j_eye_r = min(j_eye.values(), key=lambda c: c[0])
j_mouth = (material_centre("upperteeth") + material_centre("lowerteeth")) / 2
j_loops = boundary_loops([list(t) for t in wtris])


def nearest_loop(loops, pts, centre):
    return min(loops, key=lambda L: np.linalg.norm(pts[L].mean(0) - centre))


jl_eye_l = nearest_loop(j_loops, wco, j_eye_l)
jl_eye_r = nearest_loop(j_loops, wco, j_eye_r)
jl_mouth = nearest_loop(j_loops, wco, j_mouth)
j_outer = [L for L in j_loops if L not in (jl_eye_l, jl_eye_r, jl_mouth)]
print(f"[fit] {face_name}: {len(wco)} vertices welded, {len(wtris)} triangles, openings: eyes "
      f"{len(jl_eye_l)}/{len(jl_eye_r)}, mouth {len(jl_mouth)}, outer {[len(L) for L in j_outer]}")

# --- MakeHuman's head -----------------------------------------------------------------
V, groups, cur = [], defaultdict(list), None
for line in open(args.base):
    if line.startswith("v "):
        V.append([float(x) for x in line.split()[1:4]])
    elif line.startswith("g "):
        cur = line.split()[1]
    elif line.startswith("f "):
        groups[cur].append([int(t.split("/")[0]) - 1 for t in line.split()[1:]])
V = np.array(V)


def group_centre(g):
    return V[np.unique([i for f in groups[g] for i in f])].mean(0)


m_eye_l, m_eye_r = group_centre("helper-l-eye"), group_centre("helper-r-eye")
m_eye_rad = np.ptp(V[np.unique([i for f in groups["helper-l-eye"] for i in f])], axis=0).max() / 2
upper_teeth = V[np.unique([i for f in groups["helper-upper-teeth"] for i in f])]
m_mouth = (upper_teeth.mean(0) + group_centre("helper-lower-teeth")) / 2
teeth_front = upper_teeth[:, 2].max()

# Above the neck; not on or inside the eyeballs (the lids' edges and the sockets behind
# them); not the mouth's inside: everything reached from behind the teeth without
# crossing a face that looks forward (the lips' outsides and the cheeks stop it, so the
# opening's edge is where the lips meet).
def normal_z(f):
    p = V[f]
    nz = np.cross(p[1] - p[0], p[2] - p[0])
    return nz[2] / (np.linalg.norm(nz) + 1e-12)


head = []
for f in groups["body"]:
    p = V[f]
    if p[:, 1].min() < 5.8:
        continue
    if min(np.linalg.norm(p.mean(0) - m_eye_l), np.linalg.norm(p.mean(0) - m_eye_r)) < m_eye_rad * 1.03:
        continue
    head.append(f)
by_vert = defaultdict(list)
for k, f in enumerate(head):
    for i in f:
        by_vert[i].append(k)
inside = np.array([V[f].mean(0) for f in head])
seed = int(np.argmin(np.linalg.norm(inside - (m_mouth * [0, 1, 0] + [0, 0, teeth_front - 0.3]), axis=1)))
mouth_in, stack = {seed}, [seed]
while stack:
    for i in head[stack.pop()]:
        for k in by_vert[i]:
            if k not in mouth_in and normal_z(head[k]) < 0.3 and abs(inside[k][0]) < 0.45:
                mouth_in.add(k), stack.append(k)
head = [f for k, f in enumerate(head) if k not in mouth_in]
used = np.unique([i for f in head for i in f])
remap = -np.ones(len(V), np.int64)
remap[used] = np.arange(len(used))
mfaces = [[remap[i] for i in f] for f in head]
P0 = V[used]
# Only the surface reachable from the face (the cuts can leave islands inside).
adj = defaultdict(set)
for f in mfaces:
    for a, b in zip(f, f[1:] + f[:1]):
        adj[a].add(b), adj[b].add(a)
start = int(np.argmax(P0[:, 2]))  # the nose tip
keep, stack = {start}, [start]
while stack:
    for n in adj[stack.pop()]:
        if n not in keep:
            keep.add(n), stack.append(n)
mfaces = [f for f in mfaces if f[0] in keep]
used2 = np.unique([i for f in mfaces for i in f])
remap2 = -np.ones(len(P0), np.int64)
remap2[used2] = np.arange(len(used2))
mfaces = [[remap2[i] for i in f] for f in mfaces]
P0 = P0[used2]
m_loops = boundary_loops(mfaces)

# MakeHuman: y up, facing +z, decimetres. The game: z up, facing -y.
R = np.array([[1, 0, 0], [0, 0, -1], [0, 1, 0]], np.float64)
src_pts = np.array([m_eye_l, m_eye_r, m_mouth]) @ R.T
dst_pts = np.array([j_eye_l, j_eye_r, j_mouth])
sc = np.linalg.norm(dst_pts[0] - dst_pts[1]) / np.linalg.norm(src_pts[0] - src_pts[1])
t = dst_pts.mean(0) - sc * src_pts.mean(0)
P = sc * P0 @ R.T + t
ml_eye_l = nearest_loop(m_loops, P, j_eye_l)
ml_eye_r = nearest_loop(m_loops, P, j_eye_r)
ml_mouth = nearest_loop(m_loops, P, j_mouth)
print(f"[fit] base head: {len(P)} vertices, {len(mfaces)} faces, scale {sc:.4f}, openings: eyes "
      f"{len(ml_eye_l)}/{len(ml_eye_r)}, mouth {len(ml_mouth)}, others {[len(L) for L in m_loops if L not in (ml_eye_l, ml_eye_r, ml_mouth)]}")


def loop_targets(src_loop, dst_loop, src, dst):
    """Each vertex of a source opening's edge to the same angle round the game's one
    (seen from the front), on its edge."""
    s, d = src[src_loop], dst[dst_loop]
    sc_, dc = s.mean(0), d.mean(0)
    sa = np.arctan2(s[:, 2] - sc_[2], s[:, 0] - sc_[0])
    da = np.arctan2(d[:, 2] - dc[2], d[:, 0] - dc[0])
    order = np.argsort(da)
    da, d = da[order], d[order]
    da = np.concatenate([da - 2 * np.pi, da, da + 2 * np.pi])
    d = np.concatenate([d, d, d])
    out = np.empty_like(s)
    for k in range(3):
        out[:, k] = np.interp(sa, da, d[:, k])
    return out


def lip_chains(loop, pts):
    """A mouth opening's edge as its upper and lower lips' chains, each running from the
    corner at lower x to the one at higher x."""
    loop = list(loop)
    a = int(np.argmin(pts[loop, 0]))
    loop = loop[a:] + loop[:a]
    b = int(np.argmax(pts[loop, 0]))
    one, two = loop[:b + 1], [loop[0]] + loop[b:][::-1]
    return (one, two) if pts[one, 2].mean() > pts[two, 2].mean() else (two, one)


def along(chain, pts):
    d = np.r_[0, np.cumsum(np.linalg.norm(np.diff(pts[chain], axis=0), axis=1))]
    return d / d[-1]


def chain_targets(src_loop, dst_loop, src, dst):
    """Each vertex of the base head's lip edge to the same place along the game's lip
    edge (upper to upper, lower to lower), corner to corner."""
    out = {}
    for sc_, dc in zip(lip_chains(src_loop, src), lip_chains(dst_loop, dst)):
        u, du = along(sc_, src), along(dc, dst)
        for v, uu in zip(sc_, u):
            out[v] = [np.interp(uu, du, dst[dc, k]) for k in range(3)]
    return np.array([out[v] for v in src_loop])


def lip_mid_z(loop, pts, x):
    """Height of the line between the lips at each x (outside the corners: the corners')."""
    up, lo = lip_chains(loop, pts)
    return (np.interp(x, pts[up, 0], pts[up, 2]) + np.interp(x, pts[lo, 0], pts[lo, 2])) / 2


# --- the fit ------------------------------------------------------------------------------
edges = set()
for f in mfaces:
    for a, b in zip(f, f[1:] + f[:1]):
        edges.add((min(a, b), max(a, b)))
edges = np.array(sorted(edges))
n, ne = len(P), len(edges)
D = sp.csr_matrix((np.r_[np.ones(ne), -np.ones(ne)], (np.r_[np.arange(ne), np.arange(ne)], np.r_[edges[:, 0], edges[:, 1]])),
                  shape=(ne, n))
rest_edges = D @ P  # the base head's own edges, kept as far as the stiffness asks

open_src = list(ml_eye_l) + list(ml_eye_r) + list(ml_mouth)
open_dst = np.vstack([loop_targets(ml_eye_l, jl_eye_l, P, wco), loop_targets(ml_eye_r, jl_eye_r, P, wco),
                      chain_targets(ml_mouth, jl_mouth, P, wco)])
is_open = np.zeros(n, bool)
is_open[open_src] = True

# Which lip each base vertex belongs to, from the base head's own lips (before the fit).
upper_side = P[:, 2] > lip_mid_z(ml_mouth, P, P[:, 0])
X = P.copy()
for stiff in [8.0, 4.0, 2.0, 1.0, args.stiff]:
    for _ in range(3):
        cp, dist, _ = face_closest(X)
        w = np.where(is_open, 0.0, 1.0 / (1.0 + (dist / 0.01) ** 2))  # far points pull less (the scalp under the hair)
        rows = [np.sqrt(stiff) * D, sp.diags(np.sqrt(w)), sp.csr_matrix((np.full(len(open_src), 10.0), (np.arange(len(open_src)), open_src)), shape=(len(open_src), n))]
        A = sp.vstack(rows).tocsc()
        solve = spl.factorized((A.T @ A).tocsc())
        for k in range(3):
            b = np.r_[np.sqrt(stiff) * rest_edges[:, k], np.sqrt(w) * cp[:, k], 10.0 * open_dst[:, k]]
            X[:, k] = solve(A.T @ b)
    cp, dist, _ = face_closest(X)
    print(f"[fit] stiffness {stiff}: distance to the face median {np.median(dist) * 1000:.2f} mm-units, 90% {np.percentile(dist, 90) * 1000:.2f}")

# Where the base head folds over on the game's face (detail the game's face is too coarse
# for: the ears, the nostrils, the lids' corners), its own shape is kept instead: those
# vertices and two rings round them stop following the face.
free = np.zeros(n, bool)
for _ in range(4):
    cp, dist, tri = face_closest(X)
    fn = np.array([np.cross(X[f[1]] - X[f[0]], X[f[2]] - X[f[0]]) for f in mfaces])
    fn /= np.linalg.norm(fn, axis=1, keepdims=True) + 1e-12
    gn = np.array([face.face_normals[tri[f]].mean(0) for f in mfaces])
    folded = (fn * gn).sum(1) < 0.2
    print(f"[fit] folded faces: {folded.sum()}")
    if not folded.any():
        break
    for k in np.where(folded)[0]:
        free[mfaces[k]] = True
    for _ring in range(2):
        grow = free.copy()
        for a, b in edges:
            if free[a] or free[b]:
                grow[a] = grow[b] = True
        free = grow
    for _it in range(3):
        cp, dist, _ = face_closest(X)
        w = np.where(is_open | free, 0.0, 1.0 / (1.0 + (dist / 0.01) ** 2))
        A = sp.vstack([np.sqrt(args.stiff) * D, sp.diags(np.sqrt(w)), sp.csr_matrix((np.full(len(open_src), 10.0), (np.arange(len(open_src)), open_src)), shape=(len(open_src), n))]).tocsc()
        solve = spl.factorized((A.T @ A).tocsc())
        for k in range(3):
            b = np.r_[np.sqrt(args.stiff) * rest_edges[:, k], np.sqrt(w) * cp[:, k], 10.0 * open_dst[:, k]]
            X[:, k] = solve(A.T @ b)

# --- trimmed to what the face covers -------------------------------------------------------
cp, dist, tri = face_closest(X)
normal = face.face_normals[tri]
off = X - cp
along = np.abs((off * normal).sum(1))
outside = (dist > 0.0015) & (along < 0.7 * dist)  # beside the face's edge, not over it
tri_faces = []
for f in mfaces:
    if outside[f].any():
        continue
    tri_faces += [[f[0], f[i], f[i + 1]] for i in range(1, len(f) - 1)]
tri_faces = np.array(tri_faces)
used3 = np.unique(tri_faces)
remap3 = -np.ones(n, np.int64)
remap3[used3] = np.arange(len(used3))
tri_faces = remap3[tri_faces]
X = X[used3]
# The new outer edge onto the face's outer edge (the openings keep theirs).
outer_pts = np.vstack([wco[L] for L in j_outer])
new_loops = boundary_loops([list(f) for f in tri_faces])
is_open3 = is_open[used3]
for L in new_loops:
    if is_open3[L].mean() > 0.5:
        continue
    for v in L:
        X[v] = outer_pts[np.argmin(np.linalg.norm(outer_pts - X[v], axis=1))] * 0.5 + X[v] * 0.5
        X[v] = face_closest(X[v][None])[0][0]

# --- bound to the face ------------------------------------------------------------------
cp, dist, tri = face_closest(X)
# Lips: a vertex of the base head's upper lip binds to the game's upper lip, of its lower
# lip to the lower one, so the mouth opens between them.
mouth_w = np.ptp(wco[jl_mouth][:, 0])
near_mouth = (np.abs(X[:, 0] - j_mouth[0]) < mouth_w * 0.75) & (np.abs(X[:, 2] - j_mouth[2]) < 0.012) & (X[:, 1] < j_mouth[1] + 0.01)
tri_c = wco[wtris].mean(1)
tri_upper = tri_c[:, 2] > lip_mid_z(jl_mouth, wco, tri_c[:, 0])
tri_far = np.abs(tri_c[:, 0] - j_mouth[0]) > mouth_w
for side in (True, False):
    sel = np.where(near_mouth & (upper_side[used3] == side))[0]
    if not len(sel):
        continue
    ok = (tri_upper == side) | tri_far
    c2, d2, t2 = closest_on(wco, wtris[ok], X[sel])
    cp[sel], dist[sel], tri[sel] = c2, d2, np.where(ok)[0][t2]
bary = trimesh.triangles.points_to_barycentric(wco[wtris[tri]], cp)


def frames(t):
    """Each triangle's own axes: along its first edge, across it, and its normal."""
    e1 = t[:, 1] - t[:, 0]
    nrm = np.cross(e1, t[:, 2] - t[:, 0])
    e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    return np.stack([e1, np.cross(nrm, e1), nrm], 1)


# The offset in the triangle's own axes (not only along its normal): exact at rest, and
# turned with the triangle as it moves.
F = frames(wco[wtris[tri]])
offset = np.einsum("nij,nj->ni", F, X - cp)
rebuilt = (wco[wtris[tri]] * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", F, offset)
err = np.linalg.norm(rebuilt - X, axis=1)

# UVs per corner, from the face's texture where each corner is bound. The face's texture
# comes in pieces (the import splits vertices at their edges: triangles joined by shared
# unwelded vertices are one piece). A triangle takes the piece most of its corners lie on,
# and a corner bound elsewhere is found again on that piece, so no triangle spans two.
face_uvs = J["uvs"][J["mats"] == fi].astype(np.float64)
piece = np.arange(len(ftris))
parent = np.arange(J["co"].shape[0])


def root(i):
    while parent[i] != i:
        parent[i] = parent[parent[i]]
        i = parent[i]
    return i


for t in ftris:
    for v in t[1:]:
        a, b = root(t[0]), root(v)
        parent[a] = b
piece = np.array([root(t[0]) for t in ftris])
uvs = np.zeros((len(tri_faces), 3, 2))
for k, f in enumerate(tri_faces):
    ps = piece[tri[f]]
    vals, counts = np.unique(ps, return_counts=True)
    own = vals[np.argmax(counts)]
    for c, v in enumerate(f):
        t, bb = tri[v], bary[v]
        if piece[t] != own:
            sel = np.where(piece == own)[0]
            q, _, t2 = closest_on(wco, wtris[sel], X[v][None])
            t = sel[t2[0]]
            bb = trimesh.triangles.points_to_barycentric(wco[wtris[t]][None], q)[0]
        uvs[k, c] = bb @ face_uvs[t]
print(f"[fit] rebuilt head: {len(X)} vertices, {len(tri_faces)} triangles (the game's face: {len(wco)}, "
      f"{len(wtris)}); binding error max {err.max() * 1000:.3f}")
np.savez_compressed(args.out, verts=X.astype(np.float32), tris=tri_faces.astype(np.int32),
                    bind_tri=ftris[tri].astype(np.int32), uvs=uvs.astype(np.float32), bind_bary=bary.astype(np.float32),
                    bind_off=offset.astype(np.float32), bind_err=err.astype(np.float32))
print(f"[fit] -> {args.out}")
