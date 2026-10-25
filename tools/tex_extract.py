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

Default: the character textures (materials/models/character/). Writes <out>/<path>.png
and <out>/index.json (name, width, height, and an 8x8 colour signature the renderer uses
to recognise the texture once the game has loaded it).
"""
import argparse
import json
import os
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "textures", "characters"))
    ap.add_argument("--match", nargs="*", default=["materials/models/character/"])
    args = ap.parse_args()
    idx = vpk_index(args.game)
    names = sorted(k[:-4] for k in idx if k.endswith(".tth") and any(m in k for m in args.match))
    index, skipped = [], 0
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
    with open(os.path.join(args.out, "index.json"), "w") as f:
        json.dump(index, f)
    print(f"{len(index)} textures written to {os.path.abspath(args.out)} ({skipped} skipped)")


if __name__ == "__main__":
    sys.exit(main())
