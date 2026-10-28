"""Real folds for a garment: its surface (build_garment.py --dump-base) is let settle on
the rebuilt body as cloth, with a little more cloth than room, so it buckles.

    Blender --background --factory-startup --python tools/bodies/sim_folds.py --
        BASE.npz BODY.npz OUT.npz [--grow G] [--frames N] [--bend B] [--gravity W] [--hold H]

The cloth grows by G (default 0.07: 7% more cloth along every edge) while its held
vertices (the openings, a band along them, knots: the pin weights in BASE.npz) stay
where they are; the body is a collider it cannot pass through, and gravity (W times
Earth's, default 0.3) pulls the slack down. B is the bending stiffness (default 0.02):
lower gives finer, sharper folds, higher fewer, rounder ones. Every vertex is also held
lightly to where it started (weight H, default 0.15), so the slack folds where it is
instead of the whole garment ballooning away from the body. The shape after N frames
(default 40) goes to OUT.npz (verts, in BASE.npz's order) for build_garment.py --folds.
"""
import sys

import bpy
import numpy as np

args = sys.argv[sys.argv.index("--") + 1:]
base_path, body_path, out = args[:3]


def opt(name, default):
    return float(args[args.index(name) + 1]) if name in args else default


grow, frames, bend, gravity = opt("--grow", 0.07), int(opt("--frames", 40)), opt("--bend", 0.02), opt("--gravity", 0.3)
hold = opt("--hold", 0.15)

for o in list(bpy.data.objects):
    bpy.data.objects.remove(o)
scene = bpy.context.scene


def mesh_object(name, verts, tris):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts.tolist(), [], tris.tolist())
    o = bpy.data.objects.new(name, me)
    scene.collection.objects.link(o)
    return o


G = np.load(base_path)
Bd = np.load(body_path)
cloth_obj = mesh_object("garment", G["verts"], G["tris"])
body_obj = mesh_object("body", Bd["verts"], Bd["tris"])

pin = cloth_obj.vertex_groups.new(name="pin")
for i, w in enumerate(G["pin"]):
    pin.add([i], float(max(w, hold)), "REPLACE")

col = body_obj.modifiers.new("collision", "COLLISION")
body_obj.collision.thickness_outer = 0.0005
body_obj.collision.cloth_friction = 5.0

cl = cloth_obj.modifiers.new("cloth", "CLOTH")
st = cl.settings
st.quality = 10
st.mass = 0.1
st.tension_stiffness = st.compression_stiffness = 15.0
st.shear_stiffness = 5.0
st.bending_stiffness = bend
st.shrink_min = -grow  # negative shrinking grows the cloth
st.vertex_group_mass = "pin"
st.pin_stiffness = 1.0
st.effector_weights.gravity = gravity
cs = cl.collision_settings
cs.distance_min = 0.0005
cs.use_self_collision = True
cs.self_distance_min = 0.0010
cl.point_cache.frame_start = 1
cl.point_cache.frame_end = frames
scene.frame_start, scene.frame_end = 1, frames

for f in range(1, frames + 1):
    scene.frame_set(f)
    if f % 10 == 0:
        print(f"[folds] frame {f}/{frames}", flush=True)
dg = bpy.context.evaluated_depsgraph_get()
ev = cloth_obj.evaluated_get(dg)
me = ev.to_mesh()
S = np.array([v.co[:] for v in me.vertices], np.float32)
ev.to_mesh_clear()
moved = np.linalg.norm(S - G["verts"], axis=1)
print(f"[folds] {len(S)} vertices settled: moved median {np.median(moved):.4f}, 95% {np.percentile(moved, 95):.4f}, max {moved.max():.4f}")
np.savez_compressed(out, verts=S)
print(f"[folds] -> {out}")
