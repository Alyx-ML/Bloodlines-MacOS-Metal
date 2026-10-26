#!/usr/bin/env python3
"""The map textures tools/tex_extract.py --map exported, upscaled 4x with PBRify_Remix's
texture upscaler (https://github.com/Kim2091/PBRify_Remix, CC0, the player downloads it)
on the GPU, for tools/tex_pack.py. Run with chaiNNer's own Python, which has PyTorch and
spandrel:

    "~/Library/Application Support/chaiNNer/python/python/bin/python3.11" \\
        tools/tex_upscale_maps.py [--model FILE] [--dir DIR] [--only NAME ...]

Writes <name>-pbrify.png beside each export (at most --max on its longer side; alpha
enlarged plainly). Brush textures repeat across walls and floors, so each picture is
upscaled as a tile: its edges see the opposite edges, and the result repeats without a
seam. Existing results are kept; --only upscales just the textures whose name contains
one of these.
"""
import argparse
import json
import os
import sys

import numpy as np
import torch
from PIL import Image
from safetensors.torch import load_file
from spandrel import ModelLoader

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from tex_upscale import upscale  # noqa: E402

WRAP = 16  # pixels of the opposite edges each edge sees


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.path.join(HERE, "..", "build", "pbrify", "PBRify_Remix-1.7.2", "Models",
                                                    "4x-PBRify-UpscalerV4.safetensors"))
    ap.add_argument("--dir", default=os.path.join(HERE, "..", "build", "textures", "maps"))
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--max", type=int, default=2048, help="longest side of the result")
    args = ap.parse_args()
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    # A .safetensors file holds only tensors: nothing in it is run as code.
    sd = load_file(args.model) if args.model.endswith(".safetensors") else \
        torch.load(args.model, map_location="cpu", weights_only=True)
    m = ModelLoader().load_from_state_dict(sd)
    net = m.model.to(dev).eval().float()
    todo = []
    for d, _, files in os.walk(args.dir):
        if "index.json" in files:
            with open(os.path.join(d, "index.json")) as f:
                todo += [os.path.join(d, t["name"]) for t in json.load(f)
                         if not args.only or any(o in t["name"] for o in args.only)]
    done = 0
    for base in todo:
        dst = base + "-pbrify.png"
        if os.path.exists(dst):
            continue
        im = Image.open(base + ".png").convert("RGBA")
        a = np.asarray(im, np.float32) / 255
        w = min(WRAP, im.width, im.height)
        big = upscale(net, m.scale, np.pad(a[..., :3], ((w, w), (w, w), (0, 0)), mode="wrap"), dev)
        big = big[w * m.scale:-w * m.scale, w * m.scale:-w * m.scale]
        h, wd = big.shape[:2]
        k = min(1.0, args.max / max(wd, h))
        size = (int(wd * k), int(h * k))
        rgb = Image.fromarray((big * 255 + 0.5).astype(np.uint8), "RGB")
        if k < 1:
            rgb = rgb.resize(size, Image.LANCZOS)
        rgb.putalpha(im.getchannel("A").resize(size, Image.BICUBIC))
        rgb.save(dst + ".tmp.png")
        os.replace(dst + ".tmp.png", dst)
        done += 1
        print(f"{done}/{len(todo)} {os.path.relpath(base, args.dir)} -> {size[0]}x{size[1]}", flush=True)
    print(f"{done} textures upscaled ({len(todo)} listed) in {os.path.abspath(args.dir)}")


if __name__ == "__main__":
    sys.exit(main())
