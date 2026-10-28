"""One part's mesh cut down to a triangle count (Blender's collapse decimation, which
keeps the UVs), for make_lod.py.

    Blender --background --factory-startup --python tools/bodies/lod_decimate.py -- IN.npz OUT.npz TRIS

IN.npz holds verts, tris and uvs (per triangle corner); OUT.npz the same, decimated.
"""
import sys

import bpy
import numpy as np

src, out, target = sys.argv[sys.argv.index("--") + 1:][:3]
target = int(target)
D = np.load(src)
me = bpy.data.meshes.new("part")
me.from_pydata(D["verts"].tolist(), [], D["tris"].tolist())
uv = me.uv_layers.new()
uv.data.foreach_set("uv", D["uvs"].astype(np.float32).ravel())
o = bpy.data.objects.new("part", me)
bpy.context.scene.collection.objects.link(o)
ratio = min(1.0, target / max(1, len(D["tris"])))
if ratio < 1.0:
    m = o.modifiers.new("lod", "DECIMATE")
    m.decimate_type = "COLLAPSE"
    m.ratio = ratio
    m.use_collapse_triangulate = True
dg = bpy.context.evaluated_depsgraph_get()
ev = o.evaluated_get(dg).to_mesh()
ev.calc_loop_triangles()
V = np.array([v.co[:] for v in ev.vertices], np.float32)
F = np.array([t.vertices[:] for t in ev.loop_triangles], np.int32)
uvd = ev.uv_layers.active.data
UV = np.array([[uvd[i].uv[:] for i in t.loops] for t in ev.loop_triangles], np.float32)
np.savez_compressed(out, verts=V, tris=F, uvs=UV)
print(f"[decimate] {len(D['tris'])} -> {len(F)} triangles")
