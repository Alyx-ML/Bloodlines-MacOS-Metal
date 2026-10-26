#!/usr/bin/env python3
"""Extract textures from the player's own Bloodlines install as PNGs, for making normal
maps and upscales (tools/tex_normals.py). The output is the game's art: it stays on the
player's machine (by default under native/build/, which git ignores) and is never
committed or shipped.

Bloodlines keeps its files in Vampire/pack*.vpk (a list of name, offset, size at the end:
count and list offset in the last 9 bytes) and the Unofficial Patch's loose files over
them. A texture is a .tth (Troika's header, then a VTF 7.x header and its low-resolution
picture) and a .ttz (the mipmaps, zlib-compressed, smallest first); the largest mipmap is
the end of the .ttz.

    python3 tools/tex_extract.py [--game DIR] [--out DIR] [--match SUBSTRING ...]
    python3 tools/tex_extract.py --map sm_asylum_1 [--game DIR] [--out DIR]
    python3 tools/tex_extract.py --list build/logs/not_upscaled.txt --map sm_asylum_1

Default: the character textures (materials/models/character/). With --map, the colour
textures ($basetexture, $basetexture2) of everything a map shows apart from characters
and weapons: its brushes (the texture data lump; tool textures left out) and its models,
static props (the game lump's sprp) and entities (the entity lump's "model" keys), whose
materials are each texture name in the .mdl looked up in each of its material folders.
With --list, the textures named in a file, one per line: the renderer's list of what it
drew without an upscale (runtime/d3d9/tex_hires.m), characters and weapons left out. They
are added to the folder: exports already there and the rest of index.json are kept.
Writes <out>/<path>.png and <out>/index.json (name, width, height, and an 8x8 colour
signature the renderer uses to recognise the texture once the game has loaded it).
"""
import argparse
import json
import os
import re
import struct
import sys
import zlib

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))


def vpk_index(game):
    idx = {}
    vdir = os.path.join(game, "Vampire")
    for name in sorted(os.listdir(vdir)):
        if not (name.startswith("pack") and name.endswith(".vpk")):
            continue
        path = os.path.join(vdir, name)
        with open(path, "rb") as f:
            f.seek(os.path.getsize(path) - 9)
            count, off = struct.unpack("<II", f.read(8))
            f.seek(off)
            d = f.read()
        i = 0
        for _ in range(count):
            n = struct.unpack_from("<I", d, i)[0]
            fname = d[i + 4:i + 4 + n].decode("latin1").lower()
            o, s = struct.unpack_from("<II", d, i + 4 + n)
            i += 4 + n + 8
            idx[fname] = (path, o, s)
    return idx


def read(game, idx, name):
    for mod in ("Unofficial_Patch",):
        p = os.path.join(game, mod, name)
        if os.path.exists(p):
            with open(p, "rb") as f:
                return f.read()
    if name not in idx:
        return None
    path, o, s = idx[name]
    with open(path, "rb") as f:
        f.seek(o)
        return f.read(s)


def dxt_colors(b):
    c0, c1 = b[..., 0].astype(np.int32) | (b[..., 1].astype(np.int32) << 8), \
             b[..., 2].astype(np.int32) | (b[..., 3].astype(np.int32) << 8)

    def rgb(c):
        return np.stack([(c >> 11 & 31) * 255 // 31, (c >> 5 & 63) * 255 // 63, (c & 31) * 255 // 31], -1)

    a, z = rgb(c0), rgb(c1)
    four = (c0 > c1)[..., None]
    p2 = np.where(four, (2 * a + z) // 3, (a + z) // 2)
    p3 = np.where(four, (a + 2 * z) // 3, 0)
    pal = np.stack([a, z, p2, p3], -2)  # blocks x 4 x 3
    bits = b[..., 4].astype(np.uint32) | b[..., 5].astype(np.uint32) << 8 | \
        b[..., 6].astype(np.uint32) << 16 | b[..., 7].astype(np.uint32) << 24
    sel = (bits[..., None] >> (2 * np.arange(16))) & 3  # blocks x 16
    out = np.take_along_axis(pal, sel[..., None].astype(np.int64).repeat(3, -1), -2)
    transparent = (~four[..., 0])[..., None] & (sel == 3)
    return out, transparent


def decode(data, w, h, fmt):
    """VTF formats: 0 RGBA8888, 1 ABGR8888, 2 RGB888, 3 BGR888, 12 BGRA8888,
    13 DXT1, 14 DXT3, 15 DXT5. Returns an RGBA uint8 array."""
    if fmt in (0, 1, 12):
        a = np.frombuffer(data, np.uint8, w * h * 4).reshape(h, w, 4)
        return a if fmt == 0 else a[..., [3, 2, 1, 0]] if fmt == 1 else a[..., [2, 1, 0, 3]]
    if fmt in (2, 3):
        a = np.frombuffer(data, np.uint8, w * h * 3).reshape(h, w, 3)
        if fmt == 3:
            a = a[..., ::-1]
        return np.concatenate([a, np.full((h, w, 1), 255, np.uint8)], -1)
    if fmt in (13, 14, 15):
        bw, bh = max(1, (w + 3) // 4), max(1, (h + 3) // 4)
        size = 8 if fmt == 13 else 16
        b = np.frombuffer(data, np.uint8, bw * bh * size).reshape(bh, bw, size)
        col, transparent = dxt_colors(b[..., size - 8:])
        if fmt == 13:
            alpha = np.where(transparent, 0, 255)
        elif fmt == 14:
            nib = b[..., :8].astype(np.uint32)
            alpha = np.stack([(nib[..., i // 2] >> (4 * (i % 2)) & 15) * 17 for i in range(16)], -1)
        else:
            a0, a1 = b[..., 0].astype(np.int32), b[..., 1].astype(np.int32)
            bits = np.zeros((bh, bw), np.uint64)
            for i in range(6):
                bits |= b[..., 2 + i].astype(np.uint64) << np.uint64(8 * i)
            sel = ((bits[..., None] >> (np.uint64(3) * np.arange(16, dtype=np.uint64))) & np.uint64(7)).astype(np.int32)
            eight = (a0 > a1)[..., None]
            k = sel
            v8 = np.where(k == 0, a0[..., None], np.where(k == 1, a1[..., None],
                          ((8 - k) * a0[..., None] + (k - 1) * a1[..., None]) // 7))
            v6 = np.where(k == 0, a0[..., None], np.where(k == 1, a1[..., None], np.where(
                k == 6, 0, np.where(k == 7, 255, ((6 - k) * a0[..., None] + (k - 1) * a1[..., None]) // 5))))
            alpha = np.where(eight, v8, v6)
        px = np.concatenate([col, alpha[..., None]], -1).astype(np.uint8)  # bh, bw, 16, 4
        img = px.reshape(bh, bw, 4, 4, 4).transpose(0, 2, 1, 3, 4).reshape(bh * 4, bw * 4, 4)
        return img[:h, :w]
    return None


def mip_size(w, h, fmt):
    if fmt in (13, 14, 15):
        return max(1, (w + 3) // 4) * max(1, (h + 3) // 4) * (8 if fmt == 13 else 16)
    return w * h * (3 if fmt in (2, 3) else 4)


def texture(tth, ttz):
    v = tth.find(b"VTF\0")
    if v < 0:
        return None
    vh = tth[v:]
    w, h = struct.unpack_from("<HH", vh, 16)
    fmt = struct.unpack_from("<i", vh, 52)[0]
    # Some .ttz files end with a wrong checksum: inflate the raw stream, which skips it.
    try:
        data = zlib.decompressobj(-15).decompress(ttz[2:])
    except zlib.error:
        return None
    need = mip_size(w, h, fmt)
    if len(data) < need:
        return None
    img = decode(data[len(data) - need:], w, h, fmt)
    return img


def signature(rgba):
    """8x8 mean colour, 0..1: how the renderer recognises the texture once loaded."""
    h, w = rgba.shape[:2]
    a = rgba[: h // 8 * 8, : w // 8 * 8, :3].astype(np.float32) / 255
    return a.reshape(8, h // 8, 8, w // 8, 3).mean((1, 3)).round(4).reshape(-1).tolist()


def exists(game, idx, name):
    return name in idx or os.path.exists(os.path.join(game, "Unofficial_Patch", name))


def map_textures(game, idx, name):
    """The texture paths (materials/..., no extension) of a map's colour textures."""
    d = read(game, idx, "maps/%s.bsp" % name)
    if not d or d[:4] != b"VBSP":
        sys.exit("no maps/%s.bsp" % name)
    lump = [struct.unpack_from("<ii", d, 8 + 16 * i) for i in range(64)]
    # Brushes. Materials under maps/<name>/ are the compiler's copies with cubemaps baked
    # in; the originals are listed too.
    o, n = lump[43]
    so, sn = lump[44]
    strs = d[o:o + n]
    mats = set()
    for x in struct.unpack_from("<%di" % (sn // 4), d, so):
        m = strs[x:strs.index(b"\0", x)].decode("latin1").lower().replace("\\", "/")
        if not m.startswith(("maps/", "tools/")):
            mats.add(m)
    # Models: static props and entities.
    models = set()
    go = lump[35][0]
    for i in range(struct.unpack_from("<i", d, go)[0]):
        gid, _, _, fo, _ = struct.unpack_from("<4sHHii", d, go + 4 + 16 * i)
        if gid == b"prps":
            for k in range(struct.unpack_from("<i", d, fo)[0]):
                models.add(d[fo + 4 + 128 * k:fo + 132 + 128 * k].split(b"\0")[0].decode("latin1").lower())
    o, n = lump[0]
    models |= {m.lower() for m in re.findall(r'"model"\s+"(models/[^"]+\.mdl)"', d[o:o + n].decode("latin1"))}
    for m in sorted(models):
        if m.startswith(("models/character/", "models/weapons/")):
            continue
        md = read(game, idx, m)
        if not md:
            continue
        strings = {s.decode("latin1").lower() for s in re.findall(rb"([a-zA-Z0-9_/\\.-]+)\0", md)}
        dirs = {s.replace("\\", "/") for s in strings if s.endswith(("/", "\\"))}
        for dr in dirs:
            for s in strings:
                if exists(game, idx, "materials/%s%s.vmt" % (dr, s)):
                    mats.add(dr + s)
    textures = set()
    for m in mats:
        vmt = read(game, idx, "materials/%s.vmt" % m)
        if not vmt:
            continue
        for t in re.findall(r'"?\$basetexture2?"?\s+"?([^"\s]+)', vmt.decode("latin1"), re.I):
            textures.add("materials/" + t.lower().replace("\\", "/").lstrip("/"))
    return sorted(textures)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out")
    ap.add_argument("--match", nargs="*", default=["materials/models/character/"])
    ap.add_argument("--map")
    ap.add_argument("--list")
    args = ap.parse_args()
    if not args.out:
        args.out = os.path.join(HERE, "..", "build", "textures", "maps/" + args.map if args.map else
                                "drawn" if args.list else "characters")
    idx = vpk_index(args.game)
    index, skipped, kept = [], 0, 0
    if args.list:
        with open(args.list) as f:
            names = sorted({ln.strip().lower() for ln in f if ln.strip()} - {""})
        names = [n for n in names if not n.startswith(("materials/models/character/", "materials/models/weapons/"))]
        try:
            with open(os.path.join(args.out, "index.json")) as f:
                index = json.load(f)
        except FileNotFoundError:
            pass
        have = {e["name"] for e in index}
        kept = len([n for n in names if n[len("materials/"):] in have])
        names = [n for n in names if n[len("materials/"):] not in have]
    elif args.map:
        names = map_textures(args.game, idx, args.map)
    else:
        names = sorted(k[:-4] for k in idx if k.endswith(".tth") and any(m in k for m in args.match))
    added = 0
    for n in names:
        tth, ttz = read(args.game, idx, n + ".tth"), read(args.game, idx, n + ".ttz")
        img = texture(tth, ttz) if tth and ttz else None
        if img is None or img.shape[0] < 8 or img.shape[1] < 8:
            skipped += 1
            continue
        rel = n[len("materials/"):] if n.startswith("materials/") else n
        path = os.path.join(args.out, rel + ".png")
        os.makedirs(os.path.dirname(path), exist_ok=True)
        Image.fromarray(img, "RGBA").save(path)
        index.append({"name": rel, "w": int(img.shape[1]), "h": int(img.shape[0]), "sig": signature(img)})
        added += 1
    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "index.json"), "w") as f:
        json.dump(index, f)
    print(f"{added} textures written to {os.path.abspath(args.out)} ({skipped} skipped, {kept} already there)")


if __name__ == "__main__":
    sys.exit(main())
