#!/usr/bin/env python3
"""Height maps for the map textures tools/tex_extract.py --map exported, for the renderer's
parallax (metal_render.m pom_map), made with PBRify_Remix's height model
(https://github.com/Kim2091/PBRify_Remix, CC0, the player downloads it) on the GPU. Run
with chaiNNer's own Python, which has PyTorch and spandrel:

    "~/Library/Application Support/chaiNNer/python/python/bin/python3.11" \\
        tools/tex_height.py --only NAME ... [--dir DIR] [--model FILE] [--force]

Writes <name>_h.png beside each export whose name ends with one of --only (white high,
as the model makes them), from the picture the renderer draws: <name>-replace.png, else
<name>-pbrify.png, else the export itself. Brush textures repeat across walls and floors,
so each picture is read as a tile (its edges see the opposite edges) and the map repeats
without a seam. Like the textures, they are the player's own and never committed.
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
WRAP = 32  # pixels of the opposite edges each edge sees


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(HERE, "..", "build", "pbrify", "PBRify_Remix-1.7.2", "Models",
                                                    "1x-PBRify_Height.pth"))
    ap.add_argument("--dir", default=os.path.join(HERE, "..", "build", "textures", "maps"))
    ap.add_argument("--only", nargs="+", required=True, help="texture names (as materials/... without it) to make")
    ap.add_argument("--force", action="store_true", help="remake maps that exist")
    args = ap.parse_args()
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    # weights_only: the .pth file is only read as tensors, never run as code.
    net = ModelLoader().load_from_state_dict(torch.load(args.model, map_location="cpu", weights_only=True)).to(dev).eval()
    todo = []
    for d, _, files in os.walk(args.dir):
        if "index.json" in files:
            with open(os.path.join(d, "index.json")) as f:
                todo += [os.path.join(d, t["name"]) for t in json.load(f) if any(t["name"].endswith(o) for o in args.only)]
    done = 0
    for base in todo:
        dst = base + "_h.png"
        if os.path.exists(dst) and not args.force:
            continue
        src = next(p for p in (base + "-replace.png", base + "-pbrify.png", base + ".png") if os.path.exists(p))
        rgb = np.asarray(Image.open(src).convert("RGB"), np.float32) / 255
        w = min(WRAP, rgb.shape[0], rgb.shape[1])
        x = torch.from_numpy(np.pad(rgb, ((w, w), (w, w), (0, 0)), mode="wrap")).permute(2, 0, 1)[None].to(dev)
        with torch.no_grad():
            y = net(x).clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy()[w:-w, w:-w]
        Image.fromarray((y.mean(2) * 255 + 0.5).astype(np.uint8), "L").save(dst)
        done += 1
        print(f"{done} {os.path.relpath(base, args.dir)} <- {os.path.basename(src)} ({y.shape[1]}x{y.shape[0]})", flush=True)
    print(f"{done} height maps made ({len(todo)} matched) in {os.path.abspath(args.dir)}")


if __name__ == "__main__":
    sys.exit(main())
