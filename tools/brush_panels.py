#!/usr/bin/env python3
"""Real panels for a door that is a brush entity (a func_door's box with a photo of a
panelled door on its faces): each panel the texture shows is cut into the face as a
moulded recess with a raised field, lined up with the photo, for the renderer to draw in
place of the flat face (runtime/d3d9/prop_remodel.c, brush remodels). The door still
moves as the game moves it: the remodel is in the brush model's own space, as it is drawn.

    python3 tools/brush_panels.py tools/props/asylum_door.json [--game DIR] [--out DIR]

A recipe names the map, the brush models (the "*N" of their entities), the face material
to panel and the panels as rectangles of the texture in its pixels at "size" (x0 y0 x1 y1),
with the moulding's profile as rings (inset from the panel's edge and depth into the door,
in map units; the last ring's inside is the raised field):
    {"map": "maps/sm_asylum_1.bsp", "models": [18, 19], "material": "STONE/DOORB",
     "size": 512, "panels": [[104, 130, 154, 218], ...],
     "rings": [[0, 0], [0.9, 0.45], [1.5, 0.45], [2.3, 0.15]]}
A panel is cut wherever it lies wholly within a face of that material (front and back);
the rest of the face is kept flat around it. The other faces are not remodelled.

Writes build/props/brush/<map>/<model>.obj (with the extracted faces, for review) and the
renderer's files: build/remodels/brush/<map>/<model>_<draw>.msh, one for the model's faces
of that material drawn together and one for each face alone (the game may draw either
way), and their "keys". A brush remodel is keyed by its positions, not its triangles' vertex
numbers (the game builds a brush model's indices anew every frame): the first 16 hex digits
of the SHA-1 of the face corners it covers, each rounded to 1/16 unit as three int32,
sorted. Its file lists no original positions (the key holds them). Run tools/prop_pack.py
after it: that rebuilds build/remodels/index.txt from every "keys" file.
"""
import argparse
import hashlib
import json
import os
import struct
import sys

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402


def read_bsp(data):
    lumps = [struct.unpack_from("<ii", data, 8 + 16 * i) for i in range(64)]

    def lump(i):
        o, n = lumps[i]
        return data[o:o + n]

    verts = np.frombuffer(lump(3), "<f4").reshape(-1, 3).astype(np.float64)
    edges = np.frombuffer(lump(12), "<u2").reshape(-1, 2)
    surfedges = np.frombuffer(lump(13), "<i4")
    texinfo = [struct.unpack_from("<16f2i", lump(6), 72 * i) for i in range(len(lump(6)) // 72)]
    texdata = [struct.unpack_from("<3f5i", lump(2), 32 * i) for i in range(len(lump(2)) // 32)]
    table, strings = np.frombuffer(lump(44), "<i4"), lump(43)
    faces, models = lump(7), lump(14)

    def name(s):
        o = int(table[s])
        return strings[o:strings.index(b"\0", o)].decode()

    out = {}
    for m in range(len(models) // 48):
        first, n = struct.unpack_from("<2i", models, 48 * m + 40)
        fl = []
        for f in range(first, first + n):
            fe, = struct.unpack_from("<i", faces, 104 * f + 36)
            ne, ti = struct.unpack_from("<Hh", faces, 104 * f + 40)
            if ti < 0:
                continue
            t = texinfo[ti]
            td = texdata[t[17]]
            corners = []
            for e in range(ne):
                s = int(surfedges[fe + e])
                corners.append(verts[edges[abs(s)][1 if s < 0 else 0]])
            fl.append({"material": name(td[3]), "corners": np.array(corners),
                       "s": np.array(t[0:4]), "t": np.array(t[4:8]), "w": td[4], "h": td[5]})
        out[m] = fl
    return out


def uv(face, p):
    """The texture coordinates the game gives point p of the face (0..1 a repeat)."""
    return (face["s"][:3] @ p + face["s"][3]) / face["w"], (face["t"][:3] @ p + face["t"][3]) / face["h"]


def face_frame(face):
    """The face's normal (from its winding: the game winds clockwise seen from the front)
    and a map from texture coordinates to points of its plane."""
    c = face["corners"]
    n = np.cross(c[2] - c[0], c[1] - c[0])
    n /= np.linalg.norm(n)
    # p = c0 + A @ (uv - uv0): solve from the plane's two directions
    e1, e2 = c[1] - c[0], c[2] - c[0]
    d1, d2 = np.subtract(uv(face, c[1]), uv(face, c[0])), np.subtract(uv(face, c[2]), uv(face, c[0]))
    A = np.column_stack([e1, e2]) @ np.linalg.inv(np.column_stack([d1, d2]))
    uv0 = np.array(uv(face, c[0]))
    return n, lambda q: c[0] + A @ (np.asarray(q, float) - uv0)


def panelled(face, panels, size, rings):
    """Triangles (each 3 points), with their normals, of the face with the panels cut in."""
    n, at = face_frame(face)
    lo_uv = np.min([uv(face, p) for p in face["corners"]], axis=0)
    hi_uv = np.max([uv(face, p) for p in face["corners"]], axis=0)
    # the panels in this face's texture coordinates (the repeat that lies on it)
    rects = []
    for x0, y0, x1, y1 in panels:
        r = np.array([x0, y0, x1, y1], float) / size
        k = np.floor(lo_uv)
        for du in (0, 1):
            for dv in (0, 1):
                q = r + [k[0] + du, k[1] + dv, k[0] + du, k[1] + dv]
                if q[0] >= lo_uv[0] - 1e-6 and q[2] <= hi_uv[0] + 1e-6 and q[1] >= lo_uv[1] - 1e-6 and q[3] <= hi_uv[1] + 1e-6:
                    rects.append(q)
    tris = []

    def quad(a, b, c, d, nn):  # corners in order round it; fix_winding turns them to face nn
        tris.append(((a, b, c), nn))
        tris.append(((a, c, d), nn))

    # the flat face around the panels: a grid on the panels' edges, less the panels
    us = sorted({lo_uv[0], hi_uv[0], *[r[0] for r in rects], *[r[2] for r in rects]})
    vs = sorted({lo_uv[1], hi_uv[1], *[r[1] for r in rects], *[r[3] for r in rects]})
    for i in range(len(us) - 1):
        for j in range(len(vs) - 1):
            mu, mv = (us[i] + us[i + 1]) / 2, (vs[j] + vs[j + 1]) / 2
            if any(r[0] < mu < r[2] and r[1] < mv < r[3] for r in rects):
                continue
            quad(at((us[i], vs[j])), at((us[i + 1], vs[j])), at((us[i + 1], vs[j + 1])), at((us[i], vs[j + 1])), n)
    # each panel: rings going in, then the field
    for r in rects:
        def ring(inset, depth):
            # inset in map units: as texture coordinates along each direction
            pu = np.linalg.norm(at((r[0] + 1, r[1])) - at((r[0], r[1])))  # units per texture repeat
            pv = np.linalg.norm(at((r[0], r[1] + 1)) - at((r[0], r[1])))
            iu, iv = inset / pu, inset / pv
            cs = [(r[0] + iu, r[1] + iv), (r[2] - iu, r[1] + iv), (r[2] - iu, r[3] - iv), (r[0] + iu, r[3] - iv)]
            return [at(c) - n * depth for c in cs]
        rs = [ring(i, d) for i, d in rings]
        for a, b in zip(rs, rs[1:]):
            for k in range(4):
                p = [a[k], a[(k + 1) % 4], b[(k + 1) % 4], b[k]]
                nn = np.cross(p[1] - p[0], p[3] - p[0])
                nn /= np.linalg.norm(nn)
                if np.dot(nn, n) < 0:
                    nn = -nn
                quad(*p, nn)
        quad(*rs[-1], n)
    return tris, len(rects)


def fix_winding(tris):
    out = []
    for (a, b, c), nn in tris:
        if np.dot(np.cross(c - a, b - a), nn) < 0:  # clockwise seen from where it faces
            b, c = c, b
        out.append(((a, b, c), nn))
    return out


def pos_key(points):
    q = sorted({tuple(int(round(x * 16)) for x in p) for p in points})
    return hashlib.sha1(b"".join(struct.pack("<3i", *p) for p in q)).hexdigest()[:16]


def mesh_file(tris, face_of_tri, faces):
    """Vertices (position, normal, UV) shared where all three agree, and triangles."""
    ids, verts, idx = {}, [], []
    for ((pts), nn), fi in zip(tris, face_of_tri):
        tri = []
        for p in pts:
            u, v = uv(faces[fi], p)
            vert = [*p, *nn, u, v]
            k = tuple(round(x, 5) for x in vert)
            if k not in ids:
                ids[k] = len(verts)
                verts.append(vert)
            tri.append(ids[k])
        idx.append(tri)
    out = [b"BLPM", struct.pack("<III", len(verts), len(idx), 0)]
    out += [struct.pack("<8f", *x) for x in verts]
    out += [struct.pack("<3I", *t) for t in idx]
    return b"".join(out), len(verts), len(idx)


def write_file(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w" if isinstance(data, str) else "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe")
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build"))
    args = ap.parse_args()
    rc = json.load(open(args.recipe))
    data = tex_extract.read(args.game, tex_extract.vpk_index(args.game), rc["map"])
    if not data:
        sys.exit(f"{rc['map']}: not found")
    models = read_bsp(data)
    mapname = os.path.splitext(os.path.basename(rc["map"]))[0]
    rdir = os.path.join(args.out, "remodels", "brush", mapname)
    pdir = os.path.join(args.out, "props", "brush", mapname)
    os.makedirs(rdir, exist_ok=True)
    os.makedirs(pdir, exist_ok=True)
    lines = []
    for m in rc["models"]:
        faces = models[m]
        mine = [i for i, f in enumerate(faces) if f["material"].lower() == rc["material"].lower()]
        if not mine:
            sys.exit(f"model *{m}: no {rc['material']} faces")
        per_face = {}
        for i in mine:
            tris, np_ = panelled(faces[i], rc["panels"], rc["size"], rc["rings"])
            per_face[i] = fix_winding(tris)
            print(f"*{m} face {i}: {np_} panels, {len(per_face[i])} triangles (was {len(faces[i]['corners']) - 2})")
        # the faces drawn together, and each alone
        draws = [("all", mine)] + [(f"f{i}", [i]) for i in mine]
        for tag, fs in draws:
            tris = [t for i in fs for t in per_face[i]]
            fot = [i for i in fs for _ in per_face[i]]
            blob, nv, nt = mesh_file(tris, fot, faces)
            name = f"brush/{mapname}/{m}_{tag}.msh"
            write_file(os.path.join(args.out, "remodels", name), blob)
            ntris = sum(len(faces[i]["corners"]) - 2 for i in fs)
            lines.append(f"{pos_key([p for i in fs for p in faces[i]['corners']])} {ntris} {name}\n")
            if tag == "all":
                print(f"*{m}: {ntris} triangles drawn as {nt}, {nv} vertices")
        # for review: the remodelled faces and the others as they are
        with open(os.path.join(pdir, f"{m}.obj"), "w") as o:
            vn = 0
            o.write("mtllib textures.mtl\n")
            groups = {}
            for i, f in enumerate(faces):
                pts = per_face[i] if i in per_face else \
                    [((f["corners"][0], f["corners"][k], f["corners"][k + 1]), None) for k in range(1, len(f["corners"]) - 1)]
                groups.setdefault(f["material"], []).append((i, pts))
            for mat, items in groups.items():
                o.write(f"usemtl {mat}\n")
                for i, pts in items:
                    for (tri, _) in pts:
                        for p in tri:
                            u, v = uv(faces[i], p)
                            o.write(f"v {p[0]:.4f} {p[1]:.4f} {p[2]:.4f}\nvt {u:.5f} {1 - v:.5f}\n")
                        # the game's clockwise winding; OBJ readers want it the other way
                        o.write(f"f {vn + 1}/{vn + 1} {vn + 3}/{vn + 3} {vn + 2}/{vn + 2}\n")
                        vn += 3
    write_file(os.path.join(rdir, "keys"), "".join(lines))
    print(f"{len(lines)} draws listed in {os.path.join(rdir, 'keys')}; run tools/prop_pack.py to rebuild the index")


if __name__ == "__main__":
    main()
