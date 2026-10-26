#!/usr/bin/env python3
"""The PBRify batch for a whole game's textures on a rented GPU (Google Colab, see
tools/pbrify_colab.ipynb), from the job tools/colab_export.py packs on the player's Mac.
The results go back with tools/colab_import.py.

    python3 colab_pbrify.py --job DIR --out DIR [--scale 2] [--max 2048] [--tile 512]

The job (unzipped) holds models/ (PBRify_Remix's, https://github.com/Kim2091/PBRify_Remix,
CC0), tools/ (this, tex_upscale.py and tex_extract.py), and the textures as the game stores
them (<name>.tth and .ttz, decoded here as tex_extract.py does): world/ (brushes and
props, index.json with each texture's "normals") and characters/ (bodies and clothes that
have a normal map but no upscale yet). Writes to --out:
  world/<name>-pbrify.webp       upscaled --scale times, as a tile (the edges wrap)
  world/<name>_n.webp, _r.webp   PBRify's normal and roughness maps at the original size,
                                 lossless (colab_import.py turns them into PNGs)
  characters/<name>_u.webp       upscaled --scale times
The upscaler is 4x: its result is shrunk to --scale (at most --max on the longer side).
Results already in --out are kept, so a run cut off (Colab disconnects) carries on where
it stopped when started again. Upscales are WebP (quality 95), a fifth of a PNG's size:
tools/tex_pack.py stores them as BC7 in the end, which loses more than that.
"""
import argparse
import json
import os
import sys
import time

import numpy as np
import torch
from PIL import Image
from safetensors.torch import load_file
from spandrel import ModelLoader

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402
from tex_upscale import upscale  # noqa: E402

WRAP = 16  # pixels of the opposite edges each edge of a world texture sees (tex_upscale_maps.py)


def load(path, dev, dtype):
    # .safetensors and weights_only .pth hold only tensors: nothing in them is run as code.
    sd = load_file(path) if path.endswith(".safetensors") else torch.load(path, map_location="cpu", weights_only=True)
    m = ModelLoader().load_from_state_dict(sd)
    return m.model.to(dev).eval().to(dtype), m.scale


def picture(base):
    """The texture the game stores as <base>.tth and .ttz, as RGBA; None if undecodable."""
    with open(base + ".tth", "rb") as f, open(base + ".ttz", "rb") as g:
        img = tex_extract.texture(f.read(), g.read())
    return None if img is None else Image.fromarray(img, "RGBA")


def save(img, dst, **kw):
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    tmp = dst + ".tmp" + os.path.splitext(dst)[1]
    img.save(tmp, **kw)
    os.replace(tmp, dst)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--job", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--scale", type=int, default=2)
    ap.add_argument("--max", type=int, default=2048, help="longest side of an upscale")
    ap.add_argument("--tile", type=int, default=512)
    args = ap.parse_args()
    cuda = torch.cuda.is_available()
    dev = torch.device("cuda" if cuda else "mps" if torch.backends.mps.is_available() else "cpu")
    dtype = torch.float16 if cuda else torch.float32
    print(f"GPU: {torch.cuda.get_device_name(0) if cuda else dev}", flush=True)
    models = os.path.join(args.job, "models")
    up, up_scale = load(os.path.join(models, "4x-PBRify-UpscalerV4.safetensors"), dev, dtype)
    normal, _ = load(os.path.join(models, "1x-PBRify_NormalV3.pth"), dev, dtype)
    rough, _ = load(os.path.join(models, "1x-PBRify_RoughnessV2.pth"), dev, dtype)

    todo = []
    for part in ("characters", "world"):
        p = os.path.join(args.job, part, "index.json")
        if os.path.exists(p):
            with open(p) as f:
                todo += [(part, t) for t in json.load(f)]
    total = sum(t["w"] * t["h"] for _, t in todo)
    start, done, px, made, bad = time.time(), 0, 0, 0, 0
    for n, (part, t) in enumerate(todo, 1):
        dst = os.path.join(args.out, part, t["name"])
        k = args.scale
        while k > 1 and max(t["w"], t["h"]) * k > args.max:
            k //= 2
        jobs = []
        if k > 1:
            jobs.append(dst + ("-pbrify.webp" if part == "world" else "_u.webp"))
        if t.get("normals"):
            jobs += [dst + "_n.webp", dst + "_r.webp"]
        jobs = [j for j in jobs if not os.path.exists(j)]
        if jobs:
            im = picture(os.path.join(args.job, part, t["name"]))
            if im is None:
                bad += 1
                px += t["w"] * t["h"]
                continue
            rgb = np.asarray(im, np.float32)[..., :3] / 255
            for j in jobs:
                if j.endswith(("-pbrify.webp", "_u.webp")):
                    if part == "world":  # brush textures repeat: upscaled as a tile
                        w = min(WRAP, im.width, im.height)
                        big = upscale(up, up_scale, np.pad(rgb, ((w, w), (w, w), (0, 0)), mode="wrap"), dev,
                                      args.tile, dtype)
                        big = big[w * up_scale:-w * up_scale, w * up_scale:-w * up_scale]
                    else:
                        big = upscale(up, up_scale, rgb, dev, args.tile, dtype)
                    size = (im.width * k, im.height * k)
                    out = Image.fromarray((big * 255 + 0.5).astype(np.uint8), "RGB").resize(size, Image.LANCZOS)
                    out.putalpha(im.getchannel("A").resize(size, Image.BICUBIC))
                    save(out, j, quality=95, method=4)
                else:
                    x = torch.from_numpy(rgb).permute(2, 0, 1)[None].to(dev, dtype)
                    with torch.no_grad():
                        y = (normal if j.endswith("_n.webp") else rough)(x).clamp(0, 1)[0].permute(1, 2, 0)
                    y = y.float().cpu().numpy()
                    if j.endswith("_r.webp"):  # white rough, as tex_normals.py writes them
                        y = y.mean(2, keepdims=True).repeat(3, 2)
                    save(Image.fromarray((y * 255 + 0.5).astype(np.uint8), "RGB"), j, lossless=True, quality=100)
            done += 1
            made += t["w"] * t["h"]
        px += t["w"] * t["h"]
        if jobs and (done % 25 == 0 or n == len(todo)):
            spent = time.time() - start
            left = spent / max(made, 1) * (total - px)
            print(f"{n}/{len(todo)} {part}/{t['name']}: {px / total:.1%} of the pixels, "
                  f"{spent / 60:.0f} min so far, about {left / 60:.0f} min left", flush=True)
    print(f"finished: {done} textures made this run, {len(todo)} in the job ({bad} could not be read), "
          f"results in {args.out}")


if __name__ == "__main__":
    sys.exit(main())
