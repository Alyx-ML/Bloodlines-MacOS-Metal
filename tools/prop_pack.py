#!/usr/bin/env python3
"""Make the remodelled props the renderer draws in place of the game's own
(runtime/d3d9/prop_remodel.c), from the remodels tools/prop_revolve.py wrote.

    python3 tools/prop_pack.py [--props DIR] [--out DIR] [--game DIR]

For every build/props/<model>/<name>_remodel.obj, each of the model's meshes is matched
to the remodel's group of the same material (the model's first skin), and must be the
only mesh with it. Its key is the SHA-1 of its triangles' vertex numbers as the game
draws them (u32, counted from the lowest), whole numbers the renderer reads exactly from
the index buffer; the file also holds the original's positions, which the renderer
checks the vertex buffer against (the game unpacks compressed models itself, so its
floats may differ in the last bits). So the remodel is drawn exactly where that mesh
would be, and nowhere else.

Writes <out>/<model>/<mesh number>.msh and rebuilds <out>/index.txt from all of them.
"""
import argparse
import hashlib
import json
import os
import struct
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mdl_extract  # noqa: E402
import tex_extract  # noqa: E402


def read_remodel(path):
    v, vt, vn, groups, mat = [], [], [], defaultdict(list), None
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
        elif p[0] == "f":
            if len(p) != 4:
                raise mdl_extract.Refused(f"{path}: faces must be triangles")
            groups[mat].append([tuple(int(i) - 1 for i in c.split("/")) for c in p[1:]])
    return v, vt, vn, groups


def mesh_file(v, vt, vn, faces, orig):
    """The group's vertices (position, normal, UV as the game stores it) and triangles;
    corners alike in all three are one vertex, shared by their triangles."""
    ids, verts, tris = {}, [], []
    for f in faces:
        tri = []
        for c in f:
            u, w = vt[c[1]]
            vert = v[c[0]] + vn[c[2]] + [u, 1 - w]
            k = tuple(round(x, 5) for x in vert)
            if k not in ids:
                ids[k] = len(verts)
                verts.append(vert)
            tri.append(ids[k])
        tris.append(tri)
    out = [b"BLPM", struct.pack("<III", len(verts), len(tris), len(orig))]
    out += [struct.pack("<8f", *x) for x in verts]
    out += [struct.pack("<3I", *t) for t in tris]
    out += [struct.pack("<3f", *p) for p in orig]
    return b"".join(out), len(verts), len(tris)


def write_file(path, data):
    """Write to a temporary file, then rename: an interrupted run never leaves half a file."""
    tmp = path + ".tmp"
    with open(tmp, "w" if isinstance(data, str) else "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--props", default=os.path.join(HERE, "..", "build", "props"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "remodels"))
    args = ap.parse_args()
    idx = tex_extract.vpk_index(args.game)
    props, out = os.path.abspath(args.props), os.path.abspath(args.out)
    refused = 0
    for d, _, files in os.walk(props):
        for fn in files:
            if not fn.endswith("_remodel.obj"):
                continue
            stem = fn[:-len("_remodel.obj")]
            rel = os.path.relpath(d, props)
            if os.path.basename(rel) != stem:
                continue
            model = "models/" + rel.replace(os.sep, "/") + ".mdl"
            try:
                m = mdl_extract.parse(tex_extract.read(args.game, idx, model),
                                      tex_extract.read(args.game, idx, model[:-4] + ".dx80.vtx"))
                v, vt, vn, groups = read_remodel(os.path.join(d, fn))
                mats = [me["material"] for me in m["meshes"]]
                lines = []
                for k, me in enumerate(m["meshes"]):
                    if mats.count(me["material"]) > 1:
                        raise mdl_extract.Refused(f"material {me['material']} is on several meshes")
                    if me["material"] not in groups:
                        raise mdl_extract.Refused(f"the remodel has no {me['material']} group")
                    low = min(me["draw"])
                    key = hashlib.sha1(struct.pack(f"<{len(me['draw'])}I", *(i - low for i in me["draw"]))).hexdigest()[:16]
                    orig = [m["verts"][me["drawn"][i]][:3] for i in range(low, max(me["draw"]) + 1)]
                    data, nv, nt = mesh_file(v, vt, vn, groups[me["material"]], orig)
                    name = f"{rel}/{k}.msh".replace(os.sep, "/")
                    os.makedirs(os.path.join(out, rel), exist_ok=True)
                    write_file(os.path.join(out, name), data)
                    lines.append(f"{key} {len(me['tris'])} {name}\n")
                    print(f"{model} mesh {k} ({me['material']}): {len(me['tris'])} triangles -> {nt}")
                write_file(os.path.join(out, rel, "keys"), "".join(lines))
                # relief remodels' lighting is smoothed when drawn (prop_remodel.c)
                recipe = os.path.join(HERE, "props", stem + ".json")
                smooth = os.path.join(out, rel, "smooth")
                if os.path.exists(recipe) and json.load(open(recipe)).get("method") == "relief":
                    write_file(smooth, "")
                elif os.path.exists(smooth):
                    os.remove(smooth)
            except mdl_extract.Refused as e:
                print(f"refused {model}: {e}", file=sys.stderr)
                refused += 1
    lines = []
    for d, _, files in os.walk(out):
        if "keys" in files:
            lines.append(open(os.path.join(d, "keys")).read())
    write_file(os.path.join(out, "index.txt"), "".join(lines))
    print(f"{sum(x.count(chr(10)) for x in lines)} meshes listed in {os.path.join(out, 'index.txt')}, {refused} refused")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
