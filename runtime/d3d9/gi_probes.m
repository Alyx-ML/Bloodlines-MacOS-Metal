// Light probes (gi_probes.h). Each probe is six 16 x 16 views of the map from its point,
// drawn into layers of one texture, many probes per draw (instanced, each instance its
// own layer); a compute pass then sums each probe's views per axis direction and adds
// the map's point and spot lights it can see.
#import "gi_probes.h"
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#import "lm_bake.h"

#define GI_RES 16          // each view, texels across
#define GI_BATCH 341       // probes per draw: 6 layers each, up to 2048 layers
#define GI_MAX_PROBES 32768
#define GI_MAX_CELLS (16L << 20)
#define GI_FLOOR 160       // a probe's floor at most this far below

static NSString *const gi_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     // A corner: position; lightmap atlas coordinates (x < 0: none); the texture's mean
     // colour; light it gives off; the face's normal; 1 for the sky (never seen from behind).
     "struct GV { packed_float3 pos; packed_float2 uv; packed_float3 alb, emit, n; float sky; };\n"
     "struct VO { float4 pos [[position]]; float2 uv; float3 alb, emit, n, w; float sky;\n"
     "            float3 probe [[flat]]; uint layer [[render_target_array_index]]; };\n"
     "constant float3 faceF[6] = {float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0), float3(0, -1, 0), float3(0, 0, 1), float3(0, 0, -1)};\n"
     "constant float3 faceU[6] = {float3(0, 0, 1), float3(0, 0, 1), float3(0, 0, 1), float3(0, 0, 1), float3(0, 1, 0), float3(0, 1, 0)};\n"
     "vertex VO gi_vs(uint vid [[vertex_id]], uint inst [[instance_id]], device const GV *v [[buffer(0)]],\n"
     "                device const float4 *probes [[buffer(1)]], constant uint &first [[buffer(2)]]) {\n"
     "    uint f = inst % 6;\n"
     "    float3 P = probes[first + inst / 6].xyz, W = float3(v[vid].pos), d = W - P;\n"
     "    float3 F = faceF[f], U = faceU[f], R = cross(F, U);\n"
     "    const float n = 1.0, fa = 16384.0;\n"
     "    float z = dot(d, F);\n"
     "    VO o;\n"
     "    o.pos = float4(dot(d, R), dot(d, U), z * fa / (fa - n) - n * fa / (fa - n), z);\n"
     "    o.uv = float2(v[vid].uv), o.alb = float3(v[vid].alb), o.emit = float3(v[vid].emit), o.n = float3(v[vid].n);\n"
     "    o.w = W, o.sky = v[vid].sky, o.probe = P, o.layer = inst;\n"
     "    return o;\n"
     "}\n"
     // rgb the light seen, a how far; a < 0 a face seen from behind: the probe is inside a
     // wall or outside the map that way.
     "fragment float4 gi_fs(VO in [[stage_in]], texture2d<float> lm [[texture(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    if (in.sky < 0.5 && dot(in.n, in.probe - in.w) < 0.0) return float4(0.0, 0.0, 0.0, -1.0);\n"
     "    float3 l = in.uv.x >= 0.0 ? lm.sample(s, in.uv).rgb : float3(0.0);\n"
     "    return float4(in.alb * l + in.emit, length(in.w - in.probe));\n"
     "}\n"
     // A light, as lm_bake.m has them: origin and type; intensity; normal; stopdot,
     // stopdot2, exponent, radius; attenuation.
     "struct GL { float4 o, i, n, sp, att; };\n"
     "struct PO { float4 b[6], d[6], back; };\n"
     "static uint face_of(float3 d) {\n"
     "    float3 a = abs(d);\n"
     "    return a.x >= a.y && a.x >= a.z ? (d.x > 0.0 ? 0u : 1u) : a.y >= a.z ? (d.y > 0.0 ? 2u : 3u) : (d.z > 0.0 ? 4u : 5u);\n"
     "}\n"
     "static void axes(float3 d, thread float *w) {\n"
     "    w[0] = max(d.x, 0.0), w[1] = max(-d.x, 0.0), w[2] = max(d.y, 0.0), w[3] = max(-d.y, 0.0);\n"
     "    w[4] = max(d.z, 0.0), w[5] = max(-d.z, 0.0);\n"
     "}\n"
     "kernel void gi_reduce(texture2d_array<float> cap [[texture(0)]], device const float4 *probes [[buffer(0)]],\n"
     "                      device const GL *lights [[buffer(1)]], constant uint4 &k [[buffer(2)]],\n"
     "                      device PO *out [[buffer(3)]], uint gid [[thread_position_in_grid]]) {\n"
     "    if (gid >= k.y) return;\n"
     "    uint res = k.w;\n"
     "    float3 P = probes[k.x + gid].xyz;\n"
     "    float3 b[6] = {0, 0, 0, 0, 0, 0}, dl[6] = {0, 0, 0, 0, 0, 0};\n"
     "    float back = 0.0, total = 0.0, w[6];\n"
     "    for (uint f = 0; f < 6; f++) {\n"
     "        float3 F = faceF[f], U = faceU[f], R = cross(F, U);\n"
     "        for (uint j = 0; j < res; j++)\n"
     "            for (uint i = 0; i < res; i++) {\n"
     "                float x = (float(i) + 0.5) / float(res) * 2.0 - 1.0, y = 1.0 - (float(j) + 0.5) / float(res) * 2.0;\n"
     "                float3 d = F + x * R + y * U;\n"
     "                float l2 = dot(d, d), dw = 4.0 / float(res * res) / (l2 * sqrt(l2));\n"
     "                float4 c = cap.read(uint2(i, j), gid * 6 + f);\n"
     "                total += dw;\n"
     "                if (c.a < 0.0) { back += dw; continue; }\n"
     "                axes(d * rsqrt(l2), w);\n"
     "                for (int a = 0; a < 6; a++) b[a] += c.rgb * (w[a] * dw);\n"
     "            }\n"
     "    }\n"
     "    for (uint li = 0; li < k.z; li++) {\n"
     "        GL L = lights[li];\n"
     "        int type = int(L.o.w);\n"
     "        if (type != 1 && type != 2) continue;\n"
     "        float3 dv = L.o.xyz - P;\n"
     "        float len = length(dv);\n"
     "        if (len < 1e-3) continue;\n"
     "        float3 dir = dv / len;\n"
     "        float dist = max(len, 1.0);\n"
     "        if (L.sp.w > 0.0 && dist > L.sp.w) continue;\n"
     "        float fall = 1.0 / max(L.att.x + L.att.y * dist + L.att.z * dist * dist, 1e-6);\n"
     "        if (type == 2) {\n"
     "            float d2 = -dot(dir, L.n.xyz);\n"
     "            if (d2 <= L.sp.y) continue;\n"
     "            if (d2 <= L.sp.x) fall *= (d2 - L.sp.y) / (L.sp.x - L.sp.y);\n"
     "            if (L.sp.z != 0.0 && L.sp.z != 1.0) fall *= pow(d2, L.sp.z);\n"
     "        }\n"
     // Seen from the probe: nothing nearer in its direction on the view.
     "        uint f = face_of(dir);\n"
     "        float3 F = faceF[f], U = faceU[f], R = cross(F, U);\n"
     "        float fz = dot(dir, F), x = dot(dir, R) / fz, y = dot(dir, U) / fz;\n"
     "        uint i = uint(clamp((x + 1.0) * 0.5 * float(res), 0.0, float(res) - 1.0));\n"
     "        uint j = uint(clamp((1.0 - y) * 0.5 * float(res), 0.0, float(res) - 1.0));\n"
     "        float seen = cap.read(uint2(i, j), gid * 6 + f).a;\n"
     "        if (seen < len - max(8.0, 0.03 * len)) continue;\n"
     "        axes(dir, w);\n"
     "        for (int a = 0; a < 6; a++) dl[a] += L.i.xyz * (fall * w[a]);\n"
     "    }\n"
     "    for (int a = 0; a < 6; a++) out[gid].b[a] = float4(b[a] / 3.14159265, 0.0), out[gid].d[a] = float4(dl[a], 0.0);\n"
     "    out[gid].back = float4(total > 0.0 ? back / total : 1.0);\n"
     "}\n";

struct gv { float pos[3], uv[2], alb[3], emit[3], n[3], sky; };
struct gl { float o[4], i[4], n[4], sp[4], att[4]; };
struct po { float b[6][4], d[6][4], back[4]; };

// Shelf packing, as tests/bake_view.m: each face's rectangle in an atlas `width` wide;
// returns its height.
static int pack(const int *w, const int *h, int n, int width, int *x, int *y)
{
    int *order = malloc(sizeof(int) * (size_t)(n + 1));
    int m = 0;
    for (int i = 0; i < n; i++)
        if (w[i] > 0) order[m++] = i;
    for (int i = 1; i < m; i++)
        for (int j = i; j > 0 && h[order[j]] > h[order[j - 1]]; j--) {
            int t = order[j];
            order[j] = order[j - 1], order[j - 1] = t;
        }
    int cx = 0, cy = 0, row = 0;
    for (int k = 0; k < m; k++) {
        int i = order[k];
        if (cx + w[i] + 1 > width) cx = 0, cy += row + 1, row = 0;
        x[i] = cx, y[i] = cy;
        cx += w[i] + 1;
        if (h[i] > row) row = h[i];
    }
    free(order);
    return cy + row + 1;
}

static int drawn(const struct bl_bsp_world *w, const struct bl_bsp_face *f)
{
    // Not: displacements (their shape is elsewhere), nodraw, hint and skip faces.
    return f->texinfo >= 0 && f->disp < 0 && f->count >= 3 && !(w->texinfo[f->texinfo].flags & (0x80 | 0x100 | 0x200));
}

struct bl_gi *bl_gi_capture(id<MTLDevice> dev, const struct bl_bsp_world *w, char *err, int errlen)
{
    if (!dev) {
        snprintf(err, (size_t)errlen, "no Metal device");
        return NULL;
    }
    struct timespec t0;
    clock_gettime(CLOCK_MONOTONIC, &t0);
    int nf = w->nfaces;
    // The map's own lightmaps (style 0's flat set) in one atlas.
    int *ow = calloc((size_t)nf + 1, sizeof(int)), *oh = calloc((size_t)nf + 1, sizeof(int));
    int *ox = calloc((size_t)nf + 1, sizeof(int)), *oy = calloc((size_t)nf + 1, sizeof(int));
    for (int i = 0; i < nf; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (drawn(w, f) && f->lightofs >= 0 && !(w->texinfo[f->texinfo].flags & 4))
            ow[i] = f->size[0] + 1, oh[i] = f->size[1] + 1;
    }
    int aw = 2048, ah = pack(ow, oh, nf, aw, ox, oy);
    if (ah > 16384) {
        snprintf(err, (size_t)errlen, "lightmap atlas too tall (%d)", ah);
        free(ow), free(oh), free(ox), free(oy);
        return NULL;
    }
    _Float16 *atlas = calloc((size_t)aw * ah * 4, sizeof *atlas);
    for (int i = 0; i < nf; i++) {
        if (!ow[i]) continue;
        const struct bl_bsp_face *f = &w->faces[i];
        for (int y = 0; y < oh[i]; y++)
            for (int x = 0; x < ow[i]; x++) {
                float c[3];
                bl_bake_rgbe(w->lighting + 4 * ((size_t)f->lightofs + (size_t)y * ow[i] + x), c);
                _Float16 *p = atlas + 4 * ((size_t)(oy[i] + y) * aw + ox[i] + x);
                p[0] = (_Float16)c[0], p[1] = (_Float16)c[1], p[2] = (_Float16)c[2], p[3] = 1;
            }
    }
    // Glowing surfaces: the map compiler made each into surface lights; their intensity
    // over the area of the faces with that texture is the light they give off (a light of
    // intensity I lights a lightmap I cos / d^2, a glowing patch of radiance L and area A
    // L A cos cos' / (pi d^2)). The sky gives off its ambient light's.
    float (*emit)[3] = calloc((size_t)w->ntexinfo + 1, sizeof *emit);
    float *area = calloc((size_t)w->ntexinfo + 1, sizeof *area);
    float sky[3] = {0, 0, 0};
    for (int i = 0; i < nf; i++)
        if (drawn(w, &w->faces[i])) area[w->faces[i].texinfo] += w->faces[i].area;
    for (int i = 0; i < w->nlights; i++) {
        const struct bl_bsp_worldlight *l = &w->lights[i];
        if (l->style != 0) continue;
        if (l->type == 0 && l->texinfo >= 0 && l->texinfo < w->ntexinfo)
            for (int c = 0; c < 3; c++) emit[l->texinfo][c] += l->intensity[c];
        if (l->type == 5) memcpy(sky, l->intensity, 12);
    }
    for (int t = 0; t < w->ntexinfo; t++)
        for (int c = 0; c < 3; c++) emit[t][c] = area[t] > 0 ? emit[t][c] * 3.14159265f / area[t] : 0;
    // The faces as triangles (fans, by index).
    int nv = 0, ni = 0;
    for (int i = 0; i < nf; i++)
        if (drawn(w, &w->faces[i])) nv += w->faces[i].count, ni += 3 * (w->faces[i].count - 2);
    struct gv *verts = calloc((size_t)nv + 1, sizeof *verts);
    uint32_t *idx = calloc((size_t)ni + 1, sizeof *idx);
    float lo[3] = {1e9f, 1e9f, 1e9f}, hi[3] = {-1e9f, -1e9f, -1e9f};
    int kv = 0, ki = 0;
    for (int i = 0; i < nf; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (!drawn(w, f)) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        int is_sky = (t->flags & 4) != 0;
        for (int c = 1; c + 1 < f->count; c++)
            idx[ki++] = (uint32_t)kv, idx[ki++] = (uint32_t)(kv + c), idx[ki++] = (uint32_t)(kv + c + 1);
        for (int c = 0; c < f->count; c++) {
            const float *p = w->verts[w->index[f->first + c]];
            struct gv *v = &verts[kv++];
            for (int a = 0; a < 3; a++) v->pos[a] = p[a] + f->origin[a];
            if (f->model == 0)
                for (int a = 0; a < 3; a++) lo[a] = fminf(lo[a], v->pos[a]), hi[a] = fmaxf(hi[a], v->pos[a]);
            memcpy(v->n, f->normal, 12);
            v->sky = (float)is_sky;
            if (is_sky) {
                memcpy(v->emit, sky, 12);
                v->uv[0] = v->uv[1] = -1;
                continue;
            }
            memcpy(v->alb, w->texdata[t->texdata].reflectivity, 12);
            memcpy(v->emit, emit[f->texinfo], 12);
            if (!ow[i]) {
                v->uv[0] = v->uv[1] = -1;
                continue;
            }
            float s = p[0] * t->lm[0][0] + p[1] * t->lm[0][1] + p[2] * t->lm[0][2] + t->lm[0][3] - (float)f->mins[0];
            float u = p[0] * t->lm[1][0] + p[1] * t->lm[1][1] + p[2] * t->lm[1][2] + t->lm[1][3] - (float)f->mins[1];
            v->uv[0] = ((float)ox[i] + s + 0.5f) / (float)aw, v->uv[1] = ((float)oy[i] + u + 0.5f) / (float)ah;
        }
    }
    free(ow), free(oh), free(ox), free(oy), free(emit), free(area);
    if (!ki || lo[0] > hi[0]) {
        snprintf(err, (size_t)errlen, "no faces to draw");
        free(verts), free(idx), free(atlas);
        return NULL;
    }

    // The grid: over the world's bounds, 64 units apart or more; a probe at each point in
    // the map's open space with a floor no more than GI_FLOOR below, up to GI_MAX_PROBES.
    struct bl_gi *g = calloc(1, sizeof *g);
    float step = 64;
    long cells;
    for (;; step *= 1.15f) {
        cells = 1;
        for (int a = 0; a < 3; a++) {
            g->n[a] = (int)floorf((hi[a] - lo[a]) / step) + 1;
            g->origin[a] = (lo[a] + hi[a]) * 0.5f - (float)(g->n[a] - 1) * step * 0.5f;
            cells *= g->n[a];
        }
        if (cells > GI_MAX_CELLS) continue;
        free(g->slot);
        g->slot = malloc(sizeof(int) * (size_t)cells);
        g->nprobes = 0;
        for (int z = 0, k = 0; z < g->n[2]; z++)
            for (int y = 0; y < g->n[1]; y++)
                for (int x = 0; x < g->n[0]; x++, k++) {
                    float p[3] = {g->origin[0] + (float)x * step, g->origin[1] + (float)y * step, g->origin[2] + (float)z * step};
                    int keep = bl_bsp_world_open(w, p), floor = 0;
                    for (float dz = 16; keep && !floor && dz <= GI_FLOOR; dz += 16) {
                        float q[3] = {p[0], p[1], p[2] - dz};
                        floor = !bl_bsp_world_open(w, q);
                    }
                    g->slot[k] = keep && floor ? g->nprobes++ : -1;
                }
        if (g->nprobes <= GI_MAX_PROBES) break;
    }
    g->step = step;
    int np = g->nprobes;
    if (!np) {
        snprintf(err, (size_t)errlen, "no open space with a floor");
        free(verts), free(idx), free(atlas), free(g->slot), free(g);
        return NULL;
    }
    id<MTLBuffer> pb = [dev newBufferWithLength:16 * (size_t)np options:MTLResourceStorageModeShared];
    float(*pp)[4] = pb.contents;
    for (int z = 0, k = 0; z < g->n[2]; z++)
        for (int y = 0; y < g->n[1]; y++)
            for (int x = 0; x < g->n[0]; x++, k++)
                if (g->slot[k] >= 0) {
                    float *q = pp[g->slot[k]];
                    q[0] = g->origin[0] + (float)x * step, q[1] = g->origin[1] + (float)y * step;
                    q[2] = g->origin[2] + (float)z * step, q[3] = 1;
                }

    // The lights, style 0 only, as lm_bake.m takes them.
    id<MTLBuffer> lb = [dev newBufferWithLength:sizeof(struct gl) * ((size_t)w->nlights + 1) options:MTLResourceStorageModeShared];
    struct gl *gls = lb.contents;
    int nl = 0;
    for (int i = 0; i < w->nlights; i++) {
        const struct bl_bsp_worldlight *l = &w->lights[i];
        if (l->style != 0 || (l->type != 1 && l->type != 2)) continue;
        struct gl *q = &gls[nl++];
        memcpy(q->o, l->origin, 12), q->o[3] = (float)l->type;
        memcpy(q->i, l->intensity, 12), memcpy(q->n, l->normal, 12);
        q->sp[0] = l->stopdot, q->sp[1] = l->stopdot2, q->sp[2] = l->exponent, q->sp[3] = l->radius;
        memcpy(q->att, l->att, 12);
        if (q->att[0] <= 0 && q->att[1] <= 0 && q->att[2] <= 0) q->att[2] = 1;
    }

    NSError *error = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:gi_source options:[MTLCompileOptions new] error:&error];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"gi_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"gi_fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    pd.inputPrimitiveTopology = MTLPrimitiveTopologyClassTriangle;
    id<MTLRenderPipelineState> pso = lib ? [dev newRenderPipelineStateWithDescriptor:pd error:&error] : nil;
    id<MTLComputePipelineState> cps =
        pso ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"gi_reduce"] error:&error] : nil;
    if (!cps) {
        snprintf(err, (size_t)errlen, "probe shaders: %s", error.localizedDescription.UTF8String);
        free(verts), free(idx), free(atlas), free(g->slot), free(g);
        return NULL;
    }
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = MTLCompareFunctionLess, dd.depthWriteEnabled = YES;
    id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dd];
    MTLTextureDescriptor *ad = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                  width:(NSUInteger)aw
                                                                                 height:(NSUInteger)ah
                                                                              mipmapped:NO];
    id<MTLTexture> lm = [dev newTextureWithDescriptor:ad];
    [lm replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)aw, (NSUInteger)ah) mipmapLevel:0 withBytes:atlas
          bytesPerRow:(NSUInteger)aw * 8];
    free(atlas);
    id<MTLBuffer> vb = [dev newBufferWithBytes:verts length:sizeof *verts * (size_t)nv options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [dev newBufferWithBytes:idx length:4 * (size_t)ki options:MTLResourceStorageModeShared];
    free(verts), free(idx);
    MTLTextureDescriptor *cd = [MTLTextureDescriptor new];
    cd.textureType = MTLTextureType2DArray, cd.pixelFormat = MTLPixelFormatRGBA16Float;
    cd.width = cd.height = GI_RES, cd.arrayLength = GI_BATCH * 6;
    cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, cd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> cap = [dev newTextureWithDescriptor:cd];
    cd.pixelFormat = MTLPixelFormatDepth32Float, cd.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:cd];
    id<MTLBuffer> ob = [dev newBufferWithLength:sizeof(struct po) * (size_t)np options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    for (int first = 0; first < np; first += GI_BATCH) {
        uint32_t count = (uint32_t)(np - first < GI_BATCH ? np - first : GI_BATCH), f32 = (uint32_t)first;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = cap;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        // Nothing drawn: no light from there, and nothing in the way of the map's lights (the
        // map has holes where it is never seen from: nodraw faces, displacements).
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 65504);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1;
        rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.renderTargetArrayLength = count * 6;
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:pso];
        [e setDepthStencilState:dss];
        [e setCullMode:MTLCullModeNone];
        [e setVertexBuffer:vb offset:0 atIndex:0];
        [e setVertexBuffer:pb offset:0 atIndex:1];
        [e setVertexBytes:&f32 length:4 atIndex:2];
        [e setFragmentTexture:lm atIndex:0];
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)ki indexType:MTLIndexTypeUInt32
                     indexBuffer:ib indexBufferOffset:0 instanceCount:count * 6];
        [e endEncoding];
        id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
        uint32_t k4[4] = {f32, count, (uint32_t)nl, GI_RES};
        [ce setComputePipelineState:cps];
        [ce setTexture:cap atIndex:0];
        [ce setBuffer:pb offset:0 atIndex:0];
        [ce setBuffer:lb offset:0 atIndex:1];
        [ce setBytes:k4 length:sizeof k4 atIndex:2];
        [ce setBuffer:ob offset:sizeof(struct po) * (size_t)first atIndex:3];
        [ce dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        if (cb.error) {
            snprintf(err, (size_t)errlen, "probe capture: %s", cb.error.localizedDescription.UTF8String);
            free(g->slot), free(g);
            return NULL;
        }
    }
    g->bounce = malloc(sizeof *g->bounce * (size_t)np);
    g->direct = malloc(sizeof *g->direct * (size_t)np);
    g->valid = malloc((size_t)np);
    const struct po *o = ob.contents;
    for (int i = 0; i < np; i++) {
        for (int a = 0; a < 6; a++)
            for (int c = 0; c < 3; c++) g->bounce[i][a][c] = o[i].b[a][c], g->direct[i][a][c] = o[i].d[a][c];
        g->valid[i] = o[i].back[0] < 0.1f;
        g->nvalid += g->valid[i];
    }
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    g->seconds = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    snprintf(g->summary, sizeof g->summary, "%s: %d probes %.0f units apart (%d clear of walls), %d lights; %.2f s on %s",
             w->name, np, step, g->nvalid, nl, g->seconds, dev.name.UTF8String);
    return g;
}

void bl_gi_free(struct bl_gi *g)
{
    if (!g) return;
    free(g->slot), free(g->bounce), free(g->direct), free(g->valid);
    free(g);
}

int bl_gi_sample(const struct bl_gi *g, const float p[3], float bounce[6][3], float direct[6][3])
{
    float f[3];
    int c[3];
    for (int a = 0; a < 3; a++) {
        f[a] = (p[a] - g->origin[a]) / g->step;
        c[a] = (int)floorf(f[a]);
        f[a] -= (float)c[a];
    }
    memset(bounce, 0, sizeof(float) * 18), memset(direct, 0, sizeof(float) * 18);
    float sum = 0;
    for (int k = 0; k < 8; k++) {
        int x = c[0] + (k & 1), y = c[1] + (k >> 1 & 1), z = c[2] + (k >> 2);
        if (x < 0 || y < 0 || z < 0 || x >= g->n[0] || y >= g->n[1] || z >= g->n[2]) continue;
        int i = g->slot[(z * g->n[1] + y) * g->n[0] + x];
        if (i < 0 || !g->valid[i]) continue;
        float wt = (k & 1 ? f[0] : 1 - f[0]) * (k >> 1 & 1 ? f[1] : 1 - f[1]) * (k >> 2 ? f[2] : 1 - f[2]) + 1e-4f;
        for (int a = 0; a < 6; a++)
            for (int ch = 0; ch < 3; ch++) bounce[a][ch] += g->bounce[i][a][ch] * wt, direct[a][ch] += g->direct[i][a][ch] * wt;
        sum += wt;
    }
    if (sum <= 0) return 0;
    for (int a = 0; a < 6; a++)
        for (int ch = 0; ch < 3; ch++) bounce[a][ch] /= sum, direct[a][ch] /= sum;
    return 1;
}

// --- the open map's probes -----------------------------------------------------------

static pthread_mutex_t gi_lock = PTHREAD_MUTEX_INITIALIZER;
static struct bl_bsp_world *gi_world;  // the open map's, until its capture starts
static int gi_gen, gi_started = -1;
static struct bl_gi *gi_ready, *gi_prev;  // the newest capture, and the one before (in use for a frame)

void bl_map_note(struct bl_bsp_world *w, const char *host_path)
{
    pthread_mutex_lock(&gi_lock);
    bl_bsp_world_free(gi_world);
    gi_world = w, gi_gen++;
    pthread_mutex_unlock(&gi_lock);
    bl_rebake_note_path(host_path);
}

int bl_gi_gen(void)
{
    pthread_mutex_lock(&gi_lock);
    int g = gi_gen;
    pthread_mutex_unlock(&gi_lock);
    return g;
}

const struct bl_gi *bl_gi_get(int start)
{
    pthread_mutex_lock(&gi_lock);
    struct bl_gi *r = gi_ready && gi_ready->gen == gi_gen ? gi_ready : NULL;
    if (!r && start && gi_started != gi_gen && gi_world) {
        struct bl_bsp_world *w = gi_world;
        int gen = gi_gen;
        gi_world = NULL, gi_started = gen;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char err[256];
            struct bl_gi *g = bl_gi_capture(MTLCreateSystemDefaultDevice(), w, err, sizeof err);
            if (g) fprintf(stderr, "[gi] %s\n", g->summary);
            else fprintf(stderr, "[gi] %s: %s\n", w->name, err);
            bl_bsp_world_free(w);
            pthread_mutex_lock(&gi_lock);
            if (g && gen == gi_gen) {
                g->gen = gen;
                bl_gi_free(gi_prev);
                gi_prev = gi_ready, gi_ready = g;
            } else {
                bl_gi_free(g);
            }
            pthread_mutex_unlock(&gi_lock);
        });
    }
    pthread_mutex_unlock(&gi_lock);
    return r;
}
