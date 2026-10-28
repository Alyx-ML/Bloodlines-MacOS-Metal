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
#include <mach-o/dyld.h>
#include <sys/stat.h>
#include <unistd.h>

#import "lm_bake.h"
#import "mtl4.h"

#define GI_RES 16          // each view, texels across
#define GI_BATCH 341       // probes per draw: 6 layers each, up to 2048 layers
#define GI_MAX_PROBES 32768
#define GI_MAX_CELLS (16L << 20)
#define GI_FLOOR 160       // a probe's floor at most this far below
#define GI_VIS_BIAS 8      // a probe counts as seeing a point this much behind what it saw
#define GI_PROP_NEAR 1024  // props drawn into a batch of probes' views this near it

static NSString *const gi_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     // A corner: position; lightmap atlas coordinates (x < 0: none); the texture's mean
     // colour; light it gives off (emit; emitb from its back, for props); the face's normal;
     // 1 for the sky (never seen from behind), 2 for a static prop (seen from both sides).
     "struct GV { packed_float3 pos; packed_float2 uv; packed_float3 alb, emit, emitb, n; float sky; };\n"
     "struct VO { float4 pos [[position]]; float2 uv; float3 alb, emit, emitb, n, w; float sky;\n"
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
     "    o.uv = float2(v[vid].uv), o.alb = float3(v[vid].alb), o.emit = float3(v[vid].emit), o.emitb = float3(v[vid].emitb);\n"
     "    o.n = float3(v[vid].n);\n"
     "    o.w = W, o.sky = v[vid].sky, o.probe = P, o.layer = inst;\n"
     "    return o;\n"
     "}\n"
     // rgb the light seen, a how far; a < 0 a face seen from behind: the probe is inside a
     // wall or outside the map that way.
     "fragment float4 gi_fs(VO in [[stage_in]], texture2d<float> lm [[texture(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    if (in.sky < 0.5 && dot(in.n, in.probe - in.w) < 0.0) return float4(0.0, 0.0, 0.0, -1.0);\n"
     "    float3 l = in.uv.x >= 0.0 ? lm.sample(s, in.uv).rgb : float3(0.0);\n"
     "    float3 e = in.sky > 1.5 && dot(in.n, in.probe - in.w) < 0.0 ? in.emitb : in.emit;\n"
     "    return float4(in.alb * l + e, length(in.w - in.probe));\n"
     "}\n"
     // A light, as lm_bake.m has them: origin and type; intensity; normal; stopdot,
     // stopdot2, exponent, radius; attenuation.
     "struct GL { float4 o, i, n, sp, att; };\n"
     // v: how far the probe sees, mean and mean square, over each face's 4 x 4 cells
     // (GI_VIS), distances capped at `far`.
     "struct PO { float4 b[6], d[6], back; float2 v[384]; };\n"  // 6 * GI_VIS * GI_VIS
     "constant uint VIS = 8;\n"  // GI_VIS
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
     "                      device PO *out [[buffer(3)]], constant float &far [[buffer(4)]],\n"
     "                      uint gid [[thread_position_in_grid]]) {\n"
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
     "        uint per = res / VIS;\n"
     "        for (uint cy = 0; cy < VIS; cy++)\n"
     "            for (uint cx = 0; cx < VIS; cx++) {\n"
     "                float m = 0.0, m2 = 0.0;\n"
     "                for (uint j = cy * per; j < (cy + 1) * per; j++)\n"
     "                    for (uint i = cx * per; i < (cx + 1) * per; i++) {\n"
     "                        float a = cap.read(uint2(i, j), gid * 6 + f).a, r = a < 0.0 ? 0.0 : min(a, far);\n"
     "                        m += r, m2 += r * r;\n"
     "                    }\n"
     "                float k = 1.0 / float(per * per);\n"
     "                out[gid].v[f * VIS * VIS + cy * VIS + cx] = float2(m * k, m2 * k);\n"
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

struct gv { float pos[3], uv[2], alb[3], emit[3], emitb[3], n[3], sky; };
struct gl { float o[4], i[4], n[4], sp[4], att[4]; };
struct po { float b[6][4], d[6][4], back[4], v[6 * GI_VIS * GI_VIS][2]; };

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
    // Not: nodraw, hint and skip faces, or displacements whose surface could not be read.
    return f->texinfo >= 0 && (f->disp < 0 || f->dside) && f->count >= 3 && !(w->texinfo[f->texinfo].flags & (0x80 | 0x100 | 0x200));
}

// What every capture of the map's probes shares.
struct capture {
    BLJob *job;
    id<MTLDevice> dev;
    id<MTLRenderPipelineState> pso;
    id<MTLComputePipelineState> cps;
    id<MTLDepthStencilState> dss;
    id<MTLTexture> lm;
    id<MTLBuffer> pb, lb, ob;  // the probes' places, the lights, the results (struct po each)
    int np, nl;
    float far;                 // how far the probes' views count (struct po v)
};

// The probes' views `res` texels across of the triangles (verts, idx), summed into ob. The
// indices from `world` on are the props', each batch of probes drawing those within
// GI_PROP_NEAR of it (farther ones are smaller than a texel of its views).
static NSError *draw_probes(const struct capture *c, const struct gv *verts, int nv, const uint32_t *idx, int world, int ni,
                            int res)
{
    id<MTLDevice> dev = c->dev;
    id<MTLBuffer> vb = [dev newBufferWithBytes:(const void *)verts length:sizeof *verts * (size_t)nv
                                       options:MTLResourceStorageModeShared];
    id<MTLBuffer> ib = [dev newBufferWithBytes:(const void *)idx length:4 * (size_t)ni options:MTLResourceStorageModeShared];
    int nprop = (ni - world) / 3;
    float(*mid)[3] = malloc(sizeof *mid * (size_t)(nprop + 1));
    for (int i = 0; i < nprop; i++)
        for (int a = 0; a < 3; a++)
            mid[i][a] = (verts[idx[world + 3 * i]].pos[a] + verts[idx[world + 3 * i + 1]].pos[a] + verts[idx[world + 3 * i + 2]].pos[a]) / 3;
    const float(*pos)[4] = c->pb.contents;
    MTLTextureDescriptor *cd = [MTLTextureDescriptor new];
    cd.textureType = MTLTextureType2DArray, cd.pixelFormat = MTLPixelFormatRGBA16Float;
    cd.width = cd.height = (NSUInteger)res, cd.arrayLength = GI_BATCH * 6;
    cd.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead, cd.storageMode = MTLStorageModePrivate;
    id<MTLTexture> cap = [dev newTextureWithDescriptor:cd];
    cd.pixelFormat = MTLPixelFormatDepth32Float, cd.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:cd];
    // Each batch's first probe (the vertex shader's), the reduce's parameters and `far`,
    // free again once the batch before has been waited for.
    id<MTLBuffer> kb = [dev newBufferWithLength:32 options:MTLResourceStorageModeShared];
    BLJob *job = c->job;
    for (id<MTLAllocation> r in @[ vb, ib, cap, depth, kb ]) [job keep:r];
    id<MTL4ArgumentTable> at = job.table;
    for (int first = 0; first < c->np; first += GI_BATCH) {
        uint32_t count = (uint32_t)(c->np - first < GI_BATCH ? c->np - first : GI_BATCH), f32 = (uint32_t)first;
        // The props near this batch, after the map's indices (the batch before is done with them).
        float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
        for (uint32_t i = f32; i < f32 + count; i++)
            for (int a = 0; a < 3; a++) lo[a] = fminf(lo[a], pos[i][a]), hi[a] = fmaxf(hi[a], pos[i][a]);
        uint32_t *bi = (uint32_t *)ib.contents + world;
        int n = world;
        for (int i = 0; i < nprop; i++) {
            float d2 = 0;
            for (int a = 0; a < 3; a++) {
                float o = mid[i][a] < lo[a] ? lo[a] - mid[i][a] : mid[i][a] > hi[a] ? mid[i][a] - hi[a] : 0;
                d2 += o * o;
            }
            if (d2 > GI_PROP_NEAR * GI_PROP_NEAR) continue;
            for (int k = 0; k < 3; k++) *bi++ = idx[world + 3 * i + k];
            n += 3;
        }
        uint32_t *k4 = kb.contents;
        k4[0] = f32, k4[1] = count, k4[2] = (uint32_t)c->nl, k4[3] = (uint32_t)res, k4[4] = f32;
        memcpy(k4 + 5, &c->far, 4);
        id<MTL4CommandBuffer> cb = [job begin];
        MTL4RenderPassDescriptor *rp = [MTL4RenderPassDescriptor new];
        rp.colorAttachments[0].texture = cap;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        // Nothing drawn: no light from there, and nothing in the way of the map's lights (the
        // map has holes where it is never seen from: nodraw faces).
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 65504);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.depthAttachment.texture = depth;
        rp.depthAttachment.loadAction = MTLLoadActionClear;
        rp.depthAttachment.clearDepth = 1;
        rp.depthAttachment.storeAction = MTLStoreActionDontCare;
        rp.renderTargetArrayLength = count * 6;
        id<MTL4RenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:c->pso];
        [e setDepthStencilState:c->dss];
        [e setCullMode:MTLCullModeNone];
        [at setAddress:vb.gpuAddress atIndex:0];
        [at setAddress:c->pb.gpuAddress atIndex:1];
        [at setAddress:kb.gpuAddress + 16 atIndex:2];
        [at setTexture:c->lm.gpuResourceID atIndex:0];
        [e setArgumentTable:at atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:(NSUInteger)n indexType:MTLIndexTypeUInt32
                     indexBuffer:ib.gpuAddress indexBufferLength:ib.length instanceCount:count * 6];
        [e endEncoding];
        id<MTL4ComputeCommandEncoder> ce = [cb computeCommandEncoder];
        // The views drawn before they are read.
        [ce barrierAfterQueueStages:MTLStageFragment beforeStages:MTLStageDispatch visibilityOptions:MTL4VisibilityOptionDevice];
        [ce setComputePipelineState:c->cps];
        [at setTexture:cap.gpuResourceID atIndex:0];
        [at setAddress:c->pb.gpuAddress atIndex:0];
        [at setAddress:c->lb.gpuAddress atIndex:1];
        [at setAddress:kb.gpuAddress atIndex:2];
        [at setAddress:c->ob.gpuAddress + sizeof(struct po) * (size_t)first atIndex:3];
        [at setAddress:kb.gpuAddress + 20 atIndex:4];
        [ce setArgumentTable:at];
        [ce dispatchThreads:MTLSizeMake(count, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
        [ce endEncoding];
        NSError *failed = [job run];
        if (failed) {
            free(mid);
            return failed;
        }
    }
    free(mid);
    return nil;
}

// Every other probe each way of g's (a grid twice as coarse), their places into *pb.
static struct bl_gi *coarse_grid(const struct bl_gi *g, id<MTLDevice> dev, id<MTLBuffer> __strong *pb)
{
    struct bl_gi *c = calloc(1, sizeof *c);
    c->step = 2 * g->step;
    memcpy(c->origin, g->origin, sizeof c->origin);
    for (int a = 0; a < 3; a++) c->n[a] = (g->n[a] + 1) / 2;
    c->slot = malloc(sizeof(int) * (size_t)c->n[0] * c->n[1] * c->n[2]);
    *pb = [dev newBufferWithLength:16 * (size_t)g->nprobes + 16 options:MTLResourceStorageModeShared];
    float(*q)[4] = (*pb).contents;
    for (int z = 0, k = 0; z < c->n[2]; z++)
        for (int y = 0; y < c->n[1]; y++)
            for (int x = 0; x < c->n[0]; x++, k++) {
                int i = g->slot[(2 * z * g->n[1] + 2 * y) * g->n[0] + 2 * x];
                c->slot[k] = i < 0 ? -1 : c->nprobes;
                if (i < 0) continue;
                float *p = q[c->nprobes++];
                p[0] = g->origin[0] + (float)(2 * x) * g->step, p[1] = g->origin[1] + (float)(2 * y) * g->step;
                p[2] = g->origin[2] + (float)(2 * z) * g->step, p[3] = 1;
            }
    return c;
}

// The probes' light and how far each sees, from a capture's results.
static void take_probes(struct bl_gi *g, const struct po *o)
{
    int np = g->nprobes;
    if (!g->bounce) {
        g->bounce = malloc(sizeof *g->bounce * (size_t)np);
        g->direct = malloc(sizeof *g->direct * (size_t)np);
        g->vis = malloc(sizeof *g->vis * (size_t)np);
        g->valid = malloc((size_t)np);
    }
    g->nvalid = 0;
    for (int i = 0; i < np; i++) {
        for (int a = 0; a < 6; a++)
            for (int c = 0; c < 3; c++) g->bounce[i][a][c] = o[i].b[a][c], g->direct[i][a][c] = o[i].d[a][c];
        // In steps of the grid, which half floats hold (squares of up to 4 steps' distance).
        for (int k = 0; k < 6 * GI_VIS * GI_VIS; k++)
            g->vis[i][k][0] = (_Float16)(o[i].v[k][0] / g->step), g->vis[i][k][1] = (_Float16)(o[i].v[k][1] / (g->step * g->step));
        g->valid[i] = o[i].back[0] < 0.1f;
        g->nvalid += g->valid[i];
    }
}

// The light on a surface facing n from an ambient cube (+x -x +y -y +z -z), as the game
// lights models: each axis weighted by n's part along it, squared.
static void cube_light(const float b[6][3], const float d[6][3], const float n[3], float out[3])
{
    for (int c = 0; c < 3; c++) {
        out[c] = 0;
        for (int a = 0; a < 3; a++) {
            int side = 2 * a + (n[a] < 0);
            out[c] += n[a] * n[a] * (b[side][c] + d[side][c]);
        }
    }
}

// The light arriving at a prop's corner p: from the probes round it, else from those of the
// 4 x 4 x 4 round it that see it, nearest most. 0 where none do (props high on buildings,
// far from where models go).
static int prop_light(const struct bl_gi *g, const float p[3], float bounce[6][3], float direct[6][3])
{
    if (bl_gi_sample(g, p, bounce, direct)) return 1;
    int c[3];
    for (int a = 0; a < 3; a++) c[a] = (int)floorf((p[a] - g->origin[a]) / g->step);
    float sum = 0;
    for (int z = c[2] - 1; z <= c[2] + 2; z++)
        for (int y = c[1] - 1; y <= c[1] + 2; y++)
            for (int x = c[0] - 1; x <= c[0] + 2; x++) {
                if (x < 0 || y < 0 || z < 0 || x >= g->n[0] || y >= g->n[1] || z >= g->n[2]) continue;
                int i = g->slot[(z * g->n[1] + y) * g->n[0] + x];
                if (i < 0 || !g->valid[i]) continue;
                float d[3] = {p[0] - (g->origin[0] + (float)x * g->step), p[1] - (g->origin[1] + (float)y * g->step),
                              p[2] - (g->origin[2] + (float)z * g->step)};
                float wt = bl_gi_seen(g, i, d) / (d[0] * d[0] + d[1] * d[1] + d[2] * d[2] + 1);
                for (int a = 0; a < 6; a++)
                    for (int ch = 0; ch < 3; ch++) bounce[a][ch] += g->bounce[i][a][ch] * wt, direct[a][ch] += g->direct[i][a][ch] * wt;
                sum += wt;
            }
    if (sum <= 1e-12f) return 0;
    for (int a = 0; a < 6; a++)
        for (int ch = 0; ch < 3; ch++) bounce[a][ch] /= sum, direct[a][ch] /= sum;
    return 1;
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
    // The faces as triangles (fans, by index; displacements their grid's).
    int nv = 0, ni = 0;
    for (int i = 0; i < nf; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (drawn(w, f)) nv += f->dside ? f->dside * f->dside : f->count, ni += f->dside ? 6 * (f->dside - 1) * (f->dside - 1) : 3 * (f->count - 2);
    }
    struct gv *verts = calloc((size_t)nv + 1, sizeof *verts);
    uint32_t *idx = calloc((size_t)ni + 1, sizeof *idx);
    float lo[3] = {1e9f, 1e9f, 1e9f}, hi[3] = {-1e9f, -1e9f, -1e9f};
    float refl[3] = {0, 0, 0}, refl_area = 0;  // the map's surfaces' mean colour, by area
    int kv = 0, ki = 0;
    for (int i = 0; i < nf; i++) {
        const struct bl_bsp_face *f = &w->faces[i];
        if (!drawn(w, f)) continue;
        const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
        int is_sky = (t->flags & 4) != 0;
        if (!is_sky) {
            for (int c = 0; c < 3; c++) refl[c] += w->texdata[t->texdata].reflectivity[c] * f->area;
            refl_area += f->area;
        }
        int n = f->dside, corners = n ? n * n : f->count;
        if (n)
            for (int r = 0; r + 1 < n; r++)
                for (int c = 0; c + 1 < n; c++) {
                    uint32_t a = (uint32_t)(kv + r * n + c);
                    idx[ki++] = a, idx[ki++] = a + (uint32_t)n, idx[ki++] = a + (uint32_t)n + 1;
                    idx[ki++] = a, idx[ki++] = a + (uint32_t)n + 1, idx[ki++] = a + 1;
                }
        else
            for (int c = 1; c + 1 < f->count; c++)
                idx[ki++] = (uint32_t)kv, idx[ki++] = (uint32_t)(kv + c), idx[ki++] = (uint32_t)(kv + c + 1);
        for (int c = 0; c < corners; c++) {
            const struct bl_bsp_dvert *dv = n ? &w->dverts[f->dfirst + c] : NULL;
            const float *p = dv ? dv->pos : w->verts[w->index[f->first + c]];
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
            float s = dv ? dv->lux[0] : p[0] * t->lm[0][0] + p[1] * t->lm[0][1] + p[2] * t->lm[0][2] + t->lm[0][3] - (float)f->mins[0];
            float u = dv ? dv->lux[1] : p[0] * t->lm[1][0] + p[1] * t->lm[1][1] + p[2] * t->lm[1][2] + t->lm[1][3] - (float)f->mins[1];
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
    id<MTLBuffer> ob = [dev newBufferWithLength:sizeof(struct po) * (size_t)np options:MTLResourceStorageModeShared];
    BLJob *job = [[BLJob alloc] initWithDevice:dev];
    if (!job) {
        snprintf(err, (size_t)errlen, "no Metal 4 queue");
        free(verts), free(idx), bl_gi_free(g);
        return NULL;
    }
    for (id<MTLAllocation> r in @[ pb, lb, lm, ob ]) [job keep:r];
    // Distances past the farthest probe a model blends from (the far corner of its cell)
    // need not be told apart.
    struct capture cap = {job, dev, pso, cps, dss, lm, pb, lb, ob, np, nl, 2 * step};
    // The static props: the map alone first, from a grid twice as coarse, for the light
    // arriving at each prop corner (its two sides lit as the game lights
    // models, on its model's textures' mean colour, or the map's when they could not be
    // read); then the map with them, so they block light and give back what they get.
    const struct bl_props *props = w->props;
    int nprop = props ? props->ntris : 0;
    int nprop_corners = 0;
    NSError *failed = nil;
    struct bl_gi *coarse = NULL;
    int world_end = ki, unlit = 0, dropped = 0;  // prop corners no probe of the coarse grid can see
    if (nprop) {
        id<MTLBuffer> cpb;
        coarse = coarse_grid(g, dev, &cpb);
        id<MTLBuffer> cob = [dev newBufferWithLength:sizeof(struct po) * ((size_t)coarse->nprobes + 1)
                                             options:MTLResourceStorageModeShared];
        [job keep:cpb], [job keep:cob];
        struct capture cc = {job, dev, pso, cps, dss, lm, cpb, lb, cob, coarse->nprobes, nl, 2 * coarse->step};
        failed = coarse->nprobes ? draw_probes(&cc, verts, kv, idx, ki, ki, GI_RES) : nil;
        if (!failed) {
            take_probes(coarse, cob.contents);
            for (int c = 0; c < 3; c++) refl[c] = refl_area > 0 ? refl[c] / refl_area : 0.5f;
            verts = realloc(verts, sizeof *verts * ((size_t)kv + 3 * (size_t)nprop));
            idx = realloc(idx, sizeof *idx * ((size_t)ki + 3 * (size_t)nprop));
            // The collision models' triangles share their corners: each corner once (so the
            // views draw it once), lit for the mean of its triangles' normals, by area; corners
            // of props of different colours apart.
            size_t cap_n = 64;
            while (cap_n < 6 * (size_t)nprop) cap_n *= 2;
            int *at = malloc(sizeof(int) * cap_n);
            memset(at, 0xff, sizeof(int) * cap_n);
            int first = kv;
            for (int i = 0; i < nprop; i++) {
                const float(*t)[3] = props->tris[i];
                float e1[3], e2[3], n[3];
                for (int a = 0; a < 3; a++) e1[a] = t[1][a] - t[0][a], e2[a] = t[2][a] - t[0][a];
                n[0] = e1[1] * e2[2] - e1[2] * e2[1], n[1] = e1[2] * e2[0] - e1[0] * e2[2], n[2] = e1[0] * e2[1] - e1[1] * e2[0];
                if (n[0] * n[0] + n[1] * n[1] + n[2] * n[2] < 1e-12f) continue;
                const float *col = props->refl && props->refl[i][0] >= 0 ? props->refl[i] : refl;
                for (int k = 0; k < 3; k++) {
                    uint32_t key[3];
                    memcpy(key, t[k], 12);
                    size_t h = ((key[0] * 0x9E3779B1u) ^ (key[1] * 0x85EBCA77u) ^ (key[2] * 0xC2B2AE3Du)) & (cap_n - 1);
                    while (at[h] >= 0 && (memcmp(verts[at[h]].pos, t[k], 12) || memcmp(verts[at[h]].alb, col, 12)))
                        h = (h + 1) & (cap_n - 1);
                    if (at[h] < 0) {
                        struct gv *v = &verts[kv];
                        memset(v, 0, sizeof *v);
                        memcpy(v->pos, t[k], 12), memcpy(v->alb, col, 12);
                        v->uv[0] = v->uv[1] = -1;
                        v->sky = 2;
                        at[h] = kv++;
                    }
                    for (int a = 0; a < 3; a++) verts[at[h]].n[a] += n[a];  // summed now, made unit below
                    idx[ki++] = (uint32_t)at[h];
                }
            }
            free(at);
            for (int i = first; i < kv; i++) {
                struct gv *v = &verts[i];
                float l = sqrtf(v->n[0] * v->n[0] + v->n[1] * v->n[1] + v->n[2] * v->n[2]), back[3], b6[6][3], d6[6][3];
                float front_light[3] = {0, 0, 0}, back_light[3] = {0, 0, 0};
                for (int a = 0; a < 3; a++) v->n[a] = l > 1e-9f ? v->n[a] / l : 0, back[a] = -v->n[a];
                if (prop_light(coarse, v->pos, b6, d6)) cube_light(b6, d6, v->n, front_light), cube_light(b6, d6, back, back_light);
                else
                    unlit++, v->sky = -1;  // marked for leaving out
                for (int c = 0; c < 3; c++) v->emit[c] = v->alb[c] * front_light[c], v->emitb[c] = v->alb[c] * back_light[c];
            }
            nprop_corners = kv - first;
            int kept = world_end;
            for (int i = world_end; i < ki; i += 3)
                if (verts[idx[i]].sky > 0 && verts[idx[i + 1]].sky > 0 && verts[idx[i + 2]].sky > 0)
                    memmove(&idx[kept], &idx[i], 12), kept += 3;
            dropped = (ki - kept) / 3, ki = kept;
        }
        bl_gi_free(coarse);
    }
    if (!failed) failed = draw_probes(&cap, verts, kv, idx, world_end, ki, GI_RES);
    free(verts), free(idx);
    if (failed) {
        snprintf(err, (size_t)errlen, "probe capture: %s", failed.localizedDescription.UTF8String);
        bl_gi_free(g);
        return NULL;
    }
    take_probes(g, ob.contents);
    struct timespec t1;
    clock_gettime(CLOCK_MONOTONIC, &t1);
    g->seconds = (double)(t1.tv_sec - t0.tv_sec) + (double)(t1.tv_nsec - t0.tv_nsec) * 1e-9;
    snprintf(g->summary, sizeof g->summary,
             "%s: %d probes %.0f units apart (%d clear of walls), %d lights, %d prop triangles (%d of %d props' colours read; %d corners, %d unlit: %d triangles left out); %.2f s on %s",
             w->name, np, step, g->nvalid, nl, nprop, props ? props->ncolour : 0, props ? props->nfound : 0, nprop_corners, unlit, dropped, g->seconds, dev.name.UTF8String);
    return g;
}

void bl_gi_free(struct bl_gi *g)
{
    if (!g) return;
    free(g->slot), free(g->bounce), free(g->direct), free(g->vis), free(g->valid);
    free(g);
}

float bl_gi_seen(const struct bl_gi *g, int i, const float d[3])
{
    static const float F[6][3] = {{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}};
    static const float U[6][3] = {{0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 0, 1}, {0, 1, 0}, {0, 1, 0}};
    float ax = fabsf(d[0]), ay = fabsf(d[1]), az = fabsf(d[2]);
    float r = sqrtf(d[0] * d[0] + d[1] * d[1] + d[2] * d[2]) - GI_VIS_BIAS;
    if (r <= 0) return 1;
    int f = ax >= ay && ax >= az ? (d[0] > 0 ? 0 : 1) : ay >= az ? (d[1] > 0 ? 2 : 3) : (d[2] > 0 ? 4 : 5);
    const float *fv = F[f], *u = U[f];
    float R[3] = {fv[1] * u[2] - fv[2] * u[1], fv[2] * u[0] - fv[0] * u[2], fv[0] * u[1] - fv[1] * u[0]};
    float fz = d[0] * fv[0] + d[1] * fv[1] + d[2] * fv[2];
    float x = (d[0] * R[0] + d[1] * R[1] + d[2] * R[2]) / fz, y = (d[0] * u[0] + d[1] * u[1] + d[2] * u[2]) / fz;
    int cx = (int)((x + 1) * 0.5f * GI_VIS), cy = (int)((1 - y) * 0.5f * GI_VIS);
    cx = cx < 0 ? 0 : cx > GI_VIS - 1 ? GI_VIS - 1 : cx, cy = cy < 0 ? 0 : cy > GI_VIS - 1 ? GI_VIS - 1 : cy;
    const _Float16 *v = g->vis[i][(f * GI_VIS + cy) * GI_VIS + cx];
    float m = (float)v[0] * g->step, m2 = (float)v[1] * g->step * g->step;
    if (r <= m) return 1;
    float var = fmaxf(m2 - m * m, 4.0f), t = r - m, c = var / (var + t * t);
    return c * c * c;
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
        float d[3] = {p[0] - (g->origin[0] + (float)x * g->step), p[1] - (g->origin[1] + (float)y * g->step),
                      p[2] - (g->origin[2] + (float)z * g->step)};
        float wt = ((k & 1 ? f[0] : 1 - f[0]) * (k >> 1 & 1 ? f[1] : 1 - f[1]) * (k >> 2 ? f[2] : 1 - f[2]) + 1e-4f) *
                   bl_gi_seen(g, i, d);
        for (int a = 0; a < 6; a++)
            for (int ch = 0; ch < 3; ch++) bounce[a][ch] += g->bounce[i][a][ch] * wt, direct[a][ch] += g->direct[i][a][ch] * wt;
        sum += wt;
    }
    if (sum <= 0) return 0;
    for (int a = 0; a < 6; a++)
        for (int ch = 0; ch < 3; ch++) bounce[a][ch] /= sum, direct[a][ch] /= sum;
    return 1;
}

// --- the cache on disk -----------------------------------------------------------------
// A capture takes a second or three; maps come back often, so each one is kept in
// build/gi_cache, keyed on everything it was made from (the map's surfaces, lights,
// lightmaps and props) and on this build of the game.

static uint64_t fnv(uint64_t h, const void *p, size_t n)
{
    const uint8_t *b = p;
    for (size_t i = 0; i < n; i++) h = (h ^ b[i]) * 0x100000001b3ull;
    return h;
}

static uint64_t gi_key(const struct bl_bsp_world *w, char *path, size_t len)
{
    char exe[1024];
    uint32_t n = sizeof exe;
    struct stat st;
    if (_NSGetExecutablePath(exe, &n) || stat(exe, &st)) return 0;
    uint64_t h = fnv(0xcbf29ce484222325ull, &st.st_mtimespec, sizeof st.st_mtimespec);
    h = fnv(h, w->name, sizeof w->name);
    h = fnv(h, w->verts, sizeof *w->verts * (size_t)w->nverts);
    h = fnv(h, w->index, sizeof *w->index * (size_t)w->nindex);
    h = fnv(h, w->faces, sizeof *w->faces * (size_t)w->nfaces);
    h = fnv(h, w->texinfo, sizeof *w->texinfo * (size_t)w->ntexinfo);
    h = fnv(h, w->texdata, sizeof *w->texdata * (size_t)w->ntexdata);
    h = fnv(h, w->lights, sizeof *w->lights * (size_t)w->nlights);
    h = fnv(h, w->dverts, sizeof *w->dverts * (size_t)w->ndverts);
    h = fnv(h, w->lighting, 4 * (size_t)w->nsamples);
    h = fnv(h, w->planes, sizeof *w->planes * (size_t)w->nplanes);
    h = fnv(h, w->nodes, sizeof *w->nodes * (size_t)w->nnodes);
    h = fnv(h, w->leaves, sizeof *w->leaves * (size_t)w->nleaves);
    if (w->props) {
        h = fnv(h, w->props->tris, sizeof *w->props->tris * (size_t)w->props->ntris);
        if (w->props->refl) h = fnv(h, w->props->refl, sizeof *w->props->refl * (size_t)w->props->ntris);
    }
    char *slash = strrchr(exe, '/');
    if (!slash) return 0;
    *slash = 0;  // build/tests
    snprintf(path, len, "%s/../gi_cache", exe);
    mkdir(path, 0755);
    snprintf(path, len, "%s/../gi_cache/%s.gi", exe, w->name);
    return h;
}

// The file: a header (magic, version, the key, the grid and a checksum of what follows),
// then the arrays. A file that is short, long, damaged or out of range is not used.
#define GI_MAGIC 0x49474c42u  // "BLGI"
#define GI_VERSION 1
struct gi_file {
    uint32_t magic, version;
    uint64_t key, sum;  // sum: fnv over the arrays
    float origin[3], step;
    int32_t n[3], nprobes, nvalid;
    char summary[256];
};

#define GI_ARRAYS(g, np, cells) \
    {g->slot, sizeof(int) * (cells)}, {g->bounce, sizeof *g->bounce * (np)}, {g->direct, sizeof *g->direct * (np)}, \
    {g->vis, sizeof *g->vis * (np)}, {g->valid, (np)}

static void gi_cache_save(const struct bl_gi *g, uint64_t key, const char *path)
{
    size_t np = (size_t)g->nprobes, cells = (size_t)g->n[0] * g->n[1] * g->n[2];
    struct { const void *p; size_t n; } parts[] = {GI_ARRAYS(g, np, cells)};
    struct gi_file h = {GI_MAGIC, GI_VERSION, key, 0xcbf29ce484222325ull, {g->origin[0], g->origin[1], g->origin[2]},
                        g->step, {g->n[0], g->n[1], g->n[2]}, g->nprobes, g->nvalid, ""};
    snprintf(h.summary, sizeof h.summary, "%s", g->summary);
    for (size_t i = 0; i < sizeof parts / sizeof *parts; i++) h.sum = fnv(h.sum, parts[i].p, parts[i].n);
    char tmp[1100];
    snprintf(tmp, sizeof tmp, "%s.XXXXXX", path);  // its own name: two captures of one map can't mix
    int fd = mkstemp(tmp);
    FILE *f = fd < 0 ? NULL : fdopen(fd, "wb");
    if (!f) {
        if (fd >= 0) close(fd), remove(tmp);
        return;
    }
    int ok = fwrite(&h, sizeof h, 1, f) == 1;
    for (size_t i = 0; i < sizeof parts / sizeof *parts; i++) ok &= fwrite(parts[i].p, 1, parts[i].n, f) == parts[i].n;
    ok &= fclose(f) == 0;
    if (!ok || rename(tmp, path)) remove(tmp);
}

static struct bl_gi *gi_cache_load(uint64_t key, const char *path)
{
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    struct gi_file h;
    struct stat st;
    int ok = fread(&h, sizeof h, 1, f) == 1 && !fstat(fileno(f), &st) && h.magic == GI_MAGIC &&
             h.version == GI_VERSION && h.key == key && h.n[0] > 0 && h.n[1] > 0 && h.n[2] > 0 &&
             h.n[0] <= GI_MAX_CELLS && h.n[1] <= GI_MAX_CELLS && h.n[2] <= GI_MAX_CELLS && h.nprobes > 0 &&
             h.nprobes <= GI_MAX_PROBES && h.nvalid >= 0 && h.nvalid <= h.nprobes && h.step > 0;
    size_t np = ok ? (size_t)h.nprobes : 0, cells = ok ? (size_t)h.n[0] * h.n[1] * h.n[2] : 0;
    struct bl_gi *g = NULL;
    if (ok && cells <= GI_MAX_CELLS) {
        g = calloc(1, sizeof *g);
        g->slot = malloc(sizeof(int) * cells), g->bounce = malloc(sizeof *g->bounce * np);
        g->direct = malloc(sizeof *g->direct * np), g->vis = malloc(sizeof *g->vis * np), g->valid = malloc(np);
        struct { void *p; size_t n; } parts[] = {GI_ARRAYS(g, np, cells)};
        size_t want = sizeof h;
        for (size_t i = 0; i < sizeof parts / sizeof *parts; i++) want += parts[i].n, ok &= parts[i].p != NULL;
        ok &= (size_t)st.st_size == want;
        uint64_t sum = 0xcbf29ce484222325ull;
        for (size_t i = 0; ok && i < sizeof parts / sizeof *parts; i++)
            ok &= fread(parts[i].p, 1, parts[i].n, f) == parts[i].n, sum = fnv(sum, parts[i].p, parts[i].n);
        ok &= sum == h.sum;
        for (size_t i = 0; ok && i < cells; i++) ok &= g->slot[i] >= -1 && g->slot[i] < h.nprobes;
    } else {
        ok = 0;
    }
    fclose(f);
    if (!ok) {
        if (g) bl_gi_free(g);
        fprintf(stderr, "[gi] %s: not used (damaged or from another version); captured again\n", path);
        return NULL;
    }
    memcpy(g->origin, h.origin, sizeof g->origin), g->step = h.step;
    memcpy(g->n, h.n, sizeof g->n), g->nprobes = h.nprobes, g->nvalid = h.nvalid;
    h.summary[sizeof h.summary - 1] = 0;
    snprintf(g->summary, sizeof g->summary, "%.200s (from the cache)", h.summary);
    return g;
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
        // One capture at a time: a map opened twice in a row (a load in the same map) waits
        // for the first and then finds it in the cache; one for a map since left is skipped.
        static dispatch_queue_t queue;
        if (!queue)
            queue = dispatch_queue_create("bl.gi", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                          QOS_CLASS_USER_INITIATED, 0));
        dispatch_async(queue, ^{
            pthread_mutex_lock(&gi_lock);
            int stale = gen != gi_gen;
            pthread_mutex_unlock(&gi_lock);
            if (stale) {
                bl_bsp_world_free(w);
                return;
            }
            char err[256], path[1100];
            uint64_t key = gi_key(w, path, sizeof path);
            struct bl_gi *g = key ? gi_cache_load(key, path) : NULL;
            if (!g) {
                g = bl_gi_capture(MTLCreateSystemDefaultDevice(), w, err, sizeof err);
                if (g && key) gi_cache_save(g, key, path);
            }
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
