"""A character's whole mesh and skeleton from its Blender file (an SMD import), for
fit_body.py.

    Blender --background CHAR.blend --python tools/bodies/export_body.py -- OUT.npz

Writes what export_head.py does (rest positions, triangles with material names, UVs per
triangle corner) plus each vertex's bone weights and every bone's head and tail at rest,
in the mesh's own space. The output holds the game's model: it stays in native/build.
"""
import sys

import bpy
import numpy as np

out = sys.argv[sys.argv.index("--") + 1]
obj = next(o for o in bpy.data.objects if o.type == "MESH")
arm = next(o for o in bpy.data.objects if o.type == "ARMATURE")
mesh = obj.data
mesh.calc_loop_triangles()
co = np.array([v.co[:] for v in mesh.vertices], np.float32)
tris = np.array([t.vertices[:] for t in mesh.loop_triangles], np.int32)
mats = np.array([t.material_index for t in mesh.loop_triangles], np.int32)
uv_layer = mesh.uv_layers.active.data
uvs = np.array([[uv_layer[i].uv[:] for i in t.loops] for t in mesh.loop_triangles], np.float32)
names = [m.name if m else "" for m in mesh.materials]

bones = [b.name for b in arm.data.bones]
to_mesh = obj.matrix_world.inverted() @ arm.matrix_world
head = np.array([(to_mesh @ b.head_local)[:] for b in arm.data.bones], np.float32)
tail = np.array([(to_mesh @ b.tail_local)[:] for b in arm.data.bones], np.float32)
parent = np.array([bones.index(b.parent.name) if b.parent else -1 for b in arm.data.bones], np.int32)
group_bone = {g.index: (bones.index(g.name) if g.name in bones else -1) for g in obj.vertex_groups}
W = np.zeros((len(co), 4), np.float32)
B = np.zeros((len(co), 4), np.int32)
for v in mesh.vertices:
    gs = sorted(((g.weight, group_bone[g.group]) for g in v.groups if group_bone[g.group] >= 0), reverse=True)[:4]
    s = sum(w for w, _ in gs) or 1.0
    for k, (w, b) in enumerate(gs):
        W[v.index, k], B[v.index, k] = w / s, b
np.savez_compressed(out, co=co, tris=tris, mats=mats, uvs=uvs, mat_names=np.array(names),
                    bones=np.array(bones), bone_head=head, bone_tail=tail, bone_parent=parent,
                    weights=W, weight_bones=B)
print(f"[export] {obj.name}: {len(co)} vertices, {len(tris)} triangles, {len(bones)} bones -> {out}")
