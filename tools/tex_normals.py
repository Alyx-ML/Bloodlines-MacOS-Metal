#!/usr/bin/env python3
"""Normal maps for textures extracted by tools/tex_extract.py, made with PBRify_Remix's
normal model (https://github.com/Kim2091/PBRify_Remix, CC0, the player downloads it) on
the GPU. Run with chaiNNer's own Python, which has PyTorch and spandrel:

    "~/Library/Application Support/chaiNNer/python/python/bin/python3.11" \\
        tools/tex_normals.py --model .../1x-PBRify_NormalV3.pth [--match SUBSTRING ...]

With --rough (PBRify's roughness model) also <path>_r.png, how rough each spot is (white
rough, as the model makes them), which the renderer uses for the shine of skin and cloth.

Writes <textures>/<path>_n.png beside each texture (tangent space, as the model makes
them) and <textures>/normals.txt, the renderer's list of them. Like the textures, they are the player's own and never committed.
"""
import argparse
import json
import os
import sys

import numpy as np
import torch
from PIL import Image
from spandrel import ModelLoader

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--rough", help="PBRify's roughness model, for <path>_r.png too")
    ap.add_argument("--dir", default=os.path.join(HERE, "..", "build", "textures", "characters"))
    # Every person's skin and clothes: many keep the face in one "body" texture.
    ap.add_argument("--match", nargs="*", default=["character/npc/", "character/pc/"])
    ap.add_argument("--skip", nargs="*", default=["hair", "eye", "pupil", "teeth", "lens", "glass", "spec", "env",
                                                   "trans", "mask", "glint", "intestine", "liver", "gib"],
                    help="leave out textures whose file name has one of these")
    ap.add_argument("--force", action="store_true", help="remake maps that exist")
    args = ap.parse_args()
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    # weights_only: the .pth files are only read as tensors, never run as code.
    models = [(ModelLoader().load_from_state_dict(torch.load(m, map_location="cpu", weights_only=True))
               .to(dev).eval(), suffix) for m, suffix in ((args.model, "_n"), (args.rough, "_r")) if m]
    with open(os.path.join(args.dir, "index.json")) as f:
        index = json.load(f)
    todo = [t for t in index if any(m in t["name"] for m in args.match)
            and not any(k in os.path.basename(t["name"]).lower() for k in args.skip)]
    done = 0
    for t in todo:
        src = os.path.join(args.dir, t["name"] + ".png")
        rgb = None
        for model, suffix in models:
            dst = os.path.join(args.dir, t["name"] + suffix + ".png")
            if os.path.exists(dst) and not args.force:
                continue
            if rgb is None:
                rgb = np.asarray(Image.open(src).convert("RGB"), np.float32) / 255
            x = torch.from_numpy(rgb).permute(2, 0, 1)[None].to(dev)
            with torch.no_grad():
                y = model(x).clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy()
            if suffix == "_r":
                Image.fromarray((y.mean(2) * 255 + 0.5).astype(np.uint8), "L").save(dst)
            else:
                Image.fromarray((y * 255 + 0.5).astype(np.uint8), "RGB").save(dst)
            done += 1
    # The renderer's list (d3d9/tex_detail.m): size, signature and map of each texture
    # matched that has one.
    with open(os.path.join(args.dir, "normals.txt"), "w") as f:
        for t in todo:
            if os.path.exists(os.path.join(args.dir, t["name"] + "_n.png")):
                f.write(f'{t["w"]} {t["h"]} {" ".join(str(v) for v in t["sig"])} {t["name"]}_n.png\n')
    print(f"{done} maps made ({len(todo)} textures matched) in {os.path.abspath(args.dir)}")


if __name__ == "__main__":
    sys.exit(main())
