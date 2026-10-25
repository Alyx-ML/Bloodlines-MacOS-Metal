// Props smoothed: see prop_smooth.h.
#include "prop_smooth.h"
#include <math.h>
#include <stdlib.h>
#include <string.h>

static int elem_size(int type)
{
    static const uint8_t size[17] = {4, 8, 12, 16, 4, 4, 4, 8, 4, 4, 8, 4, 8, 4, 4, 4, 8};
    return type >= 0 && type < 17 ? size[type] : 0;
}

// One element of a new vertex from the three corners' (c[k], weights w[k]); n the nearest.
static void lerp_elem(uint8_t *d, const uint8_t *const c[3], const float w[3], int n, const struct prop_elem *e)
{
    int t = e->type;
    if (t <= 3) {
        for (int i = 0; i <= t; i++) {
            float v = 0;
            for (int k = 0; k < 3; k++) {
                float f;
                memcpy(&f, c[k] + 4 * i, 4);
                v += w[k] * f;
            }
            memcpy(d + 4 * i, &v, 4);
        }
    } else if (t == 4 || t == 8 || (t == 5 && e->usage != 2)) {  // bytes; blend indices are not blended
        for (int i = 0; i < 4; i++) {
            float v = w[0] * c[0][i] + w[1] * c[1][i] + w[2] * c[2][i];
            d[i] = (uint8_t)fminf(255.0f, fmaxf(0.0f, v + 0.5f));
        }
    } else if (t == 6 || t == 7 || t == 9 || t == 10) {  // signed shorts
        for (int i = 0; i < (t == 7 || t == 10 ? 4 : 2); i++) {
            float v = 0;
            for (int k = 0; k < 3; k++) {
                int16_t s;
                memcpy(&s, c[k] + 2 * i, 2);
                v += w[k] * s;
            }
            int16_t s = (int16_t)lrintf(fminf(32767.0f, fmaxf(-32768.0f, v)));
            memcpy(d + 2 * i, &s, 2);
        }
    } else if (t == 11 || t == 12) {  // unsigned shorts
        for (int i = 0; i < (t == 12 ? 4 : 2); i++) {
            float v = 0;
            for (int k = 0; k < 3; k++) {
                uint16_t s;
                memcpy(&s, c[k] + 2 * i, 2);
                v += w[k] * s;
            }
            uint16_t s = (uint16_t)lrintf(fminf(65535.0f, fmaxf(0.0f, v)));
            memcpy(d + 2 * i, &s, 2);
        }
    } else if (t == 15 || t == 16) {  // halves
        for (int i = 0; i < (t == 16 ? 4 : 2); i++) {
            float v = 0;
            for (int k = 0; k < 3; k++) {
                __fp16 h;
                memcpy(&h, c[k] + 2 * i, 2);
                v += w[k] * (float)h;
            }
            __fp16 h = (__fp16)v;
            memcpy(d + 2 * i, &h, 2);
        }
    } else {
        memcpy(d, c[n], (size_t)elem_size(t));
    }
}

struct key { int64_t q[3]; uint32_t v; };

static int key_cmp(const void *a, const void *b)
{
    const struct key *x = a, *y = b;
    for (int i = 0; i < 3; i++)
        if (x->q[i] != y->q[i]) return x->q[i] < y->q[i] ? -1 : 1;
    return x->v < y->v ? -1 : x->v > y->v;
}

static float dot3(const float *a, const float *b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }

// The surfaces meeting at a position: an orthonormal basis of their normals (0 to 3).
struct basis { int n; float b[3][3]; };

int prop_smooth(const struct prop_in *in, struct prop_out *out)
{
    memset(out, 0, sizeof *out);
    const struct prop_elem *pe = NULL, *ne = NULL;
    for (int i = 0; i < in->nel; i++) {
        if (in->el[i].usage == 0 && in->el[i].index == 0 && in->el[i].type == 2) pe = &in->el[i];
        if (in->el[i].usage == 3 && in->el[i].index == 0 && in->el[i].type == 2) ne = &in->el[i];
    }
    if (!pe || !ne || in->split < 2 || !in->ntris) return -1;
    int ps = pe->stream, ns = ne->stream;
    uint32_t nv = in->nverts[ps] < in->nverts[ns] ? in->nverts[ps] : in->nverts[ns];
    for (uint32_t i = 0; i < 3 * in->ntris; i++)
        if (in->idx[i] >= nv) return -1;
    for (int i = 0; i < in->nel; i++) {
        int s = in->el[i].stream;
        if (s >= 16 || !in->data[s] || in->el[i].offset + elem_size(in->el[i].type) > (int)in->stride[s]) return -1;
        for (uint32_t k = 0; k < 3 * in->ntris; k++)
            if (in->idx[k] >= in->nverts[s]) return -1;
    }
#define POS(v) ((const float *)(in->data[ps] + (size_t)(v) * in->stride[ps] + pe->offset))
#define NRM(v) ((const float *)(in->data[ns] + (size_t)(v) * in->stride[ns] + ne->offset))

    // The vertices used, grouped by position (to within a ten-thousandth of the mesh's size).
    float lo[3] = {INFINITY, INFINITY, INFINITY}, hi[3] = {-INFINITY, -INFINITY, -INFINITY};
    for (uint32_t i = 0; i < 3 * in->ntris; i++)
        for (int a = 0; a < 3; a++) lo[a] = fminf(lo[a], POS(in->idx[i])[a]), hi[a] = fmaxf(hi[a], POS(in->idx[i])[a]);
    float size = sqrtf((hi[0] - lo[0]) * (hi[0] - lo[0]) + (hi[1] - lo[1]) * (hi[1] - lo[1]) + (hi[2] - lo[2]) * (hi[2] - lo[2]));
    if (!(size > 0) || !isfinite(size)) return -1;
    float q = size * 1e-4f;
    struct key *keys = malloc(sizeof *keys * 3 * in->ntris);
    int32_t *group = malloc(sizeof *group * nv);
    if (!keys || !group) return free(keys), free(group), -1;
    for (uint32_t i = 0; i < nv; i++) group[i] = -1;
    uint32_t nk = 0;
    for (uint32_t i = 0; i < 3 * in->ntris; i++) {
        uint32_t v = in->idx[i];
        if (group[v] == -2) continue;
        group[v] = -2;
        const float *p = POS(v);
        keys[nk++] = (struct key){{llrintf(p[0] / q), llrintf(p[1] / q), llrintf(p[2] / q)}, v};
    }
    qsort(keys, nk, sizeof *keys, key_cmp);
    struct basis *bases = malloc(sizeof *bases * (nk ? nk : 1));
    uint32_t ng = 0;
    for (uint32_t i = 0; i < nk;) {
        uint32_t j = i;
        while (j < nk && !memcmp(keys[j].q, keys[i].q, sizeof keys[i].q)) j++;
        // Its normals in clusters (within about 25 degrees), each cluster's mean.
        float c[8][3];
        int ncl = 0;
        for (uint32_t k = i; k < j; k++) {
            const float *n0 = NRM(keys[k].v);
            float l = sqrtf(dot3(n0, n0)), n[3];
            if (!(l > 1e-6f)) continue;
            for (int a = 0; a < 3; a++) n[a] = n0[a] / l;
            int m = 0;
            for (; m < ncl; m++) {
                float cl = sqrtf(dot3(c[m], c[m]));
                if (dot3(c[m], n) > 0.9f * cl) break;
            }
            if (m == ncl && ncl == 8) continue;
            if (m == ncl) memset(c[ncl++], 0, sizeof c[0]);
            for (int a = 0; a < 3; a++) c[m][a] += n[a];
        }
        struct basis *B = &bases[ng];
        B->n = 0;
        for (int m = 0; m < ncl && B->n < 3; m++) {
            float r[3] = {c[m][0], c[m][1], c[m][2]};
            float l0 = sqrtf(dot3(r, r));
            if (!(l0 > 1e-6f)) continue;
            for (int a = 0; a < 3; a++) r[a] /= l0;
            for (int b = 0; b < B->n; b++) {
                float d = dot3(r, B->b[b]);
                for (int a = 0; a < 3; a++) r[a] -= d * B->b[b][a];
            }
            float l = sqrtf(dot3(r, r));
            if (l < 0.3f) continue;  // nearly in the span already
            for (int a = 0; a < 3; a++) B->b[B->n][a] = r[a] / l;
            B->n++;
        }
        if (B->n >= 2) out->sharp += j - i;
        for (uint32_t k = i; k < j; k++) group[keys[k].v] = (int32_t)ng;
        ng++;
        i = j;
    }
    free(keys);

    // Each triangle split into split^2, its points moved three quarters of the way to
    // where its corners' surfaces put them.
    int F = in->split, NV = (F + 1) * (F + 2) / 2;
    uint32_t lidx[17][17];
    for (int i = 0, n = 0; i <= F; i++)
        for (int j = 0; j <= F - i; j++) lidx[i][j] = (uint32_t)n++;
    out->nverts = in->ntris * (uint32_t)NV;
    out->nidx = in->ntris * (uint32_t)(F * F) * 3;
    out->idx = malloc(sizeof *out->idx * out->nidx);
    int used[16] = {0};
    for (int i = 0; i < in->nel; i++) used[in->el[i].stream] = 1;
    for (int s = 0; s < 16; s++)
        if (used[s]) out->data[s] = malloc((size_t)out->nverts * in->stride[s]);
    for (int s = 0; s < 16; s++)
        if (used[s] && !out->data[s]) out->idx = (free(out->idx), NULL);
    if (!out->idx) return free(group), free(bases), prop_smooth_free(out), -1;

    uint32_t *oi = out->idx;
    for (uint32_t t = 0; t < in->ntris; t++) {
        const uint32_t *tv = &in->idx[3 * t];
        const float *P[3] = {POS(tv[0]), POS(tv[1]), POS(tv[2])};
        const struct basis *B[3] = {&bases[group[tv[0]]], &bases[group[tv[1]]], &bases[group[tv[2]]]};
        float e = 0;
        for (int k = 0; k < 3; k++) {
            const float *a = P[k], *b = P[(k + 1) % 3];
            float d[3] = {b[0] - a[0], b[1] - a[1], b[2] - a[2]};
            e = fmaxf(e, sqrtf(dot3(d, d)));
        }
        for (int i = 0; i <= F; i++)
            for (int j = 0; j <= F - i; j++) {
                float w[3] = {(float)(F - i - j) / F, (float)i / F, (float)j / F};
                int n = w[0] >= w[1] && w[0] >= w[2] ? 0 : w[1] >= w[2] ? 1 : 2;
                float X[3], Q[3] = {0, 0, 0};
                for (int a = 0; a < 3; a++) X[a] = w[0] * P[0][a] + w[1] * P[1][a] + w[2] * P[2][a];
                for (int k = 0; k < 3; k++) {
                    float d[3] = {X[0] - P[k][0], X[1] - P[k][1], X[2] - P[k][2]}, r[3] = {X[0], X[1], X[2]};
                    for (int b = 0; b < B[k]->n; b++) {
                        float s = dot3(d, B[k]->b[b]);
                        for (int a = 0; a < 3; a++) r[a] -= s * B[k]->b[b][a];
                    }
                    for (int a = 0; a < 3; a++) Q[a] += w[k] * r[a];
                }
                float Y[3], D2 = 0;
                for (int a = 0; a < 3; a++) Y[a] = X[a] + 0.75f * (Q[a] - X[a]), D2 += (Y[a] - X[a]) * (Y[a] - X[a]);
                if (e > 0) out->moved = fmaxf(out->moved, sqrtf(D2) / e);
                uint32_t ov = t * (uint32_t)NV + lidx[i][j];
                for (int s = 0; s < 16; s++) {
                    if (!used[s]) continue;
                    uint8_t *d = out->data[s] + (size_t)ov * in->stride[s];
                    const uint8_t *c[3];
                    for (int k = 0; k < 3; k++) c[k] = in->data[s] + (size_t)tv[k] * in->stride[s];
                    memcpy(d, c[n], in->stride[s]);
                    for (int x = 0; x < in->nel; x++) {
                        const struct prop_elem *el = &in->el[x];
                        if (el->stream != s) continue;
                        const uint8_t *cc[3] = {c[0] + el->offset, c[1] + el->offset, c[2] + el->offset};
                        lerp_elem(d + el->offset, cc, w, n, el);
                        if (el == pe) memcpy(d + el->offset, Y, 12);
                        if (el == ne) {
                            float *nn = (float *)(d + el->offset), l = sqrtf(dot3(nn, nn));
                            if (l > 1e-6f)
                                for (int a = 0; a < 3; a++) nn[a] /= l;
                        }
                    }
                }
            }
        uint32_t base = t * (uint32_t)NV;
        for (int i = 0; i < F; i++)
            for (int j = 0; j < F - i; j++) {
                *oi++ = base + lidx[i][j], *oi++ = base + lidx[i + 1][j], *oi++ = base + lidx[i][j + 1];
                if (i + j < F - 1)
                    *oi++ = base + lidx[i + 1][j], *oi++ = base + lidx[i + 1][j + 1], *oi++ = base + lidx[i][j + 1];
            }
    }
    free(group), free(bases);
    return 0;
#undef POS
#undef NRM
}

void prop_smooth_free(struct prop_out *out)
{
    for (int s = 0; s < 16; s++) free(out->data[s]);
    free(out->idx);
    memset(out, 0, sizeof *out);
}
