"""Turntable views of one or more prop OBJs side by side, textured, for review.

    Blender --background --python tools/blender/prop_render.py -- [--solid] OUT.png A.obj [B.obj ...]

Each OBJ is shown from the front, at 45 degrees and from above-front, one row per OBJ,
with flat studio light and its own textures, so the original and a remodel can be compared.
"""
import math
import os
import sys

import bpy
from mathutils import Vector

args = sys.argv[sys.argv.index("--") + 1:]
solid = args[0] == "--solid"  # plain grey, for dark textures that hide the shape
out, objs = args[solid], args[solid + 1:]
VIEWS = [(0, 10), (45, 10), (20, 45)]  # azimuth, elevation in degrees
SIZE = 512

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH"
scene.display.shading.light = "STUDIO"
scene.display.shading.color_type = "SINGLE" if solid else "TEXTURE"
scene.display.shading.show_cavity = False
scene.render.resolution_x = scene.render.resolution_y = SIZE
scene.render.film_transparent = False
scene.world = bpy.data.worlds.new("w")
scene.world.color = (0.18, 0.18, 0.2)
cam = bpy.data.objects.new("cam", bpy.data.cameras.new("cam"))
scene.collection.objects.link(cam)
scene.camera = cam
cam.data.type = "ORTHO"

tiles = []
for row, path in enumerate(objs):
    before = set(bpy.data.objects)
    bpy.ops.wm.obj_import(filepath=path, forward_axis="Y", up_axis="Z")
    new = [o for o in bpy.data.objects if o not in before]
    # the game's texture alpha is mostly a shine mask, not see-through: drawn opaque
    for img in bpy.data.images:
        img.alpha_mode = "NONE"
    pts = [o.matrix_world @ Vector(c) for o in new for c in o.bound_box]
    lo = Vector([min(p[i] for p in pts) for i in range(3)])
    hi = Vector([max(p[i] for p in pts) for i in range(3)])
    centre, size = (lo + hi) / 2, (hi - lo).length
    cam.data.ortho_scale = size * 1.05
    cam.data.clip_start, cam.data.clip_end = size * 0.01, size * 10  # tall props reach past the default 100
    for col, (az, el) in enumerate(VIEWS):
        a, e = math.radians(az), math.radians(el)
        d = Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))
        cam.location = centre + d * size * 3
        cam.rotation_euler = (-d).to_track_quat("-Z", "Y").to_euler()
        scene.render.filepath = f"{out}.{row}.{col}.png"
        bpy.ops.render.render(write_still=True)
        tiles.append(scene.render.filepath)
    for o in new:
        o.hide_render = True

sheet = bpy.data.images.new("sheet", SIZE * len(VIEWS), SIZE * len(objs))
px = [0.0] * (SIZE * len(VIEWS) * SIZE * len(objs) * 4)
for t, path in enumerate(tiles):
    row, col = divmod(t, len(VIEWS))
    im = bpy.data.images.load(path)
    p = im.pixels[:]
    for y in range(SIZE):
        dst = (((len(objs) - 1 - row) * SIZE + y) * SIZE * len(VIEWS) + col * SIZE) * 4
        px[dst:dst + SIZE * 4] = p[y * SIZE * 4:(y + 1) * SIZE * 4]
    os.remove(path)
sheet.pixels[:] = px
sheet.filepath_raw = out
sheet.file_format = "PNG"
sheet.save()
print("wrote", out)
