"""The game's head and the rebuilt one (fit_head.py) side by side, for review.

    Blender --background CHAR.blend --python tools/heads/render_head.py -- HEAD.npz OUT.png
        [--solid] [--texture FACE.png] [--keys NAME=W,NAME=W ...]

Rows: the game's head, then the rebuilt one in its place (the game's face hidden), each
from the front, at 40 degrees and from the side. --keys sets flex shape keys first (one
row pair per comma-free group, separated by spaces): the rebuilt head follows the game's
face through its binding, as it would in the game. --texture paints both with the game's
face texture (the rebuilt head through its own UVs); --solid is
plain grey, for the shapes.
"""
import math
import sys

import bpy
import numpy as np
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
head_path, out = args[0], args[1]
solid = "--solid" in args
texture = args[args.index("--texture") + 1] if "--texture" in args else None
poses = [""]
if "--keys" in args:
    poses = args[args.index("--keys") + 1:]
    poses = [p for p in poses if not p.startswith("--")]
VIEWS = [0, 40, 90]  # azimuth in degrees
SIZE = 512

H = np.load(head_path)
obj = next(o for o in bpy.data.objects if o.type == "MESH")
mesh = obj.data
face_mat = next(i for i, m in enumerate(mesh.materials) if m and "face" in m.name.lower())

scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "SINGLE" if solid or not texture else "TEXTURE"
scene.display.shading.single_color = (0.75, 0.72, 0.7)
scene.display.shading.show_cavity = False
scene.render.resolution_x = scene.render.resolution_y = SIZE
scene.world = bpy.data.worlds.new("w")
scene.world.color = (0.18, 0.18, 0.2)

if texture:
    img = bpy.data.images.load(texture)
    mat = bpy.data.materials.new("tex")
    mat.use_nodes = True
    tex = mat.node_tree.nodes.new("ShaderNodeTexImage")
    tex.image = img
    mat.node_tree.links.new(tex.outputs["Color"], mat.node_tree.nodes["Principled BSDF"].inputs["Base Color"])
    mesh.materials[face_mat] = mat

# The rebuilt head, with its UVs on the face's texture (fit_head.py).
new_me = bpy.data.meshes.new("rebuilt")
new_me.from_pydata(H["verts"].tolist(), [], H["tris"].tolist())
uv = new_me.uv_layers.new()
uv.data.foreach_set("uv", H["uvs"].astype(np.float32).ravel())
for p in new_me.polygons:
    p.use_smooth = True
new = bpy.data.objects.new("rebuilt", new_me)
scene.collection.objects.link(new)
if texture:
    new_me.materials.append(mesh.materials[face_mat])
for p in mesh.polygons:
    p.use_smooth = True

centre = Vector(H["verts"].mean(0))
radius = float(np.ptp(H["verts"], axis=0).max()) * 0.75
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
cam.data.type = "ORTHO"
cam.data.ortho_scale = radius * 2.2
scene.collection.objects.link(cam)
scene.camera = cam
for o in bpy.data.objects:
    if o.type == "ARMATURE":
        o.hide_render = True

hidden_mat = bpy.data.materials.new("hidden")


def set_pose(spec):
    for k in mesh.shape_keys.key_blocks if mesh.shape_keys else []:
        k.value = 0.0
    for part in filter(None, spec.split(",")):
        name, w = part.split("=")
        mesh.shape_keys.key_blocks[name].value = float(w)
    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    ev = obj.evaluated_get(dg).to_mesh()
    pos = np.array([v.co[:] for v in ev.vertices])
    obj.evaluated_get(dg).to_mesh_clear()
    tri = pos[H["bind_tri"]]
    e1 = tri[:, 1] - tri[:, 0]
    nrm = np.cross(e1, tri[:, 2] - tri[:, 0])
    e1 /= np.linalg.norm(e1, axis=1, keepdims=True) + 1e-12
    nrm /= np.linalg.norm(nrm, axis=1, keepdims=True) + 1e-12
    axes = np.stack([e1, np.cross(nrm, e1), nrm], 1)  # as fit_head.py's frames()
    pts = (tri * H["bind_bary"][:, :, None]).sum(1) + np.einsum("nij,ni->nj", axes, H["bind_off"])
    new_me.vertices.foreach_set("co", pts.astype(np.float32).ravel())
    new_me.update()


tiles = []
tmp = bpy.app.tempdir + "tile.png"
for pose in poses:
    set_pose(pose)
    for show_new in (False, True):
        new.hide_render = not show_new
        # The game's face hidden under the rebuilt head (a material with nothing drawn).
        saved = mesh.materials[face_mat]
        if show_new:
            mesh.materials[face_mat] = hidden_mat
            hidden_mat.diffuse_color = (0, 0, 0, 0)
        obj.hide_render = False
        if show_new:
            for p in mesh.polygons:
                p.hide = p.material_index == face_mat
        for az in VIEWS:
            a = math.radians(az)
            # The game's models face -y.
            d = Vector((math.sin(a), -math.cos(a), 0.05))
            cam.location = centre + d * radius * 6
            cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
            scene.render.filepath = tmp
            bpy.ops.render.render(write_still=True)
            tiles.append(np.array(bpy.data.images.load(tmp, check_existing=False).pixels[:]).reshape(SIZE, SIZE, 4))
        mesh.materials[face_mat] = saved
        for p in mesh.polygons:
            p.hide = False

rows = [np.hstack(tiles[i:i + len(VIEWS)]) for i in range(0, len(tiles), len(VIEWS))]
sheet = np.vstack(rows[::-1])  # Blender's pixels run bottom-up: first row on top
img = bpy.data.images.new("sheet", sheet.shape[1], sheet.shape[0])
img.pixels = sheet.ravel()
img.filepath_raw = out
img.file_format = "PNG"
img.save()
print(f"[render] {len(rows)} rows -> {out}")
