// The static props' collision models, placed (bl_props.h).
//
// The static props lump (game lump "sprp", version 4): the model names (128 bytes each),
// the leaves each prop is in, then 56 bytes per prop: origin, angles, model, first leaf,
// leaf count, solid type, flags (0x10: casts no shadow), skin, fade distances, lighting
// origin.
//
// Bloodlines' archives (.vpk): the directory at the end, its file count and offset in the
// last 9 bytes; per file its name's length, the name, offset and size.
//
// A .phy: a 16-byte header (its size, an id, the number of solids, a checksum), then per
// solid its size and an IVP compact surface, the old Havok format without Half-Life 2's
// "VPHY" header. The surface's ledge tree leads to its convex pieces (ledges), each a list
// of triangles over a point array, in metres with Y and Z swapped and Y negated.
//
// Box props (solid type 3) cast their model's box; props without a .phy (bar tables) their
// visible mesh, as the 2004 bake shows. Bloodlines' own .mdl (version 2531, names 128
// bytes long, the vertices in the .mdl; its hull's corners at 0xb4 and 0xc0) and
// .dx80.vtx (version 107). The .mdl's body parts at 0x140 (count, offset), 16 bytes each
// (name, model count, base, model offset); a model is a 128-byte name, then type, radius, mesh count and offset, vertex count and offset,
// tangent offset, vertex format and six floats; meshes are 60 bytes (material, model
// offset, vertex count, first vertex). Vertex format 0: 44 bytes, the position as floats
// at 12; 1 and 2: 12 and 8 bytes, the position three 16-bit steps from the model's
// minimum (its first three floats) by its step size (the last three). The .vtx: a 36-byte
// header (body parts' count and offset at 28), then body parts, models (LOD count and
// offset), LODs (mesh count and offset, switch point), meshes (strip group count and
// offset), all as in Half-Life 2 but for the strip groups: 20 bytes, the vertex and index
// counts as 16 bits, flags, and the offsets of a vertex table (16-bit vertex numbers in
// the mesh), the indices (triangle lists) and the strips.
//
// A prop's colour, for the light it gives back (gi_probes.m): the .mdl's textures at 0x124
// (count, offset; 20 bytes each, the name's offset from the entry first), its material
// folders at 0x12c (count, offset of name offsets) and its skins at 0x134 (references per
// family, families, offset of 16-bit texture numbers); the first family's textures, each
// the first folder holding its .vmt, whose $basetexture's .tth (Troika's header, then a
// VTF 7.x one) gives its mean colour, linear, at 0x20 into the VTF header.
#include "bl_props.h"
#include <dirent.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

static int rd32(const uint8_t *p) { int v; memcpy(&v, p, 4); return v; }
static float rdf(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }
static int rd16(const uint8_t *p) { int16_t v; memcpy(&v, p, 2); return v; }

// The archives to look in, in order, and their directories.
struct vpk_file { char *name; uint32_t ofs, size; };
struct vpk { char path[1024]; struct vpk_file *files; int nfiles; };
struct search {
    char dirs[2][1024];  // loose files: the mod's folder, then the game's
    int ndirs;
    struct vpk *vpks;
    int nvpks;
};

static int by_name(const void *a, const void *b) { return strcasecmp(((const struct vpk_file *)a)->name, ((const struct vpk_file *)b)->name); }

static void vpk_open(struct search *s, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return;
    uint8_t tail[9];
    long cnt = 0, ofs = 0, end = 0;
    if (!fseek(f, 0, SEEK_END)) end = ftell(f);
    if (end >= 9 && !fseek(f, -9, SEEK_END) && fread(tail, 1, 9, f) == 9) cnt = (uint32_t)rd32(tail), ofs = (uint32_t)rd32(tail + 4);
    if (cnt <= 0 || ofs <= 0 || ofs > end - 9) {  // the directory lies before the 9-byte tail
        fclose(f);
        return;
    }
    size_t dlen = (size_t)(end - 9 - ofs);
    uint8_t *d = malloc(dlen + 1);
    int ok = d && !fseek(f, ofs, SEEK_SET) && fread(d, 1, dlen, f) == dlen;
    fclose(f);
    if (!ok) {
        free(d);
        return;
    }
    s->vpks = realloc(s->vpks, sizeof *s->vpks * (size_t)(s->nvpks + 1));
    struct vpk *v = &s->vpks[s->nvpks++];
    snprintf(v->path, sizeof v->path, "%s", path);
    v->files = calloc((size_t)cnt, sizeof *v->files);
    v->nfiles = 0;
    for (size_t p = 0; v->nfiles < cnt && p + 4 <= dlen;) {
        int n = rd32(d + p);
        if (n < 0 || p + 4 + (size_t)n + 8 > dlen) break;
        struct vpk_file *e = &v->files[v->nfiles++];
        e->name = strndup((const char *)d + p + 4, (size_t)n);
        e->ofs = (uint32_t)rd32(d + p + 4 + n), e->size = (uint32_t)rd32(d + p + 8 + n);
        p += 4 + (size_t)n + 8;
    }
    free(d);
    qsort(v->files, (size_t)v->nfiles, sizeof *v->files, by_name);
}

// The map's own files (its pakfile lump, 40: a zip archive, stored): the compiler's patched
// materials (maps/<map>/...) among them, read like an archive's.
static void pak_open(struct search *s, const char *bsp_path)
{
    FILE *f = fopen(bsp_path, "rb");
    if (!f) return;
    uint8_t h[8 + 16 * 64];
    int lofs = 0, llen = 0;
    if (fread(h, 1, sizeof h, f) == sizeof h) lofs = rd32(h + 8 + 16 * 40), llen = rd32(h + 12 + 16 * 40);
    uint8_t *d = lofs > 0 && llen >= 22 ? malloc((size_t)llen) : NULL;
    int ok = d && !fseek(f, lofs, SEEK_SET) && fread(d, 1, (size_t)llen, f) == (size_t)llen;
    fclose(f);
    long e = ok ? llen - 22 : -1;
    while (e >= 0 && rd32(d + e) != 0x06054b50) e--;
    if (e < 0) {
        free(d);
        return;
    }
    int cnt = (uint16_t)rd16(d + e + 10);
    long cd = (uint32_t)rd32(d + e + 16);
    s->vpks = realloc(s->vpks, sizeof *s->vpks * (size_t)(s->nvpks + 1));
    struct vpk *v = &s->vpks[s->nvpks++];
    snprintf(v->path, sizeof v->path, "%s", bsp_path);
    v->files = calloc((size_t)cnt + 1, sizeof *v->files);
    v->nfiles = 0;
    for (int i = 0; i < cnt && cd + 46 <= llen && rd32(d + cd) == 0x02014b50; i++) {
        int method = (uint16_t)rd16(d + cd + 10), nl = (uint16_t)rd16(d + cd + 28);
        int xl = (uint16_t)rd16(d + cd + 30), cl = (uint16_t)rd16(d + cd + 32);
        long size = (uint32_t)rd32(d + cd + 20), local = (uint32_t)rd32(d + cd + 42);
        if (cd + 46 + nl > llen || local + 30 > llen) break;
        if (method == 0) {
            long at = local + 30 + (uint16_t)rd16(d + local + 26) + (uint16_t)rd16(d + local + 28);
            struct vpk_file *fe = &v->files[v->nfiles++];
            fe->name = strndup((const char *)d + cd + 46, (size_t)nl);
            fe->ofs = (uint32_t)(lofs + at), fe->size = (uint32_t)size;
        } else {
            fprintf(stderr, "[props] %s: %.*s in its pakfile is compressed (method %d), not read\n", bsp_path, nl,
                    (const char *)d + cd + 46, method);
        }
        cd += 46 + nl + xl + cl;
    }
    free(d);
    qsort(v->files, (size_t)v->nfiles, sizeof *v->files, by_name);
}

static int by_str(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

// The mod's folder (the map's maps/ folder's parent) and the game's own (Vampire, beside
// it), with each one's pack*.vpk in name order.
static void search_open(struct search *s, const char *bsp_path)
{
    memset(s, 0, sizeof *s);
    pak_open(s, bsp_path);
    char mod[1024];
    snprintf(mod, sizeof mod, "%s", bsp_path);
    for (int up = 0; up < 2; up++) {
        char *slash = strrchr(mod, '/');
        if (!slash) return;
        *slash = 0;
    }
    snprintf(s->dirs[s->ndirs++], sizeof s->dirs[0], "%s", mod);
    char *slash = strrchr(mod, '/');
    if (slash && strcasecmp(slash + 1, "Vampire"))
        snprintf(s->dirs[s->ndirs++], sizeof s->dirs[0], "%.*s/Vampire", (int)(slash - mod), mod);
    for (int i = 0; i < s->ndirs; i++) {
        DIR *dir = opendir(s->dirs[i]);
        if (!dir) continue;
        char **names = NULL;
        int n = 0;
        for (struct dirent *e; (e = readdir(dir));) {
            size_t l = strlen(e->d_name);
            if (l > 4 && !strncasecmp(e->d_name, "pack", 4) && !strcasecmp(e->d_name + l - 4, ".vpk")) {
                names = realloc(names, sizeof *names * (size_t)(n + 1));
                names[n++] = strdup(e->d_name);
            }
        }
        closedir(dir);
        qsort(names, (size_t)n, sizeof *names, by_str);
        for (int k = 0; k < n; k++) {
            char p[2048];
            snprintf(p, sizeof p, "%s/%s", s->dirs[i], names[k]);
            vpk_open(s, p);
            free(names[k]);
        }
        free(names);
    }
}

static void search_close(struct search *s)
{
    for (int i = 0; i < s->nvpks; i++) {
        for (int k = 0; k < s->vpks[i].nfiles; k++) free(s->vpks[i].files[k].name);
        free(s->vpks[i].files);
    }
    free(s->vpks);
}

// A game file by its path (e.g. models/x.phy); NULL when none has it.
static uint8_t *search_read(const struct search *s, const char *name, long *size)
{
    for (int i = 0; i < s->ndirs; i++) {
        char p[2048];
        snprintf(p, sizeof p, "%s/%s", s->dirs[i], name);
        FILE *f = fopen(p, "rb");
        if (!f) continue;
        fseek(f, 0, SEEK_END);
        long n = ftell(f);
        fseek(f, 0, SEEK_SET);
        uint8_t *d = n > 0 ? malloc((size_t)n) : NULL;
        int ok = d && fread(d, 1, (size_t)n, f) == (size_t)n;
        fclose(f);
        if (ok) {
            *size = n;
            return d;
        }
        free(d);
    }
    for (int i = 0; i < s->nvpks; i++) {
        struct vpk_file key = {(char *)name, 0, 0};
        const struct vpk_file *e = bsearch(&key, s->vpks[i].files, (size_t)s->vpks[i].nfiles, sizeof key, by_name);
        if (!e || !e->size) continue;
        FILE *f = fopen(s->vpks[i].path, "rb");
        if (!f) continue;
        uint8_t *d = malloc(e->size);
        int ok = !fseek(f, e->ofs, SEEK_SET) && fread(d, 1, e->size, f) == e->size;
        fclose(f);
        if (ok) {
            *size = e->size;
            return d;
        }
        free(d);
    }
    return NULL;
}

// The mean colour of a model's textures (its first skin), from its .mdl; 0 when none read.
static int mdl_colour(const struct search *s, const uint8_t *m, long mn, float out[3])
{
    if (mn < 0x140 || memcmp(m, "IDST", 4) || rd32(m + 4) != 2531) return 0;
    int nt = rd32(m + 0x124), to = rd32(m + 0x128), nc = rd32(m + 0x12c), co = rd32(m + 0x130);
    int nref = rd32(m + 0x134), so = rd32(m + 0x13c);
    if (nt <= 0 || nc <= 0 || to < 0 || to + 20L * nt > mn || co < 0 || co + 4L * nc > mn || nref <= 0 || so < 0 ||
        so + 2L * nref > mn)
        return 0;
    float sum[3] = {0, 0, 0};
    int got = 0;
    for (int r = 0; r < nref; r++) {
        int t = rd16(m + so + 2 * r);
        if (t < 0 || t >= nt) continue;
        long name = to + 20L * t + rd32(m + to + 20L * t);
        if (name < 0 || name >= mn || !memchr(m + name, 0, (size_t)(mn - name))) continue;
        for (int c = 0; c < nc; c++) {
            long dir = rd32(m + co + 4 * c);
            if (dir < 0 || dir >= mn || !memchr(m + dir, 0, (size_t)(mn - dir))) continue;
            char path[512];
            snprintf(path, sizeof path, "materials/%s%s.vmt", (const char *)m + dir, (const char *)m + name);
            for (char *q = path; *q; q++) *q = *q == '\\' ? '/' : *q;
            long vl = 0;
            uint8_t *vmt = search_read(s, path, &vl);
            if (!vmt) continue;
            // $basetexture's value, quoted or not ($basetexture2 is a blend's second).
            char *v = realloc(vmt, (size_t)vl + 1), *k = v, tex[256] = "";
            v[vl] = 0;
            while ((k = strcasestr(k, "$basetexture"))) {
                k += 12;
                if (!*k || !strchr("\" \t", *k)) continue;  // not $basetexture2, $basetexturetransform
                k += strspn(k, "\" \t");
                size_t l = strcspn(k, "\" \t\r\n");
                if (l && l < sizeof tex) memcpy(tex, k, l), tex[l] = 0;
                break;
            }
            free(v);
            if (!*tex) break;
            snprintf(path, sizeof path, "materials/%s.tth", tex);
            for (char *q = path; *q; q++) *q = *q == '\\' ? '/' : *q;
            long hl = 0;
            uint8_t *h = search_read(s, path, &hl);
            for (long i = 0; h && i + 44 <= hl && i < 256; i++)
                if (!memcmp(h + i, "VTF", 4)) {
                    float c3[3] = {rdf(h + i + 32), rdf(h + i + 36), rdf(h + i + 40)};
                    if (c3[0] >= 0 && c3[0] <= 1 && c3[1] >= 0 && c3[1] <= 1 && c3[2] >= 0 && c3[2] <= 1)
                        for (int a = 0; a < 3; a++) sum[a] += c3[a];
                    got += c3[0] >= 0 && c3[0] <= 1 && c3[1] >= 0 && c3[1] <= 1 && c3[2] >= 0 && c3[2] <= 1;
                    break;
                }
            free(h);
            break;
        }
    }
    if (!got) return 0;
    for (int a = 0; a < 3; a++) out[a] = sum[a] / (float)got;
    return 1;
}

// A model's collision triangles, in the model's own space (inches), appended to *out.
struct tris { float (*t)[3][3]; int n, cap; };
static void add_tri(struct tris *o, const float a[3], const float b[3], const float c[3])
{
    if (o->n == o->cap) o->cap = o->cap ? 2 * o->cap : 256, o->t = realloc(o->t, sizeof *o->t * (size_t)o->cap);
    memcpy(o->t[o->n][0], a, 12), memcpy(o->t[o->n][1], b, 12), memcpy(o->t[o->n][2], c, 12);
    o->n++;
}

// The leaves of an IVP ledge tree: each node is 28 bytes (the right child's offset, 0 for
// a leaf; its ledge's offset; a bounding sphere; box sizes), the left child right after it.
static void ledge_tree(const uint8_t *surf, long len, long node, int depth, struct tris *o)
{
    if (depth > 64 || node < 0 || node + 28 > len) return;
    int right = rd32(surf + node), ledge = rd32(surf + node + 4);
    if (right) {
        ledge_tree(surf, len, node + 28, depth + 1, o);
        ledge_tree(surf, len, node + right, depth + 1, o);
        return;
    }
    long l = node + ledge;
    if (!ledge || l < 0 || l + 16 > len) return;
    // A ledge: its points' offset, the tree node's, flags and size, triangle count; then
    // 16 bytes per triangle: an index word, then three edges, each a start point (16 bits).
    long pts = l + rd32(surf + l);
    int nt = rd16(surf + l + 12);
    if (nt <= 0 || l + 16 + 16L * nt > len || pts < 0) return;
    for (int t = 0; t < nt; t++) {
        float v[3][3];
        int ok = 1;
        for (int e = 0; e < 3; e++) {
            unsigned idx = (unsigned)rd32(surf + l + 16 + 16 * t + 4 + 4 * e) & 0xffff;
            long p = pts + 16L * idx;
            if (p + 12 > len) {
                ok = 0;
                break;
            }
            // Metres to inches; Havok's Y is down and its Z is Half-Life's Y.
            const float k = 1.0f / 0.0254f;
            v[e][0] = rdf(surf + p) * k, v[e][1] = rdf(surf + p + 8) * k, v[e][2] = -rdf(surf + p + 4) * k;
        }
        if (ok) add_tri(o, v[0], v[1], v[2]);
    }
}

static int phy_tris(const uint8_t *d, long n, struct tris *o)
{
    if (n < 16 || rd32(d) != 16) return 0;
    int solids = rd32(d + 8), before = o->n;
    long p = 16;
    for (int i = 0; i < solids && p + 4 <= n; i++) {
        long len = rd32(d + p);
        const uint8_t *surf = d + p + 4;
        if (len < 48 || p + 4 + len > n) break;
        // The compact surface: mass centre, inertia, radius, size, the ledge tree's
        // offset, then "IVPS".
        if (!memcmp(surf + 44, "IVPS", 4)) ledge_tree(surf, len, rd32(surf + 32), 0, o);
        p += 4 + len;
    }
    return o->n > before;
}

// A model's visible triangles from its .mdl and .dx80.vtx (the first model of each body
// part, LOD 0), in the model's own space.
static int mdl_tris(const uint8_t *m, long mn, const uint8_t *v, long vn, struct tris *o)
{
    if (mn < 0x148 || memcmp(m, "IDST", 4) || rd32(m + 4) != 2531 || vn < 36 || rd32(v) != 107) return 0;
    int before = o->n;
    int nbp = rd32(m + 0x140), bpo = rd32(m + 0x144), vnbp = rd32(v + 28), vbpo = rd32(v + 32);
    for (int b = 0; b < nbp && b < vnbp; b++) {
        long bp = bpo + 16L * b, vbp = vbpo + 8L * b;
        if (bp + 16 > mn || vbp + 8 > vn || rd32(m + bp + 4) < 1 || rd32(v + vbp) < 1) continue;
        long md = bp + rd32(m + bp + 12), vmd = vbp + rd32(v + vbp + 4);
        if (md < 0 || md + 128 + 56 > mn || vmd < 0 || vmd + 8 > vn || rd32(v + vmd) < 1) continue;
        const uint8_t *h = m + md + 128;
        int nmesh = rd32(h + 8), meshofs = rd32(h + 12), nverts = rd32(h + 16), vertofs = rd32(h + 20), format = rd32(h + 28);
        int stride = format == 0 ? 44 : format == 1 ? 12 : format == 2 ? 8 : 0;
        if (!stride || md + vertofs < 0 || md + vertofs + (long)stride * nverts > mn) continue;
        float lo[3], step[3];
        for (int k = 0; k < 3; k++) lo[k] = rdf(h + 32 + 4 * k), step[k] = rdf(h + 44 + 4 * k);
        long lod = vmd + rd32(v + vmd + 4);
        if (lod < 0 || lod + 12 > vn) continue;
        int vnmesh = rd32(v + lod);
        long vmesh = lod + rd32(v + lod + 4);
        for (int e = 0; e < nmesh && e < vnmesh; e++) {
            long me = md + meshofs + 60L * e, ve = vmesh + 8L * e;
            if (me < 0 || me + 16 > mn || ve < 0 || ve + 8 > vn) break;
            int first = rd32(m + me + 12), mcount = rd32(m + me + 8);
            for (int g = 0, ng = rd32(v + ve); g < ng; g++) {
                long sg = ve + rd32(v + ve + 4) + 20L * g;
                if (sg < 0 || sg + 20 > vn) break;
                int nv = (uint16_t)rd16(v + sg), ni = (uint16_t)rd16(v + sg + 2);
                long vt = sg + rd32(v + sg + 8), ix = sg + rd32(v + sg + 12);
                if (vt < 0 || vt + 2L * nv > vn || ix < 0 || ix + 2L * ni > vn) continue;
                for (int t = 0; t + 2 < ni; t += 3) {
                    float p[3][3];
                    int ok = 1;
                    for (int c = 0; c < 3 && ok; c++) {
                        int i = (uint16_t)rd16(v + ix + 2 * (t + c));
                        int id = i < nv ? (uint16_t)rd16(v + vt + 2 * i) : mcount;
                        long at = md + vertofs + (long)stride * (first + id);
                        if (id >= mcount || first + id >= nverts) {
                            ok = 0;
                            break;
                        }
                        for (int k = 0; k < 3; k++)
                            p[c][k] = format == 0 ? rdf(m + at + 12 + 4 * k) : lo[k] + step[k] * (float)(uint16_t)rd16(m + at + 2 * k);
                    }
                    if (ok) add_tri(o, p[0], p[1], p[2]);
                }
            }
        }
    }
    return o->n > before;
}

// Half-Life's AngleMatrix: pitch, yaw, roll in degrees.
static void angle_matrix(const float a[3], float m[3][3])
{
    const float r = 3.14159265f / 180.0f;
    float sp = sinf(a[0] * r), cp = cosf(a[0] * r), sy = sinf(a[1] * r), cy = cosf(a[1] * r), sr = sinf(a[2] * r), cr = cosf(a[2] * r);
    m[0][0] = cp * cy, m[1][0] = cp * sy, m[2][0] = -sp;
    m[0][1] = sr * sp * cy - cr * sy, m[1][1] = sr * sp * sy + cr * cy, m[2][1] = sr * cp;
    m[0][2] = cr * sp * cy + sr * sy, m[1][2] = cr * sp * sy - sr * cy, m[2][2] = cr * cp;
}

// visible: each prop by its visible mesh where it has one (the object shadows, which should
// match what is drawn), else as below.
static struct bl_props *props_load(const char *bsp_path, const uint8_t *d, long size, int visible, char *err, int errlen)
{
    int gofs = rd32(d + 8 + 16 * 35), glen = rd32(d + 12 + 16 * 35);
    if (gofs < 0 || glen < 4 || (long)gofs + glen > size) {
        snprintf(err, (size_t)errlen, "no game lump");
        return NULL;
    }
    const uint8_t *sp = NULL;
    long splen = 0;
    int ver = 0;
    for (int i = 0, n = rd32(d + gofs); i < n && 4 + 16L * (i + 1) <= glen; i++) {
        const uint8_t *e = d + gofs + 4 + 16 * i;
        int ofs = rd32(e + 8), len = rd32(e + 12);
        if (memcmp(e, "prps", 4) || ofs < 0 || len < 0 || (long)ofs + len > size) continue;
        sp = d + ofs, splen = len, ver = (uint16_t)rd16(e + 6);
    }
    struct bl_props *out = calloc(1, sizeof *out);
    if (!sp) return out;  // no static props
    if (ver != 4) {
        snprintf(err, (size_t)errlen, "static props lump version %d, not 4", ver);
        free(out);
        return NULL;
    }
    long p = 0;
    int nnames = splen >= 4 ? rd32(sp) : -1;
    p = 4 + 128L * nnames;
    int nleaves = p + 4 <= splen ? rd32(sp + p) : -1;
    p += 4 + 2L * nleaves;
    int n = nnames >= 0 && nleaves >= 0 && p + 4 <= splen ? rd32(sp + p) : -1;
    p += 4;
    if (n < 0 || p + 56L * n > splen) {
        snprintf(err, (size_t)errlen, "static props lump not as expected");
        free(out);
        return NULL;
    }
    // Each model's shapes, read once: its collision model, its visible mesh, its box.
    struct tris *phy = calloc((size_t)nnames + 1, sizeof *phy), *mesh = calloc((size_t)nnames + 1, sizeof *mesh),
                *box = calloc((size_t)nnames + 1, sizeof *box);
    char *tried = calloc((size_t)nnames + 1, 1);
    float(*colour)[3] = calloc((size_t)nnames + 1, sizeof *colour);
    float(*refl)[3] = NULL;
    int *owner = NULL;
    int refl_cap = 0;
    struct search s;
    search_open(&s, bsp_path);
    struct tris all = {0};
    out->nprops = n;
    for (int i = 0; i < n; i++) {
        const uint8_t *q = sp + p + 56 * i;
        int m = (uint16_t)rd16(q + 24), flags = q[31], solid = q[30];
        if (flags & 0x10 || m >= nnames) continue;
        out->nshadow++;
        if (!tried[m]) {
            tried[m] = 1;
            char name[160];
            snprintf(name, sizeof name, "%.128s", (const char *)sp + 4 + 128 * m);
            char *dot = strrchr(name, '.');
            if (dot) {
                strcpy(dot, ".phy");
                long len = 0;
                uint8_t *f = search_read(&s, name, &len);
                if (f) phy_tris(f, len, &phy[m]);
                free(f);
                long ml = 0, vl = 0;
                strcpy(dot, ".mdl");
                uint8_t *md = search_read(&s, name, &ml);
                strcpy(dot, ".dx80.vtx");
                uint8_t *vx = md ? search_read(&s, name, &vl) : NULL;
                if (vx) mdl_tris(md, ml, vx, vl, &mesh[m]);
                if (!md || !mdl_colour(&s, md, ml, colour[m])) colour[m][0] = -1;
                if (md && ml >= 0xcc) {  // the hull: its corners at 0xb4 and 0xc0
                    float lo[3], hi[3];
                    for (int k = 0; k < 3; k++) lo[k] = rdf(md + 0xb4 + 4 * k), hi[k] = rdf(md + 0xc0 + 4 * k);
                    static const int quad[6][4] = {{0, 2, 6, 4}, {1, 5, 7, 3}, {0, 4, 5, 1}, {2, 3, 7, 6}, {0, 1, 3, 2}, {4, 6, 7, 5}};
                    float c[8][3];
                    for (int k = 0; k < 8; k++) c[k][0] = k & 1 ? hi[0] : lo[0], c[k][1] = k & 2 ? hi[1] : lo[1], c[k][2] = k & 4 ? hi[2] : lo[2];
                    if (hi[0] > lo[0] && hi[1] > lo[1] && hi[2] > lo[2])
                        for (int k = 0; k < 6; k++) add_tri(&box[m], c[quad[k][0]], c[quad[k][1]], c[quad[k][2]]), add_tri(&box[m], c[quad[k][0]], c[quad[k][2]], c[quad[k][3]]);
                }
                free(md), free(vx);
            }
        }
        // A box prop (solid 3) by its box, which the 2004 bake shows: the stage light's own
        // spot sits inside the model's box, open at its lens, and comes out blocked. Others
        // by their collision model, or by their visible mesh when they have none.
        struct tris *model = visible && mesh[m].n ? &mesh[m] : solid == 3 ? &box[m] : phy[m].n ? &phy[m] : &mesh[m];
        if (!model->n) continue;
        out->nfound++;
        out->nbox += model == &box[m], out->nmesh += model == &mesh[m];
        out->ncolour += colour[m][0] >= 0;
        float o[3] = {rdf(q), rdf(q + 4), rdf(q + 8)}, a[3] = {rdf(q + 12), rdf(q + 16), rdf(q + 20)}, r[3][3];
        angle_matrix(a, r);
        for (int t = 0; t < model->n; t++) {
            float v[3][3];
            for (int c = 0; c < 3; c++)
                for (int k = 0; k < 3; k++) {
                    const float *l = model->t[t][c];
                    v[c][k] = o[k] + r[k][0] * l[0] + r[k][1] * l[1] + r[k][2] * l[2];
                }
            add_tri(&all, v[0], v[1], v[2]);
            if (refl_cap < all.cap)
                refl_cap = all.cap, refl = realloc(refl, sizeof *refl * (size_t)refl_cap), owner = realloc(owner, sizeof *owner * (size_t)refl_cap);
            memcpy(refl[all.n - 1], colour[m], 12);
            owner[all.n - 1] = i;
        }
    }
    for (int i = 0; i < nnames; i++) free(phy[i].t), free(mesh[i].t), free(box[i].t);
    free(phy), free(mesh), free(box), free(tried), free(colour);
    search_close(&s);
    out->tris = all.t, out->refl = refl, out->owner = owner, out->ntris = all.n;
    return out;
}

struct bl_props *bl_props_load(const char *bsp_path, const uint8_t *d, long size, char *err, int errlen)
{
    return props_load(bsp_path, d, size, 0, err, errlen);
}

struct bl_props *bl_props_load_visible(const char *bsp_path, const uint8_t *d, long size, char *err, int errlen)
{
    return props_load(bsp_path, d, size, 1, err, errlen);
}

void bl_props_free(struct bl_props *p)
{
    if (!p) return;
    free(p->tris), free(p->refl), free(p->owner);
    free(p);
}
