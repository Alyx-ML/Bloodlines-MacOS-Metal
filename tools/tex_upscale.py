#!/usr/bin/env python3
"""Sharper face textures: the textures tools/tex_extract.py extracted, upscaled with
PBRify_Remix's texture upscaler (https://github.com/Kim2091/PBRify_Remix, CC0, the player
downloads it) on the GPU. Run with chaiNNer's own Python, which has PyTorch and spandrel:

    "~/Library/Application Support/chaiNNer/python/python/bin/python3.11" \\
        tools/tex_upscale.py --model .../4x-PBRify-UpscalerV4.safetensors [--first NAME ...]

Writes <textures>/<path>_u.png beside each face or head texture (4x, at most 2048 on its
longer side; alpha enlarged plainly), which the renderer (d3d9/tex_detail.m) draws in
place of the game's copy. Like the textures, they are the player's own and never
committed. --first upscales textures whose name has one of these before the rest.
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
TILE, PAD = 256, 16


def upscale(net, scale, rgb, dev):
    """rgb: h x w x 3 float32. Tiles of TILE with PAD of overlap, so the edges match."""
    h, w = rgb.shape[:2]
    out = np.zeros((h * scale, w * scale, 3), np.float32)
    src = np.pad(rgb, ((PAD, PAD), (PAD, PAD), (0, 0)), mode="reflect")
    for y in range(0, h, TILE):
        for x in range(0, w, TILE):
            th, tw = min(TILE, h - y), min(TILE, w - x)
            tile = src[y:y + th + 2 * PAD, x:x + tw + 2 * PAD]
            t = torch.from_numpy(np.ascontiguousarray(tile)).permute(2, 0, 1)[None].to(dev)
            with torch.no_grad():
                r = net(t).clamp(0, 1)[0].permute(1, 2, 0).cpu().numpy()
            p = PAD * scale
            out[y * scale:(y + th) * scale, x * scale:(x + tw) * scale] = r[p:p + th * scale, p:p + tw * scale]
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--dir", default=os.path.join(HERE, "..", "build", "textures", "characters"))
    ap.add_argument("--match", nargs="*", default=["face", "head"])
    ap.add_argument("--skip", nargs="*", default=["spec", "env", "mask", "hair", "trans"])
    ap.add_argument("--first", nargs="*", default=[])
    ap.add_argument("--max", type=int, default=2048, help="longest side of the result")
    args = ap.parse_args()
    dev = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    # A .safetensors file holds only tensors: nothing in it is run as code.
    sd = load_file(args.model) if args.model.endswith(".safetensors") else \
        torch.load(args.model, map_location="cpu", weights_only=True)
    m = ModelLoader().load_from_state_dict(sd)
    net = m.model.to(dev).eval().float()
    with open(os.path.join(args.dir, "index.json")) as f:
        index = json.load(f)
    todo = [t for t in index if any(p in t["name"] for p in ("character/npc/", "character/pc/"))
            and any(k in os.path.basename(t["name"]).lower() for k in args.match)
            and not any(k in os.path.basename(t["name"]).lower() for k in args.skip)]
    todo.sort(key=lambda t: (not any(f in t["name"] for f in args.first), t["w"] * t["h"]))
    done = 0
    for t in todo:
        dst = os.path.join(args.dir, t["name"] + "_u.png")
        if os.path.exists(dst):
            continue
        im = Image.open(os.path.join(args.dir, t["name"] + ".png")).convert("RGBA")
        a = np.asarray(im, np.float32) / 255
        big = upscale(net, m.scale, a[..., :3], dev)
        h, w = big.shape[:2]
        k = min(1.0, args.max / max(w, h))
        size = (int(w * k), int(h * k))
        rgb = Image.fromarray((big * 255 + 0.5).astype(np.uint8), "RGB")
        if k < 1:
            rgb = rgb.resize(size, Image.LANCZOS)
        alpha = im.getchannel("A").resize(size, Image.BICUBIC)
        rgb.putalpha(alpha)
        rgb.save(dst + ".tmp.png")
        os.replace(dst + ".tmp.png", dst)
        done += 1
        print(f"{done}/{len(todo)} {t['name']} -> {size[0]}x{size[1]}", flush=True)
    print(f"{done} textures upscaled ({len(todo)} matched) in {os.path.abspath(args.dir)}")


if __name__ == "__main__":
    sys.exit(main())
