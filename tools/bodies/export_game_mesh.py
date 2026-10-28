#!/usr/bin/env python3
"""A character's rebuilt parts as the files the game draws them from (runtime/d3d9/char_remodel.c).

    export_game_mesh.py CHAR.json SRC.npz PART_DIR

PART_DIR holds the parts (make_lod.py's light ones, named <character>_<part>.npz; the head
from there too). Each part goes with the game's texture its binding triangles use; for
each such texture, <textures>/<texture>_mesh.bin beside its normal map, in the game's
model space (the config's "model", the .mdl the import came from: its scale, and the
anchors set exactly on its vertices), with the game's winding and texture rows:

    "BLBM", version 4, then u32 vertex, index, anchor, binding, kept, bone and strip counts;
    per vertex: position xyz, normal xyz, uv, u32 binding, barycentric xyz, 4 bones (u8)
        and their weights (68 bytes);
    u32 indices, 3 per triangle;
    per triangle: u32 binding whose game triangle's draw draws it;
    anchors: xyz, every vertex of the game's triangles with this texture;
    bindings: 3 u32 anchors per game triangle the vertices are bound to;
    per binding: u32 strip its game triangle is drawn in;
    kept: xyz, the centres of the game's triangles with this texture still drawn;
    per anchor: its 4 bones (u8) and weights (20 bytes);
    per bone: its parent (i32, -1 for the root);
    per strip: the model bone in each of its 32 slots (i16, -1 for none).

Bones are the model's own; the game draws a texture's triangles in pieces (the .vtx's
strips), each with a few of them loaded in its own slots, as the file gives them (the
.vtx's bone changes). A vertex's bones are its binding triangle's corners',
blended by its barycentric weights. Each new triangle goes to the strip that has the
most of its corners' bones loaded (named by one of that strip's triangles), and a
vertex whose triangles go to several strips keeps only bones all of them load (the rest
on their nearest such parent), so it moves alike in each. The parts are drawn in place
of the game's triangles with this texture, except the kept ones (none hidden by any part's "hide"; a part without "hide"
replaces the whole texture). A part in the config's "keep_game" list is not drawn: the
game's own triangles it would replace (its "hide") are kept instead (make_lod.py pushes
the body in behind them).

Only textures the game skins on the graphics card, without flexes (the .dx80.vtx beside
the model: every strip group of its mesh hardware-skinned, flag 2, and not flexed, flag
1) are exported: the game rewrites the others' vertices every frame, already posed.
"""
import os
import struct
import sys

import numpy as np
from garments import load_config
from scipy.spatial import cKDTree

cfg_path, src_path, part_dir = (os.path.abspath(a) for a in sys.argv[1:4])
os.chdir(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
cfg = load_config(cfg_path)
name = os.path.splitext(os.path.basename(cfg_path))[0]
J = np.load(src_path)
co, gtris, gmats = J["co"].astype(np.float64), J["tris"], J["mats"]
mat_names = [str(m) for m in J["mat_names"]]

# The game's model space: the .mdl's vertices (a body part's model; 44-byte vertices,
# position at 12), which the import scaled.
mdl = open(cfg["model"], "rb").read()
bpo = struct.unpack_from("<i", mdl, 324)[0]
mo = bpo + struct.unpack_from("<i", mdl, bpo + 12)[0]
nmesh, mesho, nvert, verto = struct.unpack_from("<iiii", mdl, mo + 136)
P = np.frombuffer(mdl, np.float32, nvert * 11, mo + verto).reshape(nvert, 11)[:, 3:6].astype(np.float64)
k = cKDTree(P).query(co * P[:, 2].max() / co[:, 2].max())[1]
scale = (co * P[k]).sum() / (co * co).sum()
d, k = cKDTree(P).query(co * scale)
if d.max() > 0.01:
    sys.exit(f"[export] the import is not {cfg['model']} scaled: a vertex is {d.max():.3f} from the model's")
game_pos = P[k]  # each import vertex exactly where the model has it
print(f"[export] model space: {scale:.6f} per import unit")
# Bones and weights as the game has them (the import's are not: a decompile evens them
# out): a vertex's first 12 bytes are 3 weights (u8, of 255), a byte, 3 bones (i16); the
# bones (count at 240, 160 bytes each from the offset at 244) give their parent at 4.
raw = np.frombuffer(mdl, np.uint8, nvert * 44, mo + verto).reshape(nvert, 44)
W = raw[k, :3].astype(np.float64) / 255
WB = raw[k, 4:10].copy().view(np.int16).astype(np.int64)
W, WB = np.concatenate([W, np.zeros((len(k), 1))], 1), np.concatenate([WB, WB[:, :1]], 1)
nbones, boneo = struct.unpack_from("<ii", mdl, 240)
parents = np.array([struct.unpack_from("<i", mdl, boneo + i * 160 + 4)[0] for i in range(nbones)])
WB[W <= 0] = WB[:, :1].repeat(4, 1)[W <= 0]  # unused slots: the first bone, weight 0
if (WB < 0).any() or (WB >= nbones).any() or W.sum(1).min() < 0.5:
    sys.exit("[export] the model's bone weights are not as expected (3 bytes of weights, 3 i16 bones)")
W /= W.sum(1, keepdims=True)  # a few add up to a little less

# Which textures' meshes the game skins on the graphics card (.vtx: LOD 0's meshes, 8
# bytes each, the strip group count in the low half of the first; strip groups of 20
# bytes, flags at 6).
vtx = open(os.path.splitext(cfg["model"])[0] + ".dx80.vtx", "rb").read()
ntex, texo = struct.unpack_from("<ii", mdl, 292)
texname = [mdl[o:mdl.index(b"\0", o)].decode()
           for o in (texo + i * 20 + struct.unpack_from("<i", mdl, texo + i * 20)[0] for i in range(ntex))]
nref, _, skino = struct.unpack_from("<iii", mdl, 308)
skin = struct.unpack_from(f"<{nref}h", mdl, skino)
vbp = struct.unpack_from("<i", vtx, 32)[0]
vmo = vbp + struct.unpack_from("<i", vtx, vbp + 4)[0]
lod = vmo + struct.unpack_from("<i", vtx, vmo + 4)[0]
vmesho = struct.unpack_from("<i", vtx, lod + 4)[0]
# A strip group: u16 vertex, index and strip counts, flags, a byte, then i32 offsets (from
# it) of its vertices (12 bytes, the mesh's vertex at 10), u16 indices and strips. A
# strip (16 bytes): u16 index count and start, vertex count and start, 2 bytes, u16
# bone count, i32 offset (from it) of its bones (u16 slot, u16 model bone).
on_gpu, strips = {}, {}
for m in range(nmesh):
    mm = mo + mesho + m * 60
    tex = texname[skin[struct.unpack_from("<i", mdl, mm)[0]]].lower()
    vbase = struct.unpack_from("<i", mdl, mm + 12)[0]
    vm = lod + vmesho + m * 8
    ng, go = struct.unpack_from("<ii", vtx, vm)
    for g in range(ng & 0xFFFF):
        sg = vm + go + g * 20
        nv_, ni_, ns_, flags, _, vo, io, so = struct.unpack_from("<HHHBBiii", vtx, sg)
        on_gpu[tex] = on_gpu.get(tex, True) and bool(flags & 2) and not flags & 1
        orig = np.frombuffer(vtx, np.uint16, nv_ * 6, sg + vo).reshape(nv_, 6)[:, 5].astype(np.int64) + vbase
        sidx = np.frombuffer(vtx, np.uint16, ni_, sg + io)
        for st in range(ns_):
            a = sg + so + st * 16
            nidx, ioff, _, _, _, _, nbs, bso = struct.unpack_from("<HHHHBBHi", vtx, a)
            pal = dict(struct.unpack_from("<HH", vtx, a + bso + j * 4) for j in range(nbs))
            if max(pal, default=0) >= 32:
                sys.exit(f"[export] {tex}: a strip with a bone slot past 32")
            strips.setdefault(tex, []).append((pal, P[orig[sidx[ioff:ioff + nidx]].reshape(-1, 3)].mean(1)))

tri_mat = {tuple(sorted(t)): m for t, m in zip(gtris, gmats)}
tri_of = {tuple(sorted(t)): t for t in gtris}  # as the import winds it (bindings may be sorted)
tri_id = {tuple(sorted(t)): i for i, t in enumerate(gtris)}
groups = {}
for f in sorted(os.listdir(part_dir)):
    if not (f.startswith(name + "_") and f.endswith(".npz")):
        continue
    D = np.load(os.path.join(part_dir, f))
    m = np.bincount([tri_mat[tuple(sorted(b))] for b in D["bind_tri"]], minlength=len(mat_names)).argmax()
    groups.setdefault(m, []).append((f[len(name) + 1:-4], D))


def blend_bones(corners, bary):
    """The 4 strongest bones of a point bound to `corners` (import vertices) and weights."""
    acc = {}
    for c, b in zip(corners, bary):
        for w, bone in zip(W[c], WB[c]):
            if w > 0:
                acc[int(bone)] = acc.get(int(bone), 0.0) + w * b
    top = sorted(acc.items(), key=lambda x: -x[1])[:4]
    total = sum(w for _, w in top)
    top += [(top[0][0], 0.0)] * (4 - len(top))
    return [b for b, _ in top], [w / total for _, w in top]


for m, parts in groups.items():
    tex = mat_names[m]
    out = os.path.join(cfg["textures"], f"{tex}_mesh.bin")
    if not on_gpu.get(tex.lower(), False):
        print(f"[export] {tex}: the game poses it on the CPU (flexes, or too many bones), not exported")
        if os.path.exists(out):
            os.remove(out)
        continue
    mtris = np.where(gmats == m)[0]
    # Each of the texture's game triangles' strip, by its centre.
    st_slots = [pal for pal, _ in strips[tex.lower()]]
    st_pal = [set(pal.values()) for pal in st_slots]
    st_cent = np.concatenate([c for _, c in strips[tex.lower()]])
    st_num = np.concatenate([np.full(len(c), i) for i, (_, c) in enumerate(strips[tex.lower()])])
    d, j = cKDTree(st_cent).query(game_pos[gtris[mtris]].mean(1))
    if d.max() > 0.01 or len(st_cent) != len(mtris):
        sys.exit(f"[export] {tex}: the .vtx's strips are not the model's triangles")
    strip_of = -np.ones(len(gtris), np.int64)
    strip_of[mtris] = st_num[j]
    st_tris = [mtris[st_num[j] == i] for i in range(len(st_pal))]
    anchors = np.unique(gtris[mtris])
    anchor_of = -np.ones(len(co), np.int64)
    anchor_of[anchors] = np.arange(len(anchors))
    hidden, whole = set(), False
    binds, bind_id, bind_strip = [], {}, []
    verts, idx, owner = [], [], []
    agree = total = moved = 0

    def bind_of(t):
        key = tuple(int(anchor_of[i]) for i in t)
        if key not in bind_id:
            bind_id[key] = len(binds)
            binds.append(key)
            bind_strip.append(strip_of[tri_id[tuple(sorted(t))]])
        return bind_id[key]

    game_kept = set()
    for part, D in parts:
        if part in cfg.get("keep_game", []):
            game_kept.update(int(i) for i in D["hide"])
            print(f"[export] {tex}: {part} kept as the game's own, {len(D['hide'])} triangles")
    for part, D in parts:
        if part in cfg.get("keep_game", []):
            continue
        if "hide" in D:
            hidden.update(int(i) for i in D["hide"])
        else:
            whole = True
        V, F, UV = D["verts"].astype(np.float64), D["tris"], D["uvs"].astype(np.float64)
        # Smooth normals (by area), outward as the import's triangles face.
        fn = np.cross(V[F[:, 1]] - V[F[:, 0]], V[F[:, 2]] - V[F[:, 0]])
        vn = np.zeros_like(V)
        for c in range(3):
            np.add.at(vn, F[:, c], fn)
        vn /= np.maximum(np.linalg.norm(vn, axis=1, keepdims=True), 1e-12)
        g = co[np.array([tri_of[tuple(sorted(t))] for t in D["bind_tri"][F[:, 0]]])]
        agree += ((np.cross(g[:, 1] - g[:, 0], g[:, 2] - g[:, 0]) * fn).sum(1) > 0).sum()
        total += len(F)
        b = [bind_of(t) for t in D["bind_tri"]]
        bones = [blend_bones(t, w) for t, w in zip(D["bind_tri"], D["bind_bary"])]
        # Each triangle's strip: the one with most of its corners' bone weight loaded, a
        # corner's own strip first when as good.
        vstrip = np.array([strip_of[tri_id[tuple(sorted(t))]] for t in D["bind_tri"]])
        tstrip, tbind = np.zeros(len(F), np.int64), []
        for f, tri in enumerate(F):
            score = [sum(w for v in tri for bn, w in zip(*bones[v]) if bn in pal) for pal in st_pal]
            best = max(score)
            own = [vstrip[v] for v in tri if vstrip[v] >= 0 and score[vstrip[v]] >= best - 1e-6]
            tstrip[f] = own[0] if own else int(np.argmax(score))
            v = next((v for v in tri if vstrip[v] == tstrip[f]), None)
            if v is None:  # none of its corners' triangles is the strip's: its nearest one
                c = V[tri].mean(0)
                cand = st_tris[tstrip[f]]
                v_t = cand[np.argmin(np.linalg.norm(co[gtris[cand]].mean(1) - c, axis=1))]
                tbind.append(bind_of(gtris[v_t]))
            else:
                tbind.append(b[v])
        # A vertex in triangles of several strips: only bones all of them load.
        vstrips = [set() for _ in V]
        for f, tri in enumerate(F):
            for v in tri:
                vstrips[v].add(tstrip[f])
        for v in range(len(V)):
            allowed = set.intersection(*(st_pal[i] for i in vstrips[v])) if vstrips[v] else set()
            acc = {}
            for bn, w in zip(*bones[v]):
                r = bn
                while r >= 0 and r not in allowed:
                    r = parents[r]
                if r < 0:
                    r = bn
                moved += r != bn and w > 0
                if w > 0:
                    acc[r] = acc.get(r, 0.0) + w
            top = sorted(acc.items(), key=lambda x: -x[1])[:4]
            total_w = sum(w for _, w in top)
            top += [(top[0][0], 0.0)] * (4 - len(top))
            bones[v] = ([bn for bn, _ in top], [w / total_w for _, w in top])
        missing = sum(1 for f, tri in enumerate(F)
                      if any(w > 0 and bn not in st_pal[tstrip[f]] for v in tri for bn, w in zip(*bones[v])))
        # One vertex per position and texture coordinate (the game's v counts down).
        corner_uv = np.round(UV.reshape(-1, 2), 6)
        keys = np.concatenate([F.reshape(-1, 1), corner_uv], 1)
        uniq, inv = np.unique(keys, axis=0, return_inverse=True)
        base = len(verts)
        for row in uniq:
            v = int(row[0])
            verts.append(struct.pack("<8fI3f4B4f", *(V[v] * scale), *vn[v], row[1], 1 - row[2], b[v],
                                     *D["bind_bary"][v], *bones[v][0], *bones[v][1]))
        tri = inv.reshape(-1, 3) + base
        idx.append(tri[:, [0, 2, 1]])  # the game's winding
        owner += tbind
        print(f"[export] {tex}: {part}, {len(F)} triangles, {len(uniq)} vertices; strips "
              f"{np.bincount(tstrip, minlength=len(st_pal)).tolist()}, {missing} triangles with a bone their strip lacks")
    keep = [t for t in mtris if (not whole and t not in hidden) or t in game_kept]
    kept = game_pos[gtris[keep]].mean(1) if keep else np.zeros((0, 3))
    idx = np.concatenate(idx).astype(np.uint32)
    with open(out, "wb") as f:
        f.write(b"BLBM" + struct.pack("<8I", 4, len(verts), idx.size, len(anchors), len(binds), len(kept), len(parents),
                                       len(st_slots)))
        f.write(b"".join(verts))
        f.write(idx.tobytes())
        f.write(np.array(owner, np.uint32).tobytes())
        f.write(game_pos[anchors].astype(np.float32).tobytes())
        f.write(np.array(binds, np.uint32).tobytes())
        f.write(np.array(bind_strip, np.int64).astype(np.uint32).tobytes())  # -1: not the texture's
        f.write(kept.astype(np.float32).tobytes())
        for a in anchors:
            f.write(struct.pack("<4B4f", *WB[a], *W[a]))
        f.write(np.asarray(parents, np.int32).tobytes())
        for pal in st_slots:
            f.write(np.array([pal.get(i, -1) for i in range(32)], np.int16).tobytes())
    print(f"[export] -> {out}: {len(verts)} vertices, {idx.size // 3} triangles, {len(anchors)} anchors, "
          f"{len(binds)} bindings ({moved} vertex weights moved to a parent all its strips load), {len(kept)} of the game's {len(mtris)} triangles kept; "
          f"{100 * agree / total:.0f}% of triangles face as their binding's")
