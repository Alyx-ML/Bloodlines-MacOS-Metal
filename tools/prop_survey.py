#!/usr/bin/env python3
"""Which props are worth remodelling: every model placed in the game's maps, how often,
and how much of it tools/prop_revolve.py can read as round. Reads only.

    python3 tools/prop_survey.py [--game DIR] [--out FILE]

Maps are the Unofficial Patch's where it has one, else the game's (as the game loads
them). Placements are the static props of each map (its "sprp" game lump) and every
entity naming a model. Each placed model is read with tools/mdl_extract.py and its
connected parts tried as tools/prop_revolve.py would (upright, then along each part's
principal directions, with joined-on knobs left out); "round" is the share of its
triangles in parts it could remodel. Models already remodelled (build/props/.../
<name>_remodel.obj) are marked.

Writes a table ranked by placements times round triangles, the most worth doing first,
to build/props/survey.md.
"""
import argparse
import glob
import os
import re
import struct
import sys
from collections import Counter, defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import mdl_extract  # noqa: E402
import prop_revolve as pr  # noqa: E402
import tex_extract  # noqa: E402


def placements(bsp):
    """The models a map places: {model: count}."""
    out = Counter()
    lump = lambda i: struct.unpack_from("<iiii", bsp, 8 + 16 * i)  # noqa: E731
    ofs, _, _, _ = lump(35)
    for k in range(struct.unpack_from("<i", bsp, ofs)[0]):
        gid, _, _, go, gl = struct.unpack_from("<4sHHii", bsp, ofs + 4 + 16 * k)
        if gid not in (b"sprp", b"prps"):
            continue
        p = go
        nd = struct.unpack_from("<i", bsp, p)[0]
        names = [bsp[p + 4 + 128 * i:p + 4 + 128 * (i + 1)].split(b"\0")[0].decode("latin1").lower()
                 for i in range(nd)]
        p += 4 + 128 * nd
        p += 4 + 2 * struct.unpack_from("<i", bsp, p)[0]
        n = struct.unpack_from("<i", bsp, p)[0]
        p += 4
        size = (go + gl - p) // n if n else 0
        for i in range(n):
            out[names[struct.unpack_from("<H", bsp, p + i * size + 24)[0]]] += 1
    eo, el, _, _ = lump(0)
    for m in re.findall(rb'"model"\s+"(models/[^"]+\.mdl)"', bsp[eo:eo + el], re.I):
        out[m.decode("latin1").lower().replace("\\", "/")] += 1
    return out


def round_share(m):
    """Triangles in parts a revolve could remodel, and the total."""
    v = np.array([p[:3] for p in m["verts"]])
    vn = np.array(mdl_extract.normals(m))
    total = good = 0
    for me in m["meshes"]:
        faces = [[[i, 0, i] for i in t] for t in me["tris"]]
        total += len(faces)
        for part in pr.parts(v, faces):
            ids = sorted({c[0] for f in part for c in f})
            for R in pr.frames(v[ids]):
                try:
                    vR = v @ R.T
                    centre, n, _ = pr.axis_and_sides(vR[ids], loose=True)
                    good += len(pr.profile(vR, part, centre, n)[1])
                    break
                except pr.Refused:
                    pass
    return good, total


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "props", "survey.md"))
    args = ap.parse_args()
    maps = {}
    for d in ("Vampire", "Unofficial_Patch"):  # the patch's replace the game's
        for f in glob.glob(os.path.join(args.game, d, "maps", "*.bsp")):
            maps[os.path.basename(f).lower()] = f
    count, where = Counter(), defaultdict(set)
    for name, f in sorted(maps.items()):
        for mdl, k in placements(open(f, "rb").read()).items():
            count[mdl] += k
            where[mdl].add(name[:-4])
    print(f"{len(maps)} maps, {sum(count.values())} placements of {len(count)} models")
    idx = tex_extract.vpk_index(args.game)
    props = os.path.join(HERE, "..", "build", "props")
    rows = []
    for mdl, k in count.items():
        done = os.path.exists(os.path.join(props, mdl[len("models/"):-4], os.path.basename(mdl)[:-4] + "_remodel.obj"))
        try:
            m = mdl_extract.parse(tex_extract.read(args.game, idx, mdl),
                                  tex_extract.read(args.game, idx, mdl[:-4] + ".dx80.vtx"))
            good, total = round_share(m)
            note = ""
        except Exception as e:  # unreadable models are listed with why
            good = total = 0
            note = str(e).split("\n")[0][:60]
        rows.append((k * good, mdl, k, len(where[mdl]), total, good, done, note))
    rows.sort(key=lambda r: (-r[0], -r[2]))
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write(f"# Props across the game\n\n{len(maps)} maps, {sum(count.values())} placements of "
                f"{len(count)} models. Ranked by placements x round triangles.\n\n"
                "| model | placed | maps | triangles | round | done | note |\n|---|---|---|---|---|---|---|\n")
        for _, mdl, k, nm, total, good, done, note in rows:
            share = f"{100 * good // total}%" if total else ""
            f.write(f"| {mdl[len('models/'):]} | {k} | {nm} | {total} | {share} | {'yes' if done else ''} | {note} |\n")
    print(f"wrote {os.path.abspath(args.out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
