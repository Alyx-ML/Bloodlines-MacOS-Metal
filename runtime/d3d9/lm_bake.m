// The lighting rebake (lm_bake.h). The luxels are laid out on the CPU, each one's place
// and normal on its face (flat faces' pulled inside the face where the lightmap's grid
// runs past its edge, displacements' on the displaced surface); the GPU then gathers the
// direct light at each, with shadow rays to every light that reaches it, and the bounces:
// rays from each luxel, cosine-weighted, read the light of the luxels they hit from the
// pass before, times that texture's reflectivity. Each pass runs in pieces of whole
// faces, blurred and added into the packed result piece by piece, so only that and the
// last pass's flat light are kept for every luxel. The GPU work goes in small slices, paced
// to leave the game most of each frame (pace_wait).
#import "lm_bake.h"
#include <compression.h>
#include <dirent.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>

#import "mtl4.h"

static NSString *const bake_source =
    @"#include <metal_stdlib>\n"
     "#include <metal_raytracing>\n"
     "using namespace metal;\n"
     "using namespace raytracing;\n"
     // A face: normal and plane distance; texture s axis (w: the texture mirrored);
     // reflectivity (w: a luxel's width in world units); luxels across and down, first
     // luxel, texinfo flags, baked.
     "struct GF { float4 nd, ts, refl; int w, h; uint offset, flags, lit, pad0, pad1, pad2; };\n"
     // A light: origin and type; intensity; normal (spots, surfaces: where they face; the
     // sun: where its light goes); stopdot, stopdot2, exponent, radius; attenuation.
     "struct GL { float4 o, i, n, sp, att; };\n"
     "struct LX { packed_float3 p; uint face; half4 n; };\n"
     // A triangle the rays can hit: its corners' lightmap coordinates on their face (luxels
     // from its corner) and the way it faces.
     "struct TD { float2 l0, l1, l2, pad; float4 n; };\n"
     "struct BP { uint first, count, nlights, scale, rays, sky_rays; float bias; uint seed, noshadow, samples;\n"
     "            float soft, sun_cone; };\n"
     "static uint hash(uint x) { x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16; return x; }\n"
     "static float rnd(thread uint &s) { s = hash(s); return float(s >> 8) * (1.0 / 16777216.0); }\n"
     "static float3 cosine_dir(float3 N, thread uint &seed) {\n"
     "    float3 T = normalize(abs(N.z) < 0.999 ? cross(N, float3(0, 0, 1)) : cross(N, float3(1, 0, 0))), B = cross(N, T);\n"
     "    float u1 = rnd(seed), u2 = rnd(seed), phi = 6.2831853 * u1, r = sqrt(u2);\n"
     "    return normalize(T * (cos(phi) * r) + B * (sin(phi) * r) + N * sqrt(max(1.0 - u2, 0.0))); }\n"
     // vrad's bump directions round the luxel's own normal (bl_bake_bump_normals).
     "static void bump_dirs(float3 N, float4 ts, thread float3 *B) {\n"
     "    float3 r1 = cross(N, ts.xyz);\n"
     "    float l = length(r1);\n"
     "    r1 = l > 1e-5 ? r1 / l : normalize(abs(N.z) < 0.9 ? cross(N, float3(0, 0, 1)) : cross(N, float3(1, 0, 0)));\n"
     "    float3 r0 = normalize(cross(r1, N));\n"
     "    if (ts.w > 0.5) r1 = -r1;\n"
     "    B[0] = 0.81649658 * r0 + 0.57735027 * N;\n"
     "    B[1] = -0.40824829 * r0 + 0.70710678 * r1 + 0.57735027 * N;\n"
     "    B[2] = -0.40824829 * r0 - 0.70710678 * r1 + 0.57735027 * N; }\n"
     // The triangle hit along d from o, and where on it, or tri -1.
     "struct Hit { int tri; float2 b; float t; };\n"
     "static Hit trace(primitive_acceleration_structure acc, float3 o, float3 d) {\n"
     "    intersector<triangle_data> it;\n"
     "    it.assume_geometry_type(geometry_type::triangle);\n"
     "    auto h = it.intersect(ray(o, d, 0.0, 1e5), acc);\n"
     "    Hit r;\n"
     "    r.tri = h.type == intersection_type::none ? -1 : int(h.primitive_id);\n"
     "    r.b = h.triangle_barycentric_coord, r.t = h.distance;\n"
     "    return r; }\n"
     "static bool sky_hit(primitive_acceleration_structure acc, device const uint *tri_face, device const GF *faces,\n"
     "                    float3 o, float3 d) {\n"
     "    Hit h = trace(acc, o, d);\n"
     "    return h.tri >= 0 && (faces[tri_face[h.tri]].flags & 4u); }\n"
     "static bool blocked(primitive_acceleration_structure acc, float3 o, float3 d, float maxd) {\n"
     "    intersector<triangle_data> it;\n"
     "    it.assume_geometry_type(geometry_type::triangle);\n"
     "    it.accept_any_intersection(true);\n"
     "    return it.intersect(ray(o, d, 0.0, maxd), acc).type != intersection_type::none; }\n"
     // The light reaching each luxel of the piece straight from the lights (out), and from
     // the sky's ambient light apart (sky), for the flat normal and the three bump directions.
     "kernel void bake_direct(device const LX *lux [[buffer(0)]], device const GF *faces [[buffer(1)]],\n"
     "                        device const GL *lights [[buffer(2)]], device const uint *tri_face [[buffer(3)]],\n"
     "                        primitive_acceleration_structure acc [[buffer(4)]], constant BP &bp [[buffer(5)]],\n"
     "                        device float4 *out [[buffer(6)]], device float4 *sky [[buffer(9)]],\n"
     "                        uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= bp.count) return;\n"
     "    uint id = bp.first + gid;\n"
     "    LX x = lux[id];\n"
     "    GF f = faces[x.face];\n"
     "    float3 P = float3(x.p), N = normalize(float3(x.n.xyz)), o = P + N * bp.bias;\n"
     "    float3 Bn[3];\n"
     "    bump_dirs(N, f.ts, Bn);\n"
     "    float3 e[4] = {0, 0, 0, 0}, s[4] = {0, 0, 0, 0};\n"
     "    uint seed = hash(id * 9781u + 17u);\n"
     // Where each shadow ray starts: spread over the luxel, 4 x 4 across it, so a shadow's
     // edge crossing it shades it by how much of it is in shadow instead of all or nothing;
     // a point a wall stands between (the luxel at a corner) starts from its middle.
     "    float3 T = normalize(abs(N.z) < 0.999 ? cross(N, float3(0, 0, 1)) : cross(N, float3(1, 0, 0))), Bt = cross(N, T);\n"
     "    float3 og[16];\n"
     "    uint js = hash(id * 31u + 7u);\n"
     "    for (uint k = 0; k < 16; k++) {\n"
     "        float u = (float(k & 3u) + rnd(js)) * 0.25 - 0.5, v = (float(k >> 2) + rnd(js)) * 0.25 - 0.5;\n"
     "        float3 q = (T * u + Bt * v) * f.refl.w;\n"
     "        float ql = length(q);\n"
     "        og[k] = ql > 1e-4 && !blocked(acc, o, q / ql, ql) ? o + q : o;\n"
     "    }\n"
     "    for (uint li = 0; li < bp.nlights; li++) {\n"
     "        GL L = lights[li];\n"
     "        int type = int(L.o.w);\n"
     // The sky's ambient light (5): how much of the sky the luxel sees, cosine-weighted.
     "        if (type == 5) {\n"
     "            float3 v[4] = {0, 0, 0, 0};\n"
     "            for (uint r = 0; r < bp.sky_rays; r++) {\n"
     "                float3 d = cosine_dir(N, seed);\n"
     "                if (!sky_hit(acc, tri_face, faces, o, d)) continue;\n"
     "                float cn = max(dot(N, d), 0.05);\n"
     "                v[0] += 1.0;\n"
     "                for (int k = 0; k < 3; k++) v[k + 1] += clamp(max(dot(Bn[k], d), 0.0) / cn, 0.0, 4.0);\n"
     "            }\n"
     "            for (int k = 0; k < 4; k++) s[k] += L.i.xyz * v[k] / float(bp.sky_rays);\n"
     "            continue;\n"
     "        }\n"
     "        float3 dir;\n"
     "        float fall = 1.0, dist = 1e5;\n"
     "        if (type == 3) dir = -L.n.xyz;\n"
     "        else {\n"
     "            float3 dl = L.o.xyz - P;\n"
     "            float len = length(dl);\n"
     "            if (len < 1e-3) continue;\n"
     "            dir = dl / len, dist = max(len, 1.0);\n"
     "            if (L.sp.w > 0.0 && dist > L.sp.w) continue;\n"
     "            if (type == 0) {\n"  // a glowing surface
     "                float d2 = -dot(dir, L.n.xyz);\n"
     "                if (d2 <= 0.001) continue;\n"
     "                fall = d2 / (dist * dist);\n"
     "            } else {\n"
     "                fall = 1.0 / max(L.att.x + L.att.y * dist + L.att.z * dist * dist, 1e-6);\n"
     "                if (type == 2) {\n"  // a spot
     "                    float d2 = -dot(dir, L.n.xyz);\n"
     "                    if (d2 <= L.sp.y) continue;\n"
     "                    if (d2 <= L.sp.x) fall *= smoothstep(0.0, 1.0, (d2 - L.sp.y) / (L.sp.x - L.sp.y));\n"
     "                    if (L.sp.z != 0.0 && L.sp.z != 1.0) fall *= pow(d2, L.sp.z);\n"
     "                }\n"
     "            }\n"
     "        }\n"
     "        float c[4] = {dot(N, dir), dot(Bn[0], dir), dot(Bn[1], dir), dot(Bn[2], dir)};\n"
     "        float cmax = max(max(c[0], c[1]), max(c[2], c[3]));\n"
     "        float3 I = L.i.xyz * fall;\n"
     "        if (cmax <= 0.0 || max(I.x, max(I.y, I.z)) * cmax < 1e-5) continue;\n"
     "        float lit = 0.0;\n"
     "        uint ls = hash(li * 2654435761u + 12345u);\n"
     "        if (type == 3) {\n"
     // The sun: only where its rays reach the sky, spread over a small disc of directions
     // so its shadows have soft edges that widen with distance, as a real sun's do.
     "            float3 Ts = normalize(abs(dir.z) < 0.999 ? cross(dir, float3(0, 0, 1)) : cross(dir, float3(1, 0, 0)));\n"
     "            float3 Bs = cross(dir, Ts);\n"
     "            for (uint k = 0; k < bp.samples; k++) {\n"
     "                float a = 6.2831853 * rnd(ls), r = bp.sun_cone * sqrt(rnd(ls));\n"
     "                float3 d = normalize(dir + (Ts * cos(a) + Bs * sin(a)) * r);\n"
     "                if (dot(d, N) > 0.0 && sky_hit(acc, tri_face, faces, og[k & 15u], d)) lit += 1.0;\n"
     "            }\n"
     "        } else if (bp.noshadow) {\n"
     "            lit = float(bp.samples);\n"
     "        } else {\n"
     // Soft shadows: rays to points spread over a small ball round the light, so a
     // shadow's edge fades over a few luxels instead of stepping from luxel to luxel. The
     // same points for every luxel (seeded by the light), so where a prop's box cuts
     // through the ball the light changes smoothly instead of speckling.
     "            for (uint k = 0; k < bp.samples; k++) {\n"
     "                float z = rnd(ls) * 2.0 - 1.0, a = 6.2831853 * rnd(ls), r = bp.soft * pow(rnd(ls), 1.0 / 3.0);\n"
     "                float3 q = L.o.xyz + r * float3(sqrt(1.0 - z * z) * cos(a), sqrt(1.0 - z * z) * sin(a), z) - og[k & 15u];\n"
     "                float ql = length(q);\n"
     "                if (ql > 1.0 && dot(q, N) > 0.0 && !blocked(acc, og[k & 15u], q / ql, ql - 1.0)) lit += 1.0;\n"
     "            }\n"
     "        }\n"
     "        if (lit == 0.0) continue;\n"
     "        I *= lit / float(bp.samples);\n"
     "        for (int k = 0; k < 4; k++) e[k] += I * max(c[k], 0.0);\n"
     "    }\n"
     "    for (int k = 0; k < 4; k++) out[gid * 4 + k] = float4(e[k], 0.0), sky[gid * 4 + k] = float4(s[k], 0.0);\n"
     "}\n"
     // One bounce: the light arriving from the luxels the rays hit, from the pass before
     // (prev: their flat light), times their texture's reflectivity.
     "kernel void bake_bounce(device const LX *lux [[buffer(0)]], device const GF *faces [[buffer(1)]],\n"
     "                        device const uint *tri_face [[buffer(3)]],\n"
     "                        primitive_acceleration_structure acc [[buffer(4)]], constant BP &bp [[buffer(5)]],\n"
     "                        device float4 *out [[buffer(6)]], device const half4 *prev [[buffer(7)]],\n"
     "                        device const TD *tris [[buffer(8)]], uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= bp.count) return;\n"
     "    uint id = bp.first + gid;\n"
     "    LX x = lux[id];\n"
     "    GF f = faces[x.face];\n"
     "    float3 N = normalize(float3(x.n.xyz)), o = float3(x.p) + N * bp.bias;\n"
     "    float3 Bn[3];\n"
     "    bump_dirs(N, f.ts, Bn);\n"
     "    float3 s[4] = {0, 0, 0, 0};\n"
     "    uint seed = hash(id * 7919u + 1013u * bp.seed + 77u);\n"
     "    for (uint r = 0; r < bp.rays; r++) {\n"
     "        float3 d = cosine_dir(N, seed);\n"
     "        Hit h = trace(acc, o, d);\n"
     "        if (h.tri < 0) continue;\n"
     "        GF g = faces[tri_face[h.tri]];\n"
     "        TD td = tris[h.tri];\n"
     "        if (!g.lit || dot(d, td.n.xyz) >= 0.0) continue;\n"  // unlit, or its back (inside a wall)
     "        float2 l = td.l0 * (1.0 - h.b.x - h.b.y) + td.l1 * h.b.x + td.l2 * h.b.y;\n"
     "        float u = clamp((l.x + 0.5) * float(bp.scale) - 0.5, 0.0, float(g.w - 1));\n"
     "        float v = clamp((l.y + 0.5) * float(bp.scale) - 0.5, 0.0, float(g.h - 1));\n"
     "        int u0 = min(int(u), g.w - 1), v0 = min(int(v), g.h - 1), u1 = min(u0 + 1, g.w - 1), v1 = min(v0 + 1, g.h - 1);\n"
     "        float fu = u - float(u0), fv = v - float(v0);\n"
     "        uint b = g.offset;\n"
     "        float3 E = mix(mix(float3(prev[b + uint(v0 * g.w + u0)].xyz), float3(prev[b + uint(v0 * g.w + u1)].xyz), fu),\n"
     "                       mix(float3(prev[b + uint(v1 * g.w + u0)].xyz), float3(prev[b + uint(v1 * g.w + u1)].xyz), fu), fv);\n"
     "        float3 c = g.refl.xyz * E;\n"
     "        float cn = max(dot(N, d), 0.05);\n"
     "        s[0] += c;\n"
     "        for (int k = 0; k < 3; k++) s[k + 1] += c * clamp(max(dot(Bn[k], d), 0.0) / cn, 0.0, 4.0);\n"
     "    }\n"
     "    for (int k = 0; k < 4; k++) out[gid * 4 + k] = float4(s[k] / float(bp.rays), 0.0);\n"
     "}\n";

struct gface { float nd[4], ts[4], refl[4]; int w, h; uint32_t offset, flags, lit, pad[3]; };
struct glight { float o[4], i[4], n[4], sp[4], att[4]; };
struct glux { float p[3]; uint32_t face; __fp16 n[4]; };
struct gtri { float l[3][2], pad[2], n[4]; };
struct gparams { uint32_t first, count, nlights, scale, rays, sky_rays; float bias; uint32_t seed, noshadow, samples; float soft, sun_cone; };

void bl_bake_rgbe(const uint8_t *s, float out[3])
{
    float k = ldexpf(1.0f / 255.0f, (int8_t)s[3]);
    for (int i = 0; i < 3; i++) out[i] = (float)s[i] * k;
}

// RGB9E5: three 9-bit mantissas sharing a 5-bit exponent (bias 15), as Metal reads it.
uint32_t bl_bake_pack(const float rgb[3])
{
    float c[3], m = 0;
    for (int i = 0; i < 3; i++) c[i] = rgb[i] > 0 ? (rgb[i] < 65408.0f ? rgb[i] : 65408.0f) : 0, m = c[i] > m ? c[i] : m;
    if (m < 1e-9f) return 0;
    int e = (int)floorf(log2f(m));
    e = e < -16 ? -16 : e;
    e += 16;  // the shared exponent, 0 .. 31
    float d = ldexpf(1.0f, e - 15 - 9);
    if ((int)floorf(m / d + 0.5f) == 512) d *= 2, e++;
    if (e > 31) e = 31;
    uint32_t q[3];
    for (int i = 0; i < 3; i++) {
        int v = (int)floorf(c[i] / d + 0.5f);
        q[i] = (uint32_t)(v < 0 ? 0 : v > 511 ? 511 : v);
    }
    return q[0] | q[1] << 9 | q[2] << 18 | (uint32_t)e << 27;
}

void bl_bake_unpack(uint32_t v, float rgb[3])
{
    float d = ldexpf(1.0f, (int)(v >> 27) - 15 - 9);
    for (int i = 0; i < 3; i++) rgb[i] = (float)(v >> (9 * i) & 511) * d;
}

static void normalize3(float v[3])
{
    float l = sqrtf(v[0] * v[0] + v[1] * v[1] + v[2] * v[2]);
    if (l > 1e-12f)
        for (int i = 0; i < 3; i++) v[i] /= l;
}
static void cross3(const float a[3], const float b[3], float o[3])
{
    o[0] = a[1] * b[2] - a[2] * b[1], o[1] = a[2] * b[0] - a[0] * b[2], o[2] = a[0] * b[1] - a[1] * b[0];
}
static float dot3(const float a[3], const float b[3]) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }

// Whether the face's texture is mirrored (its s and t axes turn the other way round its normal).
static int mirrored(const struct bl_bsp_world *w, const struct bl_bsp_face *f)
{
    const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
    float s[3] = {t->tex[0][0], t->tex[0][1], t->tex[0][2]}, tt[3] = {t->tex[1][0], t->tex[1][1], t->tex[1][2]}, st[3];
    cross3(s, tt, st);
    return dot3(f->normal, st) < 0;
}

// vrad's GetBumpNormals with the face's own normal: its bump basis turned into world
// space along the texture's s axis, mirrored when the texture is. (The GPU builds the
// same round each luxel's normal: bump_dirs.)
void bl_bake_bump_normals(const struct bl_bsp_world *w, const struct bl_bsp_face *f, float out[3][3])
{
    static const float basis[3][3] = {{0.81649658f, 0, 0.57735027f},
                                      {-0.40824829f, 0.70710678f, 0.57735027f},
                                      {-0.40824829f, -0.70710678f, 0.57735027f}};
    const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
    float s[3] = {t->tex[0][0], t->tex[0][1], t->tex[0][2]}, r0[3], r1[3];
    cross3(f->normal, s, r1);
    normalize3(r1);
    cross3(r1, f->normal, r0);
    normalize3(r0);
    if (mirrored(w, f))
        for (int i = 0; i < 3; i++) r1[i] = -r1[i];
    for (int k = 0; k < 3; k++)
        for (int i = 0; i < 3; i++) out[k][i] = basis[k][0] * r0[i] + basis[k][1] * r1[i] + basis[k][2] * f->normal[i];
}

// The point on the face's plane at lightmap coordinates (s, t).
static void plane_point(const struct bl_bsp_texinfo *t, const struct bl_bsp_face *f, float s, float u, float p[3])
{
    const float *a = t->lm[0], *b = t->lm[1], *n = f->normal;
    float r[3] = {s - a[3], u - b[3], f->dist};
    float det = a[0] * (b[1] * n[2] - b[2] * n[1]) - a[1] * (b[0] * n[2] - b[2] * n[0]) + a[2] * (b[0] * n[1] - b[1] * n[0]);
    if (fabsf(det) < 1e-12f) {
        p[0] = p[1] = p[2] = 0;
        return;
    }
    // Cramer's rule, a column at a time.
    float m[3][3] = {{a[0], a[1], a[2]}, {b[0], b[1], b[2]}, {n[0], n[1], n[2]}};
    for (int c = 0; c < 3; c++) {
        float q[3][3];
        memcpy(q, m, sizeof q);
        for (int row = 0; row < 3; row++) q[row][c] = r[row];
        p[c] = (q[0][0] * (q[1][1] * q[2][2] - q[1][2] * q[2][1]) - q[0][1] * (q[1][0] * q[2][2] - q[1][2] * q[2][0]) +
                q[0][2] * (q[1][0] * q[2][1] - q[1][1] * q[2][0])) / det;
    }
}

// (s, t) moved inside the polygon (its corners in lightmap coordinates) when outside:
// to the nearest point of its edge, then a little towards its middle.
static void pull_inside(const float (*c)[2], int n, float pt[2])
{
    int inside = 1;
    float area = 0;
    for (int i = 0; i < n; i++) {
        const float *a = c[i], *b = c[(i + 1) % n];
        area += a[0] * b[1] - b[0] * a[1];
    }
    float sign = area >= 0 ? 1 : -1;
    for (int i = 0; i < n && inside; i++) {
        const float *a = c[i], *b = c[(i + 1) % n];
        if (sign * ((b[0] - a[0]) * (pt[1] - a[1]) - (b[1] - a[1]) * (pt[0] - a[0])) < 0) inside = 0;
    }
    if (inside) return;
    float best = 1e30f, bx = pt[0], by = pt[1], mx = 0, my = 0;
    for (int i = 0; i < n; i++) {
        const float *a = c[i], *b = c[(i + 1) % n];
        mx += a[0] / (float)n, my += a[1] / (float)n;
        float dx = b[0] - a[0], dy = b[1] - a[1], l2 = dx * dx + dy * dy;
        float t = l2 > 0 ? ((pt[0] - a[0]) * dx + (pt[1] - a[1]) * dy) / l2 : 0;
        t = t < 0 ? 0 : t > 1 ? 1 : t;
        float x = a[0] + dx * t, y = a[1] + dy * t, d = (x - pt[0]) * (x - pt[0]) + (y - pt[1]) * (y - pt[1]);
        if (d < best) best = d, bx = x, by = y;
    }
    float dx = mx - bx, dy = my - by, l = sqrtf(dx * dx + dy * dy), step = l > 0.1f ? 0.1f / l : 0;
    pt[0] = bx + dx * step, pt[1] = by + dy * step;
}

static int bakeable(const struct bl_bsp_world *w, const struct bl_bsp_face *f)
{
    return f->lightofs >= 0 && f->texinfo >= 0 && f->count >= 3 && (f->disp < 0 || f->dside) &&
           !(w->texinfo[f->texinfo].flags & 0x84);
}

// Faces that block light: the world's (its sky among them, so rays can find it) and
// displacements, not see-through ones (0x10); and brush entities' (doors, walls, grates
// standing as entities), not their sky, triggers, nodraw, hint and skip faces or tool
// textures.
static int casts(const struct bl_bsp_world *w, const struct bl_bsp_face *f)
{
    if (f->count < 3 || f->texinfo < 0 || (f->disp >= 0 && !f->dside)) return 0;
    const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
    if (t->flags & 0x10) return 0;
    if (f->model == 0) return 1;
    if (t->flags & (0x4 | 0x40 | 0x80 | 0x100 | 0x200)) return 0;
    return !(t->texdata >= 0 && t->texdata < w->ntexdata && !strncasecmp(w->texdata[t->texdata].name, "tools", 5));
}

int bl_bake_scale(const struct bl_bsp_world *w)
{
    long base = 0;
    for (int i = 0; i < w->nfaces; i++)
        if (bakeable(w, &w->faces[i])) base += (long)(w->faces[i].size[0] + 1) * (w->faces[i].size[1] + 1);
    int s = 4;
    while (s > 1 && base * s * s > 8000000) s--;
    return s;
}

// A displacement's grid cell (r, k) as two triangles of its points, the diagonal turning
// from cell to cell as the engine builds them.
static void disp_cell(int n, int r, int k, int t[2][3])
{
    int a = r * n + k, b = (r + 1) * n + k, c = (r + 1) * n + k + 1, d = r * n + k + 1;
    if ((r + k) & 1) t[0][0] = a, t[0][1] = b, t[0][2] = d, t[1][0] = b, t[1][1] = c, t[1][2] = d;
    else t[0][0] = a, t[0][1] = b, t[0][2] = c, t[1][0] = a, t[1][1] = c, t[1][2] = d;
}

// A displacement's normal at each point, from its neighbours, turned the face's way.
static void disp_normals(const struct bl_bsp_face *f, const struct bl_bsp_dvert *dv, float (*vn)[3])
{
    int n = f->dside;
    for (int r = 0; r < n; r++)
        for (int k = 0; k < n; k++) {
            const float *u0 = dv[(r > 0 ? r - 1 : r) * n + k].pos, *u1 = dv[(r + 1 < n ? r + 1 : r) * n + k].pos;
            const float *v0 = dv[r * n + (k > 0 ? k - 1 : k)].pos, *v1 = dv[r * n + (k + 1 < n ? k + 1 : k)].pos;
            float du[3], dvv[3], *o = vn[r * n + k];
            for (int a = 0; a < 3; a++) du[a] = u1[a] - u0[a], dvv[a] = v1[a] - v0[a];
            cross3(du, dvv, o);
            normalize3(o);
            if (dot3(o, f->normal) < 0)
                for (int a = 0; a < 3; a++) o[a] = -o[a];
        }
}

// A displacement's luxels on its displaced surface: its points' lightmap coordinates
// (bl_bsp_dvert.lux) make a grid over the lightmap, and each luxel's centre is found in
// the grid's triangles and takes the place and normal there. Those the grid does not
// reach (the lightmap's half-luxel border round it) take a neighbour's. Returns 0 when
// none was reached.
static int place_disp(const struct bl_bsp_world *w, const struct bl_bsp_face *f, int fi, int scale,
                      const struct bl_bake_face *bf, struct glux *lx)
{
    int n = f->dside, W = bf->w, H = bf->h;
    const struct bl_bsp_dvert *dv = &w->dverts[f->dfirst];
    float (*vn)[3] = malloc(sizeof *vn * (size_t)n * n);
    disp_normals(f, dv, vn);
    uint8_t *set = calloc((size_t)W * H, 1);
    int got = 0;
    for (int r = 0; r + 1 < n; r++)
        for (int k = 0; k + 1 < n; k++) {
            int t[2][3];
            disp_cell(n, r, k, t);
            for (int j = 0; j < 2; j++) {
                float X[3], Y[3];
                for (int c = 0; c < 3; c++)
                    X[c] = (dv[t[j][c]].lux[0] + 0.5f) * (float)scale - 0.5f, Y[c] = (dv[t[j][c]].lux[1] + 0.5f) * (float)scale - 0.5f;
                float d = (Y[1] - Y[2]) * (X[0] - X[2]) + (X[2] - X[1]) * (Y[0] - Y[2]);
                if (fabsf(d) < 1e-9f) continue;
                int x0 = (int)ceilf(fminf(X[0], fminf(X[1], X[2])) - 1e-3f), x1 = (int)floorf(fmaxf(X[0], fmaxf(X[1], X[2])) + 1e-3f);
                int y0 = (int)ceilf(fminf(Y[0], fminf(Y[1], Y[2])) - 1e-3f), y1 = (int)floorf(fmaxf(Y[0], fmaxf(Y[1], Y[2])) + 1e-3f);
                x0 = x0 < 0 ? 0 : x0, y0 = y0 < 0 ? 0 : y0, x1 = x1 >= W ? W - 1 : x1, y1 = y1 >= H ? H - 1 : y1;
                for (int y = y0; y <= y1; y++)
                    for (int x = x0; x <= x1; x++) {
                        if (set[y * W + x]) continue;
                        float a = ((Y[1] - Y[2]) * ((float)x - X[2]) + (X[2] - X[1]) * ((float)y - Y[2])) / d;
                        float b = ((Y[2] - Y[0]) * ((float)x - X[2]) + (X[0] - X[2]) * ((float)y - Y[2])) / d, c = 1 - a - b;
                        if (a < -1e-4f || b < -1e-4f || c < -1e-4f) continue;
                        struct glux *l = &lx[bf->offset + y * W + x];
                        float nn[3];
                        for (int q = 0; q < 3; q++) {
                            l->p[q] = a * dv[t[j][0]].pos[q] + b * dv[t[j][1]].pos[q] + c * dv[t[j][2]].pos[q] + f->origin[q];
                            nn[q] = a * vn[t[j][0]][q] + b * vn[t[j][1]][q] + c * vn[t[j][2]][q];
                        }
                        normalize3(nn);
                        for (int q = 0; q < 3; q++) l->n[q] = (__fp16)nn[q];
                        l->face = (uint32_t)fi;
                        set[y * W + x] = 1, got++;
                    }
            }
        }
    // The rest from their neighbours, a ring at a time.
    for (int pass = 1; got && got < W * H && pass < W + H; pass++)
        for (int y = 0; y < H; y++)
            for (int x = 0; x < W; x++) {
                if (set[y * W + x]) continue;
                for (int dy = -1; dy <= 1 && !set[y * W + x]; dy++)
                    for (int dx = -1; dx <= 1; dx++) {
                        int xx = x + dx, yy = y + dy;
                        if (xx < 0 || yy < 0 || xx >= W || yy >= H || !set[yy * W + xx] || set[yy * W + xx] > pass) continue;
                        lx[bf->offset + y * W + x] = lx[bf->offset + yy * W + xx];
                        set[y * W + x] = (uint8_t)(pass + 1 < 255 ? pass + 1 : 255), got++;
                        break;
                    }
            }
    free(vn), free(set);
    return got > 0;
}

// The triangles the rays meet, with each one's corners' lightmap coordinates and normal.
struct geo {
    float (*v)[3];
    int nv, cv;
    uint32_t (*ix)[3], *face;
    struct gtri *td;
    int nt, ct;
};
static uint32_t geo_vert(struct geo *g, const float p[3], const float off[3])
{
    if (g->nv == g->cv) g->cv = g->cv ? g->cv * 2 : 4096, g->v = realloc(g->v, sizeof *g->v * (size_t)g->cv);
    for (int a = 0; a < 3; a++) g->v[g->nv][a] = p[a] + off[a];
    return (uint32_t)g->nv++;
}
static void geo_tri(struct geo *g, const uint32_t ix[3], uint32_t face, const float l[3][2], const float n[3])
{
    if (g->nt == g->ct) {
        g->ct = g->ct ? g->ct * 2 : 4096;
        g->ix = realloc(g->ix, sizeof *g->ix * (size_t)g->ct), g->face = realloc(g->face, sizeof *g->face * (size_t)g->ct);
        g->td = realloc(g->td, sizeof *g->td * (size_t)g->ct);
    }
    memcpy(g->ix[g->nt], ix, 12);
    g->face[g->nt] = face;
    struct gtri *t = &g->td[g->nt++];
    memset(t, 0, sizeof *t);
    if (l) memcpy(t->l, l, sizeof t->l);
    if (n) memcpy(t->n, n, 12);
}

static void build_geo(const struct bl_bsp_world *w, struct geo *g)
{
    static const float zero[3];
    g->cv = w->nverts + 4096, g->v = malloc(sizeof *g->v * (size_t)g->cv), g->nv = w->nverts;
    memcpy(g->v, w->verts, sizeof *g->v * (size_t)w->nverts);
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (!casts(w, f)) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        if (f->dside) {
            int n = f->dside;
            const struct bl_bsp_dvert *dv = &w->dverts[f->dfirst];
            uint32_t first = (uint32_t)g->nv;
            for (int k = 0; k < n * n; k++) geo_vert(g, dv[k].pos, f->origin);
            for (int r = 0; r + 1 < n; r++)
                for (int k = 0; k + 1 < n; k++) {
                    int c[2][3];
                    disp_cell(n, r, k, c);
                    for (int j = 0; j < 2; j++) {
                        uint32_t ix[3];
                        float l[3][2], e1[3], e2[3], nn[3];
                        for (int q = 0; q < 3; q++) ix[q] = first + (uint32_t)c[j][q], memcpy(l[q], dv[c[j][q]].lux, 8);
                        for (int a = 0; a < 3; a++) e1[a] = dv[c[j][1]].pos[a] - dv[c[j][0]].pos[a], e2[a] = dv[c[j][2]].pos[a] - dv[c[j][0]].pos[a];
                        cross3(e1, e2, nn);
                        normalize3(nn);
                        if (dot3(nn, f->normal) < 0)
                            for (int a = 0; a < 3; a++) nn[a] = -nn[a];
                        geo_tri(g, ix, (uint32_t)i, l, nn);
                    }
                }
            continue;
        }
        uint32_t *ix = malloc(sizeof *ix * (size_t)f->count);
        float (*l)[2] = malloc(sizeof *l * (size_t)f->count);
        for (int k = 0; k < f->count; k++) {
            const float *p = w->verts[w->index[f->first + k]];
            ix[k] = f->model ? geo_vert(g, p, f->origin) : (uint32_t)w->index[f->first + k];
            for (int a = 0; a < 2; a++) l[k][a] = p[0] * t->lm[a][0] + p[1] * t->lm[a][1] + p[2] * t->lm[a][2] + t->lm[a][3] - (float)f->mins[a];
        }
        for (int k = 1; k + 1 < f->count; k++) {
            uint32_t tri[3] = {ix[0], ix[k], ix[k + 1]};
            float tl[3][2] = {{l[0][0], l[0][1]}, {l[k][0], l[k][1]}, {l[k + 1][0], l[k + 1][1]}};
            geo_tri(g, tri, (uint32_t)i, tl, f->normal);
        }
        free(ix), free(l);
    }
    // The props: one more unlit face (nfaces), blocking light and giving none back.
    if (w->props)
        for (int i = 0; i < w->props->ntris; i++) {
            uint32_t ix[3];
            for (int k = 0; k < 3; k++) ix[k] = geo_vert(g, w->props->tris[i][k], zero);
            geo_tri(g, ix, (uint32_t)w->nfaces, NULL, NULL);
        }
}

// Box blur within a face (w x h luxels of 4 sets), `r` luxels either side, along rows then columns.
static void blur_face(float (*v)[4][4], int w, int h, int r, float (*tmp)[4][4])
{
    if (r <= 0) return;
    for (int dirn = 0; dirn < 2; dirn++) {
        int n = dirn ? h : w, m = dirn ? w : h;
        for (int j = 0; j < m; j++)
            for (int x = 0; x < n; x++) {
                float acc[4][4] = {{0}};
                int cnt = 0;
                for (int d = -r; d <= r; d++) {
                    int y = x + d;
                    if (y < 0 || y >= n) continue;
                    int at = dirn ? y * w + j : j * w + y;
                    for (int k = 0; k < 4; k++)
                        for (int c = 0; c < 3; c++) acc[k][c] += v[at][k][c];
                    cnt++;
                }
                int at = dirn ? x * w + j : j * w + x;
                for (int k = 0; k < 4; k++)
                    for (int c = 0; c < 4; c++) tmp[at][k][c] = acc[k][c] / (float)cnt;
            }
        memcpy(v, tmp, sizeof *v * (size_t)w * h);
    }
}

// Sharing the GPU with the game (bl_bake_world_frame): the frames that drew the world, and
// when the newest did.
static _Atomic unsigned world_frames;
static _Atomic double world_frame_at;

static double now_seconds(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec * 1e-9;
}

void bl_bake_world_frame(void)
{
    atomic_store(&world_frame_at, now_seconds());
    atomic_fetch_add(&world_frames, 1);
}

// A bake's share while the game draws the world: one slice of BAKE_SLICE luxels a frame
// (about 2 ms of an M4 Pro's GPU for direct light, 3.5 ms for a bounce). Smaller slices
// leave most of the GPU idle, as each luxel's rays take long; bigger ones slow the frames.
struct pace { unsigned seen; int sent; };
enum { BAKE_SLICE = 4096 };

// Before a slice: while the game draws the world, once this frame's slice is sent, waits for
// its next frame.
static void pace_wait(struct pace *p)
{
    while (p->sent && now_seconds() - atomic_load(&world_frame_at) < 0.25) {
        unsigned f = atomic_load(&world_frames);
        if (f != p->seen) {
            p->seen = f, p->sent = 0;
            break;
        }
        usleep(500);
    }
}

struct bl_bake *bl_bake_map(id<MTLDevice> dev, const struct bl_bsp_world *w, int scale, int bounces, char *err, int errlen)
{
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    if (!dev.supportsRaytracing) {
        snprintf(err, (size_t)errlen, "%s has no Metal ray tracing", dev.name.UTF8String);
        return NULL;
    }
    struct bl_bake *b = calloc(1, sizeof *b);
    b->scale = scale;
    b->faces = calloc((size_t)w->nfaces + 1, sizeof *b->faces);
    // Faces for the GPU, and where each one's luxels go.
    struct gface *gf = calloc((size_t)w->nfaces + 1, sizeof *gf);
    int total = 0, ndisp = 0;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        struct gface *g = &gf[i];
        b->faces[i].offset = -1;
        for (int k = 0; k < 3; k++) g->nd[k] = f->normal[k];
        g->nd[3] = f->dist;
        if (f->texinfo < 0) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        g->flags = (uint32_t)t->flags;
        if (t->texdata >= 0 && t->texdata < w->ntexdata) memcpy(g->refl, w->texdata[t->texdata].reflectivity, 12);
        if (!bakeable(w, f)) continue;
        memcpy(g->ts, t->tex[0], 12);
        normalize3(g->ts);
        g->ts[3] = mirrored(w, f) ? 1.0f : 0.0f;
        g->w = (f->size[0] + 1) * scale, g->h = (f->size[1] + 1) * scale;
        g->offset = (uint32_t)total, g->lit = 1;
        g->refl[3] = 1.0f / (sqrtf(dot3(t->lm[0], t->lm[0])) * (float)scale);
        b->faces[i] = (struct bl_bake_face){total, g->w, g->h};
        total += g->w * g->h;
        ndisp += f->dside > 0;
    }
    b->nluxels = total;
    // The luxels: each one's place and normal on its face.
    id<MTLBuffer> luxb = [dev newBufferWithLength:sizeof(struct glux) * ((size_t)total + 1) options:MTLResourceStorageModeShared];
    struct glux *lx = luxb.contents;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        const struct bl_bake_face *bf = &b->faces[i];
        if (bf->offset < 0) continue;
        if (f->dside && place_disp(w, f, i, scale, bf, lx)) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        float (*c)[2] = malloc(sizeof(float[2]) * (size_t)f->count);
        for (int k = 0; k < f->count; k++) {
            const float *v = w->verts[w->index[f->first + k]];
            for (int a = 0; a < 2; a++) c[k][a] = v[0] * t->lm[a][0] + v[1] * t->lm[a][1] + v[2] * t->lm[a][2] + t->lm[a][3];
        }
        for (int y = 0; y < bf->h; y++)
            for (int x = 0; x < bf->w; x++) {
                float pt[2] = {(float)f->mins[0] + ((float)x + 0.5f) / (float)scale - 0.5f,
                               (float)f->mins[1] + ((float)y + 0.5f) / (float)scale - 0.5f};
                pull_inside(c, f->count, pt);
                struct glux *l = &lx[bf->offset + y * bf->w + x];
                plane_point(t, f, pt[0], pt[1], l->p);
                for (int k = 0; k < 3; k++) l->p[k] += f->origin[k], l->n[k] = (__fp16)f->normal[k];
                l->n[3] = 0;
                l->face = (uint32_t)i;
            }
        free(c);
    }
    // The occluders, and what a bounce ray needs of the triangle it meets.
    struct geo g = {0};
    build_geo(w, &g);
    int nt = g.nt, nprop = w->props ? w->props->ntris : 0;
    id<MTLBuffer> vb = [dev newBufferWithBytes:g.v length:12 * ((size_t)g.nv + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [dev newBufferWithBytes:g.ix length:12 * ((size_t)nt + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> tfb = [dev newBufferWithBytes:g.face length:4 * ((size_t)nt + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> tdb = [dev newBufferWithBytes:g.td length:sizeof(struct gtri) * ((size_t)nt + 1) options:MTLResourceStorageModeShared];
    free(g.v), free(g.ix), free(g.face), free(g.td);
    MTL4AccelerationStructureTriangleGeometryDescriptor *geo = [MTL4AccelerationStructureTriangleGeometryDescriptor new];
    geo.vertexBuffer = (MTL4BufferRange){vb.gpuAddress, vb.length}, geo.vertexStride = 12;
    geo.vertexFormat = MTLAttributeFormatFloat3;
    geo.indexBuffer = (MTL4BufferRange){ib.gpuAddress, ib.length}, geo.indexType = MTLIndexTypeUInt32;
    geo.triangleCount = (NSUInteger)nt, geo.opaque = YES;
    MTL4PrimitiveAccelerationStructureDescriptor *ad = [MTL4PrimitiveAccelerationStructureDescriptor new];
    ad.geometryDescriptors = @[ geo ];
    MTLAccelerationStructureSizes sz = [dev accelerationStructureSizesWithDescriptor:ad];
    id<MTLAccelerationStructure> accel = [dev newAccelerationStructureWithSize:sz.accelerationStructureSize];
    id<MTLBuffer> scratch = [dev newBufferWithLength:sz.buildScratchBufferSize options:MTLResourceStorageModePrivate];
    BLJob *job = [[BLJob alloc] initWithDevice:dev];
    if (!job) {
        snprintf(err, (size_t)errlen, "no Metal 4 queue");
        free(gf);
        bl_bake_free(b);
        return NULL;
    }
    for (id<MTLAllocation> r in @[ luxb, vb, ib, tfb, tdb, accel, scratch ]) [job keep:r];
    id<MTL4ComputeCommandEncoder> ae = [[job begin] computeCommandEncoder];
    [ae buildAccelerationStructure:accel descriptor:ad scratchBuffer:(MTL4BufferRange){scratch.gpuAddress, scratch.length}];
    [ae endEncoding];
    NSError *built = [job run];
    // The lights, style 0 only (the others switch or flicker).
    id<MTLBuffer> lb = [dev newBufferWithLength:sizeof(struct glight) * ((size_t)w->nlights + 1) options:MTLResourceStorageModeShared];
    struct glight *gl = lb.contents;
    int nl = 0;
    for (int i = 0; i < w->nlights; i++) {
        const struct bl_bsp_worldlight *l = &w->lights[i];
        if (l->style != 0 || l->type == 4) continue;
        struct glight *q = &gl[nl++];
        memcpy(q->o, l->origin, 12), q->o[3] = (float)l->type;
        memcpy(q->i, l->intensity, 12), memcpy(q->n, l->normal, 12);
        q->sp[0] = l->stopdot, q->sp[1] = l->stopdot2, q->sp[2] = l->exponent, q->sp[3] = l->radius;
        memcpy(q->att, l->att, 12);
        if (q->att[0] <= 0 && q->att[1] <= 0 && q->att[2] <= 0) q->att[2] = 1;
    }
    id<MTLBuffer> fb = [dev newBufferWithBytes:gf length:sizeof *gf * ((size_t)w->nfaces + 1) options:MTLResourceStorageModeShared];
    free(gf);
    NSError *error = nil;
    MTLCompileOptions *opt = [MTLCompileOptions new];
    id<MTLLibrary> lib = [dev newLibraryWithSource:bake_source options:opt error:&error];
    id<MTLComputePipelineState> pd = lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bake_direct"] error:&error] : nil;
    id<MTLComputePipelineState> pb = pd ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"bake_bounce"] error:&error] : nil;
    if (!pb) {
        snprintf(err, (size_t)errlen, "bake shader: %s", error.localizedDescription.UTF8String);
        bl_bake_free(b);
        return NULL;
    }
    // The pieces: runs of whole faces, about 32768 luxels each.
    int *piece = malloc(sizeof(int) * ((size_t)w->nfaces + 2)), npieces = 0, most = 1;
    for (int i = 0, start = 0, n = 0; i <= w->nfaces; i++) {
        int add = i < w->nfaces && b->faces[i].offset >= 0 ? b->faces[i].w * b->faces[i].h : 0;
        if (i == w->nfaces || (n && n + add > 32768)) {
            if (n) piece[npieces++] = start, most = n > most ? n : most;
            start = i, n = 0;
        }
        n += add;
    }
    piece[npieces] = w->nfaces;
    for (int p = 0; p < npieces; p++)  // each piece's first face with luxels
        while (piece[p] < w->nfaces && b->faces[piece[p]].offset < 0) piece[p]++;
    id<MTLBuffer> out = [dev newBufferWithLength:64 * (size_t)most options:MTLResourceStorageModeShared];
    id<MTLBuffer> sky = [dev newBufferWithLength:64 * (size_t)most options:MTLResourceStorageModeShared];
    id<MTLBuffer> prev = [dev newBufferWithLength:8 * ((size_t)total + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> next = [dev newBufferWithLength:8 * ((size_t)total + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> params = [dev newBufferWithLength:sizeof(struct gparams) options:MTLResourceStorageModeShared];
    for (id<MTLAllocation> r in @[ lb, fb, out, sky, prev, next, params ]) [job keep:r];
    id<MTL4ArgumentTable> at = job.table;
    [at setAddress:luxb.gpuAddress atIndex:0];
    [at setAddress:fb.gpuAddress atIndex:1];
    [at setAddress:lb.gpuAddress atIndex:2];
    [at setAddress:tfb.gpuAddress atIndex:3];
    [at setResource:accel.gpuResourceID atBufferIndex:4];
    [at setAddress:params.gpuAddress atIndex:5];
    [at setAddress:out.gpuAddress atIndex:6];
    [at setAddress:tdb.gpuAddress atIndex:8];
    [at setAddress:sky.gpuAddress atIndex:9];
    // 512 bounce rays and 128 sky rays per luxel; 16 shadow rays per light, over a ball 6
    // units across, or for the sun over a disc of directions 2 degrees across.
    struct gparams gp = {0, 0, (uint32_t)nl, (uint32_t)scale, 512, 128, 0.25f, 0, 0, 16, 3.0f, 0.0175f};
    gp.noshadow = getenv("BL_BAKE_NOSHADOW") != NULL;  // debugging: direct light without shadows
    if (getenv("BL_BAKE_RAYS")) gp.rays = (uint32_t)atoi(getenv("BL_BAKE_RAYS"));  // debugging
    // The bounces and the sky change slowly over a surface: blurred within each face (a
    // box about one of the map's own luxels across), the rays' noise goes.
    int blur = getenv("BL_BAKE_BLUR") ? atoi(getenv("BL_BAKE_BLUR")) : scale / 2 > 1 ? scale / 2 : 1;  // debugging
    b->light = calloc((size_t)total + 1, sizeof *b->light);
    float (*tmp)[4][4] = malloc(64 * (size_t)most);
    __block NSError *failed = built;
    // A pass, piece by piece, each piece in slices of its own command buffer, paced so the
    // game keeps most of the GPU (pace_wait); `done` takes each piece's light (its first
    // luxel, its first face and the face after its last).
    struct pace share = {atomic_load(&world_frames), 0}, *pc = &share;
    void (^run)(id<MTLComputePipelineState>, uint32_t, void (^)(int, int, int)) =
        ^(id<MTLComputePipelineState> p, uint32_t pass, void (^done)(int, int, int)) {
            for (int q = 0; q < npieces && !failed; q++) {
                int f0 = piece[q], f1 = piece[q + 1];
                if (f0 >= f1) continue;
                int first = b->faces[f0].offset, last = first;
                for (int i = f0; i < f1; i++)
                    if (b->faces[i].offset >= 0) last = b->faces[i].offset + b->faces[i].w * b->faces[i].h;
                for (int s = first, n; s < last && !failed; s += n) {
                    n = last - s < BAKE_SLICE ? last - s : BAKE_SLICE;
                    pace_wait(pc);
                    struct gparams *gq = params.contents;
                    *gq = gp;
                    gq->first = (uint32_t)s, gq->count = (uint32_t)n;
                    gq->seed = pass;  // a different random pattern each bounce
                    [at setAddress:out.gpuAddress + 64 * (uint64_t)(s - first) atIndex:6];
                    [at setAddress:sky.gpuAddress + 64 * (uint64_t)(s - first) atIndex:9];
                    id<MTL4ComputeCommandEncoder> e = [[job begin] computeCommandEncoder];
                    [e setComputePipelineState:p];
                    [e setArgumentTable:at];
                    [e dispatchThreads:MTLSizeMake((NSUInteger)n, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
                    [e endEncoding];
                    failed = [job run];
                    pc->sent++;
                }
                if (!failed) done(first, f0, f1);
            }
        };
    __fp16 (*pv)[4] = prev.contents, (*nx)[4] = next.contents;
    __block __fp16 (*to)[4] = pv;
    // Direct light, and the sky's blurred: the result so far, and the first bounce's source.
    run(pd, 0, ^(int first, int f0, int f1) {
        float (*o)[4][4] = out.contents, (*s)[4][4] = sky.contents;
        for (int i = f0; i < f1; i++) {
            const struct bl_bake_face *bf = &b->faces[i];
            if (bf->offset < 0) continue;
            int at0 = bf->offset - first;
            blur_face(s + at0, bf->w, bf->h, blur, tmp);
            for (int j = 0; j < bf->w * bf->h; j++) {
                float c[4][3];
                for (int k = 0; k < 4; k++)
                    for (int ch = 0; ch < 3; ch++) c[k][ch] = o[at0 + j][k][ch] + s[at0 + j][k][ch];
                for (int k = 0; k < 4; k++) b->light[bf->offset + j][k] = bl_bake_pack(c[k]);
                for (int ch = 0; ch < 3; ch++) to[bf->offset + j][ch] = (__fp16)c[0][ch];
            }
        }
    });
    // Bounces, each from the one before.
    for (int pass = 1; pass <= bounces && !failed; pass++) {
        [at setAddress:(pass & 1 ? prev : next).gpuAddress atIndex:7];
        to = pass & 1 ? nx : pv;
        run(pb, (uint32_t)pass, ^(int first, int f0, int f1) {
            float (*o)[4][4] = out.contents;
            for (int i = f0; i < f1; i++) {
                const struct bl_bake_face *bf = &b->faces[i];
                if (bf->offset < 0) continue;
                int at0 = bf->offset - first;
                blur_face(o + at0, bf->w, bf->h, blur, tmp);
                for (int j = 0; j < bf->w * bf->h; j++) {
                    for (int k = 0; k < 4; k++) {
                        float c[3];
                        bl_bake_unpack(b->light[bf->offset + j][k], c);
                        for (int ch = 0; ch < 3; ch++) c[ch] += o[at0 + j][k][ch];
                        b->light[bf->offset + j][k] = bl_bake_pack(c);
                    }
                    for (int ch = 0; ch < 3; ch++) to[bf->offset + j][ch] = (__fp16)o[at0 + j][0][ch];
                }
            }
        });
    }
    free(tmp), free(piece);
    if (failed) {
        snprintf(err, (size_t)errlen, "bake: %s", failed.localizedDescription.UTF8String);
        bl_bake_free(b);
        return NULL;
    }
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    b->seconds = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    snprintf(b->summary, sizeof b->summary,
             "%s: %d luxels (x%d per side, %d displacements), %d occluding triangles (%d of them props'), %d lights, %d bounces, "
             "%.1f s on %s", w->name, total, scale, ndisp, nt, nprop, nl, bounces, b->seconds, dev.name.UTF8String);
    return b;
}

void bl_bake_free(struct bl_bake *b)
{
    if (!b) return;
    free(b->faces), free(b->light);
    free(b);
}

// --- the cache ------------------------------------------------------------------------
//
// One file per map: a header (the map's size and date, the bake's version and scale),
// then the faces and the light, compressed (LZFSE). A file that does not match the map
// as it is now, or this bake's version, is baked again. Past CACHE_MAX bytes in all, the
// files least recently used go.

#define BAKE_VERSION 1
#define CACHE_MAX (3ll << 30)
struct cache_head { char magic[4]; int32_t version, scale, nfaces, nluxels; int64_t size, mtime, packed, raw; };

static int cache_dir(char *out, size_t cap)
{
    const char *home = getenv("HOME");
    if (!home || (getenv("BL_BAKE_CACHE") && !atoi(getenv("BL_BAKE_CACHE")))) return 0;  // BL_BAKE_CACHE=0: debugging
    snprintf(out, cap, "%s/Library/Caches/Vampire The Masquerade - Bloodlines", home);
    mkdir(out, 0755);
    snprintf(out + strlen(out), cap - strlen(out), "/lightmaps");
    mkdir(out, 0755);
    return 1;
}

// The cache file for a map: its name, and which of the game's folders it is in.
static int cache_path(const char *map, char *out, size_t cap, struct stat *st)
{
    char dir[1024];
    if (stat(map, st) || !cache_dir(dir, sizeof dir)) return 0;
    uint32_t h = 2166136261u;
    for (const char *p = map; *p; p++) h = (h ^ (uint8_t)*p) * 16777619u;
    const char *name = strrchr(map, '/');
    snprintf(out, cap, "%s/%s-%08x.bake", dir, name ? name + 1 : map, h);
    return 1;
}

static struct bl_bake *cache_read(const char *map, const struct bl_bsp_world *w)
{
    char path[1200];
    struct stat st;
    if (!cache_path(map, path, sizeof path, &st)) return NULL;
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    struct cache_head h;
    struct bl_bake *b = NULL;
    uint8_t *packed = NULL, *raw = NULL;
    if (fread(&h, sizeof h, 1, f) != 1 || memcmp(h.magic, "BLBK", 4) || h.version != BAKE_VERSION || h.size != st.st_size ||
        h.mtime != st.st_mtime || h.nfaces != w->nfaces || h.scale != bl_bake_scale(w) || h.nluxels < 0 || h.packed <= 0 ||
        h.raw != (int64_t)sizeof(struct bl_bake_face) * h.nfaces + 16ll * h.nluxels)
        goto done;
    packed = malloc((size_t)h.packed), raw = malloc((size_t)h.raw + 1);
    if (fread(packed, (size_t)h.packed, 1, f) != 1 ||
        compression_decode_buffer(raw, (size_t)h.raw + 1, packed, (size_t)h.packed, NULL, COMPRESSION_LZFSE) != (size_t)h.raw)
        goto done;
    b = calloc(1, sizeof *b);
    b->scale = h.scale, b->nluxels = h.nluxels, b->cached = 1;
    b->faces = calloc((size_t)w->nfaces + 1, sizeof *b->faces);
    b->light = calloc((size_t)h.nluxels + 1, sizeof *b->light);
    memcpy(b->faces, raw, sizeof *b->faces * (size_t)h.nfaces);
    memcpy(b->light, raw + sizeof *b->faces * (size_t)h.nfaces, 16 * (size_t)h.nluxels);
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bake_face *bf = &b->faces[i];
        if (bf->offset >= 0 && (bf->offset + (long)bf->w * bf->h > h.nluxels || bf->w <= 0 || bf->h <= 0)) {
            bl_bake_free(b);
            b = NULL;
            goto done;
        }
    }
    utimes(path, NULL);  // used: last to go
    snprintf(b->summary, sizeof b->summary, "%s: %d luxels (x%d per side) from the cache", w->name, b->nluxels, b->scale);
done:
    fclose(f);
    free(packed), free(raw);
    return b;
}

struct cache_file { char path[1200]; time_t t; off_t size; };
static int cache_file_cmp(const void *a, const void *b)
{
    time_t x = ((const struct cache_file *)a)->t, y = ((const struct cache_file *)b)->t;
    return x < y ? -1 : x > y;
}

static void cache_trim(void)
{
    char dir[1024];
    if (!cache_dir(dir, sizeof dir)) return;
    DIR *d = opendir(dir);
    if (!d) return;
    struct cache_file *fs = NULL;
    int n = 0, cap = 0;
    long long total = 0;
    for (struct dirent *e; (e = readdir(d));) {
        size_t l = strlen(e->d_name);
        if (l < 6 || strcmp(e->d_name + l - 5, ".bake")) continue;
        if (n == cap) cap = cap ? cap * 2 : 64, fs = realloc(fs, sizeof *fs * (size_t)cap);
        snprintf(fs[n].path, sizeof fs[n].path, "%s/%s", dir, e->d_name);
        struct stat st;
        if (stat(fs[n].path, &st)) continue;
        fs[n].t = st.st_mtime, fs[n].size = st.st_size, total += st.st_size, n++;
    }
    closedir(d);
    qsort(fs, (size_t)n, sizeof *fs, cache_file_cmp);
    for (int i = 0; i < n && total > CACHE_MAX; i++)
        if (!unlink(fs[i].path)) total -= fs[i].size;
    free(fs);
}

static void cache_write(const char *map, const struct bl_bake *b, const struct bl_bsp_world *w)
{
    char path[1200], part[1220];
    struct stat st;
    if (!cache_path(map, path, sizeof path, &st)) return;
    struct cache_head h = {{'B', 'L', 'B', 'K'}, BAKE_VERSION, b->scale, w->nfaces, b->nluxels, st.st_size, st.st_mtime, 0, 0};
    size_t fbytes = sizeof *b->faces * (size_t)w->nfaces;
    h.raw = (int64_t)fbytes + 16ll * b->nluxels;
    uint8_t *raw = malloc((size_t)h.raw), *packed = malloc((size_t)h.raw);
    memcpy(raw, b->faces, fbytes), memcpy(raw + fbytes, b->light, 16 * (size_t)b->nluxels);
    h.packed = (int64_t)compression_encode_buffer(packed, (size_t)h.raw, raw, (size_t)h.raw, NULL, COMPRESSION_LZFSE);
    snprintf(part, sizeof part, "%s.part", path);
    FILE *f = h.packed > 0 ? fopen(part, "wb") : NULL;
    int ok = f && fwrite(&h, sizeof h, 1, f) == 1 && fwrite(packed, (size_t)h.packed, 1, f) == 1;
    if (f) ok &= fclose(f) == 0;
    if (ok && !rename(part, path))
        fprintf(stderr, "[bake] saved %s (%.1f MB)\n", path, (double)h.packed / 1048576.0);
    else if (f) unlink(part);
    free(raw), free(packed);
    cache_trim();
}

// --- the open map's rebake ----------------------------------------------------------------

static pthread_mutex_t rb_lock = PTHREAD_MUTEX_INITIALIZER;
static char rb_path[1024];  // the open map's
static int rb_gen, rb_started = -1;
static struct bl_rebake *rb_ready, *rb_prev;  // the newest bake, and the one before (still in use for a frame)

static void rebake_free(struct bl_rebake *r)
{
    if (!r) return;
    bl_bsp_world_free(r->world), bl_bake_free(r->bake);
    free(r);
}

void bl_rebake_note_path(const char *host_path)
{
    pthread_mutex_lock(&rb_lock);
    snprintf(rb_path, sizeof rb_path, "%s", host_path);
    rb_gen++;
    pthread_mutex_unlock(&rb_lock);
}

int bl_rebake_gen(void)
{
    pthread_mutex_lock(&rb_lock);
    int g = rb_gen;
    pthread_mutex_unlock(&rb_lock);
    return g;
}

const struct bl_rebake *bl_rebake_get(int start, int bake)
{
    pthread_mutex_lock(&rb_lock);
    struct bl_rebake *r = rb_ready && rb_ready->gen == rb_gen && (rb_ready->bake || !bake) ? rb_ready : NULL;
    if (!r && start && rb_started != rb_gen * 2 + bake && rb_path[0]) {
        char *path = strdup(rb_path);
        int gen = rb_gen;
        rb_started = gen * 2 + bake;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char err[256];
            // the map's own lightmaps alone (HDR) need only the faces and their lighting, not the props
            struct bl_bsp_world *w = bake ? bl_bsp_world_load(path, err, sizeof err)
                                          : bl_bsp_world_load_no_props(path, err, sizeof err);
            struct bl_bake *b = w && bake ? cache_read(path, w) : NULL;
            if (w && bake && !b) {
                b = bl_bake_map(MTLCreateSystemDefaultDevice(), w, bl_bake_scale(w), 3, err, sizeof err);
                if (b) cache_write(path, b, w);
            }
            if (b) fprintf(stderr, "[bake] %s\n", b->summary);
            else if (!w || bake) fprintf(stderr, "[bake] %s: %s\n", path, err);
            free(path);
            pthread_mutex_lock(&rb_lock);
            if (w && (b || !bake) && gen == rb_gen) {
                struct bl_rebake *n = calloc(1, sizeof *n);
                n->gen = gen, n->world = w, n->bake = b;
                rebake_free(rb_prev);
                rb_prev = rb_ready, rb_ready = n;
            } else {
                bl_bsp_world_free(w), bl_bake_free(b);
            }
            pthread_mutex_unlock(&rb_lock);
        });
    }
    pthread_mutex_unlock(&rb_lock);
    return r;
}
