"""Rebuild a boxy prop (a van) with rounded corners and round wheels, keeping its UVs so its
texture lands where it did.

    Blender --background --python tools/blender/prop_rebuild.py -- tools/props/vw_bus.json

A recipe names the extracted model (tools/mdl_extract.py), the corners' rounding and the wheels:
    {"model": "models/scenery/vehicles/vw_bus/vw_bus.mdl", "method": "rebuild",
     "bevel": 2.5, "segments": 2, "angle": 35, "length": 15, "material": "VW_Bus",
     "wheels": {"axis": "y", "centers": [[61.27, 14.73], [-53.42, 14.73]], "radius": 16, "sides": 24}}
Corners: every edge of the body (its largest piece) of the named material, at least
"length" units long, whose faces meet at more than "angle" degrees (not an open edge),
is rounded over "bevel" units in "segments" pieces. The UVs are
interpolated across the rounding, so each side keeps its texture up to the corner.
Wheels: every separate piece lying within "radius" of one of the centres (the other two
coordinates, the axis left out) is a wheel. Each edge of its outer half (away from the
van's middle; the inner half is not seen) that runs around the axle is split so the wheel has about "sides" sides, and every point beyond 5 units from the
axle is pushed out from the flat side it lies on to the circle through that side's
corners (the original's own points stay where they are), so the tyres and rims are round.
Shading: smooth, with edges sharper than 40 degrees left hard.

Writes build/props/<model>/<name>_remodel.obj, for tools/prop_pack.py, keeping the
original's winding (the game winds clockwise; normals outward), and prints the counts.
"""
import json
import math
import os
import sys

import bmesh
import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
HUB = 5.0  # points nearer the axle than this are the hub's, left as they are

recipe = json.load(open(sys.argv[sys.argv.index("--") + 1]))
rel = os.path.splitext(recipe["model"])[0][len("models/"):]
name = os.path.basename(rel)
src = os.path.join(ROOT, "build", "props", rel, name + ".obj")
dst = os.path.join(ROOT, "build", "props", rel, name + "_remodel.obj")

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=src, forward_axis="Y", up_axis="Z")
obj = bpy.context.selected_objects[0]
bpy.context.view_layer.objects.active = obj
orig_tris = len(obj.data.polygons)

# each face turned to face the way its own normals point (the game winds against them,
# and not every face of the original is wound the same way)
cn = np.empty(len(obj.data.loops) * 3)
obj.data.corner_normals.foreach_get("vector", cn)
cn = cn.reshape(-1, 3)
bpy.ops.mesh.customdata_custom_splitnormals_clear()  # from here on, normals from the faces
bm = bmesh.new()
bm.from_mesh(obj.data)
bm.normal_update()
flip = [f for f in bm.faces if np.dot(f.normal, sum(cn[l.index] for l in f.loops)) < 0]
bmesh.ops.reverse_faces(bm, faces=flip)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.01)

# the body: the largest piece; only its corners at least "length" long (not its small details)
pieces, seen = [], set()
for v in bm.verts:
    if v in seen:
        continue
    part, stack = set(), [v]
    seen.add(v)
    while stack:
        x = stack.pop()
        part.add(x)
        for e in x.link_edges:
            y = e.other_vert(x)
            if y not in seen:
                seen.add(y)
                stack.append(y)
    pieces.append(part)
body = max(pieces, key=len)

# --- wheels -------------------------------------------------------------------------
wh = recipe.get("wheels")
nwheel = 0
if wh:
    ax = "xyz".index(wh["axis"])
    i0, i1 = [i for i in range(3) if i != ax]
    centres = [np.array(c, float) for c in wh["centers"]]
    step = 2 * math.pi / wh["sides"]

    def plane(co):
        return np.array([co[i0], co[i1]])

    seen, wheel_verts = set(), []
    for v in bm.verts:
        if v in seen:
            continue
        part, stack = [], [v]
        seen.add(v)
        while stack:
            x = stack.pop()
            part.append(x)
            for e in x.link_edges:
                y = e.other_vert(x)
                if y not in seen:
                    seen.add(y)
                    stack.append(y)
        pts = np.array([plane(x.co) for x in part])
        for c in centres:
            if np.linalg.norm(pts - c, axis=1).max() < wh["radius"]:
                wheel_verts.append((part, c))
                nwheel += 1
                break
    split_faces = set()
    for part, c in wheel_verts:
        def polar(co):
            d = plane(co) - c
            return math.hypot(*d), math.atan2(d[1], d[0])

        # the outer half of each wheel (away from the van's middle along the axle): the
        # inner half is not seen, and is left as it is
        span = {}
        for v in part:
            if polar(v.co)[0] > HUB:
                k = v.co[ax] > 0
                lo, hi = span.get(k, (abs(v.co[ax]), abs(v.co[ax])))
                span[k] = (min(lo, abs(v.co[ax])), max(hi, abs(v.co[ax])))

        def outer(v):
            lo, hi = span.get(v.co[ax] > 0, (0, 0))
            return abs(v.co[ax]) >= (lo + hi) / 2

        edges = {e for v in part for e in v.link_edges}
        for e in edges:
            va, vb = e.verts
            (ra, ta), (rb, tb) = polar(va.co), polar(vb.co)
            dt = (tb - ta + math.pi) % (2 * math.pi) - math.pi
            n = round(abs(dt) / step)
            if min(ra, rb) <= HUB or n < 2 or abs(dt) > math.pi / 3 or not (outer(va) or outer(vb)):
                continue
            pa, pb = va.co.copy(), vb.co.copy()
            split_faces |= set(e.link_faces)
            # along the arc from va: angle, distance from the axle and along it all evenly
            ends = [(i / n, ta + dt * i / n, ra + (rb - ra) * i / n) for i in range(1, n)]
            cur = e
            for k, (s, t, r) in enumerate(ends):
                # each split cuts what is left of the edge, from va's side
                fac = (s - (ends[k - 1][0] if k else 0)) / (1 - (ends[k - 1][0] if k else 0))
                start = va if k == 0 else last
                ne, nv = bmesh.utils.edge_split(cur, start, fac)
                q = pa + (pb - pa) * s
                q[i0], q[i1] = c[0] + r * math.cos(t), c[1] + r * math.sin(t)
                nv.co = q
                last = nv
                cur = ne if nv in ne.verts and vb in ne.verts else next(x for x in nv.link_edges if vb in x.verts)
    faces = [f for f in split_faces if f.is_valid]
    bmesh.ops.triangulate(bm, faces=faces, quad_method="BEAUTY", ngon_method="EAR_CLIP")

# --- corners --------------------------------------------------------------------------
mat = [m.name for m in obj.data.materials].index(recipe["material"])
lim = math.cos(math.radians(recipe["angle"]))
bm.normal_update()
bm.edges.index_update()
ids = {e.index for e in bm.edges if len(e.link_faces) == 2 and e.verts[0] in body and e.verts[1] in body
       and all(f.material_index == mat for f in e.link_faces)
       and e.link_faces[0].normal @ e.link_faces[1].normal < lim and e.calc_length() >= recipe["length"]}
round_edges = ids
bm.to_mesh(obj.data)
bm.free()
w = obj.data.attributes.new("bevel_weight_edge", "FLOAT", "EDGE")
w.data.foreach_set("value", [1.0 if i in ids else 0.0 for i in range(len(obj.data.edges))])
bev = obj.modifiers.new("round", "BEVEL")
bev.limit_method = "WEIGHT"
bev.width = recipe["bevel"]
bev.segments = recipe["segments"]
bev.profile = 0.5
bev.use_clamp_overlap = True
bev.miter_outer = "MITER_ARC"
bpy.ops.object.modifier_apply(modifier=bev.name)
tri = obj.modifiers.new("tri", "TRIANGULATE")
bpy.ops.object.modifier_apply(modifier=tri.name)
for p in obj.data.polygons:
    p.use_smooth = True
obj.data.set_sharp_from_angle(angle=math.radians(40))
obj.data.validate()

bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.ops.wm.obj_export(filepath=dst, export_selected_objects=True, forward_axis="Y", up_axis="Z",
                      export_triangulated_mesh=True, export_normals=True, export_uv=True,
                      export_materials=True, path_mode="STRIP")
# back to the game's winding, the normals still outward (as the extracted model has them)
lines = open(dst).read().splitlines()
with open(dst, "w") as f:
    for line in lines:
        if line.startswith("f "):
            line = "f " + " ".join(reversed(line.split()[1:]))
        f.write(line + "\n")
# the extracted model's .mtl (textures by the game's material names)
mtl = os.path.join(os.path.dirname(dst), name + ".mtl")
text = open(dst).read()
import re
text = re.sub(r"^mtllib .*$", "mtllib " + name + ".mtl", text, flags=re.M)
open(dst, "w").write(text)
print(f"{name}: {orig_tris} triangles -> {len(obj.data.polygons)} triangles, {len(obj.data.vertices)} vertices; "
      f"{len(round_edges)} corners rounded, {nwheel} wheel pieces made round")
print(dst)
