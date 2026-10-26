#!/usr/bin/env python3
"""Make the upscaled textures the renderer draws in place of the game's own
(runtime/d3d9/tex_hires.m), from upscaled PNGs of tools/tex_extract.py's exports.

    python3 tools/tex_pack.py [--in DIR] [--out DIR] [--game DIR] [--jobs N] [--force]

The game's files are left as they are: the game places brush textures by their size in
texels, so a larger file would stretch them. The upscaled texture only reaches the GPU,
in place of the texture whose contents are exactly the original's.

The default input is build/textures/maps, the output of tools/tex_extract.py --map.
Each PNG is matched to its texture by name, never by its look:
  - names are relative to the export folder (the nearest folder above the PNG holding
    tex_extract's index.json, else --in), with materials/ in front;
  - an upscaler's suffix after a '-' is dropped ("bartable-gigapixel-2x.png" is
    materials/.../bartable), and exactly one of the possible names must be a texture in
    the game, or the PNG is refused;
  - a PNG the size of the original is the export itself and is left alone.

The new size is the original's times the largest power of two that fits the PNG (which
must have the original's shape). Upscalers shift colours a little, so the PNG's colours
are first matched to the original's: chaiNNer's wavelet colour fix (as in PBRify_Remix's
"With Color Fix" chain), which keeps the PNG's fine detail and takes the broad colour from
the original, with the edges wrapping as brush textures repeat. A PNG named "<name>-replace.png"
is a new picture drawn in the original's layout (from other sources, not an upscale): it
keeps its own colours. The mipmaps are made from
the result (Lanczos, alpha filtered apart from colour) and stored as BC7, encoded by
tools/bc7_encode.c (compiled into build/tools).

Writes <out>/<name>.tex (see tex_hires.m), <out>/<name>.keys and <out>/index.txt: per
texture, the SHA-1 of each of the original's three largest mipmaps as the game hands
them to Direct3D (DXT blocks as they are, other pixels as B, G, R, A bytes, A 255 for
formats without alpha), so the renderer recognises the texture exactly, also when the
game is set to load smaller textures.
"""
import argparse
import ctypes
import hashlib
import os
import struct
import subprocess
import sys
import zlib
from multiprocessing import Pool

import numpy as np
from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402

FORMATS = {0: "RGBA8888", 2: "RGB888", 3: "BGR888", 12: "BGRA8888", 13: "DXT1", 14: "DXT3", 15: "DXT5"}
ENVMAP = 0x4000
BC7 = 98  # the .tex format: DXGI_FORMAT_BC7_UNORM
WAVELETS = 5  # the colour fix's levels, as in PBRify_Remix's chain


class Refused(Exception):
    pass


def lib_path():
    src = os.path.join(HERE, "bc7_encode.c")
    out = os.path.join(HERE, "..", "build", "tools", "libbc7.dylib")
    if not os.path.exists(out) or os.path.getmtime(out) < os.path.getmtime(src):
        os.makedirs(os.path.dirname(out), exist_ok=True)
        subprocess.run(["clang", "-O3", "-shared", "-o", out, src], check=True)
    return out


_lib = None


def bc7(rgba):
    global _lib
    if _lib is None:
        _lib = ctypes.CDLL(LIB)
        _lib.bc7_encode.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_int, ctypes.c_char_p]
    h, w = rgba.shape[:2]
    pw, ph = (w + 3) // 4 * 4, (h + 3) // 4 * 4
    if (pw, ph) != (w, h):  # mipmaps under 4 pixels: repeat the edge to fill the block
        rgba = np.pad(rgba, ((0, ph - h), (0, pw - w), (0, 0)), mode="edge")
    out = ctypes.create_string_buffer(pw * ph)
    _lib.bc7_encode(np.ascontiguousarray(rgba).tobytes(), pw, ph, out)
    return out.raw


def wavelet_low(a):
    """What chaiNNer's wavelet colour fix keeps of an image's colour: its 3x3 binomial blur
    applied WAVELETS times, the taps 1, 2, 4... pixels apart."""
    for i in range(WAVELETS):
        r, b = 1 << i, a * 0.25
        for dy, dx, k in ((-r, 0, .125), (r, 0, .125), (0, -r, .125), (0, r, .125),
                          (-r, -r, .0625), (-r, r, .0625), (r, -r, .0625), (r, r, .0625)):
            b += k * np.roll(a, (dy, dx), (0, 1))
        a = b
    return a


def colour_fix(o, img):
    """The image with its fine detail and the original's broad colour."""
    ref = Image.fromarray(tex_extract.decode(o["levels"][0], o["w"], o["h"], o["fmt"])).convert("RGB")
    ref = np.asarray(ref.resize(img.size, Image.BOX), np.float32)
    up = np.asarray(img.convert("RGB"), np.float32)
    fixed = Image.fromarray(np.clip(up - wavelet_low(up) + wavelet_low(ref) + 0.5, 0, 255).astype(np.uint8), "RGB")
    fixed.putalpha(img.getchannel("A"))
    return fixed


def mip_dims(w, h, mips):
    return [(max(1, w >> i), max(1, h >> i)) for i in range(mips)]


def canonical(data, w, h, fmt):
    """A mipmap's contents as the game gives them to Direct3D (tex_hires.m hashes the same)."""
    if fmt in (13, 14, 15):
        return data
    px = np.frombuffer(data, np.uint8).reshape(h, w, 4 if fmt in (0, 12) else 3)
    out = np.full((h, w, 4), 255, np.uint8)
    order = {0: [2, 1, 0, 3], 12: [0, 1, 2, 3], 2: [2, 1, 0], 3: [0, 1, 2]}[fmt]
    out[..., :len(order)] = px[..., order]
    return out.tobytes()


def original(tth, ttz):
    """Format, flags and mipmaps (largest first) of the game's texture."""
    if len(tth) < 12 or tth[:4] != b"TTH\0":
        raise Refused("not a TTH header")
    v = 12 + 8 * (tth[6] + 1)
    vh = tth[v:v + 64]
    if vh[:4] != b"VTF\0" or struct.unpack_from("<III", vh, 4) != (7, 1, 64):
        raise Refused("not a VTF 7.1 header")
    w, h, flags, frames = struct.unpack_from("<HHIH", vh, 16)
    fmt, mips = struct.unpack_from("<i", vh, 52)[0], vh[56]
    lfmt, lw, lh = struct.unpack_from("<i", vh, 57)[0], vh[61], vh[62]
    if frames != 1:
        raise Refused(f"{frames} frames (animated)")
    if flags & ENVMAP:
        raise Refused("cube map")
    if fmt not in FORMATS:
        raise Refused(f"VTF format {fmt}")
    try:  # some .ttz files end with a wrong checksum: inflate the raw stream, which skips it
        vtf = tth[v:] + zlib.decompressobj(-15).decompress(ttz[2:])
    except zlib.error:
        raise Refused("cannot inflate the .ttz")
    sizes = [tex_extract.mip_size(mw, mh, fmt) for mw, mh in mip_dims(w, h, mips)]
    low = tex_extract.mip_size(lw, lh, lfmt) if lw and lh else 0
    if len(vtf) != 64 + low + sum(sizes):
        raise Refused("file size does not match its header")
    levels, end = [], len(vtf)
    for size in sizes:
        levels.append(vtf[end - size:end])
        end -= size
    return dict(w=w, h=h, flags=flags, fmt=fmt, levels=levels)


def keys(o, name):
    lines = []
    for (mw, mh), data in list(zip(mip_dims(o["w"], o["h"], len(o["levels"])), o["levels"]))[:3]:
        if mw >= 8 and mh >= 8:
            k = hashlib.sha1(canonical(data, mw, mh, o["fmt"])).hexdigest()[:16]
            lines.append(f"{k} {mw} {mh} {name}\n")
    return "".join(lines)


def build(o, img):
    """The .tex file for the image, in BC7."""
    w, h = img.width, img.height
    mips = max(w, h).bit_length()
    rgb, alpha = img.convert("RGB"), img.getchannel("A")
    out = [b"BLHR" + struct.pack("<4I", BC7, w, h, mips)]
    for mw, mh in mip_dims(w, h, mips):
        lv = np.dstack([np.asarray(rgb.resize((mw, mh), Image.LANCZOS) if (mw, mh) != (w, h) else rgb),
                        np.asarray(alpha.resize((mw, mh), Image.LANCZOS) if (mw, mh) != (w, h) else alpha)])
        out.append(bc7(lv))
    return b"".join(out)


def target_size(o, img):
    w, h = o["w"], o["h"]
    if img.width * h != img.height * w:
        raise Refused(f"PNG is {img.width}x{img.height}, not the shape of the original {w}x{h}")
    k = 0
    while (w << (k + 1)) <= img.width:
        k += 1
    return w << k, h << k


def pack(job):
    png, name, out, force = job
    try:
        tex_out, keys_out = os.path.join(out, name + ".tex"), os.path.join(out, name + ".keys")
        tth, ttz = tex_extract.read(GAME, IDX, name + ".tth"), tex_extract.read(GAME, IDX, name + ".ttz")
        if not tth or not ttz:
            raise Refused("original .tth/.ttz not found")
        v = 12 + 8 * (tth[6] + 1) if len(tth) > 6 else 0
        img = Image.open(png)
        if len(tth) >= v + 20 and img.size == struct.unpack_from("<HH", tth, v + 16):
            return name, "same size as the original (the export), left alone", None
        if not force and all(os.path.exists(p) and os.path.getmtime(p) >= os.path.getmtime(png)
                             for p in (tex_out, keys_out)):
            return name, "up to date", None
        o = original(tth, ttz)
        img = img.convert("RGBA")
        tw, th = target_size(o, img)
        if (tw, th) != img.size:
            img = img.resize((tw, th), Image.LANCZOS)
        replace = os.path.splitext(os.path.basename(png))[0].lower().endswith("-replace")
        tex = build(o, img if replace else colour_fix(o, img))
        os.makedirs(os.path.dirname(tex_out), exist_ok=True)
        with open(tex_out, "wb") as f:
            f.write(tex)
        with open(keys_out, "w") as f:
            f.write(keys(o, name))
        return name, f"{o['w']}x{o['h']} {FORMATS[o['fmt']]} -> {tw}x{th} BC7", None
    except Refused as e:
        return name, None, f"{os.path.basename(png)}: {e}"


def find_jobs(src, game, idx):
    jobs, refused = [], []
    for d, _, files in os.walk(src):
        root = d
        while root != src and not os.path.exists(os.path.join(root, "index.json")):
            root = os.path.dirname(root)
        for f in sorted(files):
            if not f.lower().endswith((".png", ".webp")) or f == "contact_sheet.png":
                continue
            rel = os.path.relpath(os.path.join(d, os.path.splitext(f)[0]), root).replace(os.sep, "/").lower()
            folder, stem = rel.rpartition("/")[0], rel.rpartition("/")[2]
            names = [stem] + [stem[:i] for i in range(len(stem)) if stem[i] == "-" and i]
            found = [n for n in dict.fromkeys(names)
                     if tex_extract.exists(game, idx, "materials/" + (folder + "/" if folder else "") + n + ".tth")]
            if not found and rel.endswith(("_n", "_r")):
                continue  # PBRify's normal and roughness maps (tools/tex_normals.py, colab_pbrify.py)
            if len(found) != 1:
                refused.append(f"{os.path.join(d, f)}: " + ("no texture of that name in the game" if not found
                               else "matches several textures: " + ", ".join(found)))
                continue
            jobs.append((os.path.join(d, f), "materials/" + (folder + "/" if folder else "") + found[0]))
    seen, bad = {}, set()
    for png, name in jobs:
        seen.setdefault(name, []).append(png)
    for name, pngs in seen.items():
        big = [p for p in pngs if os.path.splitext(os.path.basename(p))[0].lower() != name.rsplit("/", 1)[1]]
        if len(big) > 1:
            refused.append(f"{name}: several upscales ({', '.join(os.path.basename(p) for p in big)})")
            bad.add(name)
    return [(p, n) for p, n in jobs if n not in bad], refused


def init(game, idx, lib):
    global GAME, IDX, LIB
    GAME, IDX, LIB = game, idx, lib


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--in", dest="src", default=os.path.join(HERE, "..", "build", "textures", "maps"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "hires"))
    ap.add_argument("--jobs", type=int, default=max(1, (os.cpu_count() or 2) // 2))
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()
    src, out = os.path.abspath(args.src), os.path.abspath(args.out)
    idx = tex_extract.vpk_index(args.game)
    jobs, refused = find_jobs(src, args.game, idx)
    lib = lib_path()
    work = [(p, n, out, args.force) for p, n in jobs]
    written = 0
    with Pool(args.jobs, init, (args.game, idx, lib)) as pool:
        for name, done, why in pool.imap_unordered(pack, work):
            if why:
                refused.append(f"{name}: {why}")
            elif done != "up to date" and not done.startswith("same size"):
                print(f"{name}: {done}")
                written += 1
    lines, count = [], 0
    for d, _, files in os.walk(out):
        for f in sorted(files):
            if f.endswith(".keys"):
                with open(os.path.join(d, f)) as k:
                    lines.append(k.read())
                count += 1
    with open(os.path.join(out, "index.txt"), "w") as f:
        f.write("".join(lines))
    for r in refused:
        print("refused " + r, file=sys.stderr)
    print(f"{written} textures written, {count} in all in {out}, {len(refused)} refused")
    return 1 if refused else 0


if __name__ == "__main__":
    sys.exit(main())
