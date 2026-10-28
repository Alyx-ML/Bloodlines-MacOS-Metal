#!/usr/bin/env python3
"""A light version of a character's rebuilt parts, for the game.

    make_lod.py CHAR.json SRC.npz IN_DIR OUT_DIR

For each part in IN_DIR (build_character.py's output, named <character>_<part>.npz)
with a triangle budget in the config's "lod" ({part: triangles}):
 1. what can never be seen goes: a garment's inner side further than "inner_keep"
    (default 0.02) from its openings, and the body wherever a garment covers it (a body
    triangle whose nearest garment point is on that garment's outer side, close by and
    further than "cover_margin" (default 0.03) from its openings, so the cut edge stays
    well under the garment when she moves; a narrow band like a choker hides none);
 2. the rest is decimated to the budget (lod_decimate.py, Blender's collapse);
 3. the body and head fitted under the game's own triangles a "keep_game" part leaves drawn
    (export_game_mesh.py): the head's open edge near them taken down to their middle
    height, then a vertex over its nearest one, less than "keep_game_gap" (default
    0.0015) behind and no more than 0.008 in front, moved in along its normal (and for
    the body, the corners of a triangle passing in front of one between them), and the
    body's triangles reaching above them dropped (the head covers there); a garment
    lying on skin moved in goes in with it;
 4. every vertex is bound again to the game triangles the part was bound to (as the
    builders bind: a triangle, a place in it and an offset in its axes, at rest), the
    body within "keep_game_bind" (default 0.012) of a kept triangle to that one, so it
    moves with it.
OUT_DIR gets the parts under the same names, with the same fields.
"""
import os
import subprocess
import sys

import numpy as np
import trimesh
from garments import load_config
from scipy.spatial import cKDTree

cfg_path, src_path, in_dir, out_dir = (os.path.abspath(a) for a in sys.argv[1:5])
here = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.join(here, "..", ".."))
cfg = load_config(cfg_path)
lod = cfg["lod"]
inner_keep = lod.get("inner_keep", 0.02)
cover_margin = lod.get("cover_margin", 0.03)
blender = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")
name = os.path.splitext(os.path.basename(cfg_path))[0]
os.makedirs(out_dir, exist_ok=True)
J = np.load(src_path)
co = J["co"].astype(np.float64)


def path(d, part):
    return os.path.join(d, f"{name}_{part}.npz")


def keep_faces(D, keep):
    """The part with only the kept triangles (and the vertices they use)."""
    tris = D["tris"][keep]
    used = np.unique(tris)
    remap = -np.ones(len(D["verts"]), np.int64)
    remap[used] = np.arange(len(used))
    return D["verts"][used], remap[tris], D["uvs"][keep]


garments = {g: dict(np.load(path(in_dir, g))) for g in cfg["garments"] if os.path.exists(path(in_dir, g))}
# The game's own triangles left drawn for "keep_game" parts, facing out from their middle.
kept = [int(i) for g in cfg.get("keep_game", []) for i in np.load(path(in_dir, g))["hide"]]
kept_tris = kept_n = None
if kept:
    kept_tris = co[J["tris"][kept]]
    kept_n = np.cross(kept_tris[:, 1] - kept_tris[:, 0], kept_tris[:, 2] - kept_tris[:, 0])
    kept_n /= np.linalg.norm(kept_n, axis=1, keepdims=True)
    kept_n *= np.sign(((kept_tris.mean(1) - kept_tris.reshape(-1, 3).mean(0)) * kept_n).sum(1))[:, None]
keep_gap = cfg.get("keep_game_gap", 0.0015)
body_moves = None  # the body's skin moved in by kept triangles: where it was, and by how much


def ring_at(V):
    """Around the kept triangles' middle (in the model's x, y), at each vertex's angle:
    whether any kept vertex is that way, the kept vertices' lowest and highest there,
    their mean and largest distance out, and the vertex's own angle and distance out."""
    kv = kept_tris.reshape(-1, 3)
    mid = kv[:, :2].mean(0)
    ka = np.arctan2(kv[:, 1] - mid[1], kv[:, 0] - mid[0])
    kr = np.linalg.norm(kv[:, :2] - mid, axis=1)
    va = np.arctan2(V[:, 1] - mid[1], V[:, 0] - mid[0])
    near = np.abs((va[:, None] - ka[None] + np.pi) % (2 * np.pi) - np.pi) < 0.25
    cnt = np.maximum(near.sum(1), 1)
    return dict(any=near.any(1), bot=np.where(near, kv[None, :, 2], np.inf).min(1),
                top=np.where(near, kv[None, :, 2], -np.inf).max(1), r=(near * kr[None]).sum(1) / cnt,
                r_max=np.where(near, kr[None], -np.inf).max(1), a=va, v_r=np.linalg.norm(V[:, :2] - mid, axis=1),
                mid=mid)

total_in = total_out = 0
for part, budget in lod.items():
    if part in ("inner_keep", "cover_margin"):
        continue
    p = path(in_dir, part) if part != "head" else os.path.abspath(cfg["head"])
    D = dict(np.load(p))
    n_in = len(D["tris"])
    keep = np.ones(n_in, bool)
    if "layer" in D:
        far = (D["open_dist"][D["tris"]] > inner_keep).all(1)
        keep &= ~((D["layer"] == 1) & far)
    if part == "body":
        cent = D["verts"][D["tris"]].mean(1)
        for g, G in garments.items():
            outer = np.unique(G["tris"][G["layer"] == 0])
            d, k = cKDTree(G["verts"][outer]).query(cent)
            covered = (d < cfg["garments"][g].get("thickness", 0.0) + 0.006) & (G["open_dist"][outer][k] > cover_margin)
            keep &= ~covered
    V, F, UV = keep_faces(D, keep)
    tmp_in, tmp_out = os.path.join(out_dir, f".{part}_in.npz"), os.path.join(out_dir, f".{part}_out.npz")
    np.savez_compressed(tmp_in, verts=V, tris=F, uvs=UV)
    r = subprocess.run([blender, "--background", "--factory-startup", "--python", f"{here}/lod_decimate.py", "--",
                        tmp_in, tmp_out, str(budget)], capture_output=True, text=True)
    if r.returncode or not os.path.exists(tmp_out):
        sys.exit(f"[lod] {part}: decimation failed\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")
    L = np.load(tmp_out)
    os.remove(tmp_in), os.remove(tmp_out)
    Vl, Fl, UVl = L["verts"].astype(np.float64), L["tris"], L["uvs"]
    if body_moves is not None and part in cfg["garments"]:
        # A garment lying on skin moved in by a kept triangle goes in with it (within
        # 0.008 of where that skin was, less with distance).
        P0, disp = body_moves
        sel = np.linalg.norm(disp, axis=1) > 1e-5
        d, k = cKDTree(P0[sel]).query(Vl, k=min(8, sel.sum()), distance_upper_bound=0.008)
        d, k = d.reshape(len(d), -1), k.reshape(len(k), -1)
        w = np.where(np.isfinite(d), np.clip(1 - d / 0.008, 0, 1) ** 2, 0)
        dh = disp[sel]
        acc = np.zeros_like(Vl)
        for j in range(k.shape[1]):
            ok = np.isfinite(d[:, j])
            acc[ok] += w[ok, j, None] * dh[k[ok, j]]
        wsum = w.sum(1)
        go = wsum > 0
        Vl[go] += acc[go] / wsum[go, None] * w[go].max(1)[:, None]
        if go.any():
            # Folds smoothed out as the body's are, the rest held.
            e = np.concatenate([Fl[:, [0, 1]], Fl[:, [1, 2]], Fl[:, [2, 0]]])
            e = np.unique(np.sort(e, axis=1), axis=0)
            for _ in range(20):
                acc = np.zeros_like(Vl)
                cnt = np.zeros(len(Vl))
                np.add.at(acc, e[:, 0], Vl[e[:, 1]])
                np.add.at(acc, e[:, 1], Vl[e[:, 0]])
                np.add.at(cnt, e[:, 0], 1)
                np.add.at(cnt, e[:, 1], 1)
                Vl[go] += 0.5 * (acc[go] / np.maximum(cnt[go], 1)[:, None] - Vl[go])
            print(f"[lod] {part}: {go.sum()} vertices moved in with the skin under them")
    if kept_tris is not None and part in ("body", "head"):
        # Each vertex against its nearest kept triangle.
        gap, reach = keep_gap, 0.008
        if part == "head":
            # The head's open edge ends under a kept ring, as the game's does: an edge
            # vertex close to it and no higher than a little over its top goes to the
            # middle of its height, just in from it.
            e = np.sort(Fl[:, [0, 1, 1, 2, 2, 0]].reshape(-1, 2), axis=1)
            u, c = np.unique(e, axis=0, return_counts=True)
            edge = np.zeros(len(Vl), bool)
            edge[u[c == 1].ravel()] = True
            R = ring_at(Vl)
            snap = edge & R["any"] & (Vl[:, 2] < R["top"] + 0.015) & (np.abs(R["v_r"] - R["r"]) < 0.01)
            rad = R["r"][snap] - gap
            Vl[snap, 0] = R["mid"][0] + rad * np.cos(R["a"][snap])
            Vl[snap, 1] = R["mid"][1] + rad * np.sin(R["a"][snap])
            Vl[snap, 2] = (R["top"][snap] + R["bot"][snap]) / 2
            print(f"[lod] head: {snap.sum()} edge vertices taken down under the game's kept triangles")
        moved = np.zeros(len(Vl), bool)
        for _ in range(3):  # a vertex moved off one facet of a ring can come out over the next
            best_d = np.full(len(Vl), np.inf)
            q = np.zeros_like(Vl)
            ti = np.zeros(len(Vl), np.int64)
            for i, t in enumerate(kept_tris):
                qi = trimesh.triangles.closest_point(np.repeat(t[None], len(Vl), 0), Vl)
                d = np.linalg.norm(Vl - qi, axis=1)
                b = d < best_d
                best_d[b], q[b], ti[b] = d[b], qi[b], i
            n = kept_n[ti]
            s = ((Vl - q) * n).sum(1)
            side = np.linalg.norm(Vl - q - s[:, None] * n, axis=1)
            hit = (side < 0.004) & (s > -gap + 1e-5) & (s < reach)
            Vl[hit] -= (s[hit] + gap)[:, None] * n[hit]
            moved |= hit
        if moved.any():
            print(f"[lod] {part}: {moved.sum()} vertices moved in behind the game's kept triangles")
        if part == "body":
            # A big triangle can still pass in front of a kept triangle between its corners
            # (points across each are tried): its longest edge is split, in it and in the
            # triangle on the other side, and a new vertex over a kept triangle moved in as
            # above, until none passes in front (or its edges are under 0.003).
            grid = np.array([[a, b, 1 - a - b] for a in np.linspace(0, 1, 7) for b in np.linspace(0, 1, 7) if a + b <= 1])

            def nearest_kept(P):
                bd = np.full(len(P), np.inf)
                bq = np.zeros_like(P)
                bt = np.zeros(len(P), np.int64)
                for i, t in enumerate(kept_tris):
                    qi = trimesh.triangles.closest_point(np.repeat(t[None], len(P), 0), P)
                    d = np.linalg.norm(P - qi, axis=1)
                    b = d < bd
                    bd[b], bq[b], bt[b] = d[b], qi[b], i
                n = kept_n[bt]
                s = ((P - bq) * n).sum(1)
                return s, np.linalg.norm(P - bq - s[:, None] * n, axis=1), n

            n_split = 0
            for _ in range(12):
                P = np.einsum("wk,fkd->fwd", grid, Vl[Fl]).reshape(-1, 3)
                s, side, _ = nearest_kept(P)
                over = np.where(((side < 0.0015) & (s > -gap / 2) & (s < 0.03)).reshape(len(Fl), -1).any(1))[0]
                if not len(over):
                    break
                # Each one's longest edge, no triangle given two in a round.
                edge_tris = {}
                for f in range(len(Fl)):
                    for k in range(3):
                        edge_tris.setdefault(tuple(sorted((Fl[f, k], Fl[f, (k + 1) % 3]))), []).append((f, k))
                busy, split = set(), []
                for f in over:
                    lens = [np.linalg.norm(Vl[Fl[f, k]] - Vl[Fl[f, (k + 1) % 3]]) for k in range(3)]
                    k = int(np.argmax(lens))
                    if lens[k] < 0.003:
                        continue
                    e = tuple(sorted((Fl[f, k], Fl[f, (k + 1) % 3])))
                    side_tris = edge_tris[e]
                    if any(g in busy for g, _ in side_tris):
                        continue
                    busy.update(g for g, _ in side_tris)
                    split.append(e)
                if not split:
                    break
                newF, newUV, gone = [], [], set()
                Vl = np.concatenate([Vl, np.array([(Vl[a] + Vl[b]) / 2 for a, b in split])])
                for i, e in enumerate(split):
                    m = len(Vl) - len(split) + i
                    for g, k in edge_tris[e]:
                        a, b, c = Fl[g, k], Fl[g, (k + 1) % 3], Fl[g, (k + 2) % 3]
                        ua, ub, uc = UVl[g, k], UVl[g, (k + 1) % 3], UVl[g, (k + 2) % 3]
                        um = (ua + ub) / 2
                        newF += [[a, m, c], [m, b, c]]
                        newUV += [[ua, um, uc], [um, ub, uc]]
                        gone.add(g)
                stay = np.array([f not in gone for f in range(len(Fl))])
                Fl = np.concatenate([Fl[stay], np.array(newF)])
                UVl = np.concatenate([UVl[stay], np.array(newUV, dtype=UVl.dtype)])
                n_split += len(split)
                s, side, n = nearest_kept(Vl)
                hit = (side < 0.004) & (s > -gap + 1e-5) & (s < reach)
                Vl[hit] -= (s[hit] + gap)[:, None] * n[hit]
            print(f"[lod] body: {n_split} edges split where triangles passed in front of the game's kept triangles")
            # Where the body stands further out than that over a kept triangle (up to 0.025),
            # it goes in behind it too, and the skin round it follows, less with distance
            # (none by 0.015 away), so it slopes in instead of folding.
            s, side, n = nearest_kept(Vl)
            hit = (side < 0.004) & (s > -gap + 1e-5) & (s < 0.025)
            if hit.any():
                disp = np.zeros_like(Vl)
                disp[hit] = -(s[hit] + gap)[:, None] * n[hit]
                tree = cKDTree(Vl[hit])
                d, k = tree.query(Vl[~hit], k=min(8, hit.sum()), distance_upper_bound=0.015)
                d, k = d.reshape(len(d), -1), k.reshape(len(k), -1)
                w = np.where(np.isfinite(d), np.clip(1 - d / 0.015, 0, 1) ** 2, 0)
                dh = disp[hit]
                acc = np.zeros((len(d), 3))
                for j in range(k.shape[1]):
                    ok = np.isfinite(d[:, j])
                    acc[ok] += w[ok, j, None] * dh[k[ok, j]]
                wsum = w.sum(1)
                far = np.where(wsum[:, None] > 0, acc / np.maximum(wsum, 1e-12)[:, None] * np.clip(w.max(1), 0, 1)[:, None], 0)
                disp[~hit] = far
                body_moves = (Vl.copy(), disp)
                Vl += disp
                # Folds left in the moved skin smoothed out (each moved vertex toward the
                # middle of its neighbours, the rest held), kept behind the kept triangles.
                patch = np.linalg.norm(disp, axis=1) > 1e-5
                e = np.concatenate([Fl[:, [0, 1]], Fl[:, [1, 2]], Fl[:, [2, 0]]])
                e = np.unique(np.sort(e, axis=1), axis=0)
                for _ in range(20):
                    acc = np.zeros_like(Vl)
                    cnt = np.zeros(len(Vl))
                    np.add.at(acc, e[:, 0], Vl[e[:, 1]])
                    np.add.at(acc, e[:, 1], Vl[e[:, 0]])
                    np.add.at(cnt, e[:, 0], 1)
                    np.add.at(cnt, e[:, 1], 1)
                    mid = acc / np.maximum(cnt, 1)[:, None]
                    Vl[patch] += 0.5 * (mid[patch] - Vl[patch])
                    s2, side2, n2 = nearest_kept(Vl)
                    back = patch & (side2 < 0.004) & (s2 > -gap + 1e-5) & (s2 < 0.025)
                    Vl[back] -= (s2[back] + gap)[:, None] * n2[back]
                body_moves = (body_moves[0], Vl - body_moves[0])
                print(f"[lod] body: {hit.sum()} vertices standing out over the game's kept triangles moved in, "
                      f"{(np.linalg.norm(far, axis=1) > 1e-5).sum()} round them eased")
            # The head covers the neck above a kept ring: the body's triangles that come up
            # past its top edge (at that angle around it, close to it) go.
            R = ring_at(Vl)
            above = R["any"] & (Vl[:, 2] > R["top"]) & (Vl[:, 2] < R["top"] + 0.05) & (R["v_r"] < R["r_max"] + 0.01)
            drop = above[Fl].any(1)
            if drop.any():
                used = np.unique(Fl[~drop])
                remap = -np.ones(len(Vl), np.int64)
                remap[used] = np.arange(len(used))
                Vl, Fl, UVl = Vl[used], remap[Fl[~drop]], UVl[~drop]
                print(f"[lod] body: {drop.sum()} triangles above the game's kept triangles dropped")

    # Bound again to the game triangles the part was bound to; the body just behind a kept
    # triangle to that one, so it moves with it and no gap opens between them.
    targets = np.unique(np.sort(D["bind_tri"], axis=1), axis=0)
    if kept_tris is not None and part == "body":
        targets = np.unique(np.concatenate([targets, np.sort(J["tris"][kept], axis=1)]), axis=0)
    tp_all = co[targets]
    cand = cKDTree(tp_all.mean(1)).query(Vl, k=min(16, len(targets)))[1].reshape(len(Vl), -1)
    best_d = np.full(len(Vl), np.inf)
    best_p = np.zeros_like(Vl)
    best_t = np.zeros(len(Vl), np.int64)
    for j in range(cand.shape[1]):
        q = trimesh.triangles.closest_point(tp_all[cand[:, j]], Vl)
        d = np.linalg.norm(q - Vl, axis=1)
        better = d < best_d
        best_d[better], best_p[better], best_t[better] = d[better], q[better], cand[better, j]
    if kept_tris is not None and part == "body":
        # Within "keep_game_bind" (default 0.012) of a kept triangle, the body is bound to
        # it even where a game triangle under it is nearer: those span the neck to the head,
        # and the skin bound to them would ride up over the kept part as she moves.
        is_kept = np.isin(np.arange(len(targets)), [np.where((targets == t).all(1))[0][0] for t in np.sort(J["tris"][kept], axis=1)])
        kd = np.full(len(Vl), np.inf)
        kp = np.zeros_like(Vl)
        kt = np.zeros(len(Vl), np.int64)
        for j in np.where(is_kept)[0]:
            q = trimesh.triangles.closest_point(np.repeat(tp_all[j][None], len(Vl), 0), Vl)
            d = np.linalg.norm(q - Vl, axis=1)
            b = d < kd
            kd[b], kp[b], kt[b] = d[b], q[b], j
        to_kept = kd < cfg.get("keep_game_bind", 0.012)
        best_d[to_kept], best_p[to_kept], best_t[to_kept] = kd[to_kept], kp[to_kept], kt[to_kept]
        print(f"[lod] body: {to_kept.sum()} vertices bound to the game's kept triangles")
    tp = tp_all[best_t]
    bary = trimesh.triangles.points_to_barycentric(tp, best_p)
    e1 = tp[:, 1] - tp[:, 0]
    nrm = np.cross(e1, tp[:, 2] - tp[:, 0])
    e1 /= np.linalg.norm(e1, axis=1, keepdims=True)
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True)
    Fr = np.stack([e1, np.cross(nrm, e1), nrm], 1)
    offset = np.einsum("nij,nj->ni", Fr, Vl - best_p)
    back = (tp * bary[:, :, None]).sum(1) + np.einsum("nij,ni->nj", Fr, offset)
    out = dict(verts=Vl.astype(np.float32), tris=Fl.astype(np.int32), uvs=UVl.astype(np.float32),
               bind_tri=targets[best_t].astype(np.int32), bind_bary=bary.astype(np.float32),
               bind_off=offset.astype(np.float32), bind_err=np.linalg.norm(back - Vl, axis=1).astype(np.float32))
    for k in ("mat_name", "hide"):
        if k in D:
            out[k] = D[k]
    np.savez_compressed(path(out_dir, part), **out)
    total_in += n_in
    total_out += len(Fl)
    print(f"[lod] {part}: {n_in} -> {keep.sum()} seen -> {len(Fl)} triangles, {len(Vl)} vertices")
print(f"[lod] {name}: {total_in} -> {total_out} triangles")
