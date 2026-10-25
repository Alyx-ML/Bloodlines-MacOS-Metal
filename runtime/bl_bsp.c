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
