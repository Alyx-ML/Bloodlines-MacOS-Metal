// The map's lights and visibility, from its .bsp (Source's VBSP version 17 as Bloodlines
// has it): the world lights lump (the lights the map compiler baked, with their falloff
// and spot cones), the BSP tree (planes, nodes, leaves) to find the camera's leaf and to
// test lines against solid space, and the visibility lump (which clusters of leaves can
// see which). Read when the game opens the file (bl_k32_CreateFileA_c).

#include "bl_bsp.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

struct plane { float n[3], d; };
struct node { int plane, child[2]; };
struct leaf { int contents, cluster; };

static struct map {
    char path[1024];
    struct plane *planes;
    struct node *nodes;
    struct leaf *leaves;
    int nplanes, nnodes, nleaves;
    uint8_t *vis;  // the visibility lump; NULL: everything sees everything
    int vis_len, nclusters;
    struct bl_light *lights;
    int *light_cluster;
    int nlights;
} *map;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
// The open map's surfaces go to the renderer's light probes (gi_probes.h), which keep them.
void bl_map_note(struct bl_bsp_world *w, const char *host_path);

static int rd32(const uint8_t *p) { int v; memcpy(&v, p, 4); return v; }
static float rdf(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }
static int rd16(const uint8_t *p) { int16_t v; memcpy(&v, p, 2); return v; }

static void free_map(struct map *m)
{
    if (!m) return;
    free(m->planes), free(m->nodes), free(m->leaves), free(m->vis), free(m->lights), free(m->light_cluster);
    free(m);
}

static struct map *load(const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = size > 1032 ? malloc((size_t)size) : NULL;
    if (!d || fread(d, 1, (size_t)size, f) != (size_t)size || memcmp(d, "VBSP", 4)) {
        fclose(f), free(d);
        return NULL;
    }
    fclose(f);
    struct map *m = calloc(1, sizeof *m);
    snprintf(m->path, sizeof m->path, "%s", path);
    const uint8_t *lump[64];
    int len[64];
    for (int i = 0; i < 64; i++) {
        int ofs = rd32(d + 8 + 16 * i), n = rd32(d + 12 + 16 * i);
        if (ofs < 0 || n < 0 || (long)ofs + n > size) ofs = 0, n = 0;
        lump[i] = d + ofs, len[i] = n;
    }
    m->nplanes = len[1] / 20, m->nnodes = len[5] / 32, m->nleaves = len[10] / 32;
    m->planes = calloc((size_t)m->nplanes + 1, sizeof *m->planes);
    m->nodes = calloc((size_t)m->nnodes + 1, sizeof *m->nodes);
    m->leaves = calloc((size_t)m->nleaves + 1, sizeof *m->leaves);
    for (int i = 0; i < m->nplanes; i++)
        for (int k = 0; k < 4; k++) (&m->planes[i].n[0])[k] = rdf(lump[1] + 20 * i + 4 * k);
    for (int i = 0; i < m->nnodes; i++) {
        const uint8_t *p = lump[5] + 32 * i;
        m->nodes[i].plane = rd32(p), m->nodes[i].child[0] = rd32(p + 4), m->nodes[i].child[1] = rd32(p + 8);
        if (m->nodes[i].plane < 0 || m->nodes[i].plane >= m->nplanes) m->nodes[i].plane = 0;
    }
    for (int i = 0; i < m->nleaves; i++)
        m->leaves[i].contents = rd32(lump[10] + 32 * i), m->leaves[i].cluster = rd16(lump[10] + 32 * i + 4);
    if (len[4] >= 4) {
        m->nclusters = rd32(lump[4]);
        if (m->nclusters > 0 && 4 + 8L * m->nclusters <= len[4]) {
            m->vis = malloc((size_t)len[4]);
            memcpy(m->vis, lump[4], (size_t)len[4]);
            m->vis_len = len[4];
        }
    }
    // dworldlight_t, 88 bytes: origin, intensity, normal, cluster, type, style, stopdot,
    // stopdot2, exponent, radius, constant, linear and quadratic attenuation, flags,
    // texinfo, owner. Types 1 (point) and 2 (spot) only: 0 is a glowing surface, 3 and 5
    // the sky.
    int n = len[15] / 88;
    m->lights = calloc((size_t)n + 1, sizeof *m->lights);
    m->light_cluster = calloc((size_t)n + 1, sizeof *m->light_cluster);
    for (int i = 0; i < n; i++) {
        const uint8_t *p = lump[15] + 88 * i;
        int type = rd32(p + 40);
        if (type != 1 && type != 2) continue;
        struct bl_light *l = &m->lights[m->nlights];
        for (int k = 0; k < 3; k++) l->pos[k] = rdf(p + 4 * k), l->color[k] = rdf(p + 12 + 4 * k), l->dir[k] = rdf(p + 24 + 4 * k);
        l->spot = type == 2;
        l->inner = l->spot ? rdf(p + 48) : 0, l->outer = l->spot ? rdf(p + 52) : 0;
        l->exponent = rdf(p + 56), l->radius = rdf(p + 60);
        for (int k = 0; k < 3; k++) l->att[k] = rdf(p + 64 + 4 * k);
        if (l->att[0] <= 0 && l->att[1] <= 0 && l->att[2] <= 0) l->att[2] = 1;
        if (l->color[0] <= 0 && l->color[1] <= 0 && l->color[2] <= 0) continue;
        m->light_cluster[m->nlights++] = rd32(p + 36);
    }
    free(d);
    fprintf(stderr, "[bsp] %s: %d lights, %d clusters\n", strrchr(path, '/') ? strrchr(path, '/') + 1 : path, m->nlights,
            m->nclusters);
    return m;
}

void bl_bsp_note_open(const char *host_path)
{
    size_t n = strlen(host_path);
    if (n < 4 || strcasecmp(host_path + n - 4, ".bsp") || !strcasestr(host_path, "/maps/")) return;
    pthread_mutex_lock(&lock);
    int same = map && !strcmp(map->path, host_path);
    pthread_mutex_unlock(&lock);
    if (same) return;
    struct map *m = load(host_path);
    if (!m) return;
    pthread_mutex_lock(&lock);
    struct map *old = map;
    map = m;
    pthread_mutex_unlock(&lock);
    free_map(old);
    // Its surfaces too, for the lighting rebake (read and checked).
    char err[256], summary[1024];
    struct bl_bsp_world *w = bl_bsp_world_load(host_path, err, sizeof err);
    if (!w) {
        fprintf(stderr, "[bsp] surfaces not read: %s\n", err);
        return;
    }
    int bad = bl_bsp_world_check(w, summary, sizeof summary);
    fprintf(stderr, "[bsp] %s%s\n", summary, bad ? " -- LAYOUT NOT AS EXPECTED" : "");
    if (bad) bl_bsp_world_free(w);
    else bl_map_note(w, host_path);
}

// For tools built without the renderer (tests/bsp_check): the surfaces are not kept.
__attribute__((weak)) void bl_map_note(struct bl_bsp_world *w, const char *host_path)
{
    (void)host_path;
    bl_bsp_world_free(w);
}

static int leaf_at(const struct map *m, const float p[3])
{
    int i = 0;
    for (int guard = 0; i >= 0 && guard < 4096; guard++) {
        if (i >= m->nnodes) return -1;
        const struct plane *pl = &m->planes[m->nodes[i].plane];
        float d = pl->n[0] * p[0] + pl->n[1] * p[1] + pl->n[2] * p[2] - pl->d;
        i = m->nodes[i].child[d < 0];
    }
    i = -1 - i;
    return i >= 0 && i < m->nleaves ? i : -1;
}

// Whether cluster `to` is in the potentially visible set of cluster `from`.
static int sees(const struct map *m, int from, int to)
{
    if (!m->vis || from < 0 || to < 0 || from >= m->nclusters || to >= m->nclusters) return 1;
    int ofs = rd32(m->vis + 4 + 8 * from);
    if (ofs <= 0 || ofs >= m->vis_len) return 1;
    // Run-length coded: a zero byte is followed by how many zero bytes it stands for.
    int bit = to, c = 0;
    for (const uint8_t *p = m->vis + ofs; c < m->nclusters && p < m->vis + m->vis_len; p++) {
        if (*p == 0) {
            if (p + 1 >= m->vis + m->vis_len) return 0;
            c += 8 * p[1], p++;
            if (bit < c) return 0;
            continue;
        }
        if (bit < c + 8) return (*p >> (bit - c)) & 1;
        c += 8;
    }
    return 0;
}

// Whether the line from a to b stays out of solid space.
static int clear_line(const struct map *m, int node, const float a[3], const float b[3], int depth)
{
    if (depth > 256) return 1;
    if (node < 0) {
        int l = -1 - node;
        return l >= m->nleaves || !(m->leaves[l].contents & 1);  // CONTENTS_SOLID
    }
    if (node >= m->nnodes) return 1;
    const struct plane *pl = &m->planes[m->nodes[node].plane];
    float da = pl->n[0] * a[0] + pl->n[1] * a[1] + pl->n[2] * a[2] - pl->d;
    float db = pl->n[0] * b[0] + pl->n[1] * b[1] + pl->n[2] * b[2] - pl->d;
    if (da >= 0 && db >= 0) return clear_line(m, m->nodes[node].child[0], a, b, depth + 1);
    if (da < 0 && db < 0) return clear_line(m, m->nodes[node].child[1], a, b, depth + 1);
    float t = da / (da - db), mid[3];
    for (int k = 0; k < 3; k++) mid[k] = a[k] + (b[k] - a[k]) * t;
    int side = da < 0;
    return clear_line(m, m->nodes[node].child[side], a, mid, depth + 1) &&
           clear_line(m, m->nodes[node].child[!side], mid, b, depth + 1);
}

int bl_bsp_lights(const float cam[3], struct bl_light *out, int max)
{
    pthread_mutex_lock(&lock);
    struct map *m = map;
    if (!m || !m->nnodes || max <= 0) {
        pthread_mutex_unlock(&lock);
        return 0;
    }
    int cl = leaf_at(m, cam);
    int cluster = cl >= 0 ? m->leaves[cl].cluster : -1;
    // A light seen past a wall still lights the air on this side, a little: 0.3.
    float best[64];
    if (max > 64) max = 64;
    int n = 0;
    for (int i = 0; i < m->nlights; i++) {
        struct bl_light *l = &m->lights[i];
        float v[3] = {l->pos[0] - cam[0], l->pos[1] - cam[1], l->pos[2] - cam[2]};
        float d2 = v[0] * v[0] + v[1] * v[1] + v[2] * v[2];
        float target = 0, in = 0;
        if (d2 < 3000.0f * 3000.0f && sees(m, cluster, m->light_cluster[i])) {
            in = 1;
            // The light's origin may sit just inside its fitting: start the line a little
            // towards the camera.
            float d = sqrtf(d2), s = d > 8 ? 4 / d : 0, p[3];
            for (int k = 0; k < 3; k++) p[k] = l->pos[k] - v[k] * s;
            target = clear_line(m, 0, p, cam, 0) ? 1 : 0.3f;
        }
        l->vis += (target - l->vis) * 0.15f;
        l->seen += (in - l->seen) * 0.15f;
        if (l->seen < 0.01f) continue;
        // Ranked by how much it lights here, not how much of it the camera sees: the
        // characters' light takes the list as well.
        float c = fmaxf(l->color[0], fmaxf(l->color[1], l->color[2])) * l->seen;
        float score = c / (l->att[0] + l->att[1] * sqrtf(d2) + l->att[2] * d2 + 1);
        // Kept sorted, brightest first.
        int j = n < max ? n++ : max;
        if (j == max && score <= best[max - 1]) continue;
        if (j == max) j = max - 1;
        while (j > 0 && best[j - 1] < score) out[j] = out[j - 1], best[j] = best[j - 1], j--;
        out[j] = *l, best[j] = score;
    }
    pthread_mutex_unlock(&lock);
    return n;
}

// --- the map's surfaces, for the lighting rebake ----------------------------------------
//
// VBSP 17 as Bloodlines has it differs from Half-Life 2's in the faces: 104 bytes, with
// eight light styles and eight day and night bytes (and a per-style mean colour) where
// Half-Life 2 has four styles in 56 bytes. Maps compiled again for the Unofficial Patch
// hold each face's mean colour per style just before its samples (lightofs), as Half-Life
// 2's do; the original maps do not (world->means says which, from the lump's size).
//
// Displacements as Half-Life 2's: 176 bytes each (lump 26: the start position, the first
// of its points in lump 33, the first triangle, the power), points 20 bytes (a direction,
// a distance, alpha). Its face's four corners, from the one at the start position: rows
// of 2^power + 1 points run from corner 0 to corner 1 (and 3 to 2), each from the first
// edge to the second, as the map compiler built them; a point is that place on the face
// plus its direction times its distance. The lightmap is laid over the grid: across (s)
// from corner 0 to corner 3, down (t) from corner 0 to corner 1, size + 1 luxels each way.

struct bl_bsp_world *bl_bsp_world_load(const char *path, char *err, int errlen)
{
    FILE *f = fopen(path, "rb");
    if (!f) {
        snprintf(err, (size_t)errlen, "cannot open %s", path);
        return NULL;
    }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t *d = size > 1036 ? malloc((size_t)size) : NULL;
    int ok = d && fread(d, 1, (size_t)size, f) == (size_t)size;
    fclose(f);
    if (!ok || memcmp(d, "VBSP", 4) || rd32(d + 4) != 17) {
        snprintf(err, (size_t)errlen, "%s: not a version 17 VBSP", path);
        free(d);
        return NULL;
    }
    const uint8_t *lump[64];
    int len[64];
    for (int i = 0; i < 64; i++) {
        int ofs = rd32(d + 8 + 16 * i), n = rd32(d + 12 + 16 * i);
        if (ofs < 0 || n < 0 || (long)ofs + n > size) ofs = 0, n = 0;
        lump[i] = d + ofs, len[i] = n;
    }
    struct bl_bsp_world *w = calloc(1, sizeof *w);
    const char *slash = strrchr(path, '/');
    snprintf(w->name, sizeof w->name, "%s", slash ? slash + 1 : path);
    int nplanes = len[1] / 20, nedges = len[12] / 4, nsurf = len[13] / 4;
    w->nverts = len[3] / 12;
    w->verts = calloc((size_t)w->nverts + 1, sizeof *w->verts);
    for (int i = 0; i < w->nverts; i++)
        for (int k = 0; k < 3; k++) w->verts[i][k] = rdf(lump[3] + 12 * i + 4 * k);
    w->ntexinfo = len[6] / 72;
    w->texinfo = calloc((size_t)w->ntexinfo + 1, sizeof *w->texinfo);
    for (int i = 0; i < w->ntexinfo; i++) {
        const uint8_t *p = lump[6] + 72 * i;
        for (int k = 0; k < 8; k++) (&w->texinfo[i].tex[0][0])[k] = rdf(p + 4 * k), (&w->texinfo[i].lm[0][0])[k] = rdf(p + 32 + 4 * k);
        w->texinfo[i].flags = rd32(p + 64), w->texinfo[i].texdata = rd32(p + 68);
    }
    // Texture data: reflectivity, the name's place in the string table (lumps 44 and 43),
    // size, view size.
    w->ntexdata = len[2] / 32;
    w->texdata = calloc((size_t)w->ntexdata + 1, sizeof *w->texdata);
    for (int i = 0; i < w->ntexdata; i++) {
        const uint8_t *p = lump[2] + 32 * i;
        struct bl_bsp_texdata *t = &w->texdata[i];
        for (int k = 0; k < 3; k++) t->reflectivity[k] = rdf(p + 4 * k);
        t->width = rd32(p + 16), t->height = rd32(p + 20);
        int s = rd32(p + 12);
        if (s >= 0 && 4 * s + 4 <= len[44]) {
            int ofs = rd32(lump[44] + 4 * s);
            if (ofs >= 0 && ofs < len[43])
                snprintf(t->name, sizeof t->name, "%.*s", (int)strnlen((const char *)lump[43] + ofs, (size_t)(len[43] - ofs)),
                         (const char *)lump[43] + ofs);
        }
    }
    // Models: mins, maxs, origin, head node, first face, face count.
    w->nmodels = len[14] / 48;
    w->nfaces = len[7] / 104;
    w->faces = calloc((size_t)w->nfaces + 1, sizeof *w->faces);
    w->index = calloc((size_t)nsurf + 1, sizeof *w->index);
    for (int m = 0; m < w->nmodels; m++) {
        int first = rd32(lump[14] + 48 * m + 40), n = rd32(lump[14] + 48 * m + 44);
        for (int i = first; i >= 0 && i < first + n && i < w->nfaces; i++) w->faces[i].model = m;
    }
    // Brush entities stand where their entity's origin says ("model" "*N"); their faces
    // are in the model's own space.
    float (*mo)[3] = calloc((size_t)w->nmodels + 1, sizeof *mo);
    for (const char *e = (const char *)lump[0], *end = e + len[0]; e < end;) {
        const char *open = memchr(e, '{', (size_t)(end - e)), *close = open ? memchr(open, '}', (size_t)(end - open)) : NULL;
        if (!close) break;
        int model = -1;
        float o[3] = {0};
        for (const char *k = open + 1; k < close;) {
            const char *q[4];
            int n = 0;
            for (const char *c = k; c < close && n < 4; c++)
                if (*c == '"') q[n++] = c;
            if (n < 4) break;
            int kl = (int)(q[1] - q[0] - 1);
            if (kl == 5 && !memcmp(q[0] + 1, "model", 5) && q[2][1] == '*') model = atoi(q[2] + 2);
            if (kl == 6 && !memcmp(q[0] + 1, "origin", 6)) sscanf(q[2] + 1, "%f %f %f", &o[0], &o[1], &o[2]);
            k = q[3] + 1;
        }
        if (model > 0 && model < w->nmodels) memcpy(mo[model], o, sizeof o);
        e = close + 1;
    }
    for (int i = 0; i < w->nfaces; i++) {
        const uint8_t *p = lump[7] + 104 * i;
        struct bl_bsp_face *fc = &w->faces[i];
        // The face's own plane, facing the way it does (planes come in pairs); the side
        // byte is its node's, not its own.
        int plane = (uint16_t)rd16(p + 32);
        if (plane < nplanes) {
            for (int k = 0; k < 3; k++) fc->normal[k] = rdf(lump[1] + 20 * plane + 4 * k);
            fc->dist = rdf(lump[1] + 20 * plane + 12);
        }
        int firstedge = rd32(p + 36), numedges = rd16(p + 40);
        fc->first = w->nindex;
        for (int e = 0; e < numedges && firstedge >= 0 && firstedge + e < nsurf; e++) {
            int se = rd32(lump[13] + 4 * (firstedge + e)), ed = se < 0 ? -se : se;
            if (ed >= nedges) continue;
            int v = (uint16_t)rd16(lump[12] + 4 * ed + (se < 0 ? 2 : 0));
            if (v < w->nverts) w->index[w->nindex++] = v;
        }
        fc->count = w->nindex - fc->first;
        fc->texinfo = rd16(p + 42);
        if (fc->texinfo >= w->ntexinfo) fc->texinfo = -1;
        fc->disp = rd16(p + 44);
        memcpy(fc->styles, p + 48, 8);
        for (int k = 0; k < 8; k++) fc->nstyles += fc->styles[k] != 255;
        fc->lightofs = rd32(p + 72);
        if (fc->lightofs >= 0) fc->lightofs /= 4;
        fc->area = rdf(p + 76);
        fc->mins[0] = rd32(p + 80), fc->mins[1] = rd32(p + 84);
        fc->size[0] = rd32(p + 88), fc->size[1] = rd32(p + 92);
        fc->bumped = fc->texinfo >= 0 && (w->texinfo[fc->texinfo].flags & 0x800);
        memcpy(fc->origin, mo[fc->model], sizeof fc->origin);
    }
    free(mo);
    int ndisp = len[26] / 176, nraw = len[33] / 20;
    for (int i = 0; i < w->nfaces; i++) {
        struct bl_bsp_face *fc = &w->faces[i];
        if (fc->disp < 0 || fc->disp >= ndisp || fc->count != 4) continue;
        const uint8_t *q = lump[26] + 176 * fc->disp;
        int first = rd32(q + 12), power = rd32(q + 20), n = (1 << (power & 7)) + 1;
        if (power < 2 || power > 4 || first < 0 || first + n * n > nraw) continue;
        float c[4][3], best = 1e30f;
        int start = 0;
        for (int k = 0; k < 4; k++) {
            float d2 = 0;
            for (int a = 0; a < 3; a++) c[k][a] = w->verts[w->index[fc->first + k]][a], d2 += (c[k][a] - rdf(q + 4 * a)) * (c[k][a] - rdf(q + 4 * a));
            if (d2 < best) best = d2, start = k;
        }
        w->dverts = realloc(w->dverts, sizeof *w->dverts * (size_t)(w->ndverts + n * n));
        fc->dfirst = w->ndverts, fc->dside = n;
        const float *p0 = c[start], *p1 = c[(start + 1) & 3], *p2 = c[(start + 2) & 3], *p3 = c[(start + 3) & 3];
        for (int r = 0; r < n; r++)
            for (int k = 0; k < n; k++) {
                float u = (float)r / (float)(n - 1), v = (float)k / (float)(n - 1);
                const uint8_t *dv = lump[33] + 20 * (first + r * n + k);
                struct bl_bsp_dvert *o = &w->dverts[w->ndverts++];
                for (int a = 0; a < 3; a++) {
                    float e0 = p0[a] + (p1[a] - p0[a]) * u, e1 = p3[a] + (p2[a] - p3[a]) * u;
                    o->pos[a] = e0 + (e1 - e0) * v + rdf(dv + 4 * a) * rdf(dv + 12);
                }
                o->lux[0] = v * (float)fc->size[0], o->lux[1] = u * (float)fc->size[1];
            }
    }
    w->nlights = len[15] / 88;
    w->lights = calloc((size_t)w->nlights + 1, sizeof *w->lights);
    for (int i = 0; i < w->nlights; i++) {
        const uint8_t *p = lump[15] + 88 * i;
        struct bl_bsp_worldlight *l = &w->lights[i];
        for (int k = 0; k < 3; k++)
            l->origin[k] = rdf(p + 4 * k), l->intensity[k] = rdf(p + 12 + 4 * k), l->normal[k] = rdf(p + 24 + 4 * k);
        l->cluster = rd32(p + 36), l->type = rd32(p + 40), l->style = rd32(p + 44);
        l->stopdot = rdf(p + 48), l->stopdot2 = rdf(p + 52), l->exponent = rdf(p + 56), l->radius = rdf(p + 60);
        for (int k = 0; k < 3; k++) l->att[k] = rdf(p + 64 + 4 * k);
        l->flags = rd32(p + 76), l->texinfo = rd32(p + 80), l->owner = rd32(p + 84);
    }
    // Mean colours before each face's samples, or not: whichever fills the lump exactly.
    long plain = 0, styles = 0;
    for (int i = 0; i < w->nfaces; i++)
        if (w->faces[i].lightofs >= 0 && w->faces[i].texinfo >= 0) {
            const struct bl_bsp_face *fc = &w->faces[i];
            plain += (long)(fc->size[0] + 1) * (fc->size[1] + 1) * fc->nstyles * (fc->bumped ? 4 : 1);
            styles += fc->nstyles;
        }
    w->means = plain + styles == len[8] / 4;
    w->nsamples = len[8] / 4;
    w->lighting = malloc((size_t)len[8] + 4);
    memcpy(w->lighting, lump[8], (size_t)len[8]);
    w->props = bl_props_load(path, d, size, w->props_err, sizeof w->props_err);
    w->nplanes = nplanes, w->nnodes = len[5] / 32, w->nleaves = len[10] / 32;
    w->planes = calloc((size_t)w->nplanes + 1, sizeof *w->planes);
    w->nodes = calloc((size_t)w->nnodes + 1, sizeof *w->nodes);
    w->leaves = calloc((size_t)w->nleaves + 1, sizeof *w->leaves);
    for (int i = 0; i < w->nplanes; i++)
        for (int k = 0; k < 4; k++) w->planes[i][k] = rdf(lump[1] + 20 * i + 4 * k);
    for (int i = 0; i < w->nnodes; i++) {
        const uint8_t *p = lump[5] + 32 * i;
        w->nodes[i][0] = rd32(p), w->nodes[i][1] = rd32(p + 4), w->nodes[i][2] = rd32(p + 8);
        if (w->nodes[i][0] < 0 || w->nodes[i][0] >= w->nplanes) w->nodes[i][0] = 0;
    }
    for (int i = 0; i < w->nleaves; i++) w->leaves[i][0] = rd32(lump[10] + 32 * i), w->leaves[i][1] = rd16(lump[10] + 32 * i + 4);
    free(d);
    return w;
}

void bl_bsp_world_free(struct bl_bsp_world *w)
{
    if (!w) return;
    free(w->verts), free(w->index), free(w->faces), free(w->texinfo), free(w->texdata), free(w->lights), free(w->lighting);
    free(w->dverts);
    bl_props_free(w->props);
    free(w->planes), free(w->nodes), free(w->leaves);
    free(w);
}

int bl_bsp_world_open(const struct bl_bsp_world *w, const float p[3])
{
    int i = 0;
    for (int guard = 0; i >= 0 && guard < 4096; guard++) {
        if (i >= w->nnodes) return 0;
        const float *pl = w->planes[w->nodes[i][0]];
        i = w->nodes[i][1 + (pl[0] * p[0] + pl[1] * p[1] + pl[2] * p[2] - pl[3] < 0)];
    }
    i = -1 - i;
    return i >= 0 && i < w->nleaves && !(w->leaves[i][0] & 1) && w->leaves[i][1] >= 0;
}

static int by_lightofs(const void *a, const void *b)
{
    const int *x = a, *y = b;
    return x[0] < y[0] ? -1 : x[0] > y[0];
}

int bl_bsp_world_check(const struct bl_bsp_world *w, char *buf, int len)
{
    int lit = 0, bumped = 0, bad_range = 0, bad_luxel = 0, overlap = 0, disp = 0, ntype[6] = {0};
    long samples = 0;
    float worst = 0;  // the farthest a corner falls outside its lightmap, in luxels
    int *spans = malloc(sizeof(int) * 2 * ((size_t)w->nfaces + 1));
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        disp += f->disp >= 0;
        if (f->lightofs < 0 || f->texinfo < 0) continue;
        int n = (f->size[0] + 1) * (f->size[1] + 1) * f->nstyles * (f->bumped ? 4 : 1);
        // The mean colours (one per style) come just before the samples, in some maps.
        int before = w->means ? f->nstyles : 0;
        if (f->lightofs < before || f->lightofs + n > w->nsamples) {
            bad_range++;
            continue;
        }
        spans[2 * lit] = f->lightofs - before, spans[2 * lit + 1] = f->lightofs + n;
        lit++, bumped += f->bumped, samples += n;
        if (f->disp >= 0) continue;  // a displacement's lightmap follows its grid, not the texinfo
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        float out = 0;
        for (int c = 0; c < f->count; c++) {
            const float *v = w->verts[w->index[f->first + c]];
            for (int k = 0; k < 2; k++) {
                float s = v[0] * t->lm[k][0] + v[1] * t->lm[k][1] + v[2] * t->lm[k][2] + t->lm[k][3] - (float)f->mins[k];
                out = fmaxf(out, fmaxf(-s, s - (float)f->size[k]));
            }
        }
        worst = fmaxf(worst, out);
        bad_luxel += out > 0.5f;  // half a luxel: vrad's rounding of the mins
    }
    qsort(spans, (size_t)lit, 2 * sizeof(int), by_lightofs);
    for (int i = 1; i < lit; i++) overlap += spans[2 * i] < spans[2 * i - 1];
    long used = 0;
    for (int i = 0; i < lit; i++) used += spans[2 * i + 1] - spans[2 * i];
    free(spans);
    for (int i = 0; i < w->nlights; i++)
        if (w->lights[i].type >= 0 && w->lights[i].type < 6) ntype[w->lights[i].type]++;
    int ntris = 0;
    for (int i = 0; i < w->nfaces; i++) ntris += w->faces[i].count > 2 ? w->faces[i].count - 2 : 0;
    snprintf(buf, (size_t)len,
             "%s: %d faces (%d lit, %d bumped, %d displacements), %d triangles, %d vertices, %d textures, %d models; "
             "%d lights (%d point, %d spot, %d surface, %d sun, %d sky); lightmaps %ld of %d samples used, "
             "%d out of range, %d overlapping, %d with a corner outside (worst %.2f luxels)%s; ",
             w->name, w->nfaces, lit, bumped, disp, ntris, w->nverts, w->ntexdata, w->nmodels, w->nlights, ntype[1],
             ntype[2], ntype[0], ntype[3], ntype[5], used, w->nsamples, bad_range, overlap, bad_luxel, worst,
             w->means ? ", mean colours before each face's" : "");
    size_t at = strlen(buf);
    if (w->props)
        snprintf(buf + at, (size_t)len - at, "%d static props, %d casting shadows, %d of those read (%d as boxes, %d by their visible mesh), %d triangles",
                 w->props->nprops, w->props->nshadow, w->props->nfound, w->props->nbox, w->props->nmesh, w->props->ntris);
    else
        snprintf(buf + at, (size_t)len - at, "static props: %s", w->props_err);
    return bad_range + overlap + bad_luxel + !w->props;
}
