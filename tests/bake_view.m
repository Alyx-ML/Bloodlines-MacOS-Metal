// Bakes a map's lighting again (lm_bake.m) and renders views of it with the map's own
// lightmaps and with the new ones, the light alone on each texture's mean colour
// (reflectivity), from the same cameras. Writes <out>/<view>_before.png and _after.png
// (game-derived pictures: keep them in build/) and prints how the two bakes' brightness
// compares, face by face.
//   bake_view <map.bsp> <out dir> [scale (4)] [bounces (3)] [x y z yaw pitch]...
// With no cameras: four, from the player's start, facing 0, 90, 180 and 270 degrees.
//   (built by tools/build_tests.sh into build/tests/)
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_bsp.h"
#include "lm_bake.h"

static NSString *const view_source =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VV { packed_float3 pos; packed_float2 uo, un; packed_float3 alb; };\n"
     "struct VO { float4 pos [[position]]; float2 uv; float3 alb; };\n"
     "vertex VO view_vs(uint id [[vertex_id]], device const VV *v [[buffer(0)]], constant float4x4 &m [[buffer(1)]],\n"
     "                  constant uint &after [[buffer(2)]]) {\n"
     "    VO o; o.pos = m * float4(float3(v[id].pos), 1.0); o.uv = after ? float2(v[id].un) : float2(v[id].uo);\n"
     "    o.alb = float3(v[id].alb); return o; }\n"
     "fragment float4 view_fs(VO in [[stage_in]], texture2d<float> lm [[texture(0)]]) {\n"
     "    constexpr sampler s(filter::linear, address::clamp_to_edge);\n"
     "    return float4(in.alb * lm.sample(s, in.uv).rgb, 1.0); }\n";

struct vv { float pos[3], uo[2], un[2], alb[3]; };

// Shelf packing: each face's rectangle in an atlas `width` wide; returns its height.
static int pack(const int *w, const int *h, int n, int width, int *x, int *y)
{
    int *order = malloc(sizeof(int) * (size_t)(n + 1));
    int m = 0;
    for (int i = 0; i < n; i++)
        if (w[i] > 0) order[m++] = i;
    // Tallest first.
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

static void write_png(const char *path, const uint8_t *rgba, int w, int h)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef ctx = CGBitmapContextCreate((void *)rgba, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs,
                                             (CGBitmapInfo)kCGImageAlphaNoneSkipLast);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d), CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}

static float to_srgb(float c)
{
    c = c < 0 ? 0 : c > 1 ? 1 : c;
    return c <= 0.0031308f ? 12.92f * c : 1.055f * powf(c, 1 / 2.4f) - 0.055f;
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: %s <map.bsp> <out dir> [scale] [bounces] [x y z yaw pitch]...\n", argv[0]);
            return 2;
        }
        char err[512], summary[1024];
        struct bl_bsp_world *w = bl_bsp_world_load(argv[1], err, sizeof err);
        if (!w) {
            fprintf(stderr, "%s\n", err);
            return 1;
        }
        bl_bsp_world_check(w, summary, sizeof summary);
        printf("%s\n", summary);
        int scale = argc > 3 ? atoi(argv[3]) : 4, bounces = argc > 4 ? atoi(argv[4]) : 3;
        id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
        struct bl_bake *b = bl_bake_map(dev, w, scale, bounces, err, sizeof err);
        if (!b) {
            fprintf(stderr, "%s\n", err);
            return 1;
        }
        printf("%s\n", b->summary);

        // Brightness, the map's bake against this one: each face's mean flat light.
        double sum_old = 0, sum_new = 0;
        int nf = 0, within = 0;
        float *ratios = malloc(sizeof(float) * (size_t)(w->nfaces + 1));
        for (int i = 0; i < w->nfaces; i++) {
            const struct bl_bsp_face *f = &w->faces[i];
            const struct bl_bake_face *bf = &b->faces[i];
            if (bf->offset < 0) continue;
            int n = (f->size[0] + 1) * (f->size[1] + 1);
            double o = 0, nw = 0;
            for (int k = 0; k < n; k++) {
                float c[3];
                bl_bake_rgbe(w->lighting + 4 * (size_t)(f->lightofs + k), c);
                o += 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
            }
            for (int k = 0; k < bf->w * bf->h; k++) {
                const float *c = b->light[bf->offset + k][0];
                nw += 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2];
            }
            o /= n, nw /= bf->w * bf->h;
            sum_old += o * f->area, sum_new += nw * f->area;
            if (o > 1e-3) {
                ratios[nf++] = (float)(nw / o);
                within += nw / o > 0.5 && nw / o < 2;
            }
        }
        for (int i = 1; i < nf; i++)
            for (int j = i; j > 0 && ratios[j] < ratios[j - 1]; j--) {
                float t = ratios[j];
                ratios[j] = ratios[j - 1], ratios[j - 1] = t;
            }
        // Debugging: BL_BAKE_LIST="x y z r" lists the faces near a point, old against new.
        if (getenv("BL_BAKE_LIST")) {
            float px, py, pz, pr;
            if (sscanf(getenv("BL_BAKE_LIST"), "%f %f %f %f", &px, &py, &pz, &pr) == 4)
                for (int i = 0; i < w->nfaces; i++) {
                    const struct bl_bsp_face *f = &w->faces[i];
                    const struct bl_bake_face *bf = &b->faces[i];
                    if (bf->offset < 0 || f->area < 500) continue;
                    float c[3] = {f->origin[0], f->origin[1], f->origin[2]};
                    for (int k = 0; k < f->count; k++)
                        for (int j = 0; j < 3; j++) c[j] += w->verts[w->index[f->first + k]][j] / (float)f->count;
                    if ((c[0] - px) * (c[0] - px) + (c[1] - py) * (c[1] - py) + (c[2] - pz) * (c[2] - pz) > pr * pr) continue;
                    int n = (f->size[0] + 1) * (f->size[1] + 1);
                    double o = 0, nw = 0;
                    for (int k = 0; k < n; k++) {
                        float cc[3];
                        bl_bake_rgbe(w->lighting + 4 * (size_t)(f->lightofs + k), cc);
                        o += (0.299 * cc[0] + 0.587 * cc[1] + 0.114 * cc[2]) / n;
                    }
                    for (int k = 0; k < bf->w * bf->h; k++) {
                        const float *cc = b->light[bf->offset + k][0];
                        nw += (0.299 * cc[0] + 0.587 * cc[1] + 0.114 * cc[2]) / (bf->w * bf->h);
                    }
                    const float *rf = w->texdata[w->texinfo[f->texinfo].texdata].reflectivity;
                    printf("  face %d %s n(%.0f %.0f %.0f) at (%.0f %.0f %.0f) area %.0f refl %.2f: old %.3f new %.3f\n", i,
                           w->texdata[w->texinfo[f->texinfo].texdata].name, f->normal[0], f->normal[1], f->normal[2], c[0], c[1],
                           c[2], f->area, (rf[0] + rf[1] + rf[2]) / 3, o, nw);
                }
        }
        printf("brightness, new / old: %.2f over the map (by area); per face: median %.2f, quartiles %.2f to %.2f, "
               "%d of %d within half to double\n",
               sum_new / sum_old, nf ? ratios[nf / 2] : 0, nf ? ratios[nf / 4] : 0, nf ? ratios[3 * nf / 4] : 0, within, nf);
        free(ratios);

        // The two atlases: the map's flat lightmaps (style 0) and the new flat light.
        int *ow = calloc((size_t)w->nfaces + 1, sizeof(int)), *oh = calloc((size_t)w->nfaces + 1, sizeof(int));
        int *nw_ = calloc((size_t)w->nfaces + 1, sizeof(int)), *nh = calloc((size_t)w->nfaces + 1, sizeof(int));
        int *ox = calloc((size_t)w->nfaces + 1, sizeof(int)), *oy = calloc((size_t)w->nfaces + 1, sizeof(int));
        int *nx = calloc((size_t)w->nfaces + 1, sizeof(int)), *ny = calloc((size_t)w->nfaces + 1, sizeof(int));
        for (int i = 0; i < w->nfaces; i++)
            if (b->faces[i].offset >= 0)
                ow[i] = w->faces[i].size[0] + 1, oh[i] = w->faces[i].size[1] + 1, nw_[i] = b->faces[i].w, nh[i] = b->faces[i].h;
        int aw = 2048, ah = pack(ow, oh, w->nfaces, aw, ox, oy);
        int bw = 8192, bh = pack(nw_, nh, w->nfaces, bw, nx, ny);
        if (ah > 16384 || bh > 16384) {
            fprintf(stderr, "atlas too tall: %d, %d\n", ah, bh);
            return 1;
        }
        uint16_t *oa = calloc((size_t)aw * ah * 4, 2), *na = calloc((size_t)bw * bh * 4, 2);
        for (int i = 0; i < w->nfaces; i++) {
            if (b->faces[i].offset < 0) continue;
            const struct bl_bsp_face *f = &w->faces[i];
            for (int y = 0; y < oh[i]; y++)
                for (int x = 0; x < ow[i]; x++) {
                    float c[3];
                    bl_bake_rgbe(w->lighting + 4 * (size_t)(f->lightofs + y * ow[i] + x), c);
                    _Float16 *p = (_Float16 *)&oa[4 * ((size_t)(oy[i] + y) * aw + ox[i] + x)];
                    p[0] = (_Float16)c[0], p[1] = (_Float16)c[1], p[2] = (_Float16)c[2], p[3] = 1;
                }
            for (int y = 0; y < nh[i]; y++)
                for (int x = 0; x < nw_[i]; x++) {
                    const float *c = b->light[b->faces[i].offset + y * nw_[i] + x][0];
                    _Float16 *p = (_Float16 *)&na[4 * ((size_t)(ny[i] + y) * bw + nx[i] + x)];
                    p[0] = (_Float16)c[0], p[1] = (_Float16)c[1], p[2] = (_Float16)c[2], p[3] = 1;
                }
        }
        id<MTLTexture> (^atlas)(uint16_t *, int, int) = ^(uint16_t *px, int tw, int th) {
            MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                                         width:(NSUInteger)tw
                                                                                        height:(NSUInteger)th
                                                                                     mipmapped:NO];
            id<MTLTexture> t = [dev newTextureWithDescriptor:d];
            [t replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)tw, (NSUInteger)th) mipmapLevel:0 withBytes:px
                 bytesPerRow:(NSUInteger)tw * 8];
            return t;
        };
        id<MTLTexture> before = atlas(oa, aw, ah), after = atlas(na, bw, bh);
        free(oa), free(na);

        // The faces as triangles, each corner with its place in both atlases.
        int nv = 0;
        for (int i = 0; i < w->nfaces; i++)
            if (b->faces[i].offset >= 0) nv += 3 * (w->faces[i].count - 2);
        struct vv *verts = calloc((size_t)nv + 1, sizeof *verts);
        int k = 0;
        for (int i = 0; i < w->nfaces; i++) {
            if (b->faces[i].offset < 0) continue;
            const struct bl_bsp_face *f = &w->faces[i];
            const struct bl_bsp_texinfo *t = &w->texinfo[f->texinfo];
            const float *refl = w->texdata[t->texdata].reflectivity;
            for (int c = 1; c + 1 < f->count; c++) {
                int corner[3] = {0, c, c + 1};
                for (int j = 0; j < 3; j++) {
                    const float *p = w->verts[w->index[f->first + corner[j]]];
                    struct vv *v = &verts[k++];
                    for (int a = 0; a < 3; a++) v->pos[a] = p[a] + f->origin[a];
                    memcpy(v->alb, refl, 12);
                    float s = p[0] * t->lm[0][0] + p[1] * t->lm[0][1] + p[2] * t->lm[0][2] + t->lm[0][3] - (float)f->mins[0];
                    float u = p[0] * t->lm[1][0] + p[1] * t->lm[1][1] + p[2] * t->lm[1][2] + t->lm[1][3] - (float)f->mins[1];
                    v->uo[0] = ((float)ox[i] + s + 0.5f) / (float)aw, v->uo[1] = ((float)oy[i] + u + 0.5f) / (float)ah;
                    v->un[0] = ((float)nx[i] + (s + 0.5f) * (float)scale) / (float)bw;
                    v->un[1] = ((float)ny[i] + (u + 0.5f) * (float)scale) / (float)bh;
                }
            }
        }
        id<MTLBuffer> vb = [dev newBufferWithBytes:verts length:sizeof *verts * (size_t)nv options:MTLResourceStorageModeShared];
        free(verts);

        NSError *error = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:view_source options:nil error:&error];
        if (!lib) {
            fprintf(stderr, "view shader: %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"view_vs"];
        pd.fragmentFunction = [lib newFunctionWithName:@"view_fs"];
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> pso = [dev newRenderPipelineStateWithDescriptor:pd error:&error];
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionLess, dd.depthWriteEnabled = YES;
        id<MTLDepthStencilState> dss = [dev newDepthStencilStateWithDescriptor:dd];
        const int W = 1280, H = 720;
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                                                                      width:W
                                                                                     height:H
                                                                                  mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget, cd.storageMode = MTLStorageModeShared;
        id<MTLTexture> color = [dev newTextureWithDescriptor:cd];
        MTLTextureDescriptor *zd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                      width:W
                                                                                     height:H
                                                                                  mipmapped:NO];
        zd.usage = MTLTextureUsageRenderTarget, zd.storageMode = MTLStorageModePrivate;
        id<MTLTexture> depth = [dev newTextureWithDescriptor:zd];
        id<MTLCommandQueue> q = [dev newCommandQueue];

        // The cameras.
        float cams[32][5];
        int ncams = 0;
        for (int a = 5; a + 4 < argc && ncams < 32; a += 5, ncams++)
            for (int j = 0; j < 5; j++) cams[ncams][j] = (float)atof(argv[a + j]);
        if (!ncams) {
            float start[3] = {0, 0, 0};
            // info_player_start from the entities: not kept by the reader, so from the
            // lights' middle when there is none.
            for (int i = 0; i < w->nlights; i++)
                for (int j = 0; j < 3; j++) start[j] += w->lights[i].origin[j] / (float)w->nlights;
            for (int yaw = 0; yaw < 360; yaw += 90, ncams++)
                cams[ncams][0] = start[0], cams[ncams][1] = start[1], cams[ncams][2] = start[2],
                cams[ncams][3] = (float)yaw, cams[ncams][4] = 10;
        }
        float *img = malloc(sizeof(float) * 4 * W * H * 2);
        uint8_t *rgba = malloc((size_t)W * H * 4);
        for (int c = 0; c < ncams; c++) {
            float yaw = cams[c][3] * (float)M_PI / 180, pitch = cams[c][4] * (float)M_PI / 180;
            float e[3] = {cams[c][0], cams[c][1], cams[c][2]};
            float fw[3] = {cosf(pitch) * cosf(yaw), cosf(pitch) * sinf(yaw), -sinf(pitch)};
            float rt[3] = {sinf(yaw), -cosf(yaw), 0};
            float up[3] = {rt[1] * fw[2] - rt[2] * fw[1], rt[2] * fw[0] - rt[0] * fw[2], rt[0] * fw[1] - rt[1] * fw[0]};
            float sx = 1 / tanf(45 * (float)M_PI / 180), sy = sx * (float)W / (float)H, n = 2, fz = 8000;
            float A = fz / (fz - n), B = -n * fz / (fz - n);
            float rows[4][4];
            for (int j = 0; j < 3; j++) rows[0][j] = sx * rt[j], rows[1][j] = sy * up[j], rows[2][j] = A * fw[j], rows[3][j] = fw[j];
            rows[0][3] = -sx * (rt[0] * e[0] + rt[1] * e[1] + rt[2] * e[2]);
            rows[1][3] = -sy * (up[0] * e[0] + up[1] * e[1] + up[2] * e[2]);
            rows[3][3] = -(fw[0] * e[0] + fw[1] * e[1] + fw[2] * e[2]);
            rows[2][3] = A * rows[3][3] + B;
            float m[16];
            for (int r = 0; r < 4; r++)
                for (int col = 0; col < 4; col++) m[col * 4 + r] = rows[r][col];
            for (uint32_t which = 0; which < 2; which++) {
                MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
                rp.colorAttachments[0].texture = color, rp.colorAttachments[0].loadAction = MTLLoadActionClear;
                rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                rp.colorAttachments[0].storeAction = MTLStoreActionStore;
                rp.depthAttachment.texture = depth, rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.clearDepth = 1, rp.depthAttachment.storeAction = MTLStoreActionDontCare;
                id<MTLCommandBuffer> cb = [q commandBuffer];
                id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
                [re setRenderPipelineState:pso];
                [re setDepthStencilState:dss];
                [re setVertexBuffer:vb offset:0 atIndex:0];
                [re setVertexBytes:m length:sizeof m atIndex:1];
                [re setVertexBytes:&which length:4 atIndex:2];
                [re setFragmentTexture:which ? after : before atIndex:0];
                [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(NSUInteger)nv];
                [re endEncoding];
                [cb commit];
                [cb waitUntilCompleted];
                [color getBytes:img + (size_t)which * 4 * W * H bytesPerRow:(NSUInteger)W * 16
                     fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
            }
            // One exposure for both, from the map's own bake: its log-average brightness.
            double logsum = 0;
            int lit = 0;
            for (int i = 0; i < W * H; i++) {
                float *p = img + 4 * i, l = 0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2];
                if (l > 0) logsum += log(l + 1e-4), lit++;
            }
            float exposure = lit ? 0.18f / (float)exp(logsum / lit) : 1;
            for (int which = 0; which < 2; which++) {
                for (int i = 0; i < W * H; i++) {
                    float *p = img + (size_t)which * 4 * W * H + 4 * i;
                    float l = (0.299f * p[0] + 0.587f * p[1] + 0.114f * p[2]) * exposure, s = exposure / (1 + l);
                    for (int j = 0; j < 3; j++) rgba[4 * i + j] = (uint8_t)(to_srgb(p[j] * s) * 255 + 0.5f);
                    rgba[4 * i + 3] = 255;
                }
                char path[2048];
                snprintf(path, sizeof path, "%s/view%d_%s.png", argv[2], c + 1, which ? "after" : "before");
                write_png(path, rgba, W, H);
            }
            printf("view %d: %.0f %.0f %.0f, yaw %.0f, pitch %.0f\n", c + 1, e[0], e[1], e[2], cams[c][3], cams[c][4]);
        }
        free(img), free(rgba);
        bl_bake_free(b);
        bl_bsp_world_free(w);
    }
    return 0;
}
