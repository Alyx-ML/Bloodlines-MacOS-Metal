#!/usr/bin/env python3
"""Map textures enlarged 2x with SeedVR2 (ByteDance Seed's restoration model, Apache 2.0),
run in MLX on the Mac's GPU through mlx-gen (`mlxgen upscale`) with the 7B model in 8-bit
(AbstractFramework/seedvr2-7b-8bit). It sharpens what the texture already shows without
redrawing its design: tile patterns, brick, painted walls and rugs come out clean.

    build/mlxgen/.venv/bin/python tools/tex_seedvr2.py --map sm_asylum_1 [--folders ...] [--only plaster/aswlla ...]

The setup (build/mlxgen: a venv with mlx-gen, and the model in
build/mlxgen/models/seedvr2-7b-8bit) is the player's own download; nothing of it is
committed. MLX needs the GPU, so this runs from a normal Terminal (outside a sandbox).

For each texture of the map (build/textures/maps/<map>/<folder>/<name>.png, --folders):
- skipped if the user has supplied a <name>-replace.png picture, or the texture is
  already --max-size or larger;
- wrapped around itself on every side (an eighth of its size), so the result repeats
  without seams like the brush texture it is, enlarged 2x, and trimmed back;
- its alpha, if any, enlarged smoothly and kept;
- written as <name>-seedvr2.png beside its PBRify upscale if there is one (that upscale
  is removed: tools/tex_pack.py takes one upscale per name), else in the map's folder.
Then tools/tex_pack.py packs it, matching its colours to the original's.
Textures go to SeedVR2 up to 6 per model load (about 5 minutes). A run stops starting new ones after
--minutes (4), so it ends within 10; run it again for the rest. Characters are left out (models/character):
skin and faces need their own approach.
"""
import argparse
import glob
import os
import shutil
import subprocess
import tempfile
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "build")
SUFFIXES = ("_n", "_r", "_h", "_u", "_m")
CHUNK = 6


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--map", required=True, help="the map folder whose textures to enlarge")
    ap.add_argument("--maps", default=os.path.join(ROOT, "textures", "maps"))
    ap.add_argument("--mlxgen", default=os.path.join(ROOT, "mlxgen"))
    ap.add_argument("--model", default="seedvr2-7b-8bit", help="model folder under <mlxgen>/models")
    ap.add_argument("--folders", nargs="*", default=["brick", "tile", "plaster", "carpet"])
    ap.add_argument("--only", nargs="*", help="only these textures (folder/name), or names containing these")
    ap.add_argument("--skip", nargs="*", default=["_ref", "lit", "glass", "sky", "water", "spec", "mask"])
    ap.add_argument("--max-size", type=int, default=1024, help="leave textures this size or larger as they are")
    ap.add_argument("--force", action="store_true", help="remake a -seedvr2.png already made")
    ap.add_argument("--minutes", type=float, default=4, help="start no new run of textures after this long")
    args = ap.parse_args()
    maps = os.path.abspath(args.maps)
    mlxgen = os.path.abspath(args.mlxgen)

    todo = []
    for folder in args.folders:
        for png in sorted(glob.glob(os.path.join(maps, args.map, folder, "**", "*.png"), recursive=True)):
            name = os.path.splitext(os.path.relpath(png, os.path.join(maps, args.map)))[0]
            base = os.path.basename(name)
            if "-" in base or base.endswith(SUFFIXES) or any(s in base for s in args.skip) \
                    or name.startswith("models/character/"):
                continue
            if args.only and not any(s == name or s in name for s in args.only):
                continue
            if glob.glob(os.path.join(maps, "*", name + "-replace.png")):
                continue
            if not args.force and glob.glob(os.path.join(maps, "*", name + "-seedvr2.png")):
                continue
            if min(Image.open(png).size) >= args.max_size:
                continue
            todo.append(name)
    print(f"{len(todo)} textures to enlarge")
    if not todo:
        return

    tmp = tempfile.mkdtemp(prefix="seedvr2_")
    start, left = time.time(), len(todo)
    for c in range(0, len(todo), CHUNK):
        if time.time() - start > args.minutes * 60:
            print(f"Stopped after {args.minutes:g} minutes: {left} textures left; run the same command again")
            break
        t0 = time.time()
        in_dir, out_dir = os.path.join(tmp, f"in{c}"), os.path.join(tmp, f"out{c}")
        os.makedirs(in_dir)
        os.makedirs(out_dir)
        items = []
        for i, name in enumerate(todo[c:c + CHUNK], c):
            im = Image.open(os.path.join(maps, args.map, name + ".png"))
            rgb = np.asarray(im.convert("RGB"))
            alpha = np.asarray(im.getchannel("A")) if im.mode == "RGBA" else None
            if alpha is not None and alpha.min() == 255:
                alpha = None
            pad = max(8, min(rgb.shape[:2]) // 8)
            Image.fromarray(np.pad(rgb, ((pad, pad), (pad, pad), (0, 0)), mode="wrap")).save(
                os.path.join(in_dir, f"{i:05d}.png"))
            items.append((i, name, pad, alpha))
        # --vae-tiling: the 7B's decode of a whole 1280-pixel picture runs out of GPU memory
        # on a 24 GB Mac; in tiles it fits (pictures of a million pixels or less are not tiled).
        subprocess.run([os.path.join(mlxgen, ".venv", "bin", "mlxgen"), "upscale",
                        "--model", os.path.join(mlxgen, "models", args.model), "--image-path", in_dir,
                        "--resolution", "2x", "--seed", "42", "--vae-tiling",
                        "--output", os.path.join(out_dir, "{input_name}.png")],
                       check=True)
        for i, name, pad, alpha in items:
            out = np.asarray(Image.open(os.path.join(out_dir, f"{i:05d}.png")).convert("RGB"))
            out = out[pad * 2:-pad * 2, pad * 2:-pad * 2]
            src = Image.open(os.path.join(maps, args.map, name + ".png"))
            if out.shape[:2] != (src.height * 2, src.width * 2):
                print(f"{name}: SeedVR2 gave {out.shape[1]}x{out.shape[0]}, not 2x; left out")
                continue
            # The 7B's detail with the original's colours: it recolours fine detail on its own
            # (the Asylum wall's beige scratches came out green, a brown rug blue), so only
            # its brightness is kept and the colour is the original's, enlarged.
            ycc = np.asarray(Image.fromarray(out).convert("YCbCr")).copy()
            ycc[..., 1:] = np.asarray(src.convert("RGB").resize((src.width * 2, src.height * 2), Image.LANCZOS)
                                      .convert("YCbCr"))[..., 1:]
            img = Image.fromarray(ycc, "YCbCr").convert("RGB")
            if alpha is not None:
                img.putalpha(Image.fromarray(alpha).resize(img.size, Image.LANCZOS))
            pbrify = glob.glob(os.path.join(maps, "*", name + "-pbrify.png"))
            dest = os.path.dirname(pbrify[0]) if pbrify else os.path.join(maps, args.map, os.path.dirname(name))
            img.save(os.path.join(dest, os.path.basename(name) + "-seedvr2.png"))
            for old in pbrify:
                os.remove(old)
            print(f"{name}: {src.width}x{src.height} -> {img.width}x{img.height}"
                  f"{' (PBRify upscale removed)' if pbrify else ''}", flush=True)
        left -= len(items)
        print(f"{len(items)} in {time.time() - t0:.0f} s; {left} left", flush=True)
    shutil.rmtree(tmp)


if __name__ == "__main__":
    main()
