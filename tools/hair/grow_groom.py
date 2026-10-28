# A character's groom grown from the scalp (Jeanette's for now): top and back hair from roots
# over the scalp shell to the tie on its side, the fringe filling the game's own fringe outline
# along the way its texture runs (rooted on the scalp behind it), short hairs over the skin the
# game's shell covered, and the pigtails as clumped tubes.
#     python3 tools/hair/grow_groom.py HEAD.npz STRANDS_G.npz OUT.npz   (HEAD.npz: export_head.py)
# Space: metres, x across, -y front, z up.
import sys, numpy as np
from scipy.spatial import cKDTree

head_npz, strands_npz, out = sys.argv[1:4]
rng = np.random.default_rng(7)
N_TOP, N_FRINGE, N_PIG = 4300, 3000, 1800   # about 93k points: under the game's earlier strand hair
H = np.load(head_npz)
D = np.load(strands_npz)
pts, sizes, kind, scol = D["pts"], D["sizes"], D["kind"], D["col"]
off = np.concatenate([[0], np.cumsum(sizes)])
CEN = np.array([0.0, 0.01, 1.26])


def dense(tris, n):
    a = 0.5 * np.linalg.norm(np.cross(tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]), axis=1)
    t = rng.choice(len(tris), n, p=a / a.sum())
    u, v = rng.random(n), rng.random(n)
    f = u + v > 1
    u[f], v[f] = 1 - u[f], 1 - v[f]
    T = tris[t]
    return T[:, 0] + u[:, None] * (T[:, 1] - T[:, 0]) + v[:, None] * (T[:, 2] - T[:, 0])


class Surface:
    """Smoothed point surface: closest sample, its normal (out from the head), height."""
    def __init__(self, tris, n, k=48):
        p = dense(tris.astype(np.float64), n)
        tr = cKDTree(p)
        _, nb = tr.query(p, k)
        q = p[nb]
        self.p = q.mean(1)
        cov = np.einsum("nki,nkj->nij", q - self.p[:, None], q - self.p[:, None])
        nrm = np.linalg.eigh(cov)[1][:, :, 0]
        nrm *= np.sign(np.sum(nrm * (self.p - CEN), 1))[:, None]
        self.n = nrm
        self.tree = cKDTree(self.p)

    def height(self, x):
        _, i = self.tree.query(x)
        return np.sum((x - self.p[i]) * self.n[i], -1), self.n[i]

    def place(self, x, h):
        hh, n = self.height(x)
        return x - n * (hh - h)[..., None]


scalp = Surface(H["shell"], 120000)
body = Surface(np.concatenate([H["shell"], H["skin"]]), 200000, 24)


def smooth(c, it=3):
    for _ in range(it):
        c[..., 1:-1, :] = 0.25 * c[..., :-2, :] + 0.5 * c[..., 1:-1, :] + 0.25 * c[..., 2:, :]
    return c


def keep_out(c, gap):
    """Push points below `gap` over the head/face out to it (the root left as is)."""
    s = c.shape
    x = c.reshape(-1, 3)
    h, n = body.height(x)
    lo = h < gap
    x[lo] += n[lo] * (gap - h[lo])[:, None]
    return x.reshape(s)


def resample(q, k, keep=1.0):
    t = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(q, axis=0), axis=1))])
    u = np.linspace(0, t[-1] * keep, k)
    return np.stack([np.interp(u, t, q[:, j]) for j in range(3)], -1), t[-1]


strands, cols, kinds = [], [], []
pig_n = {}
base_col = {kk: scol[np.concatenate([np.arange(off[i], off[i + 1]) for i in np.nonzero(kind == kk)[0][::40]])].mean(0)
            for kk in (0, 1, 2)}

# ---- pigtails: axis and radius by distance from the tie (from the traced pigtail strands)
ties = {}
for side in (-1, 1):
    ids = np.nonzero((kind == 1) & (np.sign(pts[off[:-1], 0]) == side))[0]
    tie = pts[off[ids]].mean(0)
    q = np.concatenate([pts[off[i]:off[i + 1]] for i in ids[::3]])
    dist = np.linalg.norm(q - tie, axis=1)
    edges = np.arange(0, np.percentile(dist, 98) + 0.008, 0.008)
    cen, rad = [tie], [0.005]
    for a, b in zip(edges[:-1], edges[1:]):
        m = (dist >= a) & (dist < b)
        if m.sum() < 50:
            break
        c = q[m].mean(0)
        cen.append(c), rad.append(np.percentile(np.linalg.norm(q[m] - c, axis=1), 75))
    cen, rad = np.array(cen), np.array(rad)
    smooth(cen, 4)
    rad = np.convolve(np.pad(rad, 2, mode="edge"), np.ones(5) / 5, "valid")
    ties[side] = tie
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(cen, axis=0), axis=1))])
    tg = np.gradient(cen, s, axis=0)
    tg /= np.linalg.norm(tg, axis=1, keepdims=True)
    u0 = np.cross(tg[0], [0, 1.0, 0])
    u0 /= np.linalg.norm(u0)
    NC = 24
    ca, cr = rng.uniform(0, 2 * np.pi, NC), np.sqrt(rng.random(NC)) * 0.8
    cwave = rng.normal(0, 1, (NC, 2))
    clen = 1 - 0.4 * rng.random(NC) ** 1.3
    K = 8
    for j in range(N_PIG):
        cl = rng.integers(NC)
        L = s[-1] * clen[cl] * rng.uniform(0.82, 1.0)
        f = np.linspace(0, L, K)
        a = np.stack([np.interp(f, s, cen[:, d]) for d in range(3)], -1)
        r = np.interp(f, s, rad)
        t = np.stack([np.interp(f, s, tg[:, d]) for d in range(3)], -1)
        u = u0 - t * (t @ u0)[:, None]
        u /= np.linalg.norm(u, axis=1, keepdims=True)
        v = np.cross(t, u)
        ang, rr = rng.uniform(0, 2 * np.pi), np.sqrt(rng.random()) * 0.98
        sp = np.array([rr * np.cos(ang), rr * np.sin(ang)])
        cp = np.array([cr[cl] * np.cos(ca[cl]), cr[cl] * np.sin(ca[cl])])
        fr = f / s[-1]
        pull = 0.9 * (f / L) ** 1.2
        o2 = (1 - pull)[:, None] * sp + pull[:, None] * cp
        tw = 0.5 * fr
        c_, s_ = np.cos(tw), np.sin(tw)
        o2 = np.stack([o2[:, 0] * c_ - o2[:, 1] * s_, o2[:, 0] * s_ + o2[:, 1] * c_], -1)
        wave = np.sin(fr[:, None] * np.array([5.0, 7.0]) + cwave[cl]) * 0.2 * fr[:, None]
        o2 = o2 + wave + rng.normal(0, 0.04, (K, 2)) * fr[:, None]
        P = a + (u * o2[:, :1] + v * o2[:, 1:]) * r[:, None]
        P[0] = tie + (P[0] - a[0]) * 0.8
        P = smooth(P, 1)
        rn = P - a
        pig_n[len(strands)] = rn / (np.linalg.norm(rn, axis=1, keepdims=True) + 1e-9)
        strands.append(P), kinds.append(1)

# ---- top and back: roots over the scalp, each to the tie on its side along the scalp
cand = scalp.p[rng.choice(len(scalp.p), N_TOP * 3, replace=False)]
cand = cand[np.abs(cand[:, 0]) > 0.0015][:N_TOP]
# The skin just below the shell at the temples holds hair too (its texture's edge is dark)
sk = dense(H["skin"].astype(np.float64), 60000)
dsh = cKDTree(scalp.p).query(sk)[0]
band = sk[(dsh < 0.006) & (dsh > 0.0005) & (np.abs(sk[:, 0]) > 0.035) & (sk[:, 2] > 1.25)]
band = band[rng.choice(len(band), min(len(band), 500), replace=False)]
cand = np.concatenate([cand, band])
K = 6
t = np.linspace(0, 1, K)
for R in cand:
    side = 1 if R[0] > 0 else -1
    T = ties[side]
    _, n_t = body.height(T)
    E = T + rng.normal(0, 0.0025, 3)
    E -= n_t * np.dot(E - T, n_t)
    c = R[None] + t[:, None] * (E - R)[None]
    depth = rng.random()
    hgt = 0.0003 + depth * (0.0006 + 0.0035 * t ** 0.8)
    # The hair rises off the parting a little before lying down
    if abs(R[0]) < 0.02 and R[2] > 1.32:
        hgt = hgt + 0.0012 * np.sin(np.pi * np.minimum(t * 3, 1))
    for _ in range(2):
        c = body.place(c, hgt)
        smooth(c, 2)
    c = body.place(c, hgt)
    c[0] = R
    if np.linalg.norm(c[-1] - c[0]) < 0.006:
        continue
    strands.append(c), kinds.append(2)

# ---- fringe: the game's own fringe pieces (a curtain from the parting over the forehead and
# the temples, and two pointed locks in front of it) filled with strands along the way their
# texture runs, each strand rooted on the scalp at the parting behind where its line starts
FT_all, FUV_all, FP = H["fringe"].astype(np.float64), H["fringe_uv"].astype(np.float64), H["fringe_piece"]


class Piece:
    def __init__(self, tris, uv):
        self.s = Surface(tris, max(4000, 160 * len(tris)), 12)
        e1, e2 = tris[:, 1] - tris[:, 0], tris[:, 2] - tris[:, 0]
        d1, d2 = uv[:, 1, 1] - uv[:, 0, 1], uv[:, 2, 1] - uv[:, 0, 1]
        a11, a12, a22 = np.sum(e1 * e1, 1), np.sum(e1 * e2, 1), np.sum(e2 * e2, 1)
        det = a11 * a22 - a12 * a12 + 1e-18
        gv = ((a22 * d1 - a12 * d2) / det)[:, None] * e1 + ((a11 * d2 - a12 * d1) / det)[:, None] * e2
        self.flow = -gv / (np.linalg.norm(gv, axis=1, keepdims=True) + 1e-12)
        self.ft = cKDTree(tris.mean(1))

    def flow_at(self, p):
        d, i = self.ft.query(p, min(4, len(self.flow)))
        w = 1 / (d + 1e-4)
        v = (self.flow[i] * w[:, None]).sum(0)
        return v / (np.linalg.norm(v) + 1e-12)

    def trace(self, p, sgn, steps=120, h=0.0012):
        path = [p]
        for _ in range(steps):
            i = self.s.tree.query(p)[1]
            n = self.s.n[i]
            fl = self.flow_at(p)
            v = sgn * (fl - n * np.dot(fl, n))
            if np.linalg.norm(v) < 1e-4:
                break
            q = p + v / np.linalg.norm(v) * h
            d, i = self.s.tree.query(q)
            if d > 0.0008:
                break
            q = q - self.s.n[i] * np.dot(q - self.s.p[i], self.s.n[i])
            path.append(q)
            p = q
        return np.array(path)


K = 9
lines = []
for k in range(FP.max() + 1):
    pc = Piece(FT_all[FP == k], FUV_all[FP == k])
    acc = []
    for p in pc.s.p[rng.permutation(len(pc.s.p))]:
        if not acc or cKDTree(np.array(acc)).query(p)[0] > 0.0019:
            acc.append(p)
    for p in acc:
        ln = np.concatenate([pc.trace(p, -1)[::-1], pc.trace(p, 1)[1:]])
        if len(ln) >= 5:
            lines.append((ln, pc.s, len(FT_all[FP == k]) < 60))
per = max(2, N_FRINGE // len(lines))
for ln, sh, small in lines:
    s = ln[0]
    hs = max(scalp.height(s)[0], 0.0012)
    # the root on the scalp behind the line's start, a little toward the parting
    R = scalp.place(s + np.array([-0.3 * s[0], 0.012, 0.004]), 0.0)
    lead = scalp.place(R[None] + np.linspace(0, 1, 5)[:-1, None] * (s - R)[None], np.linspace(0.0004, hs, 5)[:-1])
    guide, L = resample(np.concatenate([lead, ln]), K)
    smooth(guide, 1)
    guide[-1] = ln[-1]
    T = np.gradient(guide, axis=0)
    T /= np.linalg.norm(T, axis=1, keepdims=True)
    nrm = sh.n[sh.tree.query(guide)[1]]
    B = np.cross(T, nrm)
    B /= np.linalg.norm(B, axis=1, keepdims=True)
    Nn = np.cross(B, T)
    f = np.linspace(0, 1, K)
    for j in range(per * (3 if small else 1)):
        ox = rng.normal(0, 0.0005) * (1 - 0.5 * f)
        oy = rng.uniform(-0.0006, 0.0006) * np.ones(K)
        q = guide + B * ox[:, None] + Nn * oy[:, None] + rng.normal(0, 0.00012, (K, 3)) * f[:, None]
        q, _ = resample(q, K, keep=rng.uniform(0.93, 1.0))
        q = keep_out(q, 0.0010)
        q[0] = scalp.place(q[0], 0.0)
        strands.append(smooth(q, 1)), kinds.append(0)
print("fringe lines", len(lines), "strands each", per)

# ---- hairline: short hairs lying on the skin the game's hair shell covered (the scalp is
# drawn pulled in, and the face texture is dark under it)
sk_ = dense(H["skin"].astype(np.float64), 80000)
hh, _ = scalp.height(sk_)
dsh = cKDTree(scalp.p).query(sk_)[0]
under = sk_[(hh < -0.0003) & (hh > -0.008) & (dsh < 0.008)]
for p in under[rng.choice(len(under), min(len(under), 900), replace=False)]:
    side = 1 if p[0] > 0 else -1
    tip = p + np.array([0.004 * side, -0.002, -0.006]) * rng.uniform(0.5, 1.0)
    c = p[None] + np.linspace(0, 1, 3)[:, None] * (tip - p)[None]
    c = body.place(c, np.array([0.0002, 0.0004, 0.0005]))
    strands.append(c), kinds.append(2)

# ---- colours and widths
C, W = [], []
for P, kk in zip(strands, kinds):
    n = len(P)
    f = np.linspace(0, 1, n)
    base = base_col[2] * rng.uniform(0.82, 1.12) * (1 + rng.normal(0, 0.03, 3))
    shade = (0.72 + 0.28 * np.minimum(f / 0.3, 1)) * (1 + 0.08 * f)
    C.append(np.clip(base[None] * shade[:, None], 0, 1))
    w = np.linspace(0.00042, 0.00015, n) if kk == 0 else np.linspace(0.00020, 0.00007, n)
    if kk == 2:   # finer at the root, so the hairline has no cut ends
        w *= np.minimum(0.45 + 0.55 * f / 0.2, 1)
    W.append(w)
sizes = np.array([len(p) for p in strands], np.int32)
NRM = [pig_n[i] if i in pig_n else body.height(P)[1] for i, P in enumerate(strands)]
np.savez(out, nrm=np.concatenate(NRM).astype(np.float32), pts=np.concatenate(strands).astype(np.float32), col=np.concatenate(C).astype(np.float32),
         width=np.concatenate(W).astype(np.float32), sizes=sizes, kind=np.array(kinds, np.int32))
print("strands", len(strands), "by kind (fringe, pigtail, top)", np.bincount(kinds).tolist(), "points", sizes.sum())
np.save(out.rsplit("/", 1)[0] + "/ties.npy" if "/" in out else "ties.npy", np.array([ties[-1], ties[1]]))
