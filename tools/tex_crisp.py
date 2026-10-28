#!/usr/bin/env python3
"""A map texture enlarged in code, keeping its layout: for painted textures with no regular
rows (tools/tex_dintrima.py rebuilds one from its rows), such as the diner's windows.

    python3 tools/tex_crisp.py SRC.png DST.png [--scale 4]

- Enlarged with Lanczos, wrapping at the edges, so a texture that repeats still does.
- Edges made crisp: sharpened strongly along the large edges (found on a smoothed copy, so
  the plaster's speckle does not count) and a little everywhere. Mouldings and frames come
  out as clean lines, not soft blurs.
- Surface added from tiling noise: fine grain, small bumps and pits. Less on saturated
  colours (curtains, paint), which are cloth or smooth paint, not stone or plaster.
Alpha, if any, is enlarged smoothly and kept.
"""
import argparse

import numpy as np
from PIL import Image
from scipy import ndimage as nd


def enlarge(a, s):
    p = 8
    a = np.concatenate([a[:, -p:], a, a[:, :p]], 1)
    a = np.concatenate([a[-p:], a, a[:p]], 0)
    out = [np.asarray(Image.fromarray(a[..., c], "F").resize((a.shape[1] * s, a.shape[0] * s), Image.LANCZOS))
           for c in range(a.shape[2])]
    return np.stack(out, 2)[p * s:-p * s, p * s:-p * s]


def noise(rng, h, w, scale):
    """Tiling noise both ways, mean 0, sd 1, features about `scale` pixels."""
    fy, fx = np.fft.fftfreq(h)[:, None], np.fft.fftfreq(w)[None]
    r = np.sqrt(fx ** 2 + fy ** 2)
    g = np.exp(-(r * scale) ** 2 * 4) * (1 - np.exp(-(r * scale * 4) ** 2))
    n = np.real(np.fft.ifft2(np.fft.fft2(rng.standard_normal((h, w))) * g))
    return (n / n.std()).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--scale", type=int, default=4)
    ap.add_argument("--crisp", type=float, default=0.7, help="how far edges are pulled (0 none, 1 fully)")
    ap.add_argument("--grain", type=float, default=1.0, help="strength of the added surface (0 none)")
    args = ap.parse_args()
    s = args.scale
    im = Image.open(args.src)
    alpha = np.asarray(im.getchannel("A"), np.float32)[..., None] / 255 if im.mode == "RGBA" else None
    rgb = np.asarray(im.convert("RGB"), np.float32) / 255
    img = enlarge(rgb, s)
    h, w = img.shape[:2]

    # Crisp edges: sharpened only along the large edges (frames, mouldings), found on a
    # smoothed copy so the plaster's speckle does not count, and a little everywhere.
    smooth = nd.gaussian_filter(img.mean(2), s * 0.8, mode="wrap")
    edge = np.abs(nd.sobel(smooth, 0, mode="wrap")) + np.abs(nd.sobel(smooth, 1, mode="wrap"))
    weight = np.clip(edge / np.percentile(edge, 90), 0, 1)[..., None]
    img = img + (args.crisp * 1.6 * weight + 0.3) * (img - nd.gaussian_filter(img, (s * 0.7, s * 0.7, 0), mode="wrap"))

    # Surface: less on saturated colours.
    rng = np.random.default_rng(11)
    sat = img.max(2) - img.min(2)
    rough = np.clip(1 - (sat - 0.12) / 0.15, 0.25, 1)
    lumi = 1 + args.grain * rough * (0.022 * noise(rng, h, w, 2.5) + 0.02 * noise(rng, h, w, 10))
    pits = np.clip(noise(rng, h, w, 2.5) - 3.0, 0, None) * 0.3 * args.grain * rough
    img = img * (lumi * (1 - pits))[..., None]

    out = np.clip(img, 0, 1)
    if alpha is not None:
        a = np.clip(enlarge(alpha, s), 0, 1)
        out = np.concatenate([out, a], 2)
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGBA" if alpha is not None else "RGB").save(args.dst)
    print(args.dst, w, "x", h)


if __name__ == "__main__":
    main()
