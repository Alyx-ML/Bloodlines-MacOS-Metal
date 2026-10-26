#!/usr/bin/env python3
"""Remodel a round prop (bar stools, tables on a pole, bottles...) from its extracted OBJ
(tools/mdl_extract.py): the same shape as true circles with more sides, its joins
rounded where the recipe says, and the original's UV layout carried over, so the game's
texture (or its upscale) lands exactly where it did.

    python3 tools/prop_revolve.py tools/props/barstool.json

A recipe names the model and the changes, nothing else is decided by the script
("keep_others": true draws any part that is not round exactly as the original;
"any_sides": true lets a ring take any number of sides from the original's up, not
only multiples of it, for the lightest result; "smooth_outline": true rounds every bend
of the profile the original shades smoothly; "tubes": true remodels a tube, joined on or alone,
such as a lamp's bent arm, round along a smooth path):
    {"model": "models/scenery/furniture/barstool/barstool.mdl",
     "tolerance": 0.02,                   # in the model's units
     "round": [{"material": "barstool", "at": [2.431, -11.19], "radius": 0.6}]}
"at" is a corner of that material's profile (radius from the axis, height), as the
script prints them; "radius" is the rounding's. "tolerance" is how far the new surface
may stray from a true circle or arc: each material gets the fewest sides (a multiple of
the original's, so the original's UV seam stays on an edge) and each rounding the fewest
steps that keep within it, so thin parts take fewer triangles than wide ones.

The original must be made of surfaces of revolution around one vertical axis: each
connected part of a material (a table's top, its pole and base) has its vertices on
rings with the same sides on every ring, joined in one chain (its profile); parts may
differ in sides. Anything else is refused. Each new vertex takes the UV of
the nearest point of the original's surface of its material; a new face whose corners
land on different UV islands (the original's seam) takes all its UVs from the island
under its centre.

Writes build/props/<model>/<name>_remodel.obj next to the extracted one, using its .mtl.
"""
import argparse
import json
import math
import os
import sys
from collections import Counter, defaultdict

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))


class Refused(Exception):
    pass


def read_obj(path):
    v, vt, vn, groups, order, mat = [], [], [], defaultdict(list), [], None
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "v":
            v.append([float(x) for x in p[1:4]])
        elif p[0] == "vt":
            vt.append([float(x) for x in p[1:3]])
        elif p[0] == "vn":
            vn.append([float(x) for x in p[1:4]])
        elif p[0] == "usemtl":
            mat = p[1]
            if mat not in order:
                order.append(mat)
        elif p[0] == "f":
            groups[mat].append([[int(i) - 1 for i in c.split("/")[:3]] for c in p[1:]])
    return np.array(v), np.array(vt), np.array(vn), groups, order


def axis_and_sides(v, split=True, loose=False):
    """The vertical axis (x, y), the number of sides and the angle of the first. With
    split false, rings are told apart by height alone (an uneven prop such as a candle
    with drips, whose rings would break up by radius), and rings through the axis are
    left out. With loose true, the sides are those of the rings holding the most
    points, and rings of other sides (a knob or bracket joined onto the round part) are
    left to the caller."""
    pts = np.unique(np.round(v, 3), axis=0)
    rings = defaultdict(list)
    for p in pts:
        rings[round(p[2], 1)].append(p)
    full = [np.array(r) for r in rings.values() if len(r) >= 6]
    if not full:
        raise Refused("no rings of vertices")
    centre = np.mean([r[:, :2].mean(0) for r in full], 0)
    # a flat cap's centre point shares its ring's height but is no side, and rings of
    # different radii may share a height (a flange): split by radius
    if not split:
        full = [r for r in full if np.hypot(*(r[:, :2] - centre).T).min() > 0.05]
    parts = []
    for r in full if split else []:
        r = r[np.hypot(*(r[:, :2] - centre).T) > 0.05]
        rad = np.hypot(*(r[:, :2] - centre).T)
        order = np.argsort(rad)
        start = 0
        for k in range(1, len(order) + 1):
            if k == len(order) or rad[order[k]] - rad[order[k - 1]] > 0.05 + 0.01 * rad[order[k]]:
                parts.append(r[order[start:k]])
                start = k
    full = parts if split else full
    sides = Counter(len(r) for r in full if len(r))
    if len(sides) != 1 and not loose:
        raise Refused(f"rings with different numbers of sides: {sorted(sides)}")
    # the sides of the rings holding the most points: a knob's few small rings lose
    top = sorted(((k * c, k) for k, c in sides.items()), reverse=True)[:2]
    top = [(k, c) for c, k in top]
    if not top or (len(top) == 2 and top[0][1] == top[1][1]):
        raise Refused(f"no one number of sides: {sorted(sides)}")
    n = top[0][0]
    if n < 3:
        raise Refused("no rings of vertices")
    if n < 6:  # a box or a wedge, square to an axis: rounding it would make it a drum
        raise Refused(f"rings of only {n} sides: not round")
    full = [r for r in full if len(r) == n]
    centre = np.mean([r[:, :2].mean(0) for r in full], 0)
    ring = max(full, key=lambda r: np.hypot(*(r[:, :2] - centre).T).mean() if len(r) else 0)
    if len(ring) < 3:
        raise Refused("no rings of vertices")
    ang = np.sort(np.arctan2(ring[:, 1] - centre[1], ring[:, 0] - centre[0]) % (2 * math.pi))
    step = 2 * math.pi / n
    if np.abs(np.diff(ang) - step).max() > math.radians(1.5):
        raise Refused("the sides are not evenly spaced")
    return centre, n, ang[0]


def parts(v, faces):
    """The faces split into connected parts (sharing a vertex position)."""
    key = [tuple(np.round(p, 3)) for p in v]
    up = {}

    def root(x):
        while up.setdefault(x, x) != x:
            x = up[x]
        return x

    for f in faces:
        for c in f[1:]:
            up[root(key[c[0]])] = root(key[f[0][0]])
    out = {}
    for f in faces:
        out.setdefault(root(key[f[0][0]]), []).append(f)
    return list(out.values())


def profile(v, faces, centre, sides=None):
    """The part's rings as a chain of (radius, height) points, the faces it was made
    from, and (given sides) the faces touching a ring of another number of points, which are not
    round and left out of the chain. A flat cap ends the chain at the axis (radius 0)."""
    ids = sorted({c[0] for f in faces for c in f})
    rz = {i: (math.hypot(v[i][0] - centre[0], v[i][1] - centre[1]), v[i][2]) for i in ids}
    rings = []  # (radius, height) clusters
    of = {}
    for i in ids:
        r, z = rz[i]
        for k, (rr, zz, n) in enumerate(rings):
            if abs(zz - z) < 0.02 and abs(rr - r) < 0.05 + 0.01 * rr:
                rings[k] = ((rr * n + r) / (n + 1), (zz * n + z) / (n + 1), n + 1)
                of[i] = k
                break
        else:
            of[i] = len(rings)
            rings.append((r, z, 1))
    stray = []
    if sides:
        pos = defaultdict(set)
        for i in ids:
            pos[of[i]].add(tuple(np.round(v[i], 3)))
        odd = {k for k, ps in pos.items() if len(ps) != sides and rings[k][0] >= 0.1}
        stray = [f for f in faces if any(of[c[0]] in odd for c in f)]
        faces = [f for f in faces if not any(of[c[0]] in odd for c in f)]
        if len(faces) < len(stray) / 2:
            raise Refused("too little of it is round")
        used = {of[c[0]] for f in faces for c in f}
        if len(used) < 2:
            raise Refused("too little of it is round")
    else:
        used = set(range(len(rings)))
    links = defaultdict(set)
    for f in faces:
        for a in range(len(f)):
            x, y = of[f[a][0]], of[f[(a + 1) % len(f)][0]]
            if x != y:
                links[x].add(y), links[y].add(x)
    if any(len(s) > 2 for s in links.values()):
        raise Refused("the rings do not form one chain")
    ends = [k for k in used if len(links[k]) < 2]
    if len(used) > 1 and len(ends) != 2:
        raise Refused("the rings do not form one open chain")
    chain = [ends[0] if ends else min(used)]
    while len(chain) < len(used):
        nxt = [k for k in links[chain[-1]] if k not in chain]
        if not nxt:
            raise Refused("the rings do not form one chain")
        chain.append(nxt[0])
    pts = [(0.0 if rings[k][0] < 0.1 else rings[k][0], rings[k][1]) for k in chain]
    # a flat cap made without a centre point (a fan from one corner) lies wholly in its
    # ring and links it to no other: it closes that end of the chain at the axis
    flat = {of[f[0][0]] for f in faces if len({of[c[0]] for c in f}) == 1 and rings[of[f[0][0]]][0] >= 0.1}
    if flat - {chain[0], chain[-1]}:
        raise Refused("a flat face lies inside the chain, not at an end")
    if chain[-1] in flat:
        pts.append((0.0, pts[-1][1]))
    if chain[0] in flat:
        pts.insert(0, (0.0, pts[0][1]))
    return pts, faces, stray


def frames(p):
    """Rotations to try for a part's axis: upright first, then along each of its
    principal directions (a tilted tube, a lamp on its side). Each maps the axis to z."""
    out = [np.eye(3)]
    p = np.unique(np.round(p, 3), axis=0)
    if len(p) >= 4:
        _, e = np.linalg.eigh(np.cov((p - p.mean(0)).T))
        for k in range(3):
            a = e[:, k] / np.linalg.norm(e[:, k])
            if abs(a[2]) > 0.999:
                continue
            t = np.array([1.0, 0, 0]) if abs(a[0]) < 0.9 else np.array([0, 1.0, 0])
            e1 = np.cross(a, t)
            e1 /= np.linalg.norm(e1)
            out.append(np.stack([e1, np.cross(a, e1), a]))
    return out


def arc_steps(rad, angle, tol):
    """The fewest straight steps along an arc whose middles stay within tol of it."""
    if tol >= rad:
        return 1
    return max(1, math.ceil(abs(angle) / (2 * math.acos(1 - tol / rad))))


def rounded(pts, rounds, tol):
    """The profile with the given corners replaced by circular arcs; each point carries
    whether the surface is smooth through it (an arc) or creased (a plain corner)."""
    out = [(pts[0], False)]
    for j in range(1, len(pts) - 1):
        p, a, b = np.array(pts[j]), np.array(pts[j - 1]), np.array(pts[j + 1])
        rad = rounds.get(j)
        if not rad:
            out.append((tuple(p), False))
            continue
        u, w = (a - p) / np.linalg.norm(a - p), (b - p) / np.linalg.norm(b - p)
        half = math.acos(max(-1.0, min(1.0, float(u @ w)))) / 2
        d = rad / math.tan(half)  # from the corner to where the arc meets each side
        if d > 0.45 * min(np.linalg.norm(a - p), np.linalg.norm(b - p)):
            raise Refused(f"rounding {rad} at {tuple(round(x, 3) for x in p)} is too big for its sides")
        s, e = p + u * d, p + w * d
        c = p + (u + w) / np.linalg.norm(u + w) * (rad / math.sin(half))
        a0, a1 = math.atan2(*(s - c)[::-1]), math.atan2(*(e - c)[::-1])
        da = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        steps = arc_steps(rad, da, tol)
        for k in range(steps + 1):
            t = a0 + da * k / steps
            out.append(((c[0] + rad * math.cos(t), c[1] + rad * math.sin(t)), True))
    out.append((pts[-1], False))
    return out


def ring_normals(v, vn, faces, centre, pts):
    """For each profile point, the original's normal there in (radius, height) if all its
    corners share one (the original shades smoothly through that ring), else None (a
    crease, or a ring at the axis)."""
    out = []
    for r, z in pts:
        ns = []
        for f in faces:
            for c in f:
                p = v[c[0]]
                d = p[:2] - centre
                rr = math.hypot(*d)
                if rr > 1e-6 and abs(p[2] - z) < 0.03 and abs(rr - r) < 0.06 + 0.01 * r:
                    nn = vn[c[2]]
                    ns.append((float(nn[:2] @ d / rr), float(nn[2])))
        ns = np.array(ns)
        if r < 0.1 or not len(ns) or np.ptp(ns, axis=0).max() > 0.15:
            out.append(None)
        else:
            m = ns.mean(0)
            out.append(m / np.linalg.norm(m))
    return out


def smoothed(prof, normal_at):
    """The profile with every bend the original shades smoothly (one normal through the
    ring) marked smooth, so it is shaded across rather than creased; the outline is unchanged."""
    out = []
    for j, (p, smooth) in enumerate(prof):
        inner = 0 < j < len(prof) - 1
        out.append((p, smooth or (inner and normal_at.get(tuple(p)) is not None)))
    return out


def catmull(p0, p1, p2, p3, s):
    """The centripetal Catmull-Rom curve from p1 (s = 0) to p2 (s = 1): no loops or
    overshoot however unevenly the points are spaced."""
    t1 = max(np.linalg.norm(p1 - p0) ** 0.5, 1e-9)
    t2 = t1 + max(np.linalg.norm(p2 - p1) ** 0.5, 1e-9)
    t3 = t2 + max(np.linalg.norm(p3 - p2) ** 0.5, 1e-9)
    t = t1 + (t2 - t1) * s
    a1 = ((t1 - t) * p0 + t * p1) / t1
    a2 = ((t2 - t) * p1 + (t - t1) * p2) / (t2 - t1)
    a3 = ((t3 - t) * p2 + (t - t2) * p3) / (t3 - t2)
    b1 = ((t2 - t) * a1 + t * a2) / t2
    b2 = ((t3 - t) * a2 + (t - t1) * a3) / (t3 - t1)
    return ((t2 - t) * b1 + (t - t1) * b2) / (t2 - t1)


def spline(P, smooth, tol, before=None, after=None):
    """Points along a smooth curve through P, as (point, span j, fraction s along it).
    A span runs straight unless one of its ends is smooth; it curves through its
    neighbours there, and past the ends through before/after (default: straight on), in
    the fewest steps that keep within tol of the curve."""
    P = [np.asarray(p, float) for p in P]
    out = [(P[0], 0, 0.0)]
    for j in range(len(P) - 1):
        a, b = P[j], P[j + 1]
        if not (smooth[j] or smooth[j + 1]):
            out.append((b, j, 1.0))
            continue
        p0 = P[j - 1] if j > 0 and smooth[j] else (before if j == 0 and before is not None else 2 * a - b)
        last = j + 2 == len(P)
        p3 = P[j + 2] if not last and smooth[j + 1] else (after if last and after is not None else 2 * b - a)
        fine_s = np.linspace(0, 1, 33)
        fine = np.array([catmull(p0, a, b, p3, s) for s in fine_s])
        for k in range(1, 33):
            knots = np.array([catmull(p0, a, b, p3, i / k) for i in range(k + 1)])
            seg = np.clip((fine_s * k).astype(int), 0, k - 1)
            q0, d = knots[seg], knots[seg + 1] - knots[seg]
            w = np.clip(((fine - q0) * d).sum(1) / np.maximum((d * d).sum(1), 1e-12), 0, 1)
            if np.linalg.norm(fine - (q0 + d * w[:, None]), axis=1).max() <= tol:
                break
        out += [(knots[i], j, i / k) for i in range(1, k + 1)]
    return out


def auto_rounds(pts, normals):
    """Roundings for the recipe's "smooth_outline": every bend the original shades
    smoothly rounded as far as its two sides allow (an arc meeting each 0.44 of the way
    along the shorter), so a coarse dome becomes a smooth one while long straight runs
    stay straight; {profile index: radius}."""
    out = {}
    for j in range(1, len(pts) - 1):
        if normals[j] is None:
            continue
        p, a, b = (np.array(pts[k], float) for k in (j, j - 1, j + 1))
        la, lb = np.linalg.norm(a - p), np.linalg.norm(b - p)
        half = math.acos(max(-1.0, min(1.0, float((a - p) @ (b - p) / (la * lb))))) / 2
        if half < math.radians(89.5):
            out[j] = 0.44 * min(la, lb) * math.tan(half)
    return out


def bent_path(C, sharp, rad, tol):
    """Points along a tube's path through ring centres C whose rings at the indices in
    sharp come in pairs either side of a sharp bend (a stair rail's turn down): each pair
    becomes one corner where the straight runs either side meet, bent round as a pipe is
    (twice the tube's radius), and the runs between curve smoothly through their rings as
    in spline()."""
    C = [np.asarray(c, float) for c in C]
    pts, corner = [], []
    j = 0
    while j < len(C):
        if j in sharp and j + 1 in sharp and 0 < j and j + 2 < len(C):
            # where the lines through the runs either side come closest
            a, da = C[j], C[j] - C[j - 1]
            b, db = C[j + 1], C[j + 2] - C[j + 1]
            M = np.stack([da, -db], 1)
            s, t = np.linalg.lstsq(M, b - a, rcond=None)[0]
            pts.append(((a + s * da) + (b + t * db)) / 2)
            corner.append(True)
            j += 2
        else:
            pts.append(C[j])
            corner.append(False)
            j += 1
    out, run = [], [pts[0]]

    def flush(run):
        smooth = [0 < i < len(run) - 1 for i in range(len(run))]
        seg = [p for p, _, _ in spline(run, smooth, tol)]
        out.extend(seg if not out else seg[1:])

    for i in range(1, len(pts)):
        if not corner[i] or i == len(pts) - 1:
            run.append(pts[i])
            continue
        K, d1, d2 = pts[i], pts[i] - pts[i - 1], pts[i + 1] - pts[i]
        l1, l2 = np.linalg.norm(d1), np.linalg.norm(d2)
        d1, d2 = d1 / l1, d2 / l2
        bend = math.acos(max(-1.0, min(1.0, float(d1 @ d2))))
        R = 2 * rad
        L = min(R * math.tan(bend / 2), 0.45 * l1, 0.45 * l2)
        R = L / math.tan(bend / 2)
        run.append(K - d1 * L)
        flush(run)
        n1 = d2 - (d2 @ d1) * d1
        n1 /= np.linalg.norm(n1)
        c = K - d1 * L + R * n1
        steps = arc_steps(R, bend, tol)
        out.extend(c - R * (math.cos(f) * n1 - math.sin(f) * d1)
                   for f in np.linspace(0, bend, steps + 1)[1:])
        run = [K + d2 * L]
    flush(run)
    return np.array(out)


def tube(v, faces, tol, any_sides):
    """A part joined on (a lamp's arm) that is a tube, rings of the same few points along a
    bent path, remodelled round and bent smoothly: a centripetal Catmull-Rom path through
    the rings' centres, the radius changing between them as the original's does, and
    circles kept square to the path. Its vertices, normals and faces (quads)."""
    key = lambda i: tuple(np.round(v[i], 3))  # noqa: E731
    edges = {tuple(sorted((key(f[a][0]), key(f[(a + 1) % len(f)][0])))) for f in faces for a in range(len(f))}
    edges = [e for e in edges if e[0] != e[1]]
    ls = np.sort([math.dist(*e) for e in edges])
    gap = np.argmax(ls[1:] / ls[:-1])
    if ls[gap + 1] < 2 * ls[gap]:
        raise Refused("no rings told apart from the lengths between them")
    cut = (ls[gap] + ls[gap + 1]) / 2
    up = {}

    def root(x):
        while up.setdefault(x, x) != x:
            x = up[x]
        return x

    for a, b in edges:
        root(a), root(b)
        if math.dist(a, b) < cut:
            up[root(a)] = root(b)
    groups = defaultdict(list)
    for x in list(up):
        groups[root(x)].append(x)
    rings = list(groups.values())
    # two rings closer than their sides are long (a sharp bend) are taken as one: part them
    # by which ring along the tube each point leads to
    m = Counter(len(r) for r in rings).most_common(1)[0][0]
    ring_of = {x: k for k, r in enumerate(rings) for x in r}
    leads = defaultdict(set)
    for a, b in edges:
        if ring_of[a] != ring_of[b]:
            leads[a].add(ring_of[b]), leads[b].add(ring_of[a])
    pairs = []
    for r in [r for r in rings if len(r) == 2 * m]:
        to = {frozenset(leads[x]) for x in r}
        if len(to) == 2 and all(len(t) == 1 for t in to):
            halves = [[x for x in r if leads[x] == t] for t in to]
            if all(len(h) == m for h in halves):
                rings.remove(r)
                rings += halves
                pairs.append((halves[0][0], halves[1][0]))
    ring_of = {x: k for k, r in enumerate(rings) for x in r}
    names = list(range(len(rings)))
    sizes = {len(r) for r in rings}
    if len(sizes) != 1 or min(sizes) < 3 or len(names) < 3:
        raise Refused(f"not one tube: rings of {sorted(len(r) for r in rings)} points")
    links = defaultdict(set)
    for a, b in edges:
        if ring_of[a] != ring_of[b]:
            links[ring_of[a]].add(ring_of[b]), links[ring_of[b]].add(ring_of[a])
    ends = [k for k in names if len(links[k]) == 1]
    if any(len(s) > 2 for s in links.values()) or len(ends) != 2:
        raise Refused("the tube's rings do not form one open chain")
    chain = [ends[0]]
    while len(chain) < len(names):
        chain.append(next(k for k in links[chain[-1]] if k not in chain))
    pts = [np.array(rings[k]) for k in chain]
    C = [p.mean(0) for p in pts]
    rad = [float(np.linalg.norm(p - c, axis=1).mean()) for p, c in zip(pts, C)]
    m = len(pts[0])
    sharp = {chain.index(ring_of[a]) for a, b in pairs} | {chain.index(ring_of[b]) for a, b in pairs}
    if sharp:
        X = bent_path(C, sharp, float(np.median(rad)), tol)
        r = [float(np.median(rad))] * len(X)
    else:
        path = spline(C, [0 < j < len(C) - 1 for j in range(len(C))], tol)
        X = np.array([p for p, _, _ in path])
        r = [rad[j] + (rad[min(j + 1, len(rad) - 1)] - rad[j]) * s for _, j, s in path]
    T = np.gradient(X, axis=0)
    T /= np.linalg.norm(T, axis=1, keepdims=True)
    k = max(m, arc_steps(max(rad), 2 * math.pi, tol)) if any_sides else m * arc_steps(max(rad), 2 * math.pi / m, tol)
    u = pts[0][0] - C[0]
    verts, norms, grid = [], [], []
    for x, t, rr in zip(X, T, r):
        u = u - (u @ t) * t  # carried along the path without twisting
        u /= np.linalg.norm(u)
        w = np.cross(t, u)
        line = []
        for i in range(k + 1):
            a = 2 * math.pi * i / k
            d = math.cos(a) * u + math.sin(a) * w
            verts.append(x + rr * d)
            norms.append(d)
            line.append(len(verts) - 1)
        grid.append(line)
    quads = [[lo[i], lo[i + 1], hi[i + 1], hi[i]] for lo, hi in zip(grid, grid[1:]) for i in range(k)]
    print(f"    tube of {len(C)} rings of {m} points: {len(X)} rings of {k} sides")
    return np.array(verts), np.array(norms), quads


def surface(prof, centre, n, a0, tol, any_sides=False):
    """Vertices, smooth normals and faces of the profile turned around the axis. Each
    ring gets the fewest sides (a multiple of the original's n, or with any_sides any
    number from n up; the first always starts where the original's does) that keep it
    within tol of a circle, so a thin pole takes fewer than the wide base it stands on; rings with
    the same sides are joined by quads, others by triangles zipped along by angle, every
    ring's points shared by the faces either side of it (no gaps)."""
    P = np.array([p for p, _ in prof])
    # the normal of each profile segment in (r, z), pointing to the segment's right
    seg = np.diff(P, axis=0)
    sn = np.stack([seg[:, 1], -seg[:, 0]], 1)
    sn /= np.linalg.norm(sn, axis=1, keepdims=True)
    rows = []  # each: (r, z, normal in (r, z)); creased points get one row per side
    for j, (p, smooth) in enumerate(prof):
        ns = [sn[k] for k in (j - 1, j) if 0 <= k < len(sn)]
        if smooth or len(ns) == 1:
            m = sum(ns)
            rows.append([(p, m / np.linalg.norm(m))])
        else:
            rows.append([(p, ns[0]), (p, ns[1])])
    verts, norms, grid, sides = [], [], [], []
    for j, rw in enumerate(rows):
        if P[j][0] <= 1e-6:
            k = n
        elif any_sides:  # any count from n up, not only multiples: lighter, same accuracy
            k = max(n, arc_steps(P[j][0], 2 * math.pi, tol))
        else:
            k = n * arc_steps(P[j][0], 2 * math.pi / n, tol)
        angles = [a0 + 2 * math.pi * i / k for i in range(k + 1)]
        sides.append(k)
        ids = []
        for (r, z), (nr, nz) in rw:
            line = []
            for t in angles:
                ct, st = math.cos(t), math.sin(t)
                verts.append((centre[0] + r * ct, centre[1] + r * st, z))
                norms.append((nr * ct, nr * st, nz))
                line.append(len(verts) - 1)
            ids.append(line)
        grid.append(ids)
    faces = []
    for j in range(len(grid) - 1):
        if P[j][0] < 1e-6 and P[j + 1][0] < 1e-6:
            continue
        lo, hi = grid[j][-1], grid[j + 1][0]
        a, b = len(lo) - 1, len(hi) - 1
        if a == b:
            faces += [[lo[i], lo[i + 1], hi[i + 1], hi[i]] for i in range(a)]
            continue
        i = h = 0
        while i < a or h < b:
            if h == b or (i < a and (i + 1) / a <= (h + 1) / b):
                faces.append([lo[i], lo[i + 1], hi[h]])
                i += 1
            else:
                faces.append([lo[i], hi[h + 1], hi[h]])
                h += 1
    return np.array(verts), np.array(norms), faces, min(sides), max(sides)


def nearest_on_tris(p, A, B, C):
    """For point p: per triangle, the barycentric coordinates of the nearest point, and
    its squared distance."""
    ab, ac = B - A, C - A
    n = np.cross(ab, ac)
    # the projection onto each plane if it falls inside the triangle, else the nearest
    # point of its edges
    q = p - n * (((p - A) * n).sum(1) / (n * n).sum(1))[:, None]
    best_w, best_d = None, None
    cands = []
    v0, v1, v2 = ab, ac, q - A
    d00, d01, d11 = (v0 * v0).sum(1), (v0 * v1).sum(1), (v1 * v1).sum(1)
    d20, d21 = (v2 * v0).sum(1), (v2 * v1).sum(1)
    den = d00 * d11 - d01 * d01
    bv = (d11 * d20 - d01 * d21) / den
    bw = (d00 * d21 - d01 * d20) / den
    bu = 1 - bv - bw
    inside = (bu >= 0) & (bv >= 0) & (bw >= 0)
    cands.append((np.stack([bu, bv, bw], 1), np.where(inside, ((q - p) ** 2).sum(1), np.inf)))
    for (X, Y, ix, iy) in ((A, B, 0, 1), (B, C, 1, 2), (C, A, 2, 0)):
        e = Y - X
        t = np.clip(((p - X) * e).sum(1) / np.maximum((e * e).sum(1), 1e-12), 0, 1)
        w = np.zeros((len(A), 3))
        w[np.arange(len(A)), ix] = 1 - t
        w[np.arange(len(A)), iy] += t
        cands.append((w, (((X + e * t[:, None]) - p) ** 2).sum(1)))
    for w, dist in cands:
        if best_d is None:
            best_w, best_d = w.copy(), dist.copy()
        else:
            m = dist < best_d
            best_w[m], best_d[m] = w[m], dist[m]
    return best_w, best_d


def transfer_uvs(verts, quads, v, vt, faces):
    """Per quad corner: the original's UV at the nearest point of its surface."""
    tris = np.array([[c[0] for c in f[:3]] for f in faces])
    tuv = np.array([[c[1] for c in f[:3]] for f in faces])
    A, B, C = v[tris[:, 0]], v[tris[:, 1]], v[tris[:, 2]]
    UA, UB, UC = vt[tuv[:, 0]], vt[tuv[:, 1]], vt[tuv[:, 2]]

    def at(p):
        w, dist = nearest_on_tris(p, A, B, C)
        k = int(np.argmin(dist))
        return w[k] @ np.stack([UA[k], UB[k], UC[k]]), k

    def affine(k, p):
        """Triangle k's UV map extended to p (projected onto its plane)."""
        M = np.stack([B[k] - A[k], C[k] - A[k]], 1)
        st = np.linalg.lstsq(M, p - A[k], rcond=None)[0]
        return UA[k] + st[0] * (UB[k] - UA[k]) + st[1] * (UC[k] - UA[k])

    cache = {}
    out = []
    for q in quads:
        uvs = []
        for i in q:
            if i not in cache:
                cache[i] = at(verts[i])
            uvs.append(cache[i][0])
        uvs = np.array(uvs)
        if np.ptp(uvs, axis=0).max() > 0.3:  # corners on different islands
            _, k = at(verts[q].mean(0))
            uvs = np.array([affine(k, verts[i]) for i in q])
        out.append(uvs)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recipe")
    ap.add_argument("--props", default=os.path.join(HERE, "..", "build", "props"))
    args = ap.parse_args()
    recipe = json.load(open(args.recipe))
    model = recipe["model"].lower()
    folder = os.path.join(args.props, model[len("models/"):-4])
    stem = os.path.basename(folder)
    src = os.path.join(folder, stem + ".obj")
    if not os.path.exists(src):
        print(f"{src} not found: run tools/mdl_extract.py {model} first", file=sys.stderr)
        return 1
    v, vt, vn, groups, order = read_obj(src)
    try:
        tol = float(recipe["tolerance"])
        print(model)
        out_v, out_n, out_uv, out_f = [], [], [], []
        unused = list(range(len(recipe.get("round", []))))
        kept = 0
        loose = bool(recipe.get("keep_others"))

        def keep(mat, faces):
            """Faces drawn exactly as the original's."""
            ids, fs = {}, []
            for f in faces:
                vs = []
                for c in f:
                    if (c[0], c[2]) not in ids:
                        ids[c[0], c[2]] = len(out_v)
                        out_v.append(v[c[0]])
                        out_n.append(vn[c[2]])
                    vs.append(ids[c[0], c[2]])
                fs.append((vs, list(range(len(out_uv), len(out_uv) + len(f)))))
                out_uv.extend(vt[c[1]] for c in f)
            out_f.append((mat, fs))
            return len(faces)

        def add(mat, sv, sn, quads, faces, vR, vnR, R):
            """New faces made from the original's faces, in the frame R turned the model to."""
            # normals the way the original's point (most of its vertices' nearest new one
            # agreeing), and triangles wound as the game's: clockwise seen from the front
            near = [int(np.argmin(((sv - vR[c[0]]) ** 2).sum(1))) for f in faces for c in f]
            ref = np.array([vnR[c[2]] for f in faces for c in f])
            if ((sn[near] * ref).sum(1) < 0).sum() > len(near) / 2:
                sn = -sn
            area = [np.linalg.norm(np.cross(sv[q[1]] - sv[q[0]], sv[q[2]] - sv[q[0]])) for q in quads]
            q0 = quads[int(np.argmax(area))]
            fn = np.cross(sv[q0[1]] - sv[q0[0]], sv[q0[2]] - sv[q0[0]])
            if fn @ sn[q0[0]] > 0:
                quads = [q[::-1] for q in quads]
            uvs = transfer_uvs(sv, quads, vR, vt, faces)
            sv, sn = sv @ R, sn @ R  # back from the axis's frame to the model's
            base = len(out_v)
            out_v.extend(sv)
            out_n.extend(sn)
            fs = []
            for q, uv in zip(quads, uvs):
                fs.append(([base + i for i in q], list(range(len(out_uv), len(out_uv) + len(q)))))
                out_uv.extend(uv)
            out_f.append((mat, fs))

        for mat, part in [(m, p) for m in order for p in parts(v, groups[m])]:
            pids = sorted({c[0] for f in part for c in f})
            found, err = None, None
            for R in frames(v[pids]):
                try:
                    vR = v @ R.T
                    centre, n, a0 = axis_and_sides(vR[pids], loose=loose)
                    found = (R, vR, centre, n, a0) + profile(vR, part, centre, n if loose else None)
                    break
                except Refused as e:
                    err = err or e
            if not found:
                if not loose:
                    raise err
                if recipe.get("tubes"):
                    try:  # a tube on its own (a hand rail)
                        tv, tn, tq = tube(v, part, tol, recipe.get("any_sides", False))
                        add(mat, tv, tn, tq, part, v, vn, np.eye(3))
                        continue
                    except Refused as e:
                        if len(part) > 32:
                            print(f"  {mat} part of {len(part)} faces kept: {e}")
                kept += keep(mat, part)  # not round about any axis
                continue
            R, vR, centre, n, a0, pts, faces, stray = found
            vnR = vn @ R.T
            if stray and recipe.get("tubes"):
                # faces reaching the round part's rings join the two and are kept; the rest
                # may be a tube (a lamp's arm)
                def on_round(i):
                    rr = math.hypot(*(vR[i][:2] - centre))
                    return any(abs(vR[i][2] - z) < 0.03 and abs(rr - pr) < 0.06 + 0.01 * pr for pr, z in pts)
                joins = [f for f in stray if any(on_round(c[0]) for c in f)]
                arm = [f for f in stray if not any(on_round(c[0]) for c in f)]
                try:
                    tv, tn, tq = tube(vR, arm, tol, recipe.get("any_sides", False))
                    add(mat, tv, tn, tq, arm, vR, vnR, R)
                    stray = joins
                except Refused as e:
                    print(f"    joined-on part kept: {e}")
            kept += keep(mat, stray)  # joined on but not round (a knob, a bracket)
            tilt = math.degrees(math.acos(min(1.0, abs(R[2][2]))))
            print(f"  {mat}, {n} sides around ({centre[0]:.3f}, {centre[1]:.3f})"
                  + (f", axis tilted {tilt:.0f} degrees" if tilt > 0.5 else "")
                  + (f", {len(stray)} faces joined on kept" if stray else "") + ", profile: "
                  + "  ".join(f"({r:.3f}, {z:.3f})" for r, z in pts))
            rounds = {}
            for k, rd in enumerate(recipe.get("round", [])):
                if rd["material"] != mat:
                    continue
                j = min(range(len(pts)), key=lambda j: math.dist(pts[j], rd["at"]))
                if math.dist(pts[j], rd["at"]) > 0.05:
                    continue
                if j in (0, len(pts) - 1):
                    raise Refused(f"{mat} corner {rd['at']} is an end of its profile, not a corner")
                rounds[j] = rd["radius"]
                unused.remove(k)
            # bends the original shades smoothly are shaded smoothly here too (and with
            # "smooth_outline", rounded)
            normals = ring_normals(vR, vnR, faces, centre, pts)
            if recipe.get("smooth_outline"):
                rounds = {**auto_rounds(pts, normals), **rounds}
            normal_at = {tuple(p): nn for p, nn in zip(pts, normals)}
            prof = smoothed(rounded(pts, rounds, tol), normal_at)
            sv, sn, quads, lo, hi = surface(prof, centre, n, a0, tol, recipe.get("any_sides", False))
            print(f"    {lo} sides" if lo == hi else f"    {lo} to {hi} sides")
            add(mat, sv, sn, quads, faces, vR, vnR, R)
        for k in unused:
            rd = recipe["round"][k]
            raise Refused(f"{rd['material']} has no profile corner at {rd['at']}")
    except Refused as e:
        print(f"{model}: {e}", file=sys.stderr)
        return 1
    dst = os.path.join(folder, stem + "_remodel.obj")
    ntri = 0
    with open(dst, "w") as f:
        f.write(f"# {model} remodelled by tools/prop_revolve.py from {os.path.basename(args.recipe)}\n")
        f.write(f"mtllib {stem}.mtl\n")
        for p in out_v:
            f.write("v {:.6f} {:.6f} {:.6f}\n".format(*p))
        for t in out_uv:
            f.write("vt {:.6f} {:.6f}\n".format(*t))
        for nn in out_n:
            f.write("vn {:.6f} {:.6f} {:.6f}\n".format(*nn))
        for mat, fs in out_f:
            f.write(f"usemtl {mat}\n")
            for vs, ts in fs:
                for tri in ((0, 1, 2), (0, 2, 3))[:len(vs) - 2]:
                    if len({vs[i] for i in tri}) < 3 or len({tuple(np.round(out_v[vs[i]], 6)) for i in tri}) < 3:
                        continue
                    f.write("f " + " ".join(f"{vs[i] + 1}/{ts[i] + 1}/{vs[i] + 1}" for i in tri) + "\n")
                    ntri += 1
    print(f"{ntri} triangles{f' ({kept} kept as the original)' if kept else ''} -> {os.path.abspath(dst)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
