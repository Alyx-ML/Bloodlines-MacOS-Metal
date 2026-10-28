"""Round off a prop made of tubes and boxes (a traffic light): its faceted poles, arms and
lenses made round, its box corners softened, keeping its UVs so its textures land where they did.

    Blender --background --python tools/blender/prop_round.py -- tools/props/streetlight.json

A recipe names the extracted model (tools/mdl_extract.py) and how it is rounded:
    {"model": "models/scenery/street/streetlight/streetlight.mdl", "method": "round",
     "angle": 70, "crease": 0.8, "levels": 2, "flat": 1}
Edges whose faces meet at less than "angle" degrees (a tube's facets) are smoothed away;
sharper ones (a box's corners) keep "crease" of their edge (1 is a hard corner), so they
are only slightly rounded. The surface is subdivided (Catmull-Clark) "levels" times, the
open edges keeping their corners, then faces within "flat" degrees of their neighbours
(of one material and UV island) are merged again, so flat sides cost no more than before.
Shading: smooth, with edges sharper than "angle" left hard.

Writes build/props/<model>/<name>_remodel.obj, for tools/prop_pack.py, keeping the
original's winding (the game winds clockwise; normals outward), and prints the counts.
"""
import json
import math
import os
import re
import sys

import bmesh
import bpy
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.join(HERE, "..", "..")

recipe = json.load(open(sys.argv[sys.argv.index("--") + 1]))
rel = os.path.splitext(recipe["model"])[0][len("models/"):]
name = os.path.basename(rel)
src = os.path.join(ROOT, "build", "props", rel, name + ".obj")
dst = os.path.join(ROOT, "build", "props", rel, name + "_remodel.obj")
angle = math.radians(recipe["angle"])

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
# quads again where the game split them, so the subdivision follows the original's rows
bmesh.ops.join_triangles(bm, faces=bm.faces, angle_face_threshold=math.radians(40),
                         angle_shape_threshold=math.radians(40), cmp_uvs=True, cmp_materials=True)
bm.normal_update()
crease = bm.edges.layers.float.new("crease_edge")
hard = 0
for e in bm.edges:
    if len(e.link_faces) == 2 and e.link_faces[0].normal.angle(e.link_faces[1].normal, 0) > angle:
        e[crease] = recipe["crease"]
        hard += 1
# pieces with a "keep" material (a pole's fluted base: its profile is its shape) are left as they are
keep_mats = {i for i, m in enumerate(obj.data.materials) if m.name in recipe.get("keep", [])}
kept, seen = set(), set()
for f in bm.faces:
    if f in seen:
        continue
    part, stack = {f}, [f]
    seen.add(f)
    while stack:
        for e in stack.pop().edges:
            for g in e.link_faces:
                if g not in seen:
                    seen.add(g)
                    part.add(g)
                    stack.append(g)
    if any(g.material_index in keep_mats for g in part):
        kept |= part
bm.faces.index_update()
kept_ids, nkept = [f.index for f in kept], len(kept)
bm.to_mesh(obj.data)
rest = obj.copy()
rest.data = obj.data.copy()
bpy.context.collection.objects.link(rest)
bmesh.ops.delete(bm, geom=[f for f in bm.faces if f not in kept], context="FACES")
bm.to_mesh(obj.data)
bm.free()
bm = bmesh.new()
bm.from_mesh(rest.data)
bm.faces.ensure_lookup_table()
bmesh.ops.delete(bm, geom=[bm.faces[i] for i in kept_ids], context="FACES")
bm.to_mesh(rest.data)
bm.free()

bpy.ops.object.select_all(action="DESELECT")
bpy.context.view_layer.objects.active = rest
rest.select_set(True)
sub = rest.modifiers.new("round", "SUBSURF")
sub.levels = sub.render_levels = recipe["levels"]
sub.uv_smooth = "PRESERVE_CORNERS"
sub.boundary_smooth = "PRESERVE_CORNERS"
sub.use_creases = True
bpy.ops.object.modifier_apply(modifier=sub.name)
dense = len(rest.data.polygons)
dec = rest.modifiers.new("flat", "DECIMATE")
dec.decimate_type = "DISSOLVE"
dec.angle_limit = math.radians(recipe["flat"])
dec.delimit = {"MATERIAL", "UV", "SEAM"}
bpy.ops.object.modifier_apply(modifier=dec.name)
obj.select_set(True)
bpy.context.view_layer.objects.active = obj
bpy.ops.object.join()
tri = obj.modifiers.new("tri", "TRIANGULATE")
tri.quad_method = "BEAUTY"
tri.ngon_method = "BEAUTY"
bpy.ops.object.modifier_apply(modifier=tri.name)
for p in obj.data.polygons:
    p.use_smooth = True
obj.data.set_sharp_from_angle(angle=angle)
obj.data.validate()

bpy.ops.object.select_all(action="DESELECT")
obj.select_set(True)
bpy.ops.wm.obj_export(filepath=dst, export_selected_objects=True, forward_axis="Y", up_axis="Z",
                      export_triangulated_mesh=True, export_normals=True, export_uv=True,
                      export_materials=True, path_mode="STRIP")
# back to the game's winding, the normals still outward (as the extracted model has them),
# and the extracted model's .mtl (textures by the game's material names)
text = open(dst).read()
text = re.sub(r"^f (.*)$", lambda m: "f " + " ".join(reversed(m.group(1).split())), text, flags=re.M)
text = re.sub(r"^mtllib .*$", "mtllib " + name + ".mtl", text, flags=re.M)
open(dst, "w").write(text)
print(f"{name}: {orig_tris} triangles -> {dense} subdivided -> {len(obj.data.polygons)} triangles, "
      f"{len(obj.data.vertices)} vertices; {hard} corners kept, {nkept} faces left as they were")
print(dst)
