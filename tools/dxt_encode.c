// DXT1/3/5 block encoder for tools/tex_pack.py (loaded with ctypes; the script builds it).
// Colour endpoints come from the block's principal axis and are then refined by least
// squares; alpha (DXT5) uses the block's range with eight steps.
#include <stdint.h>
#include <string.h>

static int q565(const float *c)
{
    int r = (int)(c[0] * 31.0f / 255.0f + 0.5f), g = (int)(c[1] * 63.0f / 255.0f + 0.5f),
        b = (int)(c[2] * 31.0f / 255.0f + 0.5f);
    r = r < 0 ? 0 : r > 31 ? 31 : r;
    g = g < 0 ? 0 : g > 63 ? 63 : g;
    b = b < 0 ? 0 : b > 31 ? 31 : b;
    return r << 11 | g << 5 | b;
}

static void un565(int c, float *o)
{
    o[0] = (float)((c >> 11 & 31) * 255 / 31);
    o[1] = (float)((c >> 5 & 63) * 255 / 63);
    o[2] = (float)((c & 31) * 255 / 31);
}

// Palette and indices for endpoints c0, c1; returns the squared error. 'three' is the
// three-colour mode (c0 <= c1), whose index 3 is transparent black.
static float fit(const float px[16][3], const int *use, int c0, int c1, int three, uint32_t *idx)
{
    float p[4][3], a[3], b[3];
    un565(c0, a);
    un565(c1, b);
    for (int k = 0; k < 3; k++) {
        p[0][k] = a[k];
        p[1][k] = b[k];
        if (three) {
            p[2][k] = (a[k] + b[k]) / 2;
            p[3][k] = 0;
        } else {
            p[2][k] = (2 * a[k] + b[k]) / 3;
            p[3][k] = (a[k] + 2 * b[k]) / 3;
        }
    }
    float err = 0;
    *idx = 0;
    for (int i = 0; i < 16; i++) {
        int best = 3;
        if (use[i]) {
            float bd = 1e30f;
            for (int j = 0; j < (three ? 3 : 4); j++) {
                float d = 0;
                for (int k = 0; k < 3; k++) d += (px[i][k] - p[j][k]) * (px[i][k] - p[j][k]);
                if (d < bd) bd = d, best = j;
            }
            err += bd;
        }
        *idx |= (uint32_t)best << (2 * i);
    }
    return err;
}

// Least-squares endpoints for the current indices.
static int refine(const float px[16][3], const int *use, uint32_t idx, int three, float *e0, float *e1)
{
    static const float w4[4] = {1, 0, 2.0f / 3, 1.0f / 3}, w3[3] = {1, 0, 0.5f};
    float aa = 0, ab = 0, bb = 0, ax[3] = {0}, bx[3] = {0};
    for (int i = 0; i < 16; i++) {
        int j = idx >> (2 * i) & 3;
        if (!use[i] || (three && j == 3)) continue;
        float a = three ? w3[j] : w4[j], b = 1 - a;
        aa += a * a, ab += a * b, bb += b * b;
        for (int k = 0; k < 3; k++) ax[k] += a * px[i][k], bx[k] += b * px[i][k];
    }
    float det = aa * bb - ab * ab;
    if (det < 1e-6f) return 0;
    for (int k = 0; k < 3; k++) {
        e0[k] = (ax[k] * bb - bx[k] * ab) / det;
        e1[k] = (bx[k] * aa - ax[k] * ab) / det;
    }
    return 1;
}

// One colour block. 'punch' allows DXT1's transparent pixels (alpha < 128).
static void color_block(const uint8_t *rgba, int stride, int punch, uint8_t *out)
{
    float px[16][3];
    int use[16], n = 0, any_clear = 0;
    float mean[3] = {0};
    for (int i = 0; i < 16; i++) {
        const uint8_t *s = rgba + (i / 4) * stride + (i % 4) * 4;
        for (int k = 0; k < 3; k++) px[i][k] = s[k];
        use[i] = !(punch && s[3] < 128);
        any_clear |= !use[i];
        if (use[i]) {
            for (int k = 0; k < 3; k++) mean[k] += px[i][k];
            n++;
        }
    }
    uint32_t idx;
    if (!n) {  // all transparent
        out[0] = out[1] = 0, out[2] = out[3] = 0;
        idx = 0xffffffffu;
        memcpy(out + 4, &idx, 4);
        return;
    }
    for (int k = 0; k < 3; k++) mean[k] /= (float)n;
    float cov[6] = {0};
    for (int i = 0; i < 16; i++) {
        if (!use[i]) continue;
        float r = px[i][0] - mean[0], g = px[i][1] - mean[1], b = px[i][2] - mean[2];
        cov[0] += r * r, cov[1] += r * g, cov[2] += r * b, cov[3] += g * g, cov[4] += g * b, cov[5] += b * b;
    }
    float ax[3] = {0.577f, 0.577f, 0.577f};
    for (int it = 0; it < 8; it++) {
        float x = cov[0] * ax[0] + cov[1] * ax[1] + cov[2] * ax[2];
        float y = cov[1] * ax[0] + cov[3] * ax[1] + cov[4] * ax[2];
        float z = cov[2] * ax[0] + cov[4] * ax[1] + cov[5] * ax[2];
        float m = x * x + y * y + z * z;
        if (m < 1e-12f) break;
        float inv = 1.0f / __builtin_sqrtf(m);
        ax[0] = x * inv, ax[1] = y * inv, ax[2] = z * inv;
    }
    float lo = 1e30f, hi = -1e30f;
    int il = 0, ih = 0;
    for (int i = 0; i < 16; i++) {
        if (!use[i]) continue;
        float d = px[i][0] * ax[0] + px[i][1] * ax[1] + px[i][2] * ax[2];
        if (d < lo) lo = d, il = i;
        if (d > hi) hi = d, ih = i;
    }
    int three = any_clear;
    int c0 = q565(px[ih]), c1 = q565(px[il]);
    int b0 = c0, b1 = c1;
    uint32_t bi = 0;
    float best = 1e30f;
    for (int pass = 0; pass < 3; pass++) {
        // Order the endpoints for the mode: c0 > c1 is four colours, c0 <= c1 three.
        if (three ? c0 > c1 : c0 < c1) { int t = c0; c0 = c1; c1 = t; }
        if (!three && c0 == c1) {  // one colour: every index 0
            float e = fit(px, use, c0, c1, 0, &idx);
            if (e < best) best = e, b0 = c0, b1 = c1, bi = 0;
            break;
        }
        float e = fit(px, use, c0, c1, three, &idx);
        if (e < best) best = e, b0 = c0, b1 = c1, bi = idx;
        float e0[3], e1[3];
        if (!refine(px, use, idx, three, e0, e1)) break;
        int n0 = q565(e0), n1 = q565(e1);
        if (n0 == c0 && n1 == c1) break;
        c0 = n0, c1 = n1;
    }
    if (!three && b0 == b1) bi = 0;
    out[0] = (uint8_t)b0, out[1] = (uint8_t)(b0 >> 8), out[2] = (uint8_t)b1, out[3] = (uint8_t)(b1 >> 8);
    memcpy(out + 4, &bi, 4);
}

static void alpha5_block(const uint8_t *rgba, int stride, uint8_t *out)
{
    int a[16], lo = 255, hi = 0;
    for (int i = 0; i < 16; i++) {
        a[i] = rgba[(i / 4) * stride + (i % 4) * 4 + 3];
        if (a[i] < lo) lo = a[i];
        if (a[i] > hi) hi = a[i];
    }
    out[0] = (uint8_t)hi, out[1] = (uint8_t)lo;
    uint64_t bits = 0;
    if (hi > lo) {
        int p[8] = {hi, lo};
        for (int j = 1; j < 7; j++) p[j + 1] = ((7 - j) * hi + j * lo + 3) / 7;
        for (int i = 0; i < 16; i++) {
            int best = 0, bd = 1 << 30;
            for (int j = 0; j < 8; j++) {
                int d = (a[i] - p[j]) * (a[i] - p[j]);
                if (d < bd) bd = d, best = j;
            }
            bits |= (uint64_t)best << (3 * i);
        }
    }
    for (int k = 0; k < 6; k++) out[2 + k] = (uint8_t)(bits >> (8 * k));
}

static void alpha3_block(const uint8_t *rgba, int stride, uint8_t *out)
{
    for (int i = 0; i < 16; i += 2) {
        int a0 = (rgba[(i / 4) * stride + (i % 4) * 4 + 3] * 15 + 127) / 255;
        int a1 = (rgba[((i + 1) / 4) * stride + ((i + 1) % 4) * 4 + 3] * 15 + 127) / 255;
        out[i / 2] = (uint8_t)(a0 | a1 << 4);
    }
}

// rgba: w x h, both multiples of 4. fmt: 13 DXT1, 14 DXT3, 15 DXT5 (the VTF numbers).
// punch: DXT1 with one-bit alpha.
void dxt_encode(const uint8_t *rgba, int w, int h, int fmt, int punch, uint8_t *out)
{
    int stride = w * 4;
    for (int by = 0; by < h; by += 4)
        for (int bx = 0; bx < w; bx += 4) {
            const uint8_t *b = rgba + by * stride + bx * 4;
            if (fmt == 15) alpha5_block(b, stride, out), out += 8;
            if (fmt == 14) alpha3_block(b, stride, out), out += 8;
            color_block(b, stride, fmt == 13 && punch, out);
            out += 8;
        }
}
