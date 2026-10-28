"""Which of the game's triangles make up each garment of a character, from its config
(tools/bodies/<character>.json), shared by fit_body.py and build_garment.py.

The game paints most clothes on the body's one surface. A garment is picked as the
texture pieces (triangles joined by shared, unwelded vertices) of one material whose
mean colour and height match its rule:
    "material": the game material,
    "min_bright"/"max_bright": the pieces' mean brightness (0-255),
    "red": true for pieces clearly redder than they are green,
    "min_z"/"max_z": the pieces' height range must lie within these.
A garment with only "material" takes the whole material.
"""
import json
import os

import numpy as np
from PIL import Image


def load_config(path):
    with open(path) as f:
        cfg = json.load(f)
    cfg["_dir"] = os.path.dirname(os.path.abspath(path))
    return cfg


def pieces(J, mat_index):
    co_n = J["co"].shape[0]
    tris = J["tris"]
    sel = np.where(J["mats"] == mat_index)[0]
    parent = np.arange(co_n)

    def root(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    for t in tris[sel]:
        for v in t[1:]:
            parent[root(t[0])] = root(v)
    return sel, np.array([root(t[0]) for t in tris[sel]])


def garment_mask(J, spec, texdir):
    """A mask over all the game's triangles: those of this garment."""
    names = list(J["mat_names"])
    mi = names.index(spec["material"])
    mask = np.zeros(len(J["tris"]), bool)
    sel, piece = pieces(J, mi)
    rules = {k for k in spec if k != "material" and not k.startswith("_") and k in
             ("min_bright", "max_bright", "red", "min_z", "max_z")}
    if not rules:
        mask[sel] = True
        return mask
    tex = np.asarray(Image.open(os.path.join(texdir, spec["material"] + ".png")).convert("RGB")).astype(float)
    h, w, _ = tex.shape
    c = J["uvs"][sel].mean(1)
    px = tex[((1 - c[:, 1]) * h).astype(int).clip(0, h - 1), (c[:, 0] * w).astype(int).clip(0, w - 1)]
    z = J["co"][J["tris"][sel]][..., 2]
    for p in np.unique(piece):
        s = piece == p
        rgb = px[s].mean(0)
        bright = rgb.mean()
        ok = True
        ok &= bright >= spec.get("min_bright", -1)
        ok &= bright <= spec.get("max_bright", 999)
        if spec.get("red"):
            ok &= rgb[0] > 1.8 * rgb[1] + 10
        ok &= z[s].min() >= spec.get("min_z", -1e9)
        ok &= z[s].max() <= spec.get("max_z", 1e9)
        if ok:
            mask[sel[s]] = True
    return mask
