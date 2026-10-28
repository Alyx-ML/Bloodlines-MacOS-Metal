"""Remodel a rock or cliff prop with real relief: its faceted surface rounded off and
pushed in and out by its texture's height map, then thinned to a set triangle count.

    Blender --background --python tools/blender/rock_relief.py -- tools/props/cliffa.json

A recipe names the extracted model (tools/mdl_extract.py), the height map
(tools/tex_height.py), how deep the relief goes and how many triangles to keep:
    {"model": "models/scenery/structural/pier/cliffa.mdl", "method": "relief",
     "height": "sm_pier_1/models/scenery/structural/pier/cliffa_h.png",
     "depth": 32, "triangles": 4000}
"height" is under build/textures/maps. "depth" is the relief's full range in the
model's units: the height map's broad forms only (blurred to what about 4,000 triangles
can carry, as finer relief folds when thinned; the bump map has the fine detail), its
broadest light and dark bands taken out, scaled so three standard deviations either side
reach half of it.

The model is turned to face outward for Blender and back to the game's winding at the end.
It is subdivided four times. Inside, it takes the rounded (Catmull-Clark) surface;
at its open edges, where it meets the map, it keeps the original's flat faces and no
relief, fading over one original triangle, so it still meets what it met. UVs are the
original's, interpolated linearly, so the texture lands exactly where it did.
Where other props are mounted on it (build/props/<model>/<name>_pins.json, from
tools/prop_pins.py: a lamp on a cliff, a stairway up it), it keeps the original's surface within PIN_KEEP
units, fading to the full change by PIN_FADE, so they still sit on it.

Writes build/props/<model>/<name>_remodel.obj next to the extracted one, for
tools/prop_pack.py, and prints the triangle and vertex counts and how far the rounding
moved the surface.
"""
import json
import os
import sys

import bmesh
import bpy
import numpy as np
from mathutils.bvhtree import BVHTree
from mathutils.kdtree import KDTree

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")
LEVELS = 4
PIN_KEEP, PIN_FADE = 12, 40

recipe = json.load(open(sys.argv[sys.argv.index("--") + 1]))
rel = os.path.splitext(recipe["model"])[0][len("models/"):]
name = os.path.basename(rel)
src = os.path.join(ROOT, "build", "props", rel, name + ".obj")
dst = os.path.join(ROOT, "build", "props", rel, name + "_remodel.obj")
pins_path = os.path.join(ROOT, "build", "props", rel, name + "_pins.json")
pins = np.array(json.load(open(pins_path)) if os.path.exists(pins_path) else []).reshape(-1, 3)
height = os.path.join(ROOT, "build", "textures", "maps", recipe["height"])


def blur(a, sigma):
    """Gaussian blur, wrapping at the edges as the texture tiles."""
    fy = np.fft.fftfreq(a.shape[0])[:, None]
    fx = np.fft.fftfreq(a.shape[1])[None, :]
    g = np.exp(-2 * (np.pi * sigma) ** 2 * (fx * fx + fy * fy))
    return np.real(np.fft.ifft2(np.fft.fft2(a) * g))


def relief_image():
    """The height map's mid frequencies, 0.5 at rest, as a float image Blender samples."""
    img = bpy.data.images.load(height)
    w, h = img.size
    px = np.empty(w * h * 4, np.float32)
    img.pixels.foreach_get(px)
    a = px.reshape(h, w, 4)[..., 0].astype(np.float64)
    d = blur(a, 40) - blur(a, 240)
    d = np.clip(d / d.std(), -3, 3) / 6 + 0.5
    out = bpy.data.images.new("relief", w, h, float_buffer=True)
    rgba = np.repeat(d[..., None], 4, axis=2).astype(np.float32)
    rgba[..., 3] = 1
    out.pixels.foreach_set(rgba.ravel())
    return out


def subdivided(obj, kind):
    """A copy of obj subdivided LEVELS times, applied: its positions, as a mesh."""
    c = obj.copy()
    c.data = obj.data.copy()
    bpy.context.collection.objects.link(c)
    m = c.modifiers.new("sub", "SUBSURF")
    m.subdivision_type = kind
    m.levels = m.render_levels = LEVELS
    m.uv_smooth = "NONE"
    m.boundary_smooth = "PRESERVE_CORNERS"
    dg = bpy.context.evaluated_depsgraph_get()
    mesh = bpy.data.meshes.new_from_object(c.evaluated_get(dg))
    bpy.data.objects.remove(c)
    return mesh


bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.wm.obj_import(filepath=src, forward_axis="Y", up_axis="Z")
obj = bpy.context.selected_objects[0]
bpy.context.view_layer.objects.active = obj
orig_tris = len(obj.data.polygons)

bm = bmesh.new()
bm.from_mesh(obj.data)
bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.01)
bmesh.ops.reverse_faces(bm, faces=bm.faces)  # the game winds clockwise: outward for Blender
bm.to_mesh(obj.data)
orig_tree = BVHTree.FromBMesh(bm)
open_verts = {v.index for v in bm.verts if v.is_boundary}
bm.free()

# 0 on the open edges, 1 inside: how much rounding and relief each point takes
grp = obj.vertex_groups.new(name="inner")
grp.add([i for i in range(len(obj.data.vertices)) if i not in open_verts], 1.0, "REPLACE")
grp.add(list(open_verts), 0.0, "REPLACE")

flat = subdivided(obj, "SIMPLE")
round_ = subdivided(obj, "CATMULL_CLARK")
n = len(flat.vertices)
assert n == len(round_.vertices), "subdivisions differ"
a = np.empty(n * 3)
b = np.empty(n * 3)
flat.vertices.foreach_get("co", a)
round_.vertices.foreach_get("co", b)
w = np.array([next((g.weight for g in v.groups if g.group == 0), 0.0) for v in flat.vertices])
if len(pins):  # the original's surface kept where props are mounted
    kd = KDTree(len(pins))
    for i, p in enumerate(pins):
        kd.insert(p, i)
    kd.balance()
    d = np.array([kd.find(p)[2] for p in a.reshape(n, 3)])
    t = np.clip((d - PIN_KEEP) / (PIN_FADE - PIN_KEEP), 0, 1)
    w = np.minimum(w, t * t * (3 - 2 * t))
co = a.reshape(n, 3) + (b - a).reshape(n, 3) * w[:, None]
flat.vertices.foreach_set("co", co.ravel())
flat.update()

moved = np.array([(orig_tree.find_nearest(p)[3] or 0.0) for p in co])
bpy.data.meshes.remove(round_)

old = obj.data
obj.data = flat
bpy.data.meshes.remove(old)
q = np.round(w, 2)  # the same weights for the relief
for val in np.unique(q):
    obj.vertex_groups["inner"].add(np.nonzero(q == val)[0].tolist(), float(val), "REPLACE")
for p in obj.data.polygons:
    p.use_smooth = True

tex = bpy.data.textures.new("relief", "IMAGE")
tex.image = relief_image()
tex.extension = "REPEAT"
disp = obj.modifiers.new("relief", "DISPLACE")
disp.texture = tex
disp.texture_coords = "UV"
disp.uv_layer = obj.data.uv_layers[0].name
disp.direction = "NORMAL"
disp.mid_level = 0.5
disp.strength = recipe["depth"]
disp.vertex_group = "inner"

tri = obj.modifiers.new("tri", "TRIANGULATE")
dec = obj.modifiers.new("thin", "DECIMATE")
dec.decimate_type = "COLLAPSE"
dec.use_collapse_triangulate = True
dg = bpy.context.evaluated_depsgraph_get()
dense = len(bpy.data.meshes.new_from_object(obj.evaluated_get(dg)).polygons)
dec.ratio = min(1.0, recipe["triangles"] / dense)

for m in list(obj.modifiers):
    bpy.ops.object.modifier_apply(modifier=m.name)
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
            c = line.split()[1:]
            line = "f " + " ".join(reversed(c))
        f.write(line + "\n")

print(f"{name}: {orig_tris} triangles, {len(open_verts)} on open edges, {len(pins)} pins -> {dense} subdivided -> "
      f"{len(obj.data.polygons)} triangles, {len(obj.data.vertices)} vertices")
print(f"rounding moved the surface {moved.mean():.2f} on average, {moved.max():.2f} at most; "
      f"relief up to {recipe['depth'] / 2:g} either side")
print(dst)
