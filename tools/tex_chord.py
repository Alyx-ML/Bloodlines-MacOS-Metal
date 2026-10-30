#!/usr/bin/env python3
"""Material maps for map surfaces made with Ubisoft La Forge's Chord
(https://github.com/ubisoft/ubisoft-laforge-chord, research-only licence: the player
downloads the code and the model and runs it on their own textures; nothing of it is
committed or shipped). Chord reads a texture's picture and estimates its surface: the
bumps (normal map), how rough each spot is and how metallic.

    <venv>/bin/python tools/tex_chord.py --chord <chord checkout> --ckpt <chord_v1.safetensors> \\
        --map sm_hub_1 [--limit N] [--force]

The venv needs PyTorch (with the Mac's GPU, mps), diffusers, transformers 4.57.1 and
Chord's requirements.txt; Chord's code needs "cuda" changed to "mps" where it picks its
device. It runs outside the sandbox (the GPU).

For each surface texture of the map (build/textures/maps/<map>/<folder>/<name>.png,
--folders), writes beside the texture the renderer finds for that name (an earlier map
of the same name in any map folder, so a height map beside it stays paired; else the
user's <name>-replace.png's folder; else this map's), replacing what was there:
- <name>_n.png: the bumps, tangent space with green down like PBRify's, made stronger
  (--bump) since Chord's are about a third as steep;
- <name>_r.png: roughness (white rough). The ground (roads, pavements, kerbs) is kept
  rough (--ground-rough); the rain effects make it wet and shiny when it rains.
- <name>_h.png, for the ground only and where there is none: its height for the
  renderer's parallax, worked out from the bumps (height_from_normals). --heights makes
  these alone from the maps already made.
Maps of the same name in other map folders are removed (the renderer takes one).
Each texture's average metalness goes in build/textures/maps/chord_metal.txt
("<folder>/<name> <metalness>"), which the renderer uses for the metal folder's
textures in place of its guess (painted metal is not metallic). The picture read is the user's <name>-replace.png when there is one
(what the game draws), else the exported texture. Maps come out at the texture's size.
Textures done are listed in chord_done.txt and skipped (--force remakes them).
"""
import argparse
import glob
import os
import sys
import time

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
SUFFIXES = ("_n", "_r", "_h", "_u", "_m")
# Bare metal that Chord reads as paint: these keep at least 0.8 metalness.
BARE_METAL = ("brushed", "galv", "chainlink", "elevdoor")


def is_ground(name):
    """Roads, pavements, kerbs: the ground folder and asphalt, and street/sidewalk/curb anywhere."""
    return name.split("/")[0] in ("ground", "asphalt") or any(s in name for s in ("street", "sidewalk", "curb"))


def height_from_normals(n_path, h_path):
    """A height map (white high) for the parallax, from a normal map (green down) by
    Frankot-Chellappa: the slopes the normals give, integrated over the texture as a tile
    (the FFT wraps, as the brush textures repeat). The renderer stretches it to its own
    range (bl_load_height_map), so only its shape matters."""
    n = np.asarray(Image.open(n_path).convert("RGB")).astype(np.float64) / 127.5 - 1
    nz = np.maximum(n[..., 2], 0.2)
    p, q = -n[..., 0] / nz, -n[..., 1] / nz  # dh/dx, dh/dy with y down the picture
    h, w = p.shape
    u = np.fft.fftfreq(w)[None, :] * 2 * np.pi
    v = np.fft.fftfreq(h)[:, None] * 2 * np.pi
    d = u * u + v * v
    d[0, 0] = 1
    H = (-1j * u * np.fft.fft2(p) - 1j * v * np.fft.fft2(q)) / d
    H[0, 0] = 0
    # Without the swells longer than about a sixth of the texture: integrated slopes drift
    # into hills as wide as the tile, which would hide the cracks and potholes.
    c = (2 * np.pi * 6 / max(w, h)) ** 2
    H *= d / (d + c)
    # And without the finest grit (a blur of 2 pixels): at full height it stands up in
    # spikes when the parallax looks along the ground.
    H *= np.exp(-0.5 * 2.0 ** 2 * d)
    hgt = np.real(np.fft.ifft2(H))
    lo, hi = np.percentile(hgt, 1), np.percentile(hgt, 99)
    Image.fromarray((np.clip((hgt - lo) / max(hi - lo, 1e-9), 0, 1) * 255 + 0.5).astype(np.uint8), "L").save(h_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--chord", required=True, help="Chord's checkout (its chord/ package and config/)")
    ap.add_argument("--ckpt", required=True, help="chord_v1.safetensors")
    ap.add_argument("--maps", default=os.path.join(HERE, "..", "build", "textures", "maps"))
    ap.add_argument("--map", required=True, help="the map folder whose surfaces to make maps for")
    ap.add_argument("--folders", nargs="*", default=["plaster", "building", "concrete", "metal", "stone", "wood",
                                                     "brick", "ground", "tile", "asphalt"])
    ap.add_argument("--skip", nargs="*", default=["_ref", "lit", "glass", "sky", "water", "spec", "mask"],
                    help="leave out textures whose name has one of these")
    ap.add_argument("--bump", type=float, default=2.5, help="how much steeper than Chord's the bumps are made")
    ap.add_argument("--limit", type=int, default=0, help="stop after this many (0: all)")
    ap.add_argument("--force", action="store_true", help="remake maps already made with Chord")
    ap.add_argument("--only", nargs="*", help="only textures whose name has one of these")
    ap.add_argument("--heights", action="store_true",
                    help="only make the ground's height maps from its Chord maps already made (no model)")
    ap.add_argument("--ground-rough", type=float, default=0.75,
                    help="how rough the ground at least is (roads, pavements, kerbs): Chord's roughness is "
                         "squeezed into this to 1, so worn tracks still show but nothing shines like glass")
    args = ap.parse_args()
    maps = os.path.abspath(args.maps)

    done_path = os.path.join(maps, "chord_done.txt")
    done = set(open(done_path).read().split()) if os.path.exists(done_path) else set()
    metal_path = os.path.join(maps, "chord_metal.txt")
    metal = dict(l.split() for l in open(metal_path) if l.strip()) if os.path.exists(metal_path) else {}

    todo = []
    for folder in args.folders:
        for png in sorted(glob.glob(os.path.join(maps, args.map, folder, "**", "*.png"), recursive=True)):
            name = os.path.splitext(os.path.relpath(png, os.path.join(maps, args.map)))[0]
            base = os.path.basename(name)
            if "-" in base or base.endswith(SUFFIXES) or any(s in base for s in args.skip):
                continue
            if name in done and not args.force:
                continue
            if args.only and not any(s in name for s in args.only):
                continue
            todo.append(name)
    if args.heights:
        # Height maps from the ground's Chord maps already made, without the model.
        made = 0
        for name in sorted(done):
            if not is_ground(name):
                continue
            for d in sorted(os.listdir(maps)):
                base = os.path.join(maps, d, name)
                if os.path.isfile(base + "_n.png") and (args.force or not os.path.exists(base + "_h.png")):
                    height_from_normals(base + "_n.png", base + "_h.png")
                    made += 1
                    print(f"{name} -> {d}", flush=True)
        print(f"{made} height maps made")
        return
    if args.limit:
        todo = todo[:args.limit]
    print(f"{len(todo)} textures to make maps for")
    if not todo:
        return

    sys.path.insert(0, os.path.abspath(args.chord))
    import torch
    from omegaconf import OmegaConf
    from torchvision.transforms import v2
    from chord import ChordModel
    from chord.io import load_torch_file
    dev = torch.device("mps")
    t0 = time.time()
    model = ChordModel(OmegaConf.load(os.path.join(args.chord, "config", "chord.yaml")))
    model.load_state_dict(load_torch_file(args.ckpt))
    model.eval().to(dev)
    print(f"model loaded in {time.time() - t0:.0f} s")

    for i, name in enumerate(todo):
        t0 = time.time()
        others = [d for d in sorted(os.listdir(maps)) if os.path.isfile(os.path.join(maps, d, name + ".png"))
                  or os.path.isfile(os.path.join(maps, d, name + "-replace.png"))]
        target = next((d for d in others if os.path.isfile(os.path.join(maps, d, name + "_n.png"))), None)
        replace = next((d for d in others if os.path.isfile(os.path.join(maps, d, name + "-replace.png"))), None)
        target = target or replace or args.map
        game = Image.open(os.path.join(maps, args.map, name + ".png"))
        src = os.path.join(maps, replace, name + "-replace.png") if replace else os.path.join(maps, args.map, name + ".png")
        img = np.asarray(Image.open(src).convert("RGB")).astype(np.float32) / 255
        x = torch.from_numpy(img).movedim(2, 0).to(dev)
        x = v2.Resize(size=(1024, 1024), antialias=True)(x).unsqueeze(0)
        with torch.no_grad(), torch.autocast(device_type="mps", dtype=torch.bfloat16):
            out = model(x)
        size = (game.height, game.width)
        get = lambda k: v2.Resize(size=size, antialias=True)(out[k].float()).squeeze(0).cpu().numpy()
        n = get("normal") * 2 - 1  # 3 x h x w
        n[:2] *= args.bump
        n /= np.linalg.norm(n, axis=0, keepdims=True) + 1e-6
        rough, met = get("roughness"), get("metalness")
        rough, met = rough.reshape(size), met.reshape(size)
        if is_ground(name):
            rough = args.ground_rough + (1 - args.ground_rough) * rough
        u8 = lambda a: (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)
        out_base = os.path.join(maps, target, name)
        Image.fromarray(u8(np.moveaxis(n, 0, 2) * 0.5 + 0.5), "RGB").save(out_base + "_n.png")
        Image.fromarray(u8(rough), "L").save(out_base + "_r.png")
        if is_ground(name) and (args.force or not os.path.exists(out_base + "_h.png")):
            height_from_normals(out_base + "_n.png", out_base + "_h.png")
        for d in os.listdir(maps):  # one map of each name: the renderer takes one
            if d != target:
                for s in ("_n", "_r"):
                    p = os.path.join(maps, d, name + s + ".png")
                    if os.path.isfile(p):
                        os.remove(p)
        # Chord sees bare steel (brushed, galvanised, chain-link, lift doors) as paint.
        bare = any(s in name for s in BARE_METAL)
        metal[name] = f"{max(float(met.mean()), 0.8 if bare else 0):.3f}"
        done.add(name)
        # Written after each texture, so a stopped run keeps what it made.
        with open(metal_path + ".part", "w") as f:
            f.writelines(f"{k} {v}\n" for k, v in sorted(metal.items()))
        os.replace(metal_path + ".part", metal_path)
        with open(done_path + ".part", "w") as f:
            f.writelines(f"{k}\n" for k in sorted(done))
        os.replace(done_path + ".part", done_path)
        print(f"[{i + 1}/{len(todo)}] {name} -> {target}: metal {metal[name]}, {time.time() - t0:.1f} s", flush=True)


if __name__ == "__main__":
    main()
