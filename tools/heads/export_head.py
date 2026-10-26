"""A character's mesh from its Blender file (an SMD import with its flex shape keys) as
arrays, for fit_head.py.

    Blender --background CHAR.blend --python tools/heads/export_head.py -- OUT.npz

Writes the rest positions, the triangles with their material names, the UVs per
triangle corner, every shape key's positions and the image each material uses.
The output holds the game's model: it stays in native/build.
"""
import sys

import bpy
import numpy as np

out = sys.argv[sys.argv.index("--") + 1]
obj = next(o for o in bpy.data.objects if o.type == "MESH")
mesh = obj.data
mesh.calc_loop_triangles()
co = np.array([v.co[:] for v in mesh.vertices], np.float32)
tris = np.array([t.vertices[:] for t in mesh.loop_triangles], np.int32)
mats = np.array([t.material_index for t in mesh.loop_triangles], np.int32)
uv_layer = mesh.uv_layers.active.data
uvs = np.array([[uv_layer[i].uv[:] for i in t.loops] for t in mesh.loop_triangles], np.float32)
names = [m.name if m else "" for m in mesh.materials]
images = []
for m in mesh.materials:
    img = ""
    if m and m.use_nodes:
        for n in m.node_tree.nodes:
            if n.type == "TEX_IMAGE" and n.image:
                img = bpy.path.abspath(n.image.filepath)
                break
    images.append(img)
keys = mesh.shape_keys.key_blocks if mesh.shape_keys else []
key_names = [k.name for k in keys]
key_co = np.array([[p.co[:] for p in k.data] for k in keys], np.float32) if keys else np.zeros((0, len(co), 3))
np.savez_compressed(out, co=co, tris=tris, mats=mats, uvs=uvs, mat_names=np.array(names),
                    images=np.array(images), key_names=np.array(key_names), key_co=key_co)
print(f"[export] {obj.name}: {len(co)} vertices, {len(tris)} triangles, {len(key_names)} shape keys -> {out}")
for n, i in zip(names, images):
    print(f"[export]   {n}: {i or '(no image)'}")
