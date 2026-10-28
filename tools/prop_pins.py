#!/usr/bin/env python3
"""Where other props sit on a remodelled prop, in its own space, so a remodel that changes
its surface (tools/blender/rock_relief.py) keeps it where they are mounted: a lamp on a
cliff, a stairway up it.

    python3 tools/prop_pins.py tools/props/cliffa.json [--near 24]

Every map that places the recipe's model is read (the mod's maps first, then the game's
archives). For each placement, every other prop (static props, and entities with a model
and an origin, but not the other remodelled ones: tools/props/*.json with "method"
"relief", which change with it) is turned into the model's space, its whole surface sampled every --step
units (tools/mdl_extract.py reads it; only its origin for a model that cannot be read), and
every sample within --near units of the model's surface kept: a long prop such as a
stairway is held along all its length, not at one point. Writes
build/props/<model>/<name>_pins.json: a list of [x, y, z], one per sample kept (one per
--step cube), and prints how many props they came from on each map.

The maps' static props (game lump "sprp", version 4): the model names, 128 bytes each, the
leaves, then 56 bytes per prop, origin and angles (pitch, yaw, roll) first and the model's
number at 24. Entities: the entity lump's text, "origin" and "angles" as three numbers.
"""
import argparse
import glob
import json
import os
import re
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mdl_extract  # noqa: E402
import tex_extract  # noqa: E402


def angle_matrix(a):
    """Half-Life's AngleMatrix: pitch, yaw, roll in degrees; columns forward, left, up."""
    p, y, r = np.radians(a)
    sp, cp, sy, cy, sr, cr = np.sin(p), np.cos(p), np.sin(y), np.cos(y), np.sin(r), np.cos(r)
    return np.array([[cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy],
                     [cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy],
                     [-sp, sr * cp, cr * cp]])


def lump(d, i):
    o, n = struct.unpack_from("<ii", d, 8 + 16 * i)
    return d[o:o + n]


def placements(d):
    """(model name, origin, angles) for every static prop and every entity with a model."""
    out = []
    g = lump(d, 35)
    for i in range(struct.unpack_from("<i", g, 0)[0]):
        gid, _, ver, o, n = struct.unpack_from("<4sHHii", g, 4 + 16 * i)
        if gid != b"prps" or ver != 4:
            continue
        sp = d[o:o + n]
        nn = struct.unpack_from("<i", sp, 0)[0]
        names = [sp[4 + 128 * k:4 + 128 * (k + 1)].split(b"\0")[0].decode("latin1").lower() for k in range(nn)]
        p = 4 + 128 * nn
        p += 4 + 2 * struct.unpack_from("<i", sp, p)[0]
        cnt = struct.unpack_from("<i", sp, p)[0]
        p += 4
        for k in range(cnt):
            q = p + 56 * k
            org, ang = struct.unpack_from("<3f", sp, q), struct.unpack_from("<3f", sp, q + 12)
            m = struct.unpack_from("<H", sp, q + 24)[0]
            if m < nn:
                out.append((names[m], np.array(org), np.array(ang)))
    for ent in re.findall(rb"\{([^}]*)\}", lump(d, 0)):
        kv = dict(re.findall(rb'"([^"]*)"\s+"([^"]*)"', ent))
        if b"model" in kv and b"origin" in kv and kv[b"model"].lower().endswith(b".mdl"):
            org = [float(x) for x in kv[b"origin"].split()[:3]]
            ang = [float(x) for x in kv.get(b"angles", b"0 0 0").split()[:3]]
            out.append((kv[b"model"].decode("latin1").lower(), np.array(org), np.array(ang)))
    return out


def surface_distance(p, tris):
    """Distance from points p (n, 3) to the nearest of the triangles (m, 3, 3)."""
    best = np.full(len(p), np.inf)
    for a, b, c in tris:
        ab, ac, ap = b - a, c - a, p - a
        n = np.cross(ab, ac)
        nn = np.dot(n, n)
        if nn < 1e-12:
            continue
        # the point's projection, clamped onto the triangle by its barycentric coordinates
        v = np.einsum("ij,j->i", np.cross(ap, ac), n) / nn
        w = np.einsum("ij,j->i", np.cross(ab, ap), n) / nn
        v, w = np.clip(v, 0, 1), np.clip(w, 0, 1)
        s = v + w
        v, w = np.where(s > 1, v / np.maximum(s, 1), v), np.where(s > 1, w / np.maximum(s, 1), w)
        q = a + v[:, None] * ab + w[:, None] * ac
        best = np.minimum(best, np.linalg.norm(p - q, axis=1))
    return best


def surface_samples(game, idx, name, step, cache={}):
    """Points over a model's triangles, at most step apart, in its own space; its origin
    alone when it is not a model mdl_extract reads."""
    if name not in cache:
        mdl, vtx = tex_extract.read(game, idx, name), tex_extract.read(game, idx, name[:-4] + ".dx80.vtx")
        try:
            m = mdl_extract.parse(mdl, vtx) if mdl and vtx else None
        except mdl_extract.Refused:
            m = None
        if not m:
            cache[name] = np.zeros((1, 3))
            return cache[name]
        v = np.array([p[:3] for p in m["verts"]])
        pts = [v]
        for me in m["meshes"]:
            for t in me["tris"]:
                a, b, c = v[list(t)]
                n = int(np.ceil(max(np.linalg.norm(b - a), np.linalg.norm(c - a), np.linalg.norm(c - b)) / step))
                if n < 2:
                    continue
                i, j = np.meshgrid(np.arange(n + 1), np.arange(n + 1))
                keep = i + j <= n
                i, j = i[keep][:, None] / n, j[keep][:, None] / n
                pts.append(a + i * (b - a) + j * (c - a))
        cache[name] = np.concatenate(pts)
    return cache[name]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe")
    ap.add_argument("--near", type=float, default=24)
    ap.add_argument("--step", type=float, default=8)
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    args = ap.parse_args()
    model = json.load(open(args.recipe))["model"].lower()
    rel = os.path.splitext(model)[0][len("models/"):]
    name = os.path.basename(rel)
    obj = os.path.join(HERE, "..", "build", "props", rel, name + ".obj")
    v, tris = [], []
    for line in open(obj):
        s = line.split()
        if s and s[0] == "v":
            v.append([float(x) for x in s[1:4]])
        elif s and s[0] == "f":
            tris.append([v[int(c.split("/")[0]) - 1] for c in s[1:4]])
    tris = np.array(tris)
    lo, hi = tris.reshape(-1, 3).min(0) - args.near, tris.reshape(-1, 3).max(0) + args.near

    idx = tex_extract.vpk_index(args.game)
    maps = {n for n in idx if n.startswith("maps/") and n.endswith(".bsp")}
    patch = os.path.join(args.game, "Unofficial_Patch", "maps")
    if os.path.isdir(patch):
        maps |= {"maps/" + n.lower() for n in os.listdir(patch) if n.lower().endswith(".bsp")}
    remodelled = {json.load(open(f))["model"].lower() for f in glob.glob(os.path.join(HERE, "props", "*.json"))
                  if json.load(open(f)).get("method") == "relief"}
    pins = []
    for m in sorted(maps):
        d = tex_extract.read(args.game, idx, m)
        if not d or model.encode() not in d.lower():
            continue
        placed = placements(d)
        found = 0
        for mname, org, ang in placed:
            if mname != model:
                continue
            r = angle_matrix(ang)
            for oname, oorg, oang in placed:
                if oname in remodelled:
                    continue
                pts = surface_samples(args.game, idx, oname, args.step)
                world = pts @ angle_matrix(oang).T + oorg
                local = (world - org) @ r  # r's transpose applied
                inside = np.all((local > lo) & (local < hi), axis=1)
                if not inside.any():
                    continue
                near = surface_distance(local[inside], tris) <= args.near
                if near.any():
                    pins += [[round(float(x), 2) for x in p] for p in local[inside][near]]
                    found += 1
        if found:
            print(f"{m}: {found} props on {name}")
    # one per step cube: the remodel only needs to know the surface is held there
    _, first = np.unique(np.floor(np.array(pins).reshape(-1, 3) / args.step), axis=0, return_index=True)
    pins = [pins[i] for i in sorted(first)]
    out = os.path.join(HERE, "..", "build", "props", rel, name + "_pins.json")
    json.dump(pins, open(out, "w"))
    print(f"{len(pins)} pins -> {os.path.abspath(out)}")


if __name__ == "__main__":
    main()
