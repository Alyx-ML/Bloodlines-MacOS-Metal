// The lighting rebake (lm_bake.h). The luxels are laid out on the CPU (each one's place
// on its face, pulled inside the face where the lightmap's grid runs past its edge); the
// GPU then gathers the direct light at each, with a shadow ray to every light that
// reaches it, and the bounces: rays from each luxel, cosine-weighted, read the light of
// the luxels they hit from the pass before, times that texture's reflectivity.
#import "lm_bake.h"
#include <math.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import "mtl4.h"

static NSString *const bake_source =
    @"#include <metal_stdlib>\n"
     "#include <metal_raytracing>\n"
     "using namespace metal;\n"
     "using namespace raytracing;\n"
     // A face: normal and plane distance; lightmap axes; bump directions; reflectivity;
     // lightmap corner, luxels across and down, first luxel, texinfo flags, baked.
     "struct GF { float4 nd, s, t, b0, b1, b2, refl; int mins_s, mins_t, w, h; uint offset, flags, lit, pad; };\n"
     // A light: origin and type; intensity; normal (spots, surfaces: where they face; the
     // sun: where its light goes); stopdot, stopdot2, exponent, radius; attenuation.
     "struct GL { float4 o, i, n, sp, att; };\n"
     "struct LX { float4 p; uint face, pad0, pad1, pad2; };\n"
     "struct BP { uint first, count, nlights, scale, rays, sky_rays; float bias; uint seed, noshadow, samples; float soft; uint pad; };\n"
     "static uint hash(uint x) { x ^= x >> 16; x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16; return x; }\n"
     "static float rnd(thread uint &s) { s = hash(s); return float(s >> 8) * (1.0 / 16777216.0); }\n"
     "static float3 cosine_dir(float3 N, thread uint &seed) {\n"
     "    float3 T = normalize(abs(N.z) < 0.999 ? cross(N, float3(0, 0, 1)) : cross(N, float3(1, 0, 0))), B = cross(N, T);\n"
     "    float u1 = rnd(seed), u2 = rnd(seed), phi = 6.2831853 * u1, r = sqrt(u2);\n"
     "    return normalize(T * (cos(phi) * r) + B * (sin(phi) * r) + N * sqrt(max(1.0 - u2, 0.0))); }\n"
     // The face hit along d from o (and how far), or -1.
     "static int hit_face(primitive_acceleration_structure acc, device const uint *tri_face, float3 o, float3 d,\n"
     "                    float maxd, thread float &dist) {\n"
     "    intersector<triangle_data> it;\n"
     "    it.assume_geometry_type(geometry_type::triangle);\n"
     "    ray r(o, d, 0.0, maxd);\n"
     "    auto h = it.intersect(r, acc);\n"
     "    if (h.type == intersection_type::none) return -1;\n"
     "    dist = h.distance;\n"
     "    return int(tri_face[h.primitive_id]); }\n"
     "static bool blocked(primitive_acceleration_structure acc, float3 o, float3 d, float maxd) {\n"
     "    intersector<triangle_data> it;\n"
     "    it.assume_geometry_type(geometry_type::triangle);\n"
     "    it.accept_any_intersection(true);\n"
     "    ray r(o, d, 0.0, maxd);\n"
     "    return it.intersect(r, acc).type != intersection_type::none; }\n"
     "kernel void bake_direct(device const LX *lux [[buffer(0)]], device const GF *faces [[buffer(1)]],\n"
     "                        device const GL *lights [[buffer(2)]], device const uint *tri_face [[buffer(3)]],\n"
     "                        primitive_acceleration_structure acc [[buffer(4)]], constant BP &bp [[buffer(5)]],\n"
     "                        device float4 *out [[buffer(6)]], uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= bp.count) return;\n"
     "    uint id = bp.first + gid;\n"
     "    LX x = lux[id];\n"
     "    GF f = faces[x.face];\n"
     "    float3 P = x.p.xyz, N = f.nd.xyz, o = P + N * bp.bias;\n"
     "    float3 Bn[3] = {f.b0.xyz, f.b1.xyz, f.b2.xyz};\n"
     "    float3 e[4] = {0, 0, 0, 0};\n"
     "    uint seed = hash(id * 9781u + 17u);\n"
     "    for (uint li = 0; li < bp.nlights; li++) {\n"
     "        GL L = lights[li];\n"
     "        int type = int(L.o.w);\n"
     // The sky's ambient light (5): how much of the sky the luxel sees, cosine-weighted.
     "        if (type == 5) {\n"
     "            float3 s[4] = {0, 0, 0, 0};\n"
     "            for (uint r = 0; r < bp.sky_rays; r++) {\n"
     "                float3 d = cosine_dir(N, seed);\n"
     "                float t;\n"
     "                int hf = hit_face(acc, tri_face, o, d, 1e5, t);\n"
     "                if (hf < 0 || !(faces[hf].flags & 4u)) continue;\n"
     "                float cn = max(dot(N, d), 0.05);\n"
     "                s[0] += 1.0;\n"
     "                for (int k = 0; k < 3; k++) s[k + 1] += clamp(max(dot(Bn[k], d), 0.0) / cn, 0.0, 4.0);\n"
     "            }\n"
     "            for (int k = 0; k < 4; k++) e[k] += L.i.xyz * s[k] / float(bp.sky_rays);\n"
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
     "                    if (d2 <= L.sp.x) fall *= (d2 - L.sp.y) / (L.sp.x - L.sp.y);\n"
     "                    if (L.sp.z != 0.0 && L.sp.z != 1.0) fall *= pow(d2, L.sp.z);\n"
     "                }\n"
     "            }\n"
     "        }\n"
     "        float c[4] = {dot(N, dir), dot(Bn[0], dir), dot(Bn[1], dir), dot(Bn[2], dir)};\n"
     "        float cmax = max(max(c[0], c[1]), max(c[2], c[3]));\n"
     "        float3 I = L.i.xyz * fall;\n"
     "        if (cmax <= 0.0 || max(I.x, max(I.y, I.z)) * cmax < 1e-5) continue;\n"
     "        if (type == 3) {\n"  // the sun: only where the ray reaches the sky
     "            float t;\n"
     "            int hf = hit_face(acc, tri_face, o, dir, 1e5, t);\n"
     "            if (hf < 0 || !(faces[hf].flags & 4u)) continue;\n"
     "        } else if (!bp.noshadow) {\n"
     // Soft shadows: rays to points spread over a small ball round the light, so a
     // shadow's edge fades over a few luxels instead of stepping from luxel to luxel. The
     // same points for every luxel (seeded by the light), so where a prop's box cuts
     // through the ball the light changes smoothly instead of speckling.
     "            float lit = 0.0;\n"
     "            uint ls = hash(li * 2654435761u + 12345u);\n"
     "            for (uint k = 0; k < bp.samples; k++) {\n"
     "                float z = rnd(ls) * 2.0 - 1.0, a = 6.2831853 * rnd(ls), r = bp.soft * pow(rnd(ls), 1.0 / 3.0);\n"
     "                float3 q = L.o.xyz + r * float3(sqrt(1.0 - z * z) * cos(a), sqrt(1.0 - z * z) * sin(a), z) - o;\n"
     "                float ql = length(q);\n"
     "                if (ql > 1.0 && dot(q, N) > 0.0 && !blocked(acc, o, q / ql, ql - 1.0)) lit += 1.0;\n"
     "            }\n"
     "            if (lit == 0.0) continue;\n"
     "            I *= lit / float(bp.samples);\n"
     "        }\n"
     "        for (int k = 0; k < 4; k++) e[k] += I * max(c[k], 0.0);\n"
     "    }\n"
     "    for (int k = 0; k < 4; k++) out[id * 4 + k] = float4(e[k], 0.0);\n"
     "}\n"
     // One bounce: the light arriving from the luxels the rays hit, from the pass before
     // (prev: their flat light), times their texture's reflectivity.
     "kernel void bake_bounce(device const LX *lux [[buffer(0)]], device const GF *faces [[buffer(1)]],\n"
     "                        device const uint *tri_face [[buffer(3)]],\n"
     "                        primitive_acceleration_structure acc [[buffer(4)]], constant BP &bp [[buffer(5)]],\n"
     "                        device float4 *out [[buffer(6)]], device const float4 *prev [[buffer(7)]],\n"
     "                        uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= bp.count) return;\n"
     "    uint id = bp.first + gid;\n"
     "    LX x = lux[id];\n"
     "    GF f = faces[x.face];\n"
     "    float3 N = f.nd.xyz, o = x.p.xyz + N * bp.bias;\n"
     "    float3 Bn[3] = {f.b0.xyz, f.b1.xyz, f.b2.xyz};\n"
     "    float3 s[4] = {0, 0, 0, 0};\n"
     "    uint seed = hash(id * 7919u + 1013u * bp.seed + 77u);\n"
     "    for (uint r = 0; r < bp.rays; r++) {\n"
     "        float3 d = cosine_dir(N, seed);\n"
     "        float t;\n"
     "        int hf = hit_face(acc, tri_face, o, d, 1e5, t);\n"
     "        if (hf < 0) continue;\n"
     "        GF g = faces[hf];\n"
     "        if (!g.lit || dot(d, g.nd.xyz) >= 0.0) continue;\n"  // unlit, or its back (inside a wall)
     "        float3 H = o + d * t;\n"
     "        float u = clamp((dot(H, g.s.xyz) + g.s.w - float(g.mins_s) + 0.5) * float(bp.scale) - 0.5, 0.0, float(g.w - 1));\n"
     "        float v = clamp((dot(H, g.t.xyz) + g.t.w - float(g.mins_t) + 0.5) * float(bp.scale) - 0.5, 0.0, float(g.h - 1));\n"
     "        int u0 = min(int(u), g.w - 1), v0 = min(int(v), g.h - 1), u1 = min(u0 + 1, g.w - 1), v1 = min(v0 + 1, g.h - 1);\n"
     "        float fu = u - float(u0), fv = v - float(v0);\n"
     "        uint b = g.offset;\n"
     "        float3 E = mix(mix(prev[b + uint(v0 * g.w + u0)].xyz, prev[b + uint(v0 * g.w + u1)].xyz, fu),\n"
     "                       mix(prev[b + uint(v1 * g.w + u0)].xyz, prev[b + uint(v1 * g.w + u1)].xyz, fu), fv);\n"
     "        float3 c = g.refl.xyz * E;\n"
     "        float cn = max(dot(N, d), 0.05);\n"
     "        s[0] += c;\n"
     "        for (int k = 0; k < 3; k++) s[k + 1] += c * clamp(max(dot(Bn[k], d), 0.0) / cn, 0.0, 4.0);\n"
     "    }\n"
     "    for (int k = 0; k < 4; k++) out[id * 4 + k] = float4(s[k] / float(bp.rays), 0.0);\n"
     "}\n";

struct gface { float nd[4], s[4], t[4], b[3][4], refl[4]; int mins_s, mins_t, w, h; uint32_t offset, flags, lit, pad; };
struct glight { float o[4], i[4], n[4], sp[4], att[4]; };
struct glux { float p[4]; uint32_t face, pad[3]; };
struct gparams { uint32_t first, count, nlights, scale, rays, sky_rays; float bias; uint32_t seed, noshadow, samples; float soft; uint32_t pad; };

void bl_bake_rgbe(const uint8_t *s, float out[3])
{
    float k = ldexpf(1.0f / 255.0f, (int8_t)s[3]);
    for (int i = 0; i < 3; i++) out[i] = (float)s[i] * k;
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

// vrad's GetBumpNormals with the face's own normal: its bump basis turned into world
// space along the texture's s axis, mirrored when the texture is.
void bl_bake_bump_normals(const struct bl_bsp_world *w, const struct bl_bsp_face *f, float out[3][3])
{
    static const float basis[3][3] = {{0.81649658f, 0, 0.57735027f},
                                      {-0.40824829f, 0.70710678f, 0.57735027f},
                                      {-0.40824829f, -0.70710678f, 0.57735027f}};
    const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
    float s[3] = {t->tex[0][0], t->tex[0][1], t->tex[0][2]}, tt[3] = {t->tex[1][0], t->tex[1][1], t->tex[1][2]};
    float st[3], r0[3], r1[3];
    cross3(s, tt, st);
    int left = dot3(f->normal, st) < 0;
    cross3(f->normal, s, r1);
    normalize3(r1);
    cross3(r1, f->normal, r0);
    normalize3(r0);
    if (left)
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
    return f->lightofs >= 0 && f->texinfo >= 0 && f->disp < 0 && f->count >= 3 && !(w->texinfo[f->texinfo].flags & 0x84);
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
    int total = 0;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        struct gface *g = &gf[i];
        b->faces[i].offset = -1;
        for (int k = 0; k < 3; k++) g->nd[k] = f->normal[k];
        g->nd[3] = f->dist;
        if (f->texinfo < 0) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        g->flags = (uint32_t)t->flags;
        memcpy(g->s, t->lm[0], sizeof g->s), memcpy(g->t, t->lm[1], sizeof g->t);
        if (t->texdata >= 0 && t->texdata < w->ntexdata) memcpy(g->refl, w->texdata[t->texdata].reflectivity, 12);
        if (!bakeable(w, f)) continue;
        float bn[3][3];
        bl_bake_bump_normals(w, f, bn);
        for (int k = 0; k < 3; k++) memcpy(g->b[k], bn[k], 12);
        g->mins_s = f->mins[0], g->mins_t = f->mins[1];
        g->w = (f->size[0] + 1) * scale, g->h = (f->size[1] + 1) * scale;
        g->offset = (uint32_t)total, g->lit = 1;
        b->faces[i] = (struct bl_bake_face){total, g->w, g->h};
        total += g->w * g->h;
    }
    b->nluxels = total;
    // The luxels: each one's place on its face.
    id<MTLBuffer> luxb = [dev newBufferWithLength:sizeof(struct glux) * ((size_t)total + 1) options:MTLResourceStorageModeShared];
    struct glux *lx = luxb.contents;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (b->faces[i].offset < 0) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        float (*c)[2] = malloc(sizeof(float[2]) * (size_t)f->count);
        for (int k = 0; k < f->count; k++) {
            const float *v = w->verts[w->index[f->first + k]];
            for (int a = 0; a < 2; a++) c[k][a] = v[0] * t->lm[a][0] + v[1] * t->lm[a][1] + v[2] * t->lm[a][2] + t->lm[a][3];
        }
        for (int y = 0; y < b->faces[i].h; y++)
            for (int x = 0; x < b->faces[i].w; x++) {
                float pt[2] = {(float)f->mins[0] + ((float)x + 0.5f) / (float)scale - 0.5f,
                               (float)f->mins[1] + ((float)y + 0.5f) / (float)scale - 0.5f};
                pull_inside(c, f->count, pt);
                struct glux *l = &lx[b->faces[i].offset + y * b->faces[i].w + x];
                plane_point(t, f, pt[0], pt[1], l->p);
                for (int k = 0; k < 3; k++) l->p[k] += f->origin[k];
                l->face = (uint32_t)i;
            }
        free(c);
    }
    // The occluders: the world's faces (model 0), the sky's among them so rays can find
    // it; not see-through ones (0x10) and not brush entities, as vrad leaves them out; and
    // the static props' collision models, which stand for face nfaces (unlit, not sky):
    // they block light and give none back.
    int nprop = w->props ? w->props->ntris : 0;
    int ntri = nprop;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (f->model == 0 && f->count >= 3 && f->disp < 0 && f->texinfo >= 0 && !(w->texinfo[f->texinfo].flags & 0x10))
            ntri += f->count - 2;
    }
    id<MTLBuffer> vb = [dev newBufferWithLength:12 * ((size_t)w->nverts + 3 * (size_t)nprop) options:MTLResourceStorageModeShared];
    memcpy(vb.contents, w->verts, 12 * (size_t)w->nverts);
    if (nprop) memcpy((float *)vb.contents + 3 * w->nverts, w->props->tris, 36 * (size_t)nprop);
    id<MTLBuffer> ib = [dev newBufferWithLength:12 * ((size_t)ntri + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> tfb = [dev newBufferWithLength:4 * ((size_t)ntri + 1) options:MTLResourceStorageModeShared];
    uint32_t *idx = ib.contents, *tri_face = tfb.contents;
    int nt = 0;
    for (int i = 0; i < w->nfaces; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (!(f->model == 0 && f->count >= 3 && f->disp < 0 && f->texinfo >= 0 && !(w->texinfo[f->texinfo].flags & 0x10)))
            continue;
        for (int k = 1; k + 1 < f->count; k++) {
            idx[3 * nt] = (uint32_t)w->index[f->first], idx[3 * nt + 1] = (uint32_t)w->index[f->first + k];
            idx[3 * nt + 2] = (uint32_t)w->index[f->first + k + 1];
            tri_face[nt++] = (uint32_t)i;
        }
    }
    for (int i = 0; i < nprop; i++, nt++) {
        for (int k = 0; k < 3; k++) idx[3 * nt + k] = (uint32_t)(w->nverts + 3 * i + k);
        tri_face[nt] = (uint32_t)w->nfaces;
    }
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
        bl_bake_free(b);
        return NULL;
    }
    for (id<MTLAllocation> r in @[ luxb, vb, ib, tfb, accel, scratch ]) [job keep:r];
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
        struct glight *g = &gl[nl++];
        memcpy(g->o, l->origin, 12), g->o[3] = (float)l->type;
        memcpy(g->i, l->intensity, 12), memcpy(g->n, l->normal, 12);
        g->sp[0] = l->stopdot, g->sp[1] = l->stopdot2, g->sp[2] = l->exponent, g->sp[3] = l->radius;
        memcpy(g->att, l->att, 12);
        if (g->att[0] <= 0 && g->att[1] <= 0 && g->att[2] <= 0) g->att[2] = 1;
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
    size_t lbytes = 16 * 4 * ((size_t)total + 1);
    id<MTLBuffer> direct = [dev newBufferWithLength:lbytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> gather = [dev newBufferWithLength:lbytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> prev = [dev newBufferWithLength:16 * ((size_t)total + 1) options:MTLResourceStorageModeShared];
    id<MTLBuffer> params = [dev newBufferWithLength:sizeof(struct gparams) options:MTLResourceStorageModeShared];
    for (id<MTLAllocation> r in @[ lb, fb, direct, gather, prev, params ]) [job keep:r];
    id<MTL4ArgumentTable> at = job.table;
    [at setAddress:luxb.gpuAddress atIndex:0];
    [at setAddress:fb.gpuAddress atIndex:1];
    [at setAddress:lb.gpuAddress atIndex:2];
    [at setAddress:tfb.gpuAddress atIndex:3];
    [at setResource:accel.gpuResourceID atBufferIndex:4];
    [at setAddress:params.gpuAddress atIndex:5];
    [at setAddress:prev.gpuAddress atIndex:7];
    // 512 bounce rays per luxel; 16 shadow rays per light, over a ball 6 units across.
    struct gparams gp = {0, 0, (uint32_t)nl, (uint32_t)scale, 512, 64, 0.25f, 0, 0, 16, 3.0f, 0};
    gp.noshadow = getenv("BL_BAKE_NOSHADOW") != NULL;  // debugging: direct light without shadows
    if (getenv("BL_BAKE_RAYS")) gp.rays = (uint32_t)atoi(getenv("BL_BAKE_RAYS"));  // debugging
    int blur = getenv("BL_BAKE_BLUR") ? atoi(getenv("BL_BAKE_BLUR")) : scale / 2;  // debugging
    // A pass in pieces, each its own command buffer, so none runs long. Each piece's
    // parameters go in `params`, free again once the piece before has been waited for.
    __block NSError *failed = built;
    void (^run)(id<MTLComputePipelineState>, id<MTLBuffer>, uint32_t) = ^(id<MTLComputePipelineState> p, id<MTLBuffer> out,
                                                                          uint32_t pass) {
        const uint32_t piece = 32768;
        [at setAddress:out.gpuAddress atIndex:6];
        for (uint32_t first = 0; first < (uint32_t)total && !failed; first += piece) {
            struct gparams *g = params.contents;
            *g = gp;
            g->first = first, g->count = (uint32_t)total - first < piece ? (uint32_t)total - first : piece;
            g->seed = pass;  // a different random pattern each bounce
            id<MTL4ComputeCommandEncoder> e = [[job begin] computeCommandEncoder];
            [e setComputePipelineState:p];
            [e setArgumentTable:at];
            [e dispatchThreads:MTLSizeMake(g->count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
            [e endEncoding];
            failed = [job run];
        }
    };
    run(pd, direct, 0);
    b->light = calloc((size_t)total + 1, sizeof *b->light);
    memcpy(b->light, direct.contents, 64 * (size_t)total);
    // Bounces, each from the one before.
    float (*dl)[4][4] = direct.contents, (*gl4)[4][4] = gather.contents, (*pv)[4] = prev.contents;
    for (int i = 0; i < total; i++) memcpy(pv[i], dl[i][0], 16);
    float (*tmp)[4][4] = malloc(64 * ((size_t)total + 1));
    for (int pass = 1; pass <= bounces; pass++) {
        run(pb, gather, (uint32_t)pass);
        // Bounced light changes slowly over a surface: blurred within each face (a box
        // about one of the map's own luxels across), the rays' noise goes.
        for (int dirn = 0; dirn < 2; dirn++)
            for (int i = 0; i < w->nfaces; i++) {
                const struct bl_bake_face *bf = &b->faces[i];
                if (bf->offset < 0) continue;
                int r = blur, n = dirn ? bf->h : bf->w, m = dirn ? bf->w : bf->h;
                for (int j = 0; j < m; j++)
                    for (int x = 0; x < n; x++) {
                        float acc[4][4] = {{0}};
                        int cnt = 0;
                        for (int d = -r; d <= r; d++) {
                            int y = x + d;
                            if (y < 0 || y >= n) continue;
                            int at = bf->offset + (dirn ? y * bf->w + j : j * bf->w + y);
                            for (int k = 0; k < 4; k++)
                                for (int c = 0; c < 3; c++) acc[k][c] += gl4[at][k][c];
                            cnt++;
                        }
                        int at = bf->offset + (dirn ? x * bf->w + j : j * bf->w + x);
                        for (int k = 0; k < 4; k++)
                            for (int c = 0; c < 4; c++) tmp[at][k][c] = acc[k][c] / (float)cnt;
                    }
                memcpy(gl4[bf->offset], tmp[bf->offset], 64 * (size_t)bf->w * (size_t)bf->h);
            }
        for (int i = 0; i < total; i++) {
            for (int k = 0; k < 4; k++)
                for (int c = 0; c < 3; c++) b->light[i][k][c] += gl4[i][k][c];
            memcpy(pv[i], gl4[i][0], 16);
        }
    }
    free(tmp);
    if (failed) {
        snprintf(err, (size_t)errlen, "bake: %s", failed.localizedDescription.UTF8String);
        bl_bake_free(b);
        return NULL;
    }
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    b->seconds = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    snprintf(b->summary, sizeof b->summary,
             "%s: %d luxels (x%d per side), %d occluding triangles (%d of them props'), %d lights, %d bounces, %.1f s on %s", w->name,
             total, scale, nt, nprop, nl, bounces, b->seconds, dev.name.UTF8String);
    return b;
}

void bl_bake_free(struct bl_bake *b)
{
    if (!b) return;
    free(b->faces), free(b->light);
    free(b);
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
    struct bl_rebake *r = rb_ready && rb_ready->gen == rb_gen ? rb_ready : NULL;
    if (!r && start && rb_started != rb_gen && rb_path[0]) {
        char *path = strdup(rb_path);
        int gen = rb_gen;
        rb_started = gen;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char err[256];
            id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
            // the HDR lightmaps alone need only the faces and their lighting, not the props
            struct bl_bsp_world *w = bake ? bl_bsp_world_load(path, err, sizeof err)
                                          : bl_bsp_world_load_no_props(path, err, sizeof err);
            struct bl_bake *b = w && bake ? bl_bake_map(dev, w, 4, 3, err, sizeof err) : NULL;
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
