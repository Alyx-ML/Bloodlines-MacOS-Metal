#!/usr/bin/env python3
"""Pack the whole game's textures into one zip for the PBRify batch on a rented GPU
(tools/pbrify_colab.ipynb runs tools/colab_pbrify.py on it; tools/colab_import.py brings
the results back). The zip is the player's own game art: it goes only to their own
storage (their Google Drive) and is never committed or shared.

    python3 tools/colab_export.py [--game DIR] [--out FILE] [--only SUBSTRING ...] [--limit N]

In the zip, under job/, the textures as the game stores them (<name>.tth and .ttz, which
colab_pbrify.py decodes as tools/tex_extract.py does: a sixth of their size as PNGs):
  world/        every texture under materials/, and index.json (name, size, "normals":
                whether PBRify's normal and roughness maps are made too). Left out:
                characters (below), menus and HUD, developer and test textures, animated
                textures and cube maps, textures under 8 pixels, and the textures already
                exported for a level (build/textures/maps/<level>/).
  characters/   the character textures (build/textures/characters) that have a normal map
                but no upscale yet, and index.json.
  models/       PBRify_Remix's upscaler, normal and roughness models (CC0).
  tools/        colab_pbrify.py, tex_upscale.py and tex_extract.py.
Also writes build/textures/maps/all/index.json, where colab_import.py puts the results.
--only and --limit pack a part of it (for a test).
"""
import argparse
import json
import os
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402

TEXTURES = os.path.join(HERE, "..", "build", "textures")
MODELS = os.path.join(HERE, "..", "build", "pbrify", "PBRify_Remix-1.7.2", "Models")
# Folders under materials/ never upscaled: characters (their own set), menus and HUD,
# developer and test textures, and the compiler's per-map copies.
LEAVE_OUT = ("models/character/", "hud/", "interface/", "vgui/", "console/", "dev/", "debug/", "shadertest/",
             "tools/", "maps/")
# Textures that get no normal or roughness map: transparent, glowing, sky and effect
# textures, and masks.
NO_NORMALS = ("decals/", "effects/", "sprites/", "lights/", "skybox/", "particle", "liquids/", "water", "glass",
              "_ref", "env", "mask", "trans", "overlay", "glow")
ENVMAP = 0x4000


def names(game, idx):
    """materials/... texture paths (no extension), in the VPKs and the patch's loose files."""
    out = {k[:-4] for k in idx if k.startswith("materials/") and k.endswith(".tth")}
    loose = os.path.join(game, "Unofficial_Patch")
    for d, _, files in os.walk(os.path.join(loose, "materials")):
        for f in files:
            if f.lower().endswith(".tth"):
                out.add(os.path.relpath(os.path.join(d, f[:-4]), loose).replace(os.sep, "/").lower())
    return sorted(out)


def files(game, idx, name):
    """(width, height, .tth, .ttz) of a texture, or None for one left out."""
    tth, ttz = tex_extract.read(game, idx, name + ".tth"), tex_extract.read(game, idx, name + ".ttz")
    if not tth or not ttz or len(tth) < 7:
        return None
    v = 12 + 8 * (tth[6] + 1)
    if len(tth) < v + 28 or tth[v:v + 4] != b"VTF\0":
        return None
    w, h, flags, frames = struct.unpack_from("<HHIH", tth, v + 16)
    if frames != 1 or flags & ENVMAP or w < 8 or h < 8:
        return None
    return w, h, tth, ttz


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "colab", "pbrify_job.zip"))
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()
    idx = tex_extract.vpk_index(args.game)
    # Textures a level's export already has (tools/tex_extract.py --map): upscaled there.
    have = set()
    maps = os.path.join(TEXTURES, "maps")
    for level in os.listdir(maps) if os.path.isdir(maps) else []:
        p = os.path.join(maps, level, "index.json")
        if level != "all" and os.path.exists(p):
            with open(p) as f:
                have |= {t["name"] for t in json.load(f)}
    todo = [n for n in names(args.game, idx)
            if not n[len("materials/"):].startswith(LEAVE_OUT) and n[len("materials/"):] not in have
            and (not args.only or any(o in n for o in args.only))]
    if args.limit:
        todo = todo[:args.limit]
    # Characters with a normal map (tools/tex_normals.py) and no upscale yet.
    chars = os.path.join(TEXTURES, "characters")
    with open(os.path.join(chars, "index.json")) as f:
        people = [t for t in json.load(f)
                  if os.path.exists(os.path.join(chars, t["name"] + "_n.png"))
                  and not os.path.exists(os.path.join(chars, t["name"] + "_u.png"))
                  and (not args.only or any(o in t["name"] for o in args.only))]
    if args.limit:
        people = people[:args.limit]

    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    world, left_out = [], 0
    with zipfile.ZipFile(args.out + ".tmp", "w", zipfile.ZIP_STORED) as z:
        for part, wanted, entry in (
                ("world", todo, lambda rel, w, h: {"name": rel, "w": w, "h": h,
                                                   "normals": not any(k in rel for k in NO_NORMALS)}),
                ("characters", ["materials/" + t["name"] for t in people],
                 lambda rel, w, h: {"name": rel, "w": w, "h": h})):
            index = []
            for n in wanted:
                r = files(args.game, idx, n)
                if r is None:
                    left_out += 1
                    continue
                rel = n[len("materials/"):]
                z.writestr(f"job/{part}/{rel}.tth", r[2])
                z.writestr(f"job/{part}/{rel}.ttz", r[3])
                index.append(entry(rel, r[0], r[1]))
            z.writestr(f"job/{part}/index.json", json.dumps(index))
            if part == "world":
                world = index
            else:
                people = index
        for m in ("4x-PBRify-UpscalerV4.safetensors", "1x-PBRify_NormalV3.pth", "1x-PBRify_RoughnessV2.pth"):
            z.write(os.path.join(MODELS, m), "job/models/" + m)
        for t in ("colab_pbrify.py", "tex_upscale.py", "tex_extract.py"):
            z.write(os.path.join(HERE, t), "job/tools/" + t)
    os.replace(args.out + ".tmp", args.out)
    allx = os.path.join(maps, "all")
    os.makedirs(allx, exist_ok=True)
    with open(os.path.join(allx, "index.json"), "w") as f:
        json.dump(world, f)
    mpx = sum(t["w"] * t["h"] for t in world + people) / 1e6
    print(f"{len(world)} world textures ({sum(t['normals'] for t in world)} with normal maps, {left_out} left out) "
          f"and {len(people)} character textures, {mpx:.0f} megapixels, in {os.path.abspath(args.out)} "
          f"({os.path.getsize(args.out) / 1e9:.1f} GB)")


if __name__ == "__main__":
    sys.exit(main())
