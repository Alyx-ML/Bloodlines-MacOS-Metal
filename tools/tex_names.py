#!/usr/bin/env python3
"""Fingerprints of every texture in the game, so the renderer can name the textures it
draws that have no upscale yet (runtime/d3d9/tex_hires.m logs them and lists them in
build/logs/not_upscaled.txt, which tools/tex_extract.py --list exports).

    python3 tools/tex_names.py [--game DIR] [--out FILE]

Writes build/hires/names.txt: one line per mipmap, as in index.txt (tools/tex_pack.py):
the SHA-1 of each of a texture's three largest mipmaps as the game hands them to
Direct3D, its width and height, and the texture's name. Textures tex_pack.py could not
upscale (animated, cube maps, other formats) are left out.
"""
import argparse
import os
import sys
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402
import tex_pack  # noqa: E402


def one(name):
    tth, ttz = tex_extract.read(GAME, IDX, name + ".tth"), tex_extract.read(GAME, IDX, name + ".ttz")
    if not tth or not ttz:
        return ""
    try:
        return tex_pack.keys(tex_pack.original(tth, ttz), name)
    except tex_pack.Refused:
        return ""


def init(game, idx):
    global GAME, IDX
    GAME, IDX = game, idx


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "hires", "names.txt"))
    args = ap.parse_args()
    idx = tex_extract.vpk_index(args.game)
    names = sorted({k[:-4] for k in idx if k.endswith(".tth") and k.startswith("materials/")} |
                   {os.path.relpath(os.path.join(d, f), os.path.join(args.game, "Unofficial_Patch"))[:-4].lower()
                    for d, _, fs in os.walk(os.path.join(args.game, "Unofficial_Patch", "materials"))
                    for f in fs if f.lower().endswith(".tth")})
    with Pool(max(1, (os.cpu_count() or 2) // 2), init, (args.game, idx)) as pool:
        lines = pool.map(one, names, chunksize=64)
    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        f.write("".join(lines))
    print(f"{sum(1 for x in lines if x)} of {len(names)} textures fingerprinted in {os.path.abspath(args.out)}")


if __name__ == "__main__":
    sys.exit(main())
