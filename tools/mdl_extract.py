#!/usr/bin/env python3
"""A prop's model from the game as an OBJ with its textures, for remodelling (Blender).

    python3 tools/mdl_extract.py models/scenery/furniture/barstool/barstool.mdl [--out DIR] [--game DIR]

Writes <out>/<model name>/<model>.obj and .mtl, and each material's texture as a PNG
(the game's own, decoded), in the model's own space and units, with its UV layout as it
is: a remodel that keeps the UVs takes the same texture, upscaled or not.

The format is Bloodlines' MDL version 2531 (Source's 2003 layout with 128-byte names and
the vertices in the .mdl) and its .dx80.vtx (version 107). Only rigid props: models with
one bone, whose vertices are already where they are drawn.
  .mdl: name at 12; textures at 0x124 (count, offset), skins at 0x13c, body parts at 0x140.
        A model is 128-byte name, type, radius, mesh count and offset, vertex count and
        offset (one model per body part only: the size of the model record is not known); a vertex is 12 bytes of bone weights, position, normal, UV (44 bytes),
        or packed in 12 or 8 bytes when the int at 156 of the model is 1 or more (packed());
        a mesh is material, model offset, vertex count and first vertex (60 bytes).
  .vtx: body parts, models, LODs and meshes as in Source; a mesh's strip group is u16
        vertex count, u16 index count, u16 strip count, a flag byte and one more, then
        the offsets of its vertices and its triangle list. With flag 0x10 the vertices
        are u16 numbers within the mesh; with 0x08 they are 12-byte records with the
        number at 10 (found in the game's files: every one-piece prop fits one of these).
"""
import argparse
import os
import re
import struct
import sys

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import tex_extract  # noqa: E402


class Refused(Exception):
    pass


def cstr(d, o):
    return d[o:d.index(b"\0", o)].decode("latin1")


GAME = os.path.abspath(os.path.join(HERE, "..", ".."))
_normals = {}


def normal_table(kind):
    """The game's own table of normals for packed vertices, read from its StudioRender.dll
    (where its decoder, at 0x2c013a70, looks them up): kind 12 is indexed by a byte
    offset (12 bytes a normal), kind 8 by a byte (16 bytes a normal; 202 of them, then
    other data). A table runs to its first entry that is not a unit vector; one too short
    means the DLL is not the one this was read from, and nothing is guessed."""
    if kind not in _normals:
        d = open(os.path.join(GAME, "StudioRender.dll"), "rb").read()
        pe = struct.unpack_from("<I", d, 0x3c)[0]
        nsec, opt = struct.unpack_from("<H", d, pe + 6)[0], struct.unpack_from("<H", d, pe + 20)[0]
        base = struct.unpack_from("<I", d, pe + 24 + 28)[0]
        addr, size, stride = {12: (0x2c06e008, 0x10ff8, 12), 8: (0x2c06d358, 4096, 16)}[kind]
        for i in range(nsec):
            vs, va, rs, ra = struct.unpack_from("<IIII", d, pe + 24 + opt + 40 * i + 8)
            if va <= addr - base < va + rs:
                o = ra + addr - base - va
                raw = d[o:min(o + size, ra + rs)]
                break
        else:
            raise Refused("StudioRender.dll has no packed-normal table where expected")
        t = []  # up to the first entry that is not a unit vector: the table's end
        for k in range(0, len(raw) - 11, stride):
            n = struct.unpack_from("<3f", raw, k)
            if abs(sum(c * c for c in n) - 1) > 1e-3:
                break
            t.append(n)
        if len(t) < 100:
            raise Refused("StudioRender.dll has no packed-normal table where expected: another version")
        _normals[kind] = t
    return _normals[kind]


def packed(mdl, mo, verto, nvert, size):
    """A packed model's vertices, as the game's StudioRender unpacks them. The model's
    box: corner at 160, size per unit at 172.
      12 bytes: u16 x, y, z (times the size per unit), u16 byte offset into the 12-byte
                normal table, u16 u, v over 0..65535.
       8 bytes: u8 x, y, z (over 0..255, times the size), u8 index into the 16-byte
                normal table, u16 u, v over 0..65535."""
    off, step = struct.unpack_from("<3f", mdl, mo + 160), struct.unpack_from("<3f", mdl, mo + 172)
    if mo + verto + nvert * size > len(mdl):
        raise Refused(f"packed vertices ({size} bytes) run past the end of the file")
    table, out = normal_table(size), []
    for i in range(nvert):
        if size == 12:
            x, y, z, n, u, v = struct.unpack_from("<6H", mdl, mo + verto + i * 12)
            if n % 12 or n // 12 >= len(table):
                raise Refused(f"normal offset {n} is not in the table")
            nx, ny, nz = table[n // 12]
        else:
            x, y, z, n, u, v = struct.unpack_from("<4B2H", mdl, mo + verto + i * 8)
            if n >= len(table):
                raise Refused(f"normal {n} is past the table's {len(table)}")
            x, y, z = x / 255, y / 255, z / 255
            nx, ny, nz = table[n]
        out.append((off[0] + x * step[0], off[1] + y * step[1], off[2] + z * step[2], nx, ny, nz,
                    u / 65535, v / 65535))
    return out


def parse(mdl, vtx):
    if mdl[:4] != b"IDST" or struct.unpack_from("<i", mdl, 4)[0] != 2531:
        raise Refused("not a Bloodlines MDL (IDST version 2531)")
    if struct.unpack_from("<i", vtx, 0)[0] != 107:
        raise Refused("not a Bloodlines VTX (version 107)")
    nbones = struct.unpack_from("<i", mdl, 240)[0]
    if nbones != 1:
        raise Refused(f"{nbones} bones: only rigid props")
    ntex, texo = struct.unpack_from("<ii", mdl, 292)
    textures = [cstr(mdl, texo + i * 20 + struct.unpack_from("<i", mdl, texo + i * 20)[0]) for i in range(ntex)]
    ncd, cdo = struct.unpack_from("<ii", mdl, 300)
    cd = [cstr(mdl, struct.unpack_from("<i", mdl, cdo + i * 4)[0]) for i in range(ncd)]
    nref, nfam, skino = struct.unpack_from("<iii", mdl, 308)
    skin = struct.unpack_from(f"<{nref}h", mdl, skino)  # skin family 0
    nbp, bpo = struct.unpack_from("<ii", mdl, 320)
    vbp_n, vbp_o = struct.unpack_from("<ii", vtx, 28)
    if nbp != vbp_n:
        raise Refused("the .mdl and .vtx disagree on body parts")
    verts, meshes = [], []
    for b in range(nbp):
        b_o, vb_o = bpo + b * 16, vbp_o + b * 8
        nmod, base, modo = struct.unpack_from("<iii", mdl, b_o + 4)
        vnmod, vmodo = struct.unpack_from("<ii", vtx, vb_o)
        if nmod != 1 or vnmod != 1:
            raise Refused(f"body part {b} has {nmod} models: only one each")
        for m in range(nmod):
            mo, vmo = b_o + modo, vb_o + vmodo
            nmesh, mesho, nvert, verto = struct.unpack_from("<iiii", mdl, mo + 136)
            first = len(verts)
            kind = struct.unpack_from("<i", mdl, mo + 156)[0]  # 0 floats, 1 and up packed
            if kind >= 1:
                verts += packed(mdl, mo, verto, nvert, 12 if kind == 1 else 8)
            else:
                if mo + verto + nvert * 44 > len(mdl):
                    raise Refused("vertices run past the end of the file: not the 44-byte layout")
                verts += [struct.unpack_from("<3f3f2f", mdl, mo + verto + i * 44 + 12) for i in range(nvert)]
            nlod, lodo = struct.unpack_from("<ii", vtx, vmo)
            lod = vmo + lodo  # LOD 0
            vnmesh, vmesho = struct.unpack_from("<ii", vtx, lod)
            if vnmesh != nmesh:
                raise Refused("the .mdl and .vtx disagree on meshes")
            for k in range(nmesh):
                me = mo + mesho + k * 60
                mat, _, mnv, mfirst = struct.unpack_from("<iiii", mdl, me)
                vm = lod + vmesho + k * 8
                ngroups, go = struct.unpack_from("<ii", vtx, vm)
                tris, draw, drawn = [], [], []
                for g in range(ngroups):
                    sg = vm + go + g * 20
                    gnv, gni, _, flags, _ = struct.unpack_from("<HHHBB", vtx, sg)
                    gvo, gio, _ = struct.unpack_from("<iii", vtx, sg + 8)
                    if flags & 0x10:  # the vertices as u16 numbers within the mesh
                        ids = struct.unpack_from(f"<{gnv}H", vtx, sg + gvo)
                    elif flags & 0x08:  # 12-byte records, the number at 10
                        ids = tuple(struct.unpack_from("<H", vtx, sg + gvo + 12 * i + 10)[0] for i in range(gnv))
                    else:
                        raise Refused(f"strip group flags {flags:#x}: vertex layout not known")
                    if any(i >= mnv for i in ids):
                        raise Refused("a strip group names a vertex past its mesh")
                    idx = struct.unpack_from(f"<{gni}H", vtx, sg + gio)
                    tris += [tuple(first + mfirst + ids[i] for i in idx[t:t + 3]) for t in range(0, gni - 2, 3)]
                    # as the game draws it: indices into the group's vertices, in order
                    draw += [len(drawn) + i for i in idx]
                    drawn += [first + mfirst + i for i in ids]
                meshes.append(dict(material=textures[skin[mat]], tris=tris, draw=draw, drawn=drawn))
    return dict(name=cstr(mdl, 12), textures=textures, cd=cd, verts=verts, meshes=meshes)


def normals(m):
    """The model's normals, as the game has them (packed ones from its tables)."""
    return [p[3:6] for p in m["verts"]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("model")
    ap.add_argument("--game", default=os.path.abspath(os.path.join(HERE, "..", "..")))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "build", "props"))
    args = ap.parse_args()
    global GAME
    GAME = args.game
    idx = tex_extract.vpk_index(args.game)
    name = args.model.lower()
    mdl, vtx = tex_extract.read(args.game, idx, name), tex_extract.read(args.game, idx, name[:-4] + ".dx80.vtx")
    if not mdl or not vtx:
        print(f"{name}: .mdl or .dx80.vtx not found", file=sys.stderr)
        return 1
    try:
        m = parse(mdl, vtx)
    except Refused as e:
        print(f"{name}: {e}", file=sys.stderr)
        return 1
    out = os.path.join(args.out, name[len("models/"):-4])
    os.makedirs(out, exist_ok=True)
    stem = os.path.basename(out)
    with open(os.path.join(out, stem + ".mtl"), "w") as f:
        for mat in dict.fromkeys(me["material"] for me in m["meshes"]):
            # as the game finds it: the first texture folder holding the material, whose
            # $basetexture names the texture
            # (names in any case, a doubled or leading slash ignored, as the game's file system does)
            dirs = [re.sub("/+", "/", d.lower().replace("\\", "/")) for d in m["cd"]]
            vmt = next((d + mat.lower() for d in dirs
                        if tex_extract.exists(args.game, idx, "materials/" + d + mat.lower() + ".vmt")), None)
            base = vmt and re.search(r'"?\$basetexture"?\s+"?([^"\s]+)',
                                     tex_extract.read(args.game, idx, "materials/" + vmt + ".vmt").decode("latin1"), re.I)
            tex = base and re.sub("/+", "/", base.group(1).lower().replace("\\", "/")).lstrip("/")
            if not tex or not tex_extract.exists(args.game, idx, "materials/" + tex + ".tth"):
                print(f"{name}: no texture found for material {mat}", file=sys.stderr)
                return 1
            t = tex_extract.texture(tex_extract.read(args.game, idx, "materials/" + tex + ".tth"),
                                    tex_extract.read(args.game, idx, "materials/" + tex + ".ttz"))
            Image.fromarray(t).save(os.path.join(out, mat + ".png"))
            f.write(f"newmtl {mat}\n# materials/{tex}\nmap_Kd {mat}.png\n\n")
    with open(os.path.join(out, stem + ".obj"), "w") as f:
        f.write(f"# {name} from the game, in its own units (tools/mdl_extract.py)\nmtllib {stem}.mtl\n")
        for p in m["verts"]:
            f.write("v {:.6f} {:.6f} {:.6f}\n".format(*p[:3]))
        for p in m["verts"]:
            f.write("vt {:.6f} {:.6f}\n".format(p[6], 1 - p[7]))
        for p in normals(m):
            f.write("vn {:.6f} {:.6f} {:.6f}\n".format(*p))
        ntri = 0
        for k, me in enumerate(m["meshes"]):
            f.write(f"g mesh{k}_{me['material']}\nusemtl {me['material']}\n")
            for t in me["tris"]:
                f.write("f " + " ".join(f"{i + 1}/{i + 1}/{i + 1}" for i in t) + "\n")
            ntri += len(me["tris"])
    print(f"{name}: {len(m['meshes'])} meshes, {ntri} triangles -> {os.path.abspath(out)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
