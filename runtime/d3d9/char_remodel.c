#include "char_remodel.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// How far (model units) a draw's vertex may be from its anchor: the file's anchors are
// the model's own positions, so only float rounding.
#define CHAR_TOL 0.05f

struct bl_body_mesh *char_mesh_parse(const void *bytes, size_t len, const char *path)
{
    const uint32_t *h = bytes;
    if (len < 36 || memcmp(h, "BLBM", 4) || h[1] != 4) {
        fprintf(stderr, "[char] %s is not a character mesh (BLBM version 4): made again by tools/bodies/export_game_mesh.py\n",
                path);
        return NULL;
    }
    uint32_t nv = h[2], ni = h[3], na = h[4], nb = h[5], nk = h[6], nbones = h[7], nst = h[8];
    size_t need = 36 + (size_t)nv * sizeof(struct bl_body_vertex) + (size_t)ni * 4 + (size_t)ni / 3 * 4 + (size_t)na * 12 + (size_t)nb * 16 +
                  (size_t)nk * 12 + (size_t)na * sizeof(struct bl_body_skin) + (size_t)nbones * 4 + (size_t)nst * 64;
    if (len != need || ni % 3 || nbones > 256) {
        fprintf(stderr, "[char] %s: %zu bytes, %zu expected for its counts\n", path, len, need);
        return NULL;
    }
    struct bl_body_mesh *m = calloc(1, sizeof *m);
    uint8_t *copy = malloc(len - 36 + 1);
    memcpy(copy, (const uint8_t *)bytes + 36, len - 36);
    m->nverts = nv, m->nidx = ni, m->nanchors = na, m->nbinds = nb, m->nkept = nk, m->nbones = nbones, m->nstrips = nst;
    m->verts = (const struct bl_body_vertex *)copy;
    m->idx = (const uint32_t *)(copy + (size_t)nv * sizeof(struct bl_body_vertex));
    m->owner = m->idx + ni;
    m->anchors = (const float(*)[3])((const uint8_t *)m->owner + (size_t)ni / 3 * 4);
    m->binds = (const uint32_t(*)[3])((const uint8_t *)m->anchors + (size_t)na * 12);
    m->bind_strip = (const uint32_t *)((const uint8_t *)m->binds + (size_t)nb * 12);
    m->kept = (const float(*)[3])(m->bind_strip + nb);
    m->skin = (const struct bl_body_skin *)((const uint8_t *)m->kept + (size_t)nk * 12);
    m->parent = (const int32_t *)((const uint8_t *)m->skin + (size_t)na * sizeof(struct bl_body_skin));
    m->slots = (const int16_t(*)[32])(m->parent + nbones);
    int bad = 0;
    for (uint32_t i = 0; i < ni; i++) bad |= m->idx[i] >= nv;
    for (uint32_t i = 0; i < ni / 3; i++) bad |= m->owner[i] >= nb;
    for (uint32_t i = 0; i < nv; i++) {
        bad |= m->verts[i].bind >= nb;
        for (int j = 0; j < 4; j++) bad |= m->verts[i].bones[j] >= nbones;
    }
    for (uint32_t i = 0; i < nb; i++)
        bad |= m->binds[i][0] >= na || m->binds[i][1] >= na || m->binds[i][2] >= na ||
               (m->bind_strip[i] >= nst && m->bind_strip[i] != UINT32_MAX);
    for (uint32_t i = 0; i < nst * 32; i++) bad |= m->slots[i / 32][i % 32] >= (int)nbones;
    for (uint32_t i = 0; i < na; i++)
        for (int j = 0; j < 4; j++) bad |= m->skin[i].bones[j] >= nbones;
    for (uint32_t i = 0; i < nbones; i++) bad |= m->parent[i] >= (int32_t)i;  // parents come first
    if (bad) {
        fprintf(stderr, "[char] %s: a number past its table\n", path);
        free(copy), free(m);
        return NULL;
    }
    return m;
}

static const struct prop_elem *find(const struct prop_in *in, int usage, int type)
{
    for (int i = 0; i < in->nel; i++)
        if (in->el[i].usage == usage && in->el[i].index == 0 && (type < 0 || in->el[i].type == type)) return &in->el[i];
    return NULL;
}

static const uint8_t *elem(const struct prop_in *in, const struct prop_elem *e, uint32_t v)
{
    return in->data[e->stream] + (size_t)v * in->stride[e->stream] + e->offset;
}

static float dist2(const float *a, const float *b)
{
    float x = a[0] - b[0], y = a[1] - b[1], z = a[2] - b[2];
    return x * x + y * y + z * z;
}

// Bone weights and slots as the vertex shader reads them: a D3DCOLOR's bytes are BGRA in
// memory, so its x is byte 2, but the game's shaders swizzle bone slots back
// (D3DCOLORtoUBYTE4), so slot s is byte s either way; weights as colours go by component.
static const int color_byte[4] = {2, 1, 0, 3};

struct skin {
    const struct prop_elem *we, *ie;
    int nw;      // weights stored
    int nslots;  // bones per vertex: nw, or nw + 1 when the last weight is 1 less the rest
};

static void skin_read(const struct prop_in *in, const struct skin *k, uint32_t v, int bone[4], float w[4])
{
    const uint8_t *ib = elem(in, k->ie, v);
    float sum = 0;
    for (int s = 0; s < 4; s++) {
        bone[s] = ib[s];
        w[s] = 0;
        if (s < k->nw) {
            const uint8_t *wb = elem(in, k->we, v);
            if (k->we->type <= 3)
                memcpy(&w[s], wb + 4 * s, 4);
            else
                w[s] = wb[k->we->type == 4 ? color_byte[s] : s] / 255.0f;
            sum += w[s];
        }
    }
    if (k->nslots > k->nw) w[k->nw] = 1 - sum;
    if (!k->nw) w[0] = 1;
}

static void skin_write(const struct prop_in *in, const struct skin *k, uint8_t *rec_i, uint8_t *rec_w, const int bone[4],
                       const float w[4])
{
    for (int s = 0; s < k->nslots; s++) rec_i[s] = (uint8_t)bone[s];
    for (int s = 0; s < k->nw; s++) {
        if (k->we->type <= 3)
            memcpy(rec_w + 4 * s, &w[s], 4);
        else
            rec_w[k->we->type == 4 ? color_byte[s] : s] = (uint8_t)fminf(255, w[s] * 255 + 0.5f);
    }
}

int char_remodel(const struct prop_in *in, const struct bl_body_mesh *m, const char *name, struct prop_out *out)
{
    memset(out, 0, sizeof *out);
    const struct prop_elem *pe = find(in, 0, 2), *ne = find(in, 3, 2), *te = find(in, 5, 1);
    struct skin k = {find(in, 1, -1), find(in, 2, -1), 0, 0};
    static char said[64][256];
    static int nsaid;
    int known = 0;
    for (int i = 0; i < nsaid && !known; i++) known = !strcmp(said[i], name);
#define REFUSE(...)                                                                                       \
    do {                                                                                                  \
        if (!known && nsaid < 64) snprintf(said[nsaid++], sizeof said[0], "%s", name),                    \
                                  fprintf(stderr, "[char] %s: ", name), fprintf(stderr, __VA_ARGS__);     \
        return 0;                                                                                         \
    } while (0)
    if (!pe || !ne || !te) REFUSE("the draw has no float3 position and normal or float2 UV, not drawn\n");
    if (!k.ie || (k.ie->type != 4 && k.ie->type != 5)) REFUSE("bone slots not as bytes, not drawn\n");
    if (k.we) {
        k.nw = k.we->type <= 3 ? k.we->type + 1 : (k.we->type == 4 || k.we->type == 8) ? 4 : -1;
        if (k.nw < 0) REFUSE("bone weights of type %d, not drawn\n", k.we->type);
    }
    uint32_t high = 0;
    for (uint32_t i = 0; i < in->ntris * 3; i++) {
        for (int b = 0; b < 16; b++)
            if (in->data[b] && in->idx[i] >= in->nverts[b]) REFUSE("a triangle past the vertex buffer\n");
        high = in->idx[i] > high ? in->idx[i] : high;
    }

    // The draw's vertices, and each anchor's nearest of them.
    uint32_t *dv = malloc(sizeof *dv * (in->ntris * 3 + 1)), nd = 0;
    uint8_t *seen = calloc(high + 1, 1);
    for (uint32_t i = 0; i < in->ntris * 3; i++)
        if (!seen[in->idx[i]]) seen[in->idx[i]] = 1, dv[nd++] = in->idx[i];
    free(seen);
    float *dmin = malloc(sizeof *dmin * (nd + 1)), *amin = malloc(sizeof *amin * (m->nanchors + 1));
    uint32_t *anear = malloc(sizeof *anear * (m->nanchors + 1));
    for (uint32_t j = 0; j < nd; j++) dmin[j] = INFINITY;
    for (uint32_t a = 0; a < m->nanchors; a++) {
        amin[a] = INFINITY, anear[a] = dv[0];
        for (uint32_t j = 0; j < nd; j++) {
            float d = dist2(m->anchors[a], (const float *)elem(in, pe, dv[j]));
            if (d < amin[a]) amin[a] = d, anear[a] = dv[j];
            if (d < dmin[j]) dmin[j] = d;
        }
    }
    uint32_t worst = 0;
    for (uint32_t j = 1; j < nd; j++) worst = dmin[j] > dmin[worst] ? j : worst;
    if (!nd || dmin[worst] > CHAR_TOL * CHAR_TOL) {
        const float *p = (const float *)elem(in, pe, dv[worst]);
        float d = sqrtf(dmin[worst]);
        free(dv), free(dmin), free(amin), free(anear);
        REFUSE("the draw's vertex at %g %g %g is %g from the model the mesh was made for, not drawn\n", p[0], p[1], p[2], d);
    }
    free(dmin);
    // Weights stored for every bone but the last (implied) when some vertex's add up to
    // less than 1.
    k.nslots = k.nw ? k.nw : 1;
    if (k.nw && k.nw < 4)
        for (uint32_t j = 0; j < nd && k.nslots == k.nw; j++) {
            int bone[4];
            float w[4], sum = 0;
            skin_read(in, &k, dv[j], bone, w);
            for (int s = 0; s < k.nw; s++) sum += w[s];
            if (sum < 0.99f) k.nslots = k.nw + 1;
        }

    // The bindings whose triangle this draw has (by its centre), and so its strip.
    float(*tc)[3] = malloc(sizeof *tc * (in->ntris + 1));
    for (uint32_t t = 0; t < in->ntris; t++)
        for (int c = 0; c < 3; c++) {
            float s = 0;
            for (int j = 0; j < 3; j++) s += ((const float *)elem(in, pe, in->idx[3 * t + j]))[c];
            tc[t][c] = s / 3;
        }
    uint8_t *ours = calloc(m->nbinds + 1, 1);
    uint32_t svotes[256] = {0}, strip = 0;
    for (uint32_t b = 0; b < m->nbinds; b++) {
        const uint32_t *a = m->binds[b];
        if (amin[a[0]] > CHAR_TOL * CHAR_TOL || amin[a[1]] > CHAR_TOL * CHAR_TOL || amin[a[2]] > CHAR_TOL * CHAR_TOL) continue;
        float c[3];
        for (int j = 0; j < 3; j++) c[j] = (m->anchors[a[0]][j] + m->anchors[a[1]][j] + m->anchors[a[2]][j]) / 3;
        for (uint32_t t = 0; t < in->ntris && !ours[b]; t++) ours[b] = dist2(c, tc[t]) < CHAR_TOL * CHAR_TOL;
        if (ours[b] && m->bind_strip[b] < 256) svotes[m->bind_strip[b]]++;
    }
    for (uint32_t i = 1; i < m->nstrips && i < 256; i++) strip = svotes[i] > svotes[strip] ? i : strip;
    if (!svotes[strip]) {
        free(tc), free(ours), free(dv), free(amin), free(anear);
        REFUSE("none of the file's triangles in the draw, not drawn\n");
    }

    // Which slot holds which of the model's bones: the strip's, checked against the draw's
    // vertices (each slot an anchor weights holds the anchor's bone of that weight).
    int slot[256];
    for (int r = 0; r < 256; r++) slot[r] = -1;
    for (int hw = 0; hw < 32; hw++)
        if (m->slots[strip][hw] >= 0) slot[m->slots[strip][hw]] = hw;
    uint32_t checked = 0, wrong = 0;
    for (uint32_t a = 0; a < m->nanchors; a++) {
        if (amin[a] > CHAR_TOL * CHAR_TOL) continue;
        int hb[4];
        float hw[4];
        skin_read(in, &k, anear[a], hb, hw);
        for (int s = 0; s < k.nslots; s++) {
            if (hw[s] <= 0.02f) continue;
            int bone = hb[s] < 32 ? m->slots[strip][hb[s]] : -1, own = 0;
            float w = 0;
            for (int j = 0; j < 4; j++) w += m->skin[a].bones[j] == bone ? m->skin[a].w[j] : 0;
            own = fabsf(w - hw[s]) < 0.03f;
            checked++, wrong += !own;
        }
    }
    free(amin);
    if (wrong * 100 > checked) {
        free(tc), free(ours), free(dv), free(anear);
        REFUSE("the draw's bone slots are not strip %u's (%u of %u wrong), not drawn\n", strip, wrong, checked);
    }
    int loaded = 0;
    for (int r = 0; r < 256; r++) loaded += slot[r] >= 0;

    // The new triangles of this draw, then the game's it keeps.
    uint32_t *vmap = malloc(sizeof *vmap * (m->nverts + 1)), nv = 0;
    for (uint32_t v = 0; v < m->nverts; v++) vmap[v] = UINT32_MAX;
    uint32_t *idx = malloc(sizeof *idx * (m->nidx + 3 * in->ntris + 1)), ni = 0;
    for (uint32_t t = 0; t < m->nidx / 3; t++) {
        if (!ours[m->owner[t]]) continue;
        for (int c = 0; c < 3; c++) {
            uint32_t v = m->idx[3 * t + c];
            if (vmap[v] == UINT32_MAX) vmap[v] = nv++;
            idx[ni++] = vmap[v];
        }
    }
    free(ours);
    uint32_t *keep = malloc(sizeof *keep * (in->ntris * 3 + 1)), nkeep = 0;
    for (uint32_t t = 0; t < in->ntris; t++) {
        int hit = 0;
        for (uint32_t q = 0; q < m->nkept && !hit; q++) hit = dist2(m->kept[q], tc[t]) < CHAR_TOL * CHAR_TOL;
        if (hit)
            for (int c = 0; c < 3; c++) keep[nkeep++] = in->idx[3 * t + c];
    }
    free(tc);
    uint32_t nnew = nv, moved = 0, unloaded = 0;
    nv += nkeep;  // the kept triangles' corners copied as they are, one each
    for (int b = 0; b < 16; b++)
        if (in->data[b]) out->data[b] = calloc(nv ? nv : 1, in->stride[b]);
    for (uint32_t v = 0; v < m->nverts; v++) {
        if (vmap[v] == UINT32_MAX) continue;
        const struct bl_body_vertex *s = &m->verts[v];
        const uint32_t *a = m->binds[s->bind];
        int near = s->bary[1] > s->bary[0] ? (s->bary[2] > s->bary[1] ? 2 : 1) : (s->bary[2] > s->bary[0] ? 2 : 0);
        uint32_t o = vmap[v], base = anear[a[near]];
        for (int b = 0; b < 16; b++)
            if (out->data[b])
                memcpy(out->data[b] + (size_t)o * in->stride[b], in->data[b] + (size_t)base * in->stride[b], in->stride[b]);
        memcpy(out->data[pe->stream] + (size_t)o * in->stride[pe->stream] + pe->offset, s->pos, 12);
        memcpy(out->data[ne->stream] + (size_t)o * in->stride[ne->stream] + ne->offset, s->nrm, 12);
        memcpy(out->data[te->stream] + (size_t)o * in->stride[te->stream] + te->offset, s->uv, 8);
        // Bones: the vertex's own, each in the slot the draw loaded it in (or its nearest
        // loaded parent's), the strongest kept.
        int slots[4], ns = 0, bone[4] = {0};
        float wts[4], w[4] = {0}, sum = 0;
        for (int j = 0; j < 4; j++) {
            if (s->w[j] <= 0) continue;
            int r = s->bones[j];
            while (r >= 0 && slot[r] < 0) r = m->parent[r];
            int hw;
            if (r >= 0) {
                hw = slot[r];
                moved += r != s->bones[j];
            } else {  // nor any parent: the nearest corner's strongest
                int cb[4];
                float cw[4];
                skin_read(in, &k, base, cb, cw);
                hw = cb[0];
                unloaded++;
            }
            int i = 0;
            while (i < ns && slots[i] != hw) i++;
            if (i == ns) slots[ns] = hw, wts[ns++] = 0;
            wts[i] += s->w[j];
        }
        for (int sl = 0; sl < k.nslots; sl++) {
            int best = -1;
            for (int j = 0; j < ns; j++)
                if (wts[j] > 0 && (best < 0 || wts[j] > wts[best])) best = j;
            if (best < 0) {
                bone[sl] = bone[0];
                continue;
            }
            bone[sl] = slots[best], w[sl] = wts[best], sum += wts[best], wts[best] = -1;
        }
        for (int sl = 0; sl < k.nslots; sl++) w[sl] = sum > 0 ? w[sl] / sum : (sl == 0);
        uint8_t *ri = out->data[k.ie->stream] + (size_t)o * in->stride[k.ie->stream] + k.ie->offset;
        uint8_t *rw = k.we ? out->data[k.we->stream] + (size_t)o * in->stride[k.we->stream] + k.we->offset : NULL;
        skin_write(in, &k, ri, rw, bone, w);
    }
    for (uint32_t i = 0; i < nkeep; i++) {
        for (int b = 0; b < 16; b++)
            if (out->data[b])
                memcpy(out->data[b] + (size_t)(nnew + i) * in->stride[b], in->data[b] + (size_t)keep[i] * in->stride[b],
                       in->stride[b]);
        idx[ni++] = nnew + i;
    }
    free(keep), free(vmap), free(dv), free(anear);
    out->nverts = nv;
    out->idx = idx;
    out->nidx = ni;
    fprintf(stderr,
            "[char] %s: %u of the game's triangles drawn as %u new, %u kept (%d bones a vertex%s; strip %u, %d bones, "
            "%u of %u slots checked wrong, %u weights on a parent, %u on none)\n",
            name, in->ntris, (ni - nkeep) / 3, nkeep / 3, k.nslots, k.nslots > k.nw && k.nw ? ", the last implied" : "",
            strip, loaded, wrong, checked, moved, unloaded);
#undef REFUSE
    return 1;
}
