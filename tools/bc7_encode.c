// BC7 block encoder for tools/tex_pack.py (loaded with ctypes; the script builds it).
// Each block tries the modes that suit it and keeps the one with the smallest squared
// error: 6 (one line through RGBA, 4-bit indices), 1 (two colour lines over one of 64
// partitions, opaque blocks only, 3-bit indices) and 5 (colour and alpha on lines of their
// own, 2-bit indices, blocks with alpha only). A line's endpoints come from its pixels'
// principal axis and are then refined by least squares.
#include <math.h>
#include <stdint.h>
#include <string.h>

static const int W2[4] = {0, 21, 43, 64};
static const int W3[8] = {0, 9, 18, 27, 37, 46, 55, 64};
static const int W4[16] = {0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64};

// The two-subset partitions (pixel order, row by row) and each one's second anchor.
static const uint8_t PART2[64][16] = {
    {0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1}, {0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1},
    {0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1}, {0, 0, 0, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 1},
    {0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 1, 1}, {0, 0, 1, 1, 0, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1},
    {0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1}, {0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 0, 1, 1, 1},
    {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1}, {0, 0, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1},
    {0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1}, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 1, 1, 1},
    {0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}, {0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1},
    {0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1}, {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1},
    {0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1, 1}, {0, 1, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0}, {0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0},
    {0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0}, {0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0},
    {0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0}, {0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 1},
    {0, 0, 1, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0}, {0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0},
    {0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 0}, {0, 0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 1, 1, 0, 0},
    {0, 0, 0, 1, 0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0}, {0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0},
    {0, 1, 1, 1, 0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0}, {0, 0, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0},
    {0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1, 0, 1}, {0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1},
    {0, 1, 0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0}, {0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0},
    {0, 0, 1, 1, 1, 1, 0, 0, 0, 0, 1, 1, 1, 1, 0, 0}, {0, 1, 0, 1, 0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0},
    {0, 1, 1, 0, 1, 0, 0, 1, 0, 1, 1, 0, 1, 0, 0, 1}, {0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 1, 0, 0, 1, 0, 1},
    {0, 1, 1, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 1, 0}, {0, 0, 0, 1, 0, 0, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0},
    {0, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1, 0, 0}, {0, 0, 1, 1, 1, 0, 1, 1, 1, 1, 0, 1, 1, 1, 0, 0},
    {0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1, 0, 1, 1, 0}, {0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 1, 1},
    {0, 1, 1, 0, 0, 1, 1, 0, 1, 0, 0, 1, 1, 0, 0, 1}, {0, 0, 0, 0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 0, 0, 0},
    {0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0}, {0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0}, {0, 0, 0, 0, 0, 1, 0, 0, 1, 1, 1, 0, 0, 1, 0, 0},
    {0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 1}, {0, 0, 1, 1, 0, 1, 1, 0, 1, 1, 0, 0, 1, 0, 0, 1},
    {0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0}, {0, 0, 1, 1, 1, 0, 0, 1, 1, 1, 0, 0, 0, 1, 1, 0},
    {0, 1, 1, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 0, 0, 1}, {0, 1, 1, 0, 0, 0, 1, 1, 0, 0, 1, 1, 1, 0, 0, 1},
    {0, 1, 1, 1, 1, 1, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 1, 1, 0, 0, 0, 1, 1, 1, 0, 0, 1, 1, 1},
    {0, 0, 0, 0, 1, 1, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1}, {0, 0, 1, 1, 0, 0, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0},
    {0, 0, 1, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1, 1, 1, 0}, {0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 1, 0, 1, 1, 1},
};
static const uint8_t ANCHOR2[64] = {
    15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 15, 2, 8, 2, 2, 8, 8, 15, 2, 8, 2, 2, 8, 8, 2, 2,
    15, 15, 6, 8, 2, 8, 15, 15, 2, 8, 2, 2, 2, 15, 15, 6, 6, 2, 6, 8, 15, 15, 2, 2, 15, 15, 15, 15, 15, 2, 2, 15,
};

// How a mode stores an endpoint: 'bits' per channel, then a p-bit of its own (1), one
// shared by the subset's two endpoints (2) or none (0).
struct quant {
    int bits, pbit;
};

static int expand(int q, int p, struct quant Q)
{
    int b = Q.bits + (Q.pbit != 0), v = (Q.pbit ? q << 1 | p : q) << (8 - b);
    return v | v >> b;
}

static int quantise(float e, int p, struct quant Q)
{
    int top = (1 << Q.bits) - 1, q = (int)(e * top / 255.0f + 0.5f), best = 0;
    float bd = 1e30f;
    for (int c = q - 1; c <= q + 1; c++) {
        int cc = c < 0 ? 0 : c > top ? top : c;
        float d = fabsf(expand(cc, p, Q) - e);
        if (d < bd) bd = d, best = cc;
    }
    return best;
}

// One line through n pixels of 'ch' channels: the quantised endpoints q[2][4] and p-bits,
// each pixel's index and the squared error.
struct line {
    int q[2][4], p[2], idx[16];
    float err;
};

// Indices and error for the float endpoints e, trying the p-bits the mode allows.
static void place(const float (*px)[4], int n, int ch, const int *w, int nw, struct quant Q, const float e[2][4],
                  struct line *best)
{
    best->err = 1e30f;
    for (int pc = 0; pc < (Q.pbit == 1 ? 4 : Q.pbit == 2 ? 2 : 1); pc++) {
        struct line l;
        l.p[0] = pc & 1;
        l.p[1] = Q.pbit == 1 ? pc >> 1 : pc & 1;
        int v[2][4];
        for (int k = 0; k < 2; k++)
            for (int c = 0; c < ch; c++) v[k][c] = expand(l.q[k][c] = quantise(e[k][c], l.p[k], Q), l.p[k], Q);
        float pal[16][4];
        for (int j = 0; j < nw; j++)
            for (int c = 0; c < ch; c++) pal[j][c] = (float)(((64 - w[j]) * v[0][c] + w[j] * v[1][c] + 32) >> 6);
        l.err = 0;
        for (int i = 0; i < n; i++) {
            float bd = 1e30f;
            for (int j = 0; j < nw; j++) {
                float d = 0;
                for (int c = 0; c < ch; c++) d += (px[i][c] - pal[j][c]) * (px[i][c] - pal[j][c]);
                if (d < bd) bd = d, l.idx[i] = j;
            }
            l.err += bd;
        }
        if (l.err < best->err) *best = l;
    }
}

static void fit(const float (*px)[4], int n, int ch, int ibits, struct quant Q, struct line *out)
{
    const int *w = ibits == 2 ? W2 : ibits == 3 ? W3 : W4;
    int nw = 1 << ibits;
    float mean[4] = {0}, cov[4][4] = {{0}}, axis[4] = {1, 1, 1, 1}, e[2][4];
    for (int i = 0; i < n; i++)
        for (int c = 0; c < ch; c++) mean[c] += px[i][c] / n;
    for (int i = 0; i < n; i++)
        for (int a = 0; a < ch; a++)
            for (int b = 0; b < ch; b++) cov[a][b] += (px[i][a] - mean[a]) * (px[i][b] - mean[b]);
    for (int it = 0; it < 8; it++) {
        float t[4] = {0}, len = 0;
        for (int a = 0; a < ch; a++)
            for (int b = 0; b < ch; b++) t[a] += cov[a][b] * axis[b];
        for (int a = 0; a < ch; a++) len += t[a] * t[a];
        if (len < 1e-12f) break;
        len = 1 / sqrtf(len);
        for (int a = 0; a < ch; a++) axis[a] = t[a] * len;
    }
    float lo = 1e30f, hi = -1e30f;
    for (int i = 0; i < n; i++) {
        float t = 0;
        for (int c = 0; c < ch; c++) t += (px[i][c] - mean[c]) * axis[c];
        lo = t < lo ? t : lo;
        hi = t > hi ? t : hi;
    }
    for (int c = 0; c < ch; c++) {
        e[0][c] = fminf(255, fmaxf(0, mean[c] + lo * axis[c]));
        e[1][c] = fminf(255, fmaxf(0, mean[c] + hi * axis[c]));
    }
    place(px, n, ch, w, nw, Q, e, out);
    for (int it = 0; it < 3 && out->err > 0; it++) {  // least squares for the indices found
        float aa = 0, ab = 0, bb = 0, ax[4] = {0}, bx[4] = {0};
        for (int i = 0; i < n; i++) {
            float t = w[out->idx[i]] / 64.0f, s = 1 - t;
            aa += s * s, ab += s * t, bb += t * t;
            for (int c = 0; c < ch; c++) ax[c] += s * px[i][c], bx[c] += t * px[i][c];
        }
        float det = aa * bb - ab * ab;
        if (fabsf(det) < 1e-6f) break;
        for (int c = 0; c < ch; c++) {
            e[0][c] = fminf(255, fmaxf(0, (bb * ax[c] - ab * bx[c]) / det));
            e[1][c] = fminf(255, fmaxf(0, (aa * bx[c] - ab * ax[c]) / det));
        }
        struct line l;
        place(px, n, ch, w, nw, Q, e, &l);
        if (l.err >= out->err) break;
        *out = l;
    }
}

// The 128-bit block, written from its lowest bit up.
struct bits {
    uint8_t *b;
    int at;
};

static void put(struct bits *s, uint32_t v, int n)
{
    for (int i = 0; i < n; i++, s->at++)
        if (v >> i & 1) s->b[s->at >> 3] |= (uint8_t)(1 << (s->at & 7));
}

// An anchor pixel's index must have its top bit clear: swap the endpoints if not.
static void anchor(struct line *l, int n, int at, int ibits, int ch, int swap_p)
{
    int top = (1 << ibits) - 1;
    if (l->idx[at] <= top >> 1) return;
    for (int c = 0; c < ch; c++) {
        int t = l->q[0][c];
        l->q[0][c] = l->q[1][c];
        l->q[1][c] = t;
    }
    if (swap_p) {
        int t = l->p[0];
        l->p[0] = l->p[1];
        l->p[1] = t;
    }
    for (int i = 0; i < n; i++) l->idx[i] = top - l->idx[i];
}

static float mode6(const float px[16][4], uint8_t *out)
{
    struct line l;
    fit(px, 16, 4, 4, (struct quant){7, 1}, &l);
    anchor(&l, 16, 0, 4, 4, 1);
    struct bits s = {out, 0};
    memset(out, 0, 16);
    put(&s, 1 << 6, 7);
    for (int c = 0; c < 4; c++) put(&s, l.q[0][c], 7), put(&s, l.q[1][c], 7);
    put(&s, l.p[0], 1), put(&s, l.p[1], 1);
    for (int i = 0; i < 16; i++) put(&s, l.idx[i], i ? 4 : 3);
    return l.err;
}

static float mode5(const float px[16][4], uint8_t *out)
{
    float a[16][4];
    for (int i = 0; i < 16; i++) a[i][0] = px[i][3];
    struct line c, al;
    fit(px, 16, 3, 2, (struct quant){7, 0}, &c);
    fit(a, 16, 1, 2, (struct quant){8, 0}, &al);
    anchor(&c, 16, 0, 2, 3, 0);
    anchor(&al, 16, 0, 2, 1, 0);
    struct bits s = {out, 0};
    memset(out, 0, 16);
    put(&s, 1 << 5, 6);
    put(&s, 0, 2);  // no channel rotation
    for (int k = 0; k < 3; k++) put(&s, c.q[0][k], 7), put(&s, c.q[1][k], 7);
    put(&s, al.q[0][0], 8), put(&s, al.q[1][0], 8);
    for (int i = 0; i < 16; i++) put(&s, c.idx[i], i ? 2 : 1);
    for (int i = 0; i < 16; i++) put(&s, al.idx[i], i ? 2 : 1);
    return c.err + al.err;
}

// How far a partition's subsets are from lying on lines: the variance off each subset's
// principal axis.
static float spread(const float px[16][4], int part)
{
    float total = 0;
    for (int sub = 0; sub < 2; sub++) {
        float mean[3] = {0}, cov[3][3] = {{0}}, axis[3] = {1, 1, 1};
        int n = 0;
        for (int i = 0; i < 16; i++)
            if (PART2[part][i] == sub) {
                for (int c = 0; c < 3; c++) mean[c] += px[i][c];
                n++;
            }
        for (int c = 0; c < 3; c++) mean[c] /= n;
        for (int i = 0; i < 16; i++)
            if (PART2[part][i] == sub)
                for (int a = 0; a < 3; a++)
                    for (int b = 0; b < 3; b++) cov[a][b] += (px[i][a] - mean[a]) * (px[i][b] - mean[b]);
        float lambda = 0;
        for (int it = 0; it < 4; it++) {
            float t[3] = {0}, len = 0;
            for (int a = 0; a < 3; a++)
                for (int b = 0; b < 3; b++) t[a] += cov[a][b] * axis[b];
            for (int a = 0; a < 3; a++) len += t[a] * t[a];
            if (len < 1e-12f) break;
            lambda = sqrtf(len);
            for (int a = 0; a < 3; a++) axis[a] = t[a] / lambda;
        }
        total += cov[0][0] + cov[1][1] + cov[2][2] - lambda;
    }
    return total;
}

static float mode1(const float px[16][4], uint8_t *out)
{
    int cand[4] = {0, 1, 2, 3};
    float cs[4] = {1e30f, 1e30f, 1e30f, 1e30f};
    for (int p = 0; p < 64; p++) {  // the four partitions whose subsets lie closest to lines
        float s = spread(px, p);
        for (int k = 0; k < 4; k++)
            if (s < cs[k]) {
                for (int j = 3; j > k; j--) cs[j] = cs[j - 1], cand[j] = cand[j - 1];
                cs[k] = s, cand[k] = p;
                break;
            }
    }
    float best = 1e30f;
    for (int k = 0; k < 4; k++) {
        int part = cand[k], at[2] = {0, ANCHOR2[part]}, map[2][16], n[2] = {0, 0};
        float sp[2][16][4];
        for (int i = 0; i < 16; i++) {
            int sub = PART2[part][i];
            memcpy(sp[sub][n[sub]], px[i], sizeof px[i]);
            map[sub][n[sub]++] = i;
        }
        struct line l[2];
        float err = 0;
        for (int sub = 0; sub < 2; sub++) {
            fit(sp[sub], n[sub], 3, 3, (struct quant){6, 2}, &l[sub]);
            int a = 0;
            while (map[sub][a] != at[sub]) a++;
            anchor(&l[sub], n[sub], a, 3, 3, 0);
            err += l[sub].err;
        }
        if (err >= best) continue;
        best = err;
        int idx[16];
        for (int sub = 0; sub < 2; sub++)
            for (int j = 0; j < n[sub]; j++) idx[map[sub][j]] = l[sub].idx[j];
        struct bits s = {out, 0};
        memset(out, 0, 16);
        put(&s, 1 << 1, 2);
        put(&s, part, 6);
        for (int c = 0; c < 3; c++)
            for (int sub = 0; sub < 2; sub++) put(&s, l[sub].q[0][c], 6), put(&s, l[sub].q[1][c], 6);
        put(&s, l[0].p[0], 1), put(&s, l[1].p[0], 1);
        for (int i = 0; i < 16; i++) put(&s, idx[i], i == 0 || i == at[1] ? 2 : 3);
    }
    return best;
}

// rgba: w x h pixels, both multiples of 4; out: 16 bytes per block, row by row.
void bc7_encode(const uint8_t *rgba, int w, int h, uint8_t *out)
{
    for (int by = 0; by < h / 4; by++)
        for (int bx = 0; bx < w / 4; bx++, out += 16) {
            float px[16][4];
            int opaque = 1;
            for (int i = 0; i < 16; i++) {
                const uint8_t *s = rgba + ((size_t)(by * 4 + i / 4) * w + bx * 4 + i % 4) * 4;
                for (int c = 0; c < 4; c++) px[i][c] = s[c];
                opaque &= s[3] == 255;
            }
            uint8_t b[16];
            float err = mode6(px, out), e;
            if (err > 0 && (e = opaque ? mode1(px, b) : mode5(px, b)) < err) memcpy(out, b, 16);
        }
}
