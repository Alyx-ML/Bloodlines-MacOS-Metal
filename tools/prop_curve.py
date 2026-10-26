#!/usr/bin/env python3
"""Remodel a round prop that is not a clean surface of revolution (drips, uneven rims,
inner and outer walls: candles, glasses) from its extracted OBJ (tools/mdl_extract.py):
every triangle split finer and its new points placed by angle around the prop's axis
rather than along straight lines, so the facets become arcs, while each point's height
and distance from the axis, and every UV, are what the original's triangle gives there.
Nothing is smoothed away and the texture lands exactly where it did.

    python3 tools/prop_curve.py tools/props/ascandle.json

A recipe names the model and the tolerance, nothing else:
    {"model": "models/scenery/furniture/ascandle/ascandle.mdl", "method": "curve",
     "tolerance": 0.02}
"tolerance" is how far the surface may stray from a true arc, in the model's units:
each material is split into the fewest pieces per edge that keep its widest part
within it, so small parts (a wick) stay as they are.

The axis and number of sides come from the original as in tools/prop_revolve.py, and
must be found or the model is refused. Writes build/props/<model>/<name>_remodel.obj
next to the extracted one, using its .mtl.
"""
import argparse
import json
import math
import os
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from prop_revolve import Refused, arc_steps, axis_and_sides  # noqa: E402

NEAR_AXIS = 1e-3  # points this close to the axis have no angle of their own


def read_obj(path):
    v, vt, vn, groups, order, mat = [], [], [], {}, [], None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "v":
            v.append([float(x) for x in p[1:4]])
        elif p[0] == "vt":
            vt.append([float(x) for x in p[1:3]])
        elif p[0] == "vn":
            vn.append([float(x) for x in p[1:4]])
        elif p[0] == "usemtl":
            mat = p[1]
            if mat not in groups:
                groups[mat] = []
                order.append(mat)
        elif p[0] == "f":
            groups[mat].append([tuple(int(i) - 1 for i in c.split("/")) for c in p[1:]])
    return np.array(v), np.array(vt), np.array(vn), groups, order


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
    try:
        centre, n, _ = axis_and_sides(v, split=False)
    except Refused as e:
        print(f"{model}: {e}", file=sys.stderr)
        return 1
    tol = float(recipe["tolerance"])
    d = v[:, :2] - centre
    r, th = np.hypot(d[:, 0], d[:, 1]), np.arctan2(d[:, 1], d[:, 0])
    print(f"{model}: {n} sides around ({centre[0]:.3f}, {centre[1]:.3f})")

    out_v, out_vn, out_vt, out_f, ids = [], [], [], [], {}

    def point(corners, w, k):
        """The point at integer weights w (summing to k) of the corners' positions, by
        angle around the axis; shared by every triangle that reaches it."""
        key = tuple(sorted((corners[i][0], corners[i][2], w[i]) for i in range(3) if w[i]))
        if key in ids:
            return ids[key]
        vi = [c for c, _, _ in key]
        ni = [c for _, c, _ in key]
        ws = np.array([x for _, _, x in key], float) / k
        far = [j for j in range(len(vi)) if r[vi[j]] > NEAR_AXIS]
        if far:  # angles unwrapped around the first, averaged over the points that have one
            a0 = th[vi[far[0]]]
            ang = [a0 + (th[vi[j]] - a0 + math.pi) % (2 * math.pi) - math.pi for j in far]
            t = sum(ws[j] * a for j, a in zip(far, ang)) / sum(ws[j] for j in far)
        else:
            t = 0.0
        rr = float(ws @ r[vi])
        z = float(ws @ v[vi, 2])
        out_v.append((centre[0] + rr * math.cos(t), centre[1] + rr * math.sin(t), z))
        # the normal turned with the point: its parts along the axis, outwards and around
        nr = nt = nz = 0.0
        for j in range(len(vi)):
            a = th[vi[j]] if r[vi[j]] > NEAR_AXIS else t
            x, y, zz = vn[ni[j]]
            nr += ws[j] * (x * math.cos(a) + y * math.sin(a))
            nt += ws[j] * (-x * math.sin(a) + y * math.cos(a))
            nz += ws[j] * zz
        nn = np.array([nr * math.cos(t) - nt * math.sin(t), nr * math.sin(t) + nt * math.cos(t), nz])
        out_vn.append(nn / (np.linalg.norm(nn) or 1))
        ids[key] = len(out_v) - 1
        return ids[key]

    ntri = 0
    for mat in order:
        faces = groups[mat]
        vids = sorted({c[0] for f in faces for c in f})
        k = arc_steps(float(r[vids].max()), 2 * math.pi / n, tol)
        print(f"  {mat}: split {k}x per edge")
        tris = []
        for f in faces:
            uv = vt[[c[1] for c in f]]
            grid = {}
            for i in range(k + 1):
                for j in range(k + 1 - i):
                    w = (i, j, k - i - j)
                    out_vt.append(tuple(np.array(w, float) / k @ uv))
                    grid[i, j] = (point(f, w, k), len(out_vt) - 1)
            for i in range(k):
                for j in range(k - i):
                    tris.append((grid[i, j], grid[i + 1, j], grid[i, j + 1]))
                    if i + j < k - 1:
                        tris.append((grid[i + 1, j], grid[i + 1, j + 1], grid[i, j + 1]))
        out_f.append((mat, tris))
        ntri += len(tris)

    dst = os.path.join(folder, stem + "_remodel.obj")
    with open(dst, "w") as f:
        f.write(f"# {model} remodelled by tools/prop_curve.py from {os.path.basename(args.recipe)}\n")
        f.write(f"mtllib {stem}.mtl\n")
        for p in out_v:
            f.write("v {:.6f} {:.6f} {:.6f}\n".format(*p))
        for t in out_vt:
            f.write("vt {:.6f} {:.6f}\n".format(*t))
        for p in out_vn:
            f.write("vn {:.6f} {:.6f} {:.6f}\n".format(*p))
        for mat, tris in out_f:
            f.write(f"g {mat}\nusemtl {mat}\n")
            for tri in tris:
                f.write("f " + " ".join(f"{a + 1}/{b + 1}/{a + 1}" for a, b in tri) + "\n")
    print(f"{ntri} triangles (the original {sum(len(g) for g in groups.values())}) -> {os.path.abspath(dst)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
