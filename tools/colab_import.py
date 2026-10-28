#!/usr/bin/env python3
"""Bring back the PBRify batch's results (tools/colab_pbrify.py's --out folder, as Google
Drive downloads it: one or more zips, or the folder itself) and make the textures the
renderer draws from them.

    python3 tools/colab_import.py RESULT [RESULT ...] [--no-pack]

world/ goes to build/textures/maps/all/ (where tools/colab_export.py wrote index.json):
the upscales stay WebP, which tools/tex_pack.py then stores as BC7 in build/hires, and
the normal and roughness maps (lossless WebP) become the PNGs the renderer finds there
(metal_render.m pbr_map; roughness one channel, as tools/tex_normals.py writes it).
characters/ <name>_u.webp go to build/textures/characters/<name>_u.png, beside each
normal map (d3d9/tex_detail.m). Files already there are replaced.
"""
import argparse
import io
import os
import subprocess
import sys
import zipfile

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
TEXTURES = os.path.realpath(os.path.join(HERE, "..", "build", "textures"))


def inside(dst):
    """dst, if it lies under TEXTURES (a zip's names could lead anywhere with ..)."""
    real = os.path.realpath(dst)
    if os.path.commonpath([real, TEXTURES]) != TEXTURES:
        raise SystemExit(f"colab_import: refusing to write outside {TEXTURES}: {dst}")
    return real


def place(path, data):
    """Where a result goes: its path from world/ or characters/ on. False if not a result."""
    parts = path.replace("\\", "/").split("/")
    for i, p in enumerate(parts):
        if p in ("world", "characters") and i + 1 < len(parts):
            rest = parts[i + 1:]
            if any(q in ("", ".", "..") for q in rest):
                return False  # not a plain path below world/ or characters/
            rel = "/".join(rest)
            if ".tmp." in rel:
                return False  # cut off while being written
            if p == "world" and rel.endswith(("_n.webp", "_r.webp")):
                dst = inside(os.path.join(TEXTURES, "maps", "all", rel[:-5] + ".png"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                img = Image.open(io.BytesIO(data()))
                img.convert("L" if rel.endswith("_r.webp") else "RGB").save(dst)
            elif p == "world":
                dst = inside(os.path.join(TEXTURES, "maps", "all", rel))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                with open(dst, "wb") as f:
                    f.write(data())
            elif rel.endswith("_u.webp"):
                dst = inside(os.path.join(TEXTURES, "characters", rel[:-5] + ".png"))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                Image.open(io.BytesIO(data())).save(dst)
            else:
                return False
            return True
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("results", nargs="+")
    ap.add_argument("--no-pack", action="store_true", help="leave out tools/tex_pack.py")
    args = ap.parse_args()
    n = 0
    for r in args.results:
        if os.path.isdir(r):
            for d, _, files in os.walk(r):
                for f in files:
                    p = os.path.join(d, f)
                    n += place(os.path.relpath(p, r), lambda p=p: open(p, "rb").read())
        else:
            with zipfile.ZipFile(r) as z:
                for m in z.namelist():
                    if not m.endswith("/"):
                        n += place(m, lambda m=m: z.read(m))
        print(f"{n} results so far ({os.path.basename(r)})", flush=True)
    if not args.no_pack:
        # The upscales into the textures the renderer draws (BC7), all levels' exports.
        subprocess.run([sys.executable, os.path.join(HERE, "tex_pack.py")])
    print(f"{n} results imported")


if __name__ == "__main__":
    sys.exit(main())
