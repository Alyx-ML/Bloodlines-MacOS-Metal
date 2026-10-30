#include "prop_remodel.h"

#include <CommonCrypto/CommonDigest.h>
#include <mach-o/dyld.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct entry {
    uint64_t key;
    uint32_t ntris;
    int brush;  // under brush/: keyed by its positions (brush_key), not its vertex numbers
    char file[256];
};

static struct entry *entries;
static size_t nentries;
static int loaded;
static char dir[1024];

static int by_key(const void *a, const void *b)
{
    uint64_t x = ((const struct entry *)a)->key, y = ((const struct entry *)b)->key;
    return x < y ? -1 : x > y;
}

static void load_list(void)
{
    loaded = 1;
    char exe[1024];
    uint32_t n = sizeof exe;
    if (_NSGetExecutablePath(exe, &n)) return;
    char *slash = strrchr(exe, '/');
    if (!slash) return;
    *slash = 0;  // build/tests
    snprintf(dir, sizeof dir, "%s/../remodels", exe);
    char list[1100];
    snprintf(list, sizeof list, "%s/index.txt", dir);
    FILE *f = fopen(list, "r");
    if (!f) return;
    size_t cap = 0;
    struct entry e;
    while (fscanf(f, "%16llx %u %255[^\n]", (unsigned long long *)&e.key, &e.ntris, e.file) == 3) {
        e.brush = !strncmp(e.file, "brush/", 6);
        if (nentries == cap) entries = realloc(entries, sizeof *entries * (cap = cap ? cap * 2 : 64));
        entries[nentries++] = e;
    }
    fclose(f);
    qsort(entries, nentries, sizeof *entries, by_key);
    fprintf(stderr, "[remodel] %zu meshes listed in %s\n", nentries, dir);
}

int prop_remodel_listed(uint32_t ntris)
{
    if (!loaded) load_list();
    for (size_t i = 0; i < nentries; i++)
        if (entries[i].ntris == ntris && !entries[i].brush) return 1;
    return 0;
}

int prop_remodel_brush_listed(uint32_t ntris)
{
    if (!loaded) load_list();
    for (size_t i = 0; i < nentries; i++)
        if (entries[i].ntris == ntris && entries[i].brush) return 1;
    return 0;
}

static int by_point(const void *a, const void *b)
{
    const int32_t *x = a, *y = b;
    for (int k = 0; k < 3; k++)
        if (x[k] != y[k]) return x[k] < y[k] ? -1 : 1;
    return 0;
}

// A brush remodel's key (tools/brush_panels.py pos_key): the first 8 bytes of the SHA-1 of
// the distinct points the draw uses, each rounded to 1/16 unit as three int32, sorted.
static uint64_t brush_key(const struct prop_in *in, const struct prop_elem *pe)
{
    uint32_t n = in->ntris * 3, m = 0;
    int32_t(*q)[3] = malloc(sizeof *q * (n ? n : 1));
    if (!q) return 0;
    for (uint32_t i = 0; i < n; i++) {
        const float *p = (const float *)(in->data[pe->stream] + (size_t)in->idx[i] * in->stride[pe->stream] + pe->offset);
        for (int k = 0; k < 3; k++) q[i][k] = (int32_t)lrintf(p[k] * 16);
    }
    qsort(q, n, sizeof *q, by_point);
    for (uint32_t i = 0; i < n; i++)
        if (!m || by_point(q[i], q[m - 1])) memcpy(q[m++], q[i], sizeof *q);
    uint8_t d[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(q, (CC_LONG)(m * sizeof *q), d);
    free(q);
    uint64_t key = 0;
    for (int i = 0; i < 8; i++) key = key << 8 | d[i];
    return key;
}

static const struct prop_elem *find(const struct prop_in *in, int usage, int type)
{
    for (int i = 0; i < in->nel; i++)
        if (in->el[i].usage == usage && in->el[i].index == 0 && in->el[i].type == type) return &in->el[i];
    return NULL;
}

static const float *pos_of(const struct prop_in *in, const struct prop_elem *p, uint32_t v)
{
    return (const float *)(in->data[p->stream] + (size_t)v * in->stride[p->stream] + p->offset);
}

// The nearest point of triangle abc to p, as barycentric weights (Ericson, Real-Time
// Collision Detection 5.1.5); returns the squared distance.
static float nearest(const float *p, const float *a, const float *b, const float *c, float w[3])
{
    float ab[3], ac[3], ap[3], bp[3], cp[3];
    for (int k = 0; k < 3; k++) ab[k] = b[k] - a[k], ac[k] = c[k] - a[k], ap[k] = p[k] - a[k];
#define DOT(x, y) (x[0] * y[0] + x[1] * y[1] + x[2] * y[2])
    float d1 = DOT(ab, ap), d2 = DOT(ac, ap);
    if (d1 <= 0 && d2 <= 0) {
        w[0] = 1, w[1] = w[2] = 0;
    } else {
        for (int k = 0; k < 3; k++) bp[k] = p[k] - b[k];
        float d3 = DOT(ab, bp), d4 = DOT(ac, bp);
        for (int k = 0; k < 3; k++) cp[k] = p[k] - c[k];
        float d5 = DOT(ab, cp), d6 = DOT(ac, cp);
        float vc = d1 * d4 - d3 * d2, vb = d5 * d2 - d1 * d6, va = d3 * d6 - d5 * d4;
        if (d3 >= 0 && d4 <= d3) {
            w[1] = 1, w[0] = w[2] = 0;
        } else if (vc <= 0 && d1 >= 0 && d3 <= 0) {
            float t = d1 / (d1 - d3);
            w[0] = 1 - t, w[1] = t, w[2] = 0;
        } else if (d6 >= 0 && d5 <= d6) {
            w[2] = 1, w[0] = w[1] = 0;
        } else if (vb <= 0 && d2 >= 0 && d6 <= 0) {
            float t = d2 / (d2 - d6);
            w[0] = 1 - t, w[2] = t, w[1] = 0;
        } else if (va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0) {
            float t = (d4 - d3) / ((d4 - d3) + (d5 - d6));
            w[1] = 1 - t, w[2] = t, w[0] = 0;
        } else {
            float den = 1 / (va + vb + vc);
            w[1] = vb * den, w[2] = vc * den, w[0] = 1 - w[1] - w[2];
        }
    }
#undef DOT
    float d = 0;
    for (int k = 0; k < 3; k++) {
        float q = w[0] * a[k] + w[1] * b[k] + w[2] * c[k] - p[k];
        d += q * q;
    }
    return d;
}

// One element of a new vertex from three of the game's: interpolated where the type is
// a number, else the nearest vertex's.
static void blend(uint8_t *dst, const uint8_t *src[3], const float w[3], int near, int type)
{
    switch (type) {
    case 0: case 1: case 2: case 3:  // FLOAT1..4
        for (int k = 0; k <= type; k++) {
            float f[3], r;
            for (int j = 0; j < 3; j++) memcpy(&f[j], src[j] + 4 * k, 4);
            r = w[0] * f[0] + w[1] * f[1] + w[2] * f[2];
            memcpy(dst + 4 * k, &r, 4);
        }
        break;
    case 4: case 8:  // D3DCOLOR, UBYTE4N
        for (int k = 0; k < 4; k++)
            dst[k] = (uint8_t)fminf(255, w[0] * src[0][k] + w[1] * src[1][k] + w[2] * src[2][k] + 0.5f);
        break;
    case 9: case 10:  // SHORT2N, SHORT4N
        for (int k = 0; k < (type == 9 ? 2 : 4); k++) {
            int16_t s[3], r;
            for (int j = 0; j < 3; j++) memcpy(&s[j], src[j] + 2 * k, 2);
            r = (int16_t)lrintf(w[0] * s[0] + w[1] * s[1] + w[2] * s[2]);
            memcpy(dst + 2 * k, &r, 2);
        }
        break;
    case 11: case 12:  // USHORT2N, USHORT4N
        for (int k = 0; k < (type == 11 ? 2 : 4); k++) {
            uint16_t s[3], r;
            for (int j = 0; j < 3; j++) memcpy(&s[j], src[j] + 2 * k, 2);
            r = (uint16_t)lrintf(w[0] * s[0] + w[1] * s[1] + w[2] * s[2]);
            memcpy(dst + 2 * k, &r, 2);
        }
        break;
    default: {  // indices (UBYTE4), packed and half formats: the nearest vertex's
        static const int size[17] = {4, 8, 12, 16, 4, 4, 4, 8, 4, 4, 8, 4, 8, 4, 4, 4, 8};
        if (type < 17) memcpy(dst, src[near], (size_t)size[type]);
    }
    }
}

// A relief remodel's colours (the game's lighting worked out at the original's corners,
// blended across its big triangles, which shows them): each a Gaussian mean of those
// within SMOOTH_R units, for remodels whose folder holds a "smooth" file
// (tools/prop_pack.py writes it for tools/blender/rock_relief.py's). Bytes colours only.
#define SMOOTH_R 48.0f
static int smooth_colours(const struct prop_in *in, struct prop_out *out, const float *mv, uint32_t nv)
{
    int done = 0;
    for (int i = 0; i < in->nel; i++) {
        const struct prop_elem *el = &in->el[i];
        if (el->usage != 10 || (el->type != 4 && el->type != 8) || !out->data[el->stream]) continue;
        uint32_t st = in->stride[el->stream];
        uint8_t *base = out->data[el->stream] + el->offset;
        float *acc = calloc((size_t)nv * 4, sizeof *acc);
        if (!acc) continue;
        const float k = -1 / (2 * (SMOOTH_R / 2) * (SMOOTH_R / 2));
        for (uint32_t a = 0; a < nv; a++) {
            const float *p = mv + 8 * a;
            float sum = 0, c[4] = {0};
            for (uint32_t b = 0; b < nv; b++) {
                const float *q = mv + 8 * b;
                float dx = p[0] - q[0], dy = p[1] - q[1], dz = p[2] - q[2], d2 = dx * dx + dy * dy + dz * dz;
                if (d2 > SMOOTH_R * SMOOTH_R) continue;
                float wt = expf(d2 * k);
                const uint8_t *src = base + (size_t)b * st;
                for (int j = 0; j < 4; j++) c[j] += wt * src[j];
                sum += wt;
            }
            for (int j = 0; j < 4; j++) acc[4 * a + j] = c[j] / sum;
        }
        for (uint32_t a = 0; a < nv; a++)
            for (int j = 0; j < 4; j++) base[(size_t)a * st + j] = (uint8_t)fminf(255, acc[4 * a + j] + 0.5f);
        free(acc);
        done++;
    }
    return done;
}

static int wants_smooth(const char *file)
{
    char path[1400];
    snprintf(path, sizeof path, "%s/%s", dir, file);
    char *slash = strrchr(path, '/');
    if (!slash) return 0;
    snprintf(slash + 1, sizeof path - (size_t)(slash + 1 - path), "smooth");
    FILE *f = fopen(path, "rb");
    if (f) fclose(f);
    return f != NULL;
}

static int remodel(const struct prop_in *in, struct prop_out *out, char *name, size_t namelen, int brush)
{
    memset(out, 0, sizeof *out);
    if (!loaded) load_list();
    if (!nentries) return 0;
    const struct prop_elem *pe = find(in, 0, 2), *ne = find(in, 3, 2), *te = find(in, 5, 1);
    uint32_t low = UINT32_MAX, high = 0;
    for (uint32_t i = 0; i < in->ntris * 3; i++) {
        for (int b = 0; b < 16; b++)
            if (in->data[b] && in->idx[i] >= in->nverts[b]) return 0;
        low = in->idx[i] < low ? in->idx[i] : low;
        high = in->idx[i] > high ? in->idx[i] : high;
    }
    struct entry k = {0}, *e;
    if (brush) {
        if (!pe || !(k.key = brush_key(in, pe))) return 0;
    } else {
        CC_SHA1_CTX c;
        CC_SHA1_Init(&c);
        for (uint32_t i = 0; i < in->ntris * 3; i++) {
            uint32_t x = in->idx[i] - low;
            CC_SHA1_Update(&c, &x, 4);
        }
        uint8_t d[CC_SHA1_DIGEST_LENGTH];
        CC_SHA1_Final(d, &c);
        for (int i = 0; i < 8; i++) k.key = k.key << 8 | d[i];
    }
    float *mv = NULL;
    uint32_t *mi = NULL, nv = 0, nt = 0;
    if ((e = bsearch(&k, entries, nentries, sizeof *entries, by_key)))
        while (e > entries && e[-1].key == k.key) e--;
    for (; e && e < entries + nentries && e->key == k.key && !mv; e++) {
        if (e->ntris != in->ntris || e->brush != brush) continue;
        char path[1400];
        snprintf(path, sizeof path, "%s/%s", dir, e->file);
        FILE *f = fopen(path, "rb");
        uint32_t h[4];
        if (!f || fread(h, 4, 4, f) != 4 || memcmp(h, "BLPM", 4)) {
            fprintf(stderr, "[remodel] %s is missing or not a remodel file\n", path);
            if (f) fclose(f);
            continue;
        }
        nv = h[1], nt = h[2];
        uint32_t no = h[3];
        float *orig = malloc(sizeof(float) * 3 * (no ? no : 1));
        mv = malloc(sizeof(float) * 8 * (nv ? nv : 1));
        mi = malloc(sizeof(uint32_t) * 3 * (nt ? nt : 1));
        int ok = orig && mv && mi && fread(mv, sizeof(float) * 8, nv, f) == nv && fread(mi, 12, nt, f) == nt &&
                 fread(orig, 12, no, f) == no;
        fclose(f);
        if (!ok) fprintf(stderr, "[remodel] %s is cut short\n", path);
        for (uint32_t i = 0; ok && i < nt * 3; i++)
            if (mi[i] >= nv) {
                fprintf(stderr, "[remodel] %s has a triangle past its vertices\n", path);
                ok = 0;
            }
        if (ok && !pe) {
            static int said;
            if (!said++) fprintf(stderr, "[remodel] %s: the game's positions are not 3 floats, not drawn\n", e->file);
            ok = 0;
        }
        // Every position the draw uses within 0.01 of the original's: this mesh, not
        // another with the same triangles. A brush remodel's key is its positions.
        ok = ok && (brush ? no == 0 : no == high - low + 1);
        for (uint32_t i = 0; ok && !brush && i < in->ntris * 3; i++) {
            const float *p = pos_of(in, pe, in->idx[i]), *q = orig + 3 * (in->idx[i] - low);
            ok = fabsf(p[0] - q[0]) <= 0.01f && fabsf(p[1] - q[1]) <= 0.01f && fabsf(p[2] - q[2]) <= 0.01f;
        }
        free(orig);
        if (!ok) {
            free(mv), free(mi);
            mv = NULL, mi = NULL;
        } else
            snprintf(name, namelen, "%s", e->file);
    }
    if (!mv) {
        if (brush) return 0;  // brush draws of a listed size are many: none logged
        // A draw the size of a listed mesh that is not it: logged, as a remodel made for
        // this draw would have its key.
        static int logged;
        for (size_t i = 0; i < nentries && logged < 20 && pe; i++)
            if (entries[i].ntris == in->ntris && !entries[i].brush) {
                const float *p0 = pos_of(in, pe, in->idx[0]);
                fprintf(stderr, "[remodel] %u-triangle draw with key %016llx, first point %g %g %g: no remodel\n",
                        in->ntris, (unsigned long long)k.key, p0[0], p0[1], p0[2]);
                logged++;
                break;
            }
        return 0;
    }

    for (int b = 0; b < 16; b++)
        if (in->data[b]) out->data[b] = calloc(nv, in->stride[b]);
    for (uint32_t v = 0; v < nv; v++) {
        const float *p = mv + 8 * v;
        float best = INFINITY, w[3] = {1, 0, 0};
        uint32_t t = 0;
        for (uint32_t i = 0; i < in->ntris; i++) {
            float wi[3];
            float dd = nearest(p, pos_of(in, pe, in->idx[3 * i]), pos_of(in, pe, in->idx[3 * i + 1]),
                               pos_of(in, pe, in->idx[3 * i + 2]), wi);
            if (dd < best) best = dd, t = i, memcpy(w, wi, sizeof w);
        }
        int near = w[1] > w[0] ? (w[2] > w[1] ? 2 : 1) : (w[2] > w[0] ? 2 : 0);
        for (int b = 0; b < 16; b++) {
            if (!out->data[b]) continue;
            uint8_t *dst = out->data[b] + (size_t)v * in->stride[b];
            const uint8_t *src[3];
            for (int j = 0; j < 3; j++) src[j] = in->data[b] + (size_t)in->idx[3 * t + j] * in->stride[b];
            memcpy(dst, src[near], in->stride[b]);  // bytes no element covers
            for (int i = 0; i < in->nel; i++) {
                if (in->el[i].stream != b) continue;
                const uint8_t *es[3] = {src[0] + in->el[i].offset, src[1] + in->el[i].offset, src[2] + in->el[i].offset};
                blend(dst + in->el[i].offset, es, w, near, in->el[i].type);
            }
        }
        // A brush remodel's faces turn away from the flat face under them (a panel's
        // moulding): its tangent and binormal turned with them, by the turn from the
        // original's normal to the remodel's.
        if (brush && ne) {
            float a[3], k[3];
            memcpy(a, out->data[ne->stream] + (size_t)v * in->stride[ne->stream] + ne->offset, 12);
            const float *b = p + 3;
            float la = sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]);
            k[0] = a[1] * b[2] - a[2] * b[1], k[1] = a[2] * b[0] - a[0] * b[2], k[2] = a[0] * b[1] - a[1] * b[0];
            float s = sqrtf(k[0] * k[0] + k[1] * k[1] + k[2] * k[2]) / (la > 0 ? la : 1);
            float c = (a[0] * b[0] + a[1] * b[1] + a[2] * b[2]) / (la > 0 ? la : 1);
            if (la > 0 && s > 1e-4f) {
                for (int j = 0; j < 3; j++) k[j] /= s * la;
                for (int i = 0; i < in->nel; i++) {
                    const struct prop_elem *el = &in->el[i];
                    if ((el->usage != 6 && el->usage != 7) || el->type != 2 || !out->data[el->stream]) continue;
                    float t[3], r[3];
                    uint8_t *at = out->data[el->stream] + (size_t)v * in->stride[el->stream] + el->offset;
                    memcpy(t, at, 12);
                    float kt = k[0] * t[0] + k[1] * t[1] + k[2] * t[2];
                    float kx[3] = {k[1] * t[2] - k[2] * t[1], k[2] * t[0] - k[0] * t[2], k[0] * t[1] - k[1] * t[0]};
                    for (int j = 0; j < 3; j++) r[j] = t[j] * c + kx[j] * s + k[j] * kt * (1 - c);
                    memcpy(at, r, 12);
                }
            }
        }
        memcpy(out->data[pe->stream] + (size_t)v * in->stride[pe->stream] + pe->offset, p, 12);
        if (ne) memcpy(out->data[ne->stream] + (size_t)v * in->stride[ne->stream] + ne->offset, p + 3, 12);
        if (te) memcpy(out->data[te->stream] + (size_t)v * in->stride[te->stream] + te->offset, p + 6, 8);
    }
    if (wants_smooth(name)) {
        int n = smooth_colours(in, out, mv, nv);
        static int said;
        if (said++ < 8) fprintf(stderr, "[remodel] %s: %d colour element%s smoothed\n", name, n, n == 1 ? "" : "s");
    }
    out->nverts = nv;
    out->idx = mi;
    out->nidx = nt * 3;
    free(mv);
    return 1;
}

int prop_remodel(const struct prop_in *in, struct prop_out *out, char *name, size_t namelen)
{
    return remodel(in, out, name, namelen, 0);
}

int prop_remodel_brush(const struct prop_in *in, struct prop_out *out, char *name, size_t namelen)
{
    return remodel(in, out, name, namelen, 1);
}

int prop_remodel_brush_known(uint64_t key, uint32_t ntris)
{
    if (!loaded) load_list();
    struct entry k = {.key = key}, *e = nentries ? bsearch(&k, entries, nentries, sizeof *entries, by_key) : NULL;
    if (e)
        while (e > entries && e[-1].key == key) e--;
    for (; e && e < entries + nentries && e->key == key; e++)
        if (e->brush && e->ntris == ntris) return 1;
    return 0;
}

uint64_t prop_remodel_brush_key(const struct prop_in *in)
{
    const struct prop_elem *pe = find(in, 0, 2);
    if (!pe || !in->data[pe->stream]) return 0;
    for (uint32_t i = 0; i < in->ntris * 3; i++)
        if (in->idx[i] >= in->nverts[pe->stream]) return 0;
    return brush_key(in, pe);
}
