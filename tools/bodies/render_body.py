"""The game's character and the rebuilt one side by side, for review.

    Blender --background CHAR.blend --python tools/bodies/render_body.py -- TEXDIR OUT.png
        PART.npz [PART.npz ...] [--solid] [--crop X0,Z0,X1,Z1]

Each PART.npz (fit_body.py, fit_head.py, ...) replaces the game's material it was bound
to: that material is hidden on the game's model and the part drawn in its place with the
same texture (TEXDIR/<material>.png, or <material>_opaque2.png where the game's has its
alpha used for something else). A part holding "mat_name" is drawn with that texture
instead. Rows: the game's model, then the rebuilt one, each from the front, at 45
degrees, from the side and from behind. --crop frames a box (in the model's x and
height) instead of the whole figure, for a closer look; --solid is plain grey.
"""
import math
import os
import sys

import bpy
import numpy as np
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
texdir, out = args[0], args[1]
parts = [a for a in args[2:] if a.endswith(".npz")]
solid = "--solid" in args
crop = [float(x) for x in args[args.index("--crop") + 1].split(",")] if "--crop" in args else None
VIEWS = [0, 45, 90, 180]

obj = next(o for o in bpy.data.objects if o.type == "MESH")
mesh = obj.data
for o in bpy.data.objects:
    if o.type == "ARMATURE":
        o.hide_render = True


def texture_for(name):
    for suffix in ("_opaque2.png", ".png"):
        p = os.path.join(texdir, name + suffix)
        if os.path.exists(p):
            return p
    return None


def textured(name):
    m = bpy.data.materials.new(name + "_r")
    p = texture_for(name)
    if p:
        m.use_nodes = True
        t = m.node_tree.nodes.new("ShaderNodeTexImage")
        t.image = bpy.data.images.load(p)
        m.node_tree.nodes.active = t
    return m


for i, m in enumerate(mesh.materials):
    if m:
        mesh.materials[i] = textured(m.name)
mat_names = [m.name[:-2] if m else "" for m in mesh.materials]

scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "SINGLE" if solid else "TEXTURE"
scene.display.shading.single_color = (0.75, 0.72, 0.7)
scene.render.resolution_x, scene.render.resolution_y = (768, 1024) if not crop else (768, 768)
scene.world = bpy.data.worlds.new("w")
scene.world.color = (0.2, 0.2, 0.22)

co = np.array([v.co[:] for v in mesh.vertices])
new_objs, replaced, hide_polys = [], set(), set()
mesh.calc_loop_triangles()
tri_mat = {tuple(sorted(t.vertices)): t.material_index for t in mesh.loop_triangles}
for path in parts:
    H = np.load(path)
    if "mat_name" in H:
        mat = str(H["mat_name"])
    else:
        # The material its binding triangles belong to on the game's model.
        votes = [tri_mat.get(tuple(sorted(b)), -1) for b in H["bind_tri"][:200]]
        mat = mat_names[max(set(votes), key=votes.count)]
    if "hide" in H:  # the game's triangles it replaces (the import keeps them as its faces, in order)
        hide_polys.update(int(i) for i in H["hide"])
    else:
        replaced.add(mat)
    me = bpy.data.meshes.new(os.path.basename(path))
    me.from_pydata(H["verts"].tolist(), [], H["tris"].tolist())
    if "uvs" in H:
        uv = me.uv_layers.new()
        uv.data.foreach_set("uv", H["uvs"].astype(np.float32).ravel())
    for p in me.polygons:
        p.use_smooth = True
    me.materials.append(textured(mat))
    o = bpy.data.objects.new(me.name, me)
    scene.collection.objects.link(o)
    new_objs.append(o)
for p in mesh.polygons:
    p.use_smooth = True

cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.type = "ORTHO"
scene.collection.objects.link(cam)
scene.camera = cam
if crop:
    x0, z0, x1, z1 = crop
    centre = Vector(((x0 + x1) / 2, 0, (z0 + z1) / 2))
    cam.data.ortho_scale = max(x1 - x0, z1 - z0)
else:
    centre = Vector((0, 0, co[:, 2].max() / 2))
    cam.data.ortho_scale = co[:, 2].max() * 1.07

tiles = []
tmp = bpy.app.tempdir + "tile.png"
for show_new in (False, True):
    for o in new_objs:
        o.hide_render = not show_new
    if show_new:
        # A copy of the game's model without the faces the parts replace.
        bm_obj = obj.copy()
        bm_obj.data = mesh.copy()
        for e in list(bm_obj.data.vertices) + list(bm_obj.data.edges):
            e.select = False
        for p in bm_obj.data.polygons:
            p.select = mat_names[p.material_index] in replaced or p.index in hide_polys
            if p.select:
                for v in p.vertices:
                    bm_obj.data.vertices[v].select = True
        bpy.context.scene.collection.objects.link(bm_obj)
        bpy.context.view_layer.objects.active = bm_obj
        bpy.ops.object.mode_set(mode="EDIT")
        bpy.ops.mesh.select_mode(type="FACE")
        bpy.ops.mesh.delete(type="FACE")
        bpy.ops.object.mode_set(mode="OBJECT")
        obj.hide_render = True
    for az in VIEWS:
        a = math.radians(az)
        d = Vector((math.sin(a), -math.cos(a), 0.05))  # the game's models face -y
        cam.location = centre + d * 5
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = tmp
        bpy.ops.render.render(write_still=True)
        img = bpy.data.images.load(tmp, check_existing=False)
        tiles.append(np.array(img.pixels[:]).reshape(img.size[1], img.size[0], 4))
        bpy.data.images.remove(img)
    if show_new:
        bpy.data.objects.remove(bm_obj)
        obj.hide_render = False

rows = [np.hstack(tiles[i:i + len(VIEWS)]) for i in range(0, len(tiles), len(VIEWS))]
sheet = np.vstack(rows[::-1])  # Blender's pixels run bottom-up: first row on top
img = bpy.data.images.new("sheet", sheet.shape[1], sheet.shape[0])
img.pixels = sheet.ravel()
img.filepath_raw = out
img.file_format = "PNG"
img.save()
print(f"[render] {len(rows)} rows -> {out}")
