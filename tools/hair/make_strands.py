"""A character's groom as strands for the game (tex_detail.m bl_detail_hair, version 3):
points along thin strands, which the renderer draws itself in a compute pass (metal_render.m,
hair_run), each strand as wide as it really is, the share of each pixel it covers blended
front to back.

    python3 tools/hair/make_strands.py GROOM.npz HEAD.npz OLD_HAIR.bin OUT_HAIR.bin OUT_HAIR.png

GROOM.npz: the groom from grow_groom.py (pts, nrm, col, width, sizes, kind), in the space of
the hair's anchors. HEAD.npz: the scalp shell from export_head.py. OLD_HAIR.bin: an earlier
hair file for the same hair (the cards), for its anchors, the rectangle of the game's texture
to keep and the game's triangles under the hair; only those of the scalp shell are kept, the
game's fringe locks are the groom's now.

Every point is one vertex with its colour and half-width; the indices are the strands'
segments, two points each. The colours go into OUT_HAIR.png too, one column of K texels per
strand, for the game's own shader that lights each point. The output holds the game's hair:
it stays in native/build.
"""
import struct
import sys

import numpy as np
from PIL import Image
from scipy.spatial import cKDTree

if len(sys.argv) != 6 or not sys.argv[1].endswith(".npz") or not sys.argv[4].endswith(".bin"):
    sys.exit(__doc__)
groom, head, old_path, out_bin, out_png = sys.argv[1:6]
COLS = 1024                            # strands a row of the colour texture

g = np.load(groom)
pts, nrm, col, width, sizes = g["pts"], g["nrm"], g["col"], g["width"], g["sizes"]
off = np.concatenate([[0], np.cumsum(sizes)])
ns, K = len(sizes), int(sizes.max())
rows = -(-ns // COLS) * K
col_i, blk = np.arange(ns) % COLS, np.arange(ns) // COLS

img = np.zeros((rows, COLS, 4), np.uint8)
img[..., 3] = 255
verts = np.zeros((len(pts), 12), np.float32)
verts[:, 0:3], verts[:, 3:6] = pts, nrm
verts[:, 8:11], verts[:, 11] = np.clip(col, 0, 1), width
idx = []
for i in range(ns):
    a, n = off[i], sizes[i]
    verts[a:a + n, 6] = (col_i[i] + 0.5) / COLS
    verts[a:a + n, 7] = (blk[i] * K + np.arange(n) + 0.5) / rows
    img[blk[i] * K + np.arange(n), col_i[i], :3] = np.clip(col[a:a + n] * 255 + 0.5, 0, 255).astype(np.uint8)
    q = a + np.arange(n - 1)
    idx.append(np.stack([q, q + 1], -1).ravel())
idx = np.concatenate(idx).astype(np.uint32)

old = open(old_path, "rb").read()
magic, ver, nv0, ni0, na = struct.unpack("<4sIIII", old[:20])
tail = old[20 + nv0 * (32 if ver == 1 else 48) + ni0 * 4:]  # anchors, the rectangle to keep, the base
b_at = na * 12 + 16
nb = struct.unpack("<I", tail[b_at:b_at + 4])[0]
cen = np.frombuffer(tail[b_at + 4:b_at + 4 + nb * 12], np.float32).reshape(-1, 3)
shell = np.load(head)["shell"].mean(1)
cen = cen[cKDTree(shell).query(cen)[0] < 0.0015]
print(f"base: {len(cen)} of the game's {nb} triangles kept under the strands (the scalp shell)")
tail = tail[:b_at] + struct.pack("<I", len(cen)) + cen.astype(np.float32).tobytes()
with open(out_bin, "wb") as f:
    f.write(struct.pack("<4sIIII", b"BLHM", 3, len(verts), len(idx), na))
    f.write(verts.tobytes())
    f.write(idx.tobytes())
    f.write(tail)
Image.fromarray(img).save(out_png)
print(f"strands {ns} ({np.bincount(g['kind']).tolist()} by kind: fringe, pigtail, top), "
      f"{len(verts)} points, {len(idx) // 2} segments, colours {COLS}x{rows}")
