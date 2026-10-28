# Head surfaces for the groom: the hair shell (scalp) and face/body near the head, as triangles.
import bpy, bmesh, numpy as np, sys
out = sys.argv[sys.argv.index("--") + 1]
ob = max((o for o in bpy.data.objects if o.type == "MESH"), key=lambda o: len(o.data.polygons))
bm = bmesh.new(); bm.from_mesh(ob.data); bm.transform(ob.matrix_world); bmesh.ops.triangulate(bm, faces=bm.faces[:])
names = [s.material.name.lower() if s.material else "" for s in ob.material_slots]
h1 = names.index("jeanette_hair_1")
# Components of the hair_1 faces; the scalp shell is the one holding the highest vertex.
faces = [f for f in bm.faces if f.material_index == h1]
seen, comps = set(), []
for f in faces:
    if f.index in seen: continue
    st, c = [f], []
    seen.add(f.index)
    while st:
        g = st.pop(); c.append(g)
        for e in g.edges:
            for h in e.link_faces:
                if h.material_index == h1 and h.index not in seen: seen.add(h.index); st.append(h)
    comps.append(c)
shell = max(comps, key=lambda c: max(v.co.z for f in c for v in f.verts))
tri = lambda fs: np.array([[v.co[:] for v in f.verts] for f in fs], np.float32)
skin = [f for f in bm.faces if names[f.material_index] in ("jeanette_face", "jeanette_body") and f.calc_center_median().z > 1.1]
fringe_c = [c for c in comps if c is not shell]   # the game's fringe pieces: the shape to grow along
fringe = [f for c in fringe_c for f in c]
uvl = bm.loops.layers.uv.active
fuv = np.array([[l[uvl].uv[:] for l in f.loops] for f in fringe], np.float32)
fpiece = np.concatenate([np.full(len(c), i) for i, c in enumerate(fringe_c)]).astype(np.int32)
np.savez(out, shell=tri(shell), skin=tri(skin), fringe=tri(fringe), fringe_uv=fuv, fringe_piece=fpiece)
print("shell", len(shell), "skin", len(skin), "comps", [len(c) for c in comps])
