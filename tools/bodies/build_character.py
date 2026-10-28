#!/usr/bin/env python3
"""A character's whole rebuild, every step in order, from its config.

    build_character.py CHAR.json OUT_DIR [--render]

Runs export_body.py (once), fit_body.py, then build_garment.py for each garment in the
config; a garment with "folds" ({"grow", "bend", "gravity", "hold"}: sim_folds.py's
settings) has its surface settled as cloth on the body first. Each garment pushes the
body in under itself. Then build_straps.py for each of "straps" and build_cuffs.py for
each of "cuffs". With --render, OUT_DIR/<name>_full.png and _torso.png compare
the game's model with the rebuild (render_body.py). The config's paths are from native/. Blender is $BLENDER, or the
usual app. Everything written holds the game's model: OUT_DIR belongs in native/build.
"""
import os
import subprocess
import sys

from garments import load_config

cfg_path, out = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
render = "--render" in sys.argv
here = os.path.dirname(os.path.abspath(__file__))
os.chdir(os.path.join(here, "..", ".."))  # the config's paths are from native/
cfg = load_config(cfg_path)
blender = os.environ.get("BLENDER", "/Applications/Blender.app/Contents/MacOS/Blender")
name = os.path.splitext(os.path.basename(cfg_path))[0]
os.makedirs(out, exist_ok=True)
blend = os.path.abspath(cfg["blend"])
src = f"{out}/{name}_src.npz"
body = f"{out}/{name}_body.npz"


def run(*cmd):
    print("[character]", " ".join(os.path.basename(str(c)) if os.sep in str(c) else str(c) for c in cmd[:4]), flush=True)
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    for line in r.stdout.splitlines():
        if line.startswith("["):
            print("   ", line)
    if r.returncode:
        sys.exit(f"[character] failed:\n{r.stdout[-2000:]}\n{r.stderr[-2000:]}")


py = sys.executable
if not os.path.exists(src):
    run(blender, "--background", blend, "--python", f"{here}/export_body.py", "--", src)
run(py, f"{here}/fit_body.py", src, cfg.get("base", "build/heads/src/base.obj"), body, "--config", cfg_path)
parts = [body]
for g, spec in cfg["garments"].items():
    part = f"{out}/{name}_{g}.npz"
    garment = [py, f"{here}/build_garment.py", cfg_path, src, g, part]
    if "folds" in spec:
        base = f"{out}/{name}_{g}_base.npz"
        sim = f"{out}/{name}_{g}_sim.npz"
        run(*garment, "--dump-base", base, "--body", body)
        f = spec["folds"]
        run(blender, "--background", "--factory-startup", "--python", f"{here}/sim_folds.py", "--", base, body, sim,
            "--grow", f.get("grow", 0.07), "--bend", f.get("bend", 0.02), "--gravity", f.get("gravity", 0.3),
            "--hold", f.get("hold", 0.15))
        garment += ["--folds", sim]
    run(*garment, "--body", body)
    parts.append(part)
# Straps on a rebuilt garment, cuffs on the body (once every garment has pushed it in).
for st, spec in cfg.get("straps", {}).items():
    part = f"{out}/{name}_{st}.npz"
    run(py, f"{here}/build_straps.py", cfg_path, src, st, part, "--surface", f"{out}/{name}_{spec['on']}.npz")
    parts.append(part)
for cf in cfg.get("cuffs", {}):
    part = f"{out}/{name}_{cf}.npz"
    run(py, f"{here}/build_cuffs.py", cfg_path, src, cf, part, "--body", body)
    parts.append(part)
if cfg.get("head"):
    parts.append(os.path.abspath(cfg["head"]))
if render:
    tex = os.path.abspath(cfg["textures"])
    run(blender, "--background", blend, "--python", f"{here}/render_body.py", "--", tex, f"{out}/{name}_full.png", *parts)
    run(blender, "--background", blend, "--python", f"{here}/render_body.py", "--", tex, f"{out}/{name}_torso.png", *parts,
        "--crop", "-0.2,0.75,0.2,1.25")
print(f"[character] {name}: {len(parts)} parts in {out}")
