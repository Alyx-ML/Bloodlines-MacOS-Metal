#!/usr/bin/env python3
"""dintrima at 8x (4096x1024), built from the original's layout in code:
- the mouldings from the original's average row colours (no noise in them, so the lines stay crisp),
- the stains and broad colour from the original, blurred and enlarged smoothly,
- the carved frieze enlarged, sharpened and lit as relief from its own shading,
- the two block joints drawn as clean cuts,
- limestone grain, mottling and pits from tiling noise. Tiles left to right.

    python3 tools/tex_dintrima.py build/textures/maps/diner/concrete/dintrima.png \
        build/textures/maps/diner/concrete/dintrima-replace.png
"""
import sys
import numpy as np
from PIL import Image
from scipy import ndimage as nd

src, dst = sys.argv[1], sys.argv[2]
S = 8
o = np.asarray(Image.open(src).convert("RGB"), np.float32) / 255
h, w, _ = o.shape
H, W = h * S, w * S
rng = np.random.default_rng(7)


def enlarge(a, resample=Image.BICUBIC):
    """Enlarge S times, wrapping left to right so the result tiles."""
    p = 8
    a = np.concatenate([a[:, -p:], a, a[:, :p]], 1)
    out = []
    for c in range(a.shape[2]):
        im = Image.fromarray(a[..., c].astype(np.float32), "F").resize((a.shape[1] * S, H), resample)
        out.append(np.asarray(im))
    return np.stack(out, 2)[:, p * S:-p * S]


def noise(scale, octaves=1):
    """Tiling noise (both ways), mean 0, sd 1, features about `scale` pixels."""
    f = np.zeros((H, W), np.float32)
    fy, fx = np.fft.fftfreq(H)[:, None], np.fft.fftfreq(W)[None]
    r = np.sqrt(fx ** 2 + fy ** 2)
    for k in range(octaves):
        s = scale / 2 ** k
        g = np.exp(-(r * s) ** 2 * 4) * (1 - np.exp(-(r * s * 4) ** 2))
        n = np.real(np.fft.ifft2(np.fft.fft2(rng.standard_normal((H, W))) * g))
        f += n / n.std() * 0.6 ** k
    return f / f.std()


# The mouldings: each row's colour, the joints left out, enlarged along y only and sharpened.
cols = np.ones(w, bool)
cols[[9, 10, 11, 12, 103, 104, 105, 106, 413, 414, 415, 416, 420, 421, 422, 423]] = False
rows = np.median(o[:, cols], 1)                                  # h x 3
ry = np.stack([np.asarray(Image.fromarray(rows[:, c][:, None], "F").resize((1, H), Image.LANCZOS))[:, 0]
               for c in range(3)], 1)
ry = ry + 0.6 * (ry - nd.gaussian_filter1d(ry, S * 0.8, 0))       # crisper edges
bands = np.broadcast_to(ry[:, None], (H, W, 3)).copy()

# Stains and broad colour: the original minus its rows, blurred, enlarged.
resid = o - rows[:, None]
resid = nd.gaussian_filter(resid, (1.2, 1.2, 0), mode=("nearest", "wrap", "nearest"))
bands += enlarge(resid)

# The frieze (rows 52-86): the original enlarged, sharpened, and lit from above as relief.
fr = enlarge(o, Image.LANCZOS)
lum = fr.mean(2)
fr = fr + 0.6 * (fr - nd.gaussian_filter(fr, (S * 0.7, S * 0.7, 0), mode="wrap"))
height = nd.gaussian_filter(lum, S * 0.6, mode="wrap")
gy, gx = np.gradient(height)
shade = np.clip(1 + (-gy * 0.8 - gx * 0.3) * S * 4, 0.65, 1.4)
fr = fr * shade[..., None]
y = np.arange(H)[:, None, None] / S
mask = np.clip((y - 51.5) * 2, 0, 1) * np.clip((86.5 - y) * 2, 0, 1)
img = bands * (1 - mask) + fr * mask

# The block joints in the top band: clean dark cuts with a lit edge beside them.
x = np.arange(W)[None, :, None] / S
top = np.clip((46.5 - y) * 2, 0, 1)
for jx, strength in ((104.8, 0.75), (421.8, 0.6), (414.8, 0.35)):
    d = np.abs(x - jx) * S
    cut = np.exp(-(d / 2.2) ** 2) * strength
    lit = np.exp(-((x - jx) * S - 4) ** 2 / 6) * 0.12 * strength
    img = img * (1 - cut * top) + lit * top
bottom = np.clip((y - 87.5) * 2, 0, 1)
d = np.abs(x - 10.8) * S
img = img * (1 - np.exp(-(d / 2.2) ** 2) * 0.35 * bottom) + np.exp(-((x - 10.8) * S - 4) ** 2 / 6) * 0.05 * bottom

# Limestone: fine grain, mottling and pits.
lumi = 1 + 0.035 * noise(3) + 0.022 * noise(40, 3)
pits = np.clip(noise(2.5) - 2.9, 0, None) * 0.3
img = img * lumi[..., None] * (1 - pits[..., None])
img += 0.012 * noise(1.5)[..., None]

Image.fromarray((np.clip(img, 0, 1) * 255 + 0.5).astype(np.uint8), "RGB").save(dst)
print(dst, W, "x", H)
