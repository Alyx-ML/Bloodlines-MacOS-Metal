// Metal renderer behind the D3D9 device.
//
// Render targets and depth buffers are Metal textures; a render pass stays open while
// the bound targets stay the same. A Clear() covering the whole target becomes the next
// pass's load action, a partial one draws a quad. Draws translate the D3D9 state into
// cached pipeline, depth-stencil and sampler states; shaders go through
// d3d9_shader.c. Dynamic vertex buffers, user-pointer draws and all index data are
// copied per draw into per-frame upload buffers, so later guest writes cannot change
// what an earlier draw reads; static vertex buffers live in MTLBuffers refreshed on
// Unlock. Present() copies the back buffer to the window's CAMetalLayer when there is
// a window (BL_WINDOW=1), otherwise the frame stays offscreen.
//
// Debug environment:
//   BL_MAX_FRAMES=n          exit after n presented frames
//   BL_DUMP_FRAME=n[,m...]   write frame n's back buffer to BL_DUMP_DIR/frame_<n>.png, and the last
//                            offscreen target (e.g. the shadow atlas) to frame_<n>_rt.png
//   BL_DUMP_DIR=dir          (default: current directory)
//   BL_DRAW_STATS=n[+k]      log the draws of frame n (and the k-1 frames after it)
//   BL_DRAW_DUMP=n[,m...]    log the vertices, constants and shaders of draws n, m...; with "p<count>[:k]",
//                            of the k-th (default first) draw in frame BL_DRAW_STATS with that many primitives
//                            (with BL_DUMP_DIR, its 32-bit textures are also written as PNGs)
//   BL_TEX_STATS=1           with BL_DRAW_STATS, log the mean brightness of each 32-bit texture drawn
//   BL_SHADOW_SHOW=1         draw shadow receivers opaque instead of darkening
//   BL_FPS_MAX=n             with a window, present at most n frames a second (default 60, 0 = no cap)
//   BL_PACING=0              plain presents, even on screens whose refresh is a multiple of the cap
//   BL_PACING_STATS=1        log how many refreshes apart frames reach the screen
//   BL_FULLSCREEN=0|1        start in a window or full screen (default: what the game asks for)
//   BL_WIDESCREEN=stretch    keep the game's 4:3 projection on wider modes (default: corrected)
//   BL_MSAA=n                multisampling of the back buffer and its depth buffer (default 2, 1 = off)
//   BL_ANISO=n               anisotropic filtering for filtered mipmapped textures (default 16, 1 = off)
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bl_cocoa.h"
#include "d3d9_shader.h"
#include "d3d9_state.h"

static id<MTLDevice> mtl;
static id<MTLCommandQueue> queue;
static id<MTLCommandBuffer> cmd;
static id<MTLRenderCommandEncoder> enc;
static struct obj *enc_color, *enc_depth;  // targets of the open pass
static int enc_samples = 1;                // and its sample count
static CAMetalLayer *layer;

// Clears waiting for the next pass on these targets.
static struct obj *clear_color_target, *clear_depth_target;
static MTLClearColor clear_color;
static double clear_depth;
static uint32_t clear_stencil;
static int clear_has_stencil;

static uint32_t resized_w, resized_h;  // back buffer size (resize comes before init)
static unsigned long frames, draws, frame_draws;
static long max_frames = -1;
static int draw_stats;
static long draw_stats_frame, draw_stats_count = 1;
// Debug switches read once at start-up: getenv() per draw showed up in profiles.
static const char *env_draw_dump, *env_dump_dir;
static int env_tex_stats, env_shadow_show;
static double fps_max;  // frame cap with a window (BL_FPS_MAX, default 60; 0 = none)
static int env_pacing, env_pacing_stats;  // BL_PACING (default on), BL_PACING_STATS
static int env_aniso;   // forced anisotropy (BL_ANISO, default 16)
static int env_widescreen;  // correct the 4:3 projection on wider modes (BL_WIDESCREEN, default on)
static int msaa;        // samples for the back buffer and its depth (BL_MSAA, default 2; 1 = off)

#define LOG_ONCE(...) do { static int once_; if (!once_++) fprintf(stderr, __VA_ARGS__); } while (0)

// --- per-frame upload buffers ------------------------------------------------------

#define FRAMES_IN_FLIGHT 3
#define CHUNK (32u << 20)
static dispatch_semaphore_t in_flight;
static NSMutableArray<id<MTLBuffer>> *chunks[FRAMES_IN_FLIGHT];
static int frame_slot;
static NSUInteger chunk_index, chunk_used;

// Copies n bytes into this frame's upload space (aligned); returns buffer and offset.
static id<MTLBuffer> upload(const void *data, NSUInteger n, NSUInteger *offset)
{
    NSMutableArray<id<MTLBuffer>> *list = chunks[frame_slot];
    chunk_used = (chunk_used + 255) & ~(NSUInteger)255;
    if (chunk_index >= list.count || chunk_used + n > list[chunk_index].length) {
        if (chunk_index < list.count && chunk_used) chunk_index++;
        while (chunk_index < list.count && list[chunk_index].length < n) chunk_index++;
        if (chunk_index >= list.count)
            [list addObject:[mtl newBufferWithLength:n > CHUNK ? n : CHUNK options:MTLResourceStorageModeShared]];
        chunk_used = 0;
    }
    id<MTLBuffer> b = list[chunk_index];
    if (data) memcpy((uint8_t *)b.contents + chunk_used, data, n);
    *offset = chunk_used;
    chunk_used += n;
    return b;
}

// --- formats and textures --------------------------------------------------------

static int is_depth_format(uint32_t f) { return f >= 70 && f <= 83; }  // D3DFMT_D16_LOCKABLE .. D24FS8

static MTLPixelFormat target_format(uint32_t f)
{
    if (is_depth_format(f)) return MTLPixelFormatDepth32Float_Stencil8;
    switch (f) {
    case 113: return MTLPixelFormatRGBA16Float;  // A16B16G16R16F
    case 36: return MTLPixelFormatRGBA16Unorm;   // A16B16G16R16
    case 114: return MTLPixelFormatR32Float;     // R32F
    case 116: return MTLPixelFormatRGBA32Float;  // A32B32G32R32F
    default: return MTLPixelFormatBGRA8Unorm;    // A8R8G8B8, X8R8G8B8 and the 16-bit RGB formats
    }
}

#define FOURCC(a, b, c, d) ((uint32_t)(a) | (uint32_t)(b) << 8 | (uint32_t)(c) << 16 | (uint32_t)(d) << 24)

// How a D3D texture format is stored: the Metal format, a channel swizzle, and whether
// the texels need converting to BGRA8 on upload.
struct texfmt {
    MTLPixelFormat pf;
    MTLTextureSwizzleChannels swz;
    int convert;  // 0 copy, else the D3D format to expand to BGRA8
    int block;    // bytes per 4x4 block for BC formats
};

static struct texfmt texture_format(uint32_t f)
{
    MTLTextureSwizzleChannels id = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                                  MTLTextureSwizzleBlue, MTLTextureSwizzleAlpha);
    MTLTextureSwizzleChannels rgb1 = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                                    MTLTextureSwizzleBlue, MTLTextureSwizzleOne);
    switch (f) {
    case 21: return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, 0, 0};
    case 22: return (struct texfmt){MTLPixelFormatBGRA8Unorm, rgb1, 0, 0};
    case 20: case 23: case 24: case 25: case 26: case 27: case 29: case 30: case 31: case 32: case 33: case 52:
        return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, (int)f, 0};
    case 28: return (struct texfmt){MTLPixelFormatA8Unorm, id, 0, 0};
    case 50:  // L8
        return (struct texfmt){MTLPixelFormatR8Unorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed,
                                                             MTLTextureSwizzleRed, MTLTextureSwizzleOne), 0, 0};
    case 51:  // A8L8
        return (struct texfmt){MTLPixelFormatRG8Unorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed,
                                                             MTLTextureSwizzleRed, MTLTextureSwizzleGreen), 0, 0};
    case 60:  // V8U8
        return (struct texfmt){MTLPixelFormatRG8Snorm,
                               MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleGreen,
                                                             MTLTextureSwizzleOne, MTLTextureSwizzleOne), 0, 0};
    case 63: return (struct texfmt){MTLPixelFormatRGBA8Snorm, id, 0, 0};  // Q8W8V8U8
    case 36: return (struct texfmt){MTLPixelFormatRGBA16Unorm, id, 0, 0};
    case 113: return (struct texfmt){MTLPixelFormatRGBA16Float, id, 0, 0};
    case 114: return (struct texfmt){MTLPixelFormatR32Float, id, 0, 0};
    case 116: return (struct texfmt){MTLPixelFormatRGBA32Float, id, 0, 0};
    case FOURCC('D', 'X', 'T', '1'): return (struct texfmt){MTLPixelFormatBC1_RGBA, id, 0, 8};
    case FOURCC('D', 'X', 'T', '2'): case FOURCC('D', 'X', 'T', '3'):
        return (struct texfmt){MTLPixelFormatBC2_RGBA, id, 0, 16};
    case FOURCC('D', 'X', 'T', '4'): case FOURCC('D', 'X', 'T', '5'):
        return (struct texfmt){MTLPixelFormatBC3_RGBA, id, 0, 16};
    }
    if (is_depth_format(f)) return (struct texfmt){MTLPixelFormatDepth32Float_Stencil8, id, 0, 0};
    LOG_ONCE("[metal] texture format %u not supported, using BGRA8\n", f);
    return (struct texfmt){MTLPixelFormatBGRA8Unorm, id, 0, 0};
}

static inline uint32_t expand(uint32_t v, int bits) { return bits ? (v * 255 + ((1u << bits) - 1) / 2) / ((1u << bits) - 1) : 255; }

// One row of a 16/24/32-bit D3D format as BGRA8.
static void convert_row(uint32_t f, const uint8_t *src, uint8_t *dst, uint32_t w)
{
    for (uint32_t x = 0; x < w; x++, dst += 4) {
        uint32_t r = 0, g = 0, b = 0, a = 255;
        if (f == 20) {  // R8G8B8 (bytes B, G, R)
            b = src[3 * x], g = src[3 * x + 1], r = src[3 * x + 2];
        } else if (f == 31 || f == 32 || f == 33) {  // A2B10G10R10, A8B8G8R8, X8B8G8R8
            uint32_t v = ((const uint32_t *)src)[x];
            if (f == 31) r = v >> 2 & 255, g = v >> 12 & 255, b = v >> 22 & 255, a = expand(v >> 30, 2);
            else r = v & 255, g = v >> 8 & 255, b = v >> 16 & 255, a = f == 32 ? v >> 24 : 255;
        } else if (f == 52) {  // A4L4
            uint8_t v = src[x];
            r = g = b = expand(v & 15, 4), a = expand(v >> 4, 4);
        } else if (f == 27) {  // R3G3B2
            uint8_t v = src[x];
            r = expand(v >> 5 & 7, 3), g = expand(v >> 2 & 7, 3), b = expand(v & 3, 2);
        } else {
            uint32_t v = ((const uint16_t *)src)[x];
            switch (f) {
            case 23: r = expand(v >> 11, 5), g = expand(v >> 5 & 63, 6), b = expand(v & 31, 5); break;  // R5G6B5
            case 24: case 25:  // X1R5G5B5, A1R5G5B5
                r = expand(v >> 10 & 31, 5), g = expand(v >> 5 & 31, 5), b = expand(v & 31, 5);
                a = f == 25 ? (v >> 15 ? 255 : 0) : 255;
                break;
            case 26: case 30:  // A4R4G4B4, X4R4G4B4
                r = expand(v >> 8 & 15, 4), g = expand(v >> 4 & 15, 4), b = expand(v & 15, 4);
                a = f == 26 ? expand(v >> 12, 4) : 255;
                break;
            case 29: r = expand(v >> 5 & 7, 3), g = expand(v >> 2 & 7, 3), b = expand(v & 3, 2), a = v >> 8; break;
            }
        }
        dst[0] = (uint8_t)b, dst[1] = (uint8_t)g, dst[2] = (uint8_t)r, dst[3] = (uint8_t)a;
    }
}

static id<MTLTexture> target_texture(struct obj *o);

// Uploads one level (2D surface or volume) from guest memory.
static void upload_level(id<MTLTexture> t, struct texfmt tf, struct obj *s, NSUInteger slice, NSUInteger level)
{
    const uint8_t *src = bl_g2h(s->mem);
    MTLRegion r = MTLRegionMake3D(0, 0, 0, s->width, s->height, t.textureType == MTLTextureType3D ? s->depth : 1);
    if (tf.convert) {
        uint32_t row = s->width * 4;
        uint8_t *tmp = malloc((size_t)row * s->height * s->depth);
        for (uint32_t z = 0; z < s->depth; z++)
            for (uint32_t y = 0; y < s->height; y++)
                convert_row((uint32_t)tf.convert, src + z * s->slice + y * s->pitch, tmp + (z * s->height + y) * row,
                            s->width);
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:tmp bytesPerRow:row bytesPerImage:row * s->height];
        free(tmp);
    } else if (tf.block) {
        // Levels smaller than a block still upload a whole block.
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:src bytesPerRow:s->pitch bytesPerImage:s->slice];
    } else {
        [t replaceRegion:r mipmapLevel:level slice:slice withBytes:src bytesPerRow:s->pitch bytesPerImage:s->slice];
    }
    s->dirty = 0;
}

// The Metal texture of a D3D texture object, created and refreshed from guest memory.
static id<MTLTexture> texture_of(struct obj *tex)
{
    if (tex->type == OBJ_SURFACE) return target_texture(tex);
    int rt = (tex->usage & 1) != 0;  // D3DUSAGE_RENDERTARGET
    id<MTLTexture> t = (__bridge id<MTLTexture>)tex->gpu;
    struct texfmt tf = texture_format(tex->format);
    if (!t) {
        MTLTextureDescriptor *d = [MTLTextureDescriptor new];
        d.textureType = tex->type == OBJ_CUBETEXTURE ? MTLTextureTypeCube
                      : tex->type == OBJ_VOLUMETEXTURE ? MTLTextureType3D : MTLTextureType2D;
        d.pixelFormat = rt ? target_format(tex->format) : tf.pf;
        d.width = tex->width, d.height = tex->height, d.depth = tex->type == OBJ_VOLUMETEXTURE ? tex->depth : 1;
        d.mipmapLevelCount = tex->levels;
        d.usage = MTLTextureUsageShaderRead | (rt ? MTLTextureUsageRenderTarget : 0);
        d.storageMode = rt ? MTLStorageModePrivate : MTLStorageModeShared;
        if (!rt) d.swizzle = tf.swz;
        t = [mtl newTextureWithDescriptor:d];
        if (!t) bl_fatal("cannot create a %ux%u texture of format %u", tex->width, tex->height, tex->format);
        tex->gpu = (__bridge_retained void *)t;
        tex->dirty = !rt;
        if (!rt)
            for (uint32_t i = 0; i < tex->nsubs; i++) tex->subs[i]->dirty = 1;
    }
    if (tex->dirty && !rt) {
        uint32_t faces = tex->type == OBJ_CUBETEXTURE ? 6 : 1;
        for (uint32_t f = 0; f < faces; f++)
            for (uint32_t l = 0; l < tex->levels; l++) {
                struct obj *s = tex->subs[f * tex->levels + l];
                if (s->dirty) upload_level(t, tf, s, f, l);
            }
        tex->dirty = 0;
    }
    return t;
}

// Render target surfaces: their own texture, or a level of the texture they belong to.
static id<MTLTexture> target_texture(struct obj *o)
{
    if (o->gpu) return (__bridge id<MTLTexture>)o->gpu;
    id<MTLTexture> t;
    struct obj *owner = o->owner;
    if (owner && owner->type != OBJ_DEVICE && (owner->usage & 1)) {
        id<MTLTexture> parent = texture_of(owner);
        uint32_t i = 0;
        while (i < owner->nsubs && owner->subs[i] != o) i++;
        NSUInteger level = i % owner->levels, slice = i / owner->levels;
        t = [parent newTextureViewWithPixelFormat:parent.pixelFormat textureType:MTLTextureType2D
                                           levels:NSMakeRange(level, 1) slices:NSMakeRange(slice, 1)];
    } else {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:target_format(o->format)
                                                                                     width:o->width
                                                                                    height:o->height
                                                                                 mipmapped:NO];
        d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        d.storageMode = MTLStorageModePrivate;
        t = [mtl newTextureWithDescriptor:d];
    }
    t.label = [NSString stringWithFormat:@"surface %ux%u fmt %u", o->width, o->height, o->format];
    o->gpu = (__bridge_retained void *)t;
    return t;
}

// Multisampling covers the device's own surfaces: the back buffer and the automatic
// depth buffer. Passes on them draw into a multisampled copy and resolve into the
// surface's texture at the end, so everything that reads the surface sees the
// resolved image. Other render targets (shadows, reflections) stay single-sampled.
static int multisampled(struct obj *o) { return msaa > 1 && o && o->owner && o->owner->type == OBJ_DEVICE; }

static id<MTLTexture> ms_texture(struct obj *o)
{
    if (o->gpu_ms) return (__bridge id<MTLTexture>)o->gpu_ms;
    id<MTLTexture> single = target_texture(o);
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:single.pixelFormat
                                                                                 width:o->width
                                                                                height:o->height
                                                                             mipmapped:NO];
    d.textureType = MTLTextureType2DMultisample;
    d.sampleCount = (NSUInteger)msaa;
    d.usage = MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [mtl newTextureWithDescriptor:d];
    t.label = [NSString stringWithFormat:@"surface %ux%u fmt %u x%d", o->width, o->height, o->format, msaa];
    o->gpu_ms = (__bridge_retained void *)t;
    o->ms_stale = 1;  // whatever the surface holds is not in the new copy
    return t;
}

// --- shaders -----------------------------------------------------------------------

// One D3DVERTEXELEMENT9.
struct element { uint16_t stream, offset; uint8_t type, method, usage, index; };

@interface BLShader : NSObject {
@public
    struct d3d_shader_info info;
    const uint32_t *code;  // NULL for fixed-function stages: ff (pixel) or ffv (vertex)
    struct d3d_ff_ps ff;
    struct d3d_ff_vs ffv;
    int ff_vertex;
    uint64_t serial;
    NSMutableDictionary<NSData *, id> *variants;  // id<MTLFunction>, or NSNull for a shader that failed
}
@end
@implementation BLShader
@end

static uint64_t next_serial = 1;

static BLShader *shader_of(struct obj *o)
{
    if (o->gpu) return (__bridge BLShader *)o->gpu;
    BLShader *sh = [BLShader new];
    char err[256];
    sh->code = bl_g2h(o->mem);
    if (d3d_shader_parse(sh->code, &sh->info, err, sizeof err)) bl_fatal("shader: %s", err);
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    o->gpu = (__bridge_retained void *)sh;
    return sh;
}

// The pixel "shader" of a draw without one: the texture stage cascade, one BLShader per
// distinct set of stage states.
static BLShader *ff_pixel_shader(struct d3d_state *s)
{
    static NSMutableDictionary<NSData *, BLShader *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    struct d3d_ff_ps k;
    memset(&k, 0, sizeof k);
    for (int i = 0; i < 8; i++) {
        const uint32_t *t = s->tss[i];
        k.colorop[i] = (uint8_t)t[1];
        if (k.colorop[i] <= 1) break;
        k.colorarg[i][0] = (uint8_t)t[26], k.colorarg[i][1] = (uint8_t)t[2], k.colorarg[i][2] = (uint8_t)t[3];
        k.alphaop[i] = (uint8_t)t[4];
        k.alphaarg[i][0] = (uint8_t)t[27], k.alphaarg[i][1] = (uint8_t)t[5], k.alphaarg[i][2] = (uint8_t)t[6];
        k.resultarg[i] = (uint8_t)t[28], k.texcoord[i] = (uint8_t)(t[11] & 7);
    }
    k.specular = s->rs[29] != 0;  // SPECULARENABLE
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    BLShader *sh = cache[key];
    if (sh) return sh;
    sh = [BLShader new];
    sh->ff = k;
    sh->info.pixel = 1, sh->info.major = 1;  // ps_1_x rules for projected texcoords
    sh->info.color_outputs = 1;
    sh->info.sampler_mask = d3d_ff_ps_samplers(&k);
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    cache[key] = sh;
    if (getenv("BL_FF_TRACE")) {
        fprintf(stderr, "[ff] pixel stages %lu:", (unsigned long)sh->serial);
        for (int i = 0; i < 8 && k.colorop[i] > 1; i++)
            fprintf(stderr, " [%d: color %u(%#x,%#x,%#x) alpha %u(%#x,%#x,%#x) tc %u%s]", i, k.colorop[i],
                    k.colorarg[i][1], k.colorarg[i][2], k.colorarg[i][0], k.alphaop[i], k.alphaarg[i][1],
                    k.alphaarg[i][2], k.alphaarg[i][0], k.texcoord[i], k.resultarg[i] == 5 ? " temp" : "");
        fprintf(stderr, "%s\n", k.specular ? " +specular" : "");
    }
    return sh;
}

// The vertex "shader" of a draw without one, for the inputs its declaration has.
static BLShader *ff_vertex_shader(const struct element *el, int nel)
{
    static NSMutableDictionary<NSData *, BLShader *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    struct d3d_ff_vs k;
    memset(&k, 0, sizeof k);
    for (int j = 0; j < nel; j++) {
        if (el[j].usage == 9 && el[j].index == 0) k.positiont = 1;  // POSITIONT
        if (el[j].usage == 10 && el[j].index < 2) k.color[el[j].index] = 1;
        if (el[j].usage == 5 && el[j].index < 8) k.tex_mask |= (uint8_t)(1u << el[j].index);
    }
    NSData *key = [NSData dataWithBytes:&k length:sizeof k];
    BLShader *sh = cache[key];
    if (sh) return sh;
    sh = [BLShader new];
    sh->ffv = k, sh->ff_vertex = 1;
    sh->info.input_mask = 1, sh->info.input_usage[0] = k.positiont ? 9 : 0;
    for (int c = 0; c < 2; c++)
        if (k.color[c]) sh->info.input_mask |= 2u << c, sh->info.input_usage[1 + c] = 10, sh->info.input_index[1 + c] = (uint8_t)c;
    for (int n = 0; n < 8; n++)
        if (k.tex_mask & (1u << n))
            sh->info.input_mask |= 8u << n, sh->info.input_usage[3 + n] = 5, sh->info.input_index[3 + n] = (uint8_t)n;
    sh->serial = next_serial++;
    sh->variants = [NSMutableDictionary new];
    cache[key] = sh;
    return sh;
}

// Row-major 4x4 product a * b (D3D matrices are row-major, vectors are rows).
static void mat_mul(const float *a, const float *b, float *out)
{
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++) {
            float t = 0;
            for (int k = 0; k < 4; k++) t += a[4 * i + k] * b[4 * k + j];
            out[4 * i + j] = t;
        }
}

static id<MTLFunction> shader_function(BLShader *sh, const struct d3d_shader_variant *v)
{
    NSData *key = [NSData dataWithBytes:v length:sizeof *v];
    id f = sh->variants[key];
    if (f) return f == [NSNull null] ? nil : f;
    // A shader that does not translate or compile is logged once and its draws are
    // skipped (NSNull in the cache), so one bad shader does not end the game.
    char err[256];
    char *msl = sh->code ? d3d_shader_msl(sh->code, v, err, sizeof err)
                : sh->ff_vertex ? d3d_ff_vs_msl(&sh->ffv, err, sizeof err) : d3d_ff_ps_msl(&sh->ff, v, err, sizeof err);
    if (!msl) {
        fprintf(stderr, "[metal] shader %lu does not translate: %s\n", (unsigned long)sh->serial, err);
        sh->variants[key] = [NSNull null];
        return nil;
    }
    NSError *error = nil;
    MTLCompileOptions *opt = [MTLCompileOptions new];
    if (@available(macOS 15.0, *)) opt.mathMode = MTLMathModeSafe;
    else opt.fastMathEnabled = NO;
    id<MTLLibrary> lib = [mtl newLibraryWithSource:[NSString stringWithUTF8String:msl] options:opt error:&error];
    if (!lib) {
        fprintf(stderr, "[metal] shader %lu does not compile, its draws are skipped: %s\n%s\n",
                (unsigned long)sh->serial, error.localizedDescription.UTF8String, msl);
        free(msl);
        sh->variants[key] = [NSNull null];
        return nil;
    }
    free(msl);
    f = [lib newFunctionWithName:@"bl_main"];
    sh->variants[key] = f;
    return f;
}

// Internal shaders: partial clears.
static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask,
                                                 int samples);
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color, int samples);

// --- vertex input --------------------------------------------------------------------

// D3DDECLTYPE -> Metal vertex format and the shader-side type.
static MTLVertexFormat decl_format(uint32_t type, uint8_t *kind)
{
    *kind = D3D_IN_FLOAT;
    switch (type) {
    case 0: return MTLVertexFormatFloat;
    case 1: return MTLVertexFormatFloat2;
    case 2: return MTLVertexFormatFloat3;
    case 3: return MTLVertexFormatFloat4;
    case 4: return MTLVertexFormatUChar4Normalized_BGRA;  // D3DCOLOR
    case 5: *kind = D3D_IN_UINT; return MTLVertexFormatUChar4;
    case 6: *kind = D3D_IN_SINT; return MTLVertexFormatShort2;
    case 7: *kind = D3D_IN_SINT; return MTLVertexFormatShort4;
    case 8: return MTLVertexFormatUChar4Normalized;
    case 9: return MTLVertexFormatShort2Normalized;
    case 10: return MTLVertexFormatShort4Normalized;
    case 11: return MTLVertexFormatUShort2Normalized;
    case 12: return MTLVertexFormatUShort4Normalized;
    case 14: return MTLVertexFormatInt1010102Normalized;
    case 15: return MTLVertexFormatHalf2;
    case 16: return MTLVertexFormatHalf4;
    default: LOG_ONCE("[metal] vertex type %u not supported\n", type); return MTLVertexFormatFloat4;
    }
}


// Elements of the bound declaration, or of the FVF expressed as a declaration.
static int vertex_elements(struct d3d_state *s, struct element *e, int max)
{
    int n = 0;
    if (s->vdecl) {
        const struct element *d = bl_g2h(s->vdecl->mem);
        while (n < max && d[n].stream != 0xFF) e[n] = d[n], n++;
        return n;
    }
    uint32_t fvf = s->fvf;
    uint16_t off = 0;
#define ADD(t, u, i, size) (e[n++] = (struct element){0, off, t, 0, u, i}, off += size)
    uint32_t pos = fvf & 0x400E;
    if (pos == 0x4) ADD(3, 9, 0, 16);       // XYZRHW: POSITIONT
    else if (pos) {
        ADD(2, 0, 0, 12);                   // XYZ
        int weights = pos == 0x6 ? 1 : pos == 0x8 ? 2 : pos == 0xA ? 3 : pos == 0xC ? 4 : pos == 0xE ? 5 : 0;
        if (pos == 0x4002) ADD(3, 0, 1, 4); // XYZW: w joins the position (approximation)
        if (weights) {
            int last_is_index = (fvf & 0x1000) || (fvf & 0x8000);  // LASTBETA_UBYTE4 / D3DCOLOR
            int w = weights - (last_is_index ? 1 : 0);
            if (w) ADD((uint8_t)(w - 1), 1, 0, (uint16_t)(4 * w));
            if (last_is_index) ADD((fvf & 0x1000) ? 5 : 4, 2, 0, 4);
        }
    }
    if (fvf & 0x10) ADD(2, 3, 0, 12);       // NORMAL
    if (fvf & 0x20) ADD(0, 4, 0, 4);        // PSIZE
    if (fvf & 0x40) ADD(4, 10, 0, 4);       // DIFFUSE
    if (fvf & 0x80) ADD(4, 10, 1, 4);       // SPECULAR
    uint32_t ntex = (fvf >> 8) & 15;
    for (uint32_t i = 0; i < ntex && n < max; i++) {
        uint32_t f = (fvf >> (16 + 2 * i)) & 3;  // 0: 2 floats, 1: 3, 2: 4, 3: 1
        static const uint8_t type[4] = {1, 2, 3, 0}, size[4] = {8, 12, 16, 4};
        ADD(type[f], 5, (uint8_t)i, size[f]);
    }
#undef ADD
    return n;
}

// --- pipeline state --------------------------------------------------------------------

struct pipe_key {
    uint64_t vs, ps;
    struct d3d_shader_variant vsv, psv;
    uint16_t color_format, depth_format;
    uint32_t blend[7];  // enable, src, dst, op, src alpha, dst alpha, op alpha
    uint32_t write_mask;
    struct { uint16_t offset; uint8_t format, buffer; } attr[16];
    uint16_t stride[17];
    uint8_t constant[17];
    uint8_t point;
    uint8_t samples, alpha_to_coverage;
};

static NSMutableDictionary<NSData *, id<MTLRenderPipelineState>> *pipelines;
static NSMutableDictionary<NSData *, id<MTLDepthStencilState>> *depth_states;
static NSMutableDictionary<NSData *, id<MTLSamplerState>> *samplers;
static id<MTLBuffer> zero_buffer;

static MTLBlendFactor blend_factor(uint32_t b, int alpha)
{
    switch (b) {
    case 1: return MTLBlendFactorZero;
    case 2: return MTLBlendFactorOne;
    case 3: return alpha ? MTLBlendFactorSourceAlpha : MTLBlendFactorSourceColor;
    case 4: return alpha ? MTLBlendFactorOneMinusSourceAlpha : MTLBlendFactorOneMinusSourceColor;
    case 5: return MTLBlendFactorSourceAlpha;
    case 6: return MTLBlendFactorOneMinusSourceAlpha;
    case 7: return MTLBlendFactorDestinationAlpha;
    case 8: return MTLBlendFactorOneMinusDestinationAlpha;
    case 9: return alpha ? MTLBlendFactorDestinationAlpha : MTLBlendFactorDestinationColor;
    case 10: return alpha ? MTLBlendFactorOneMinusDestinationAlpha : MTLBlendFactorOneMinusDestinationColor;
    case 11: return MTLBlendFactorSourceAlphaSaturated;
    case 14: return alpha ? MTLBlendFactorBlendAlpha : MTLBlendFactorBlendColor;
    case 15: return alpha ? MTLBlendFactorOneMinusBlendAlpha : MTLBlendFactorOneMinusBlendColor;
    default: return MTLBlendFactorOne;
    }
}

static MTLBlendOperation blend_op(uint32_t op)
{
    switch (op) {
    case 2: return MTLBlendOperationSubtract;
    case 3: return MTLBlendOperationReverseSubtract;
    case 4: return MTLBlendOperationMin;
    case 5: return MTLBlendOperationMax;
    default: return MTLBlendOperationAdd;
    }
}

static MTLCompareFunction compare(uint32_t f)
{
    static const MTLCompareFunction m[] = {
        MTLCompareFunctionAlways, MTLCompareFunctionNever, MTLCompareFunctionLess, MTLCompareFunctionEqual,
        MTLCompareFunctionLessEqual, MTLCompareFunctionGreater, MTLCompareFunctionNotEqual,
        MTLCompareFunctionGreaterEqual, MTLCompareFunctionAlways,
    };
    return f <= 8 ? m[f] : MTLCompareFunctionAlways;
}

static MTLStencilOperation stencil_op(uint32_t op)
{
    static const MTLStencilOperation m[] = {
        MTLStencilOperationKeep, MTLStencilOperationKeep, MTLStencilOperationZero, MTLStencilOperationReplace,
        MTLStencilOperationIncrementClamp, MTLStencilOperationDecrementClamp, MTLStencilOperationInvert,
        MTLStencilOperationIncrementWrap, MTLStencilOperationDecrementWrap,
    };
    return op <= 8 ? m[op] : MTLStencilOperationKeep;
}

static id<MTLRenderPipelineState> pipeline(struct pipe_key *k, id<MTLFunction> vs, id<MTLFunction> ps)
{
    NSData *key = [NSData dataWithBytes:k length:sizeof *k];
    id<MTLRenderPipelineState> p = pipelines[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs;
    d.fragmentFunction = ps;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    uint32_t used = 0;
    for (int i = 0; i < 16; i++) {
        if (!k->attr[i].format) continue;
        vd.attributes[i].format = (MTLVertexFormat)k->attr[i].format;
        vd.attributes[i].offset = k->attr[i].offset;
        vd.attributes[i].bufferIndex = k->attr[i].buffer;
        used |= 1u << k->attr[i].buffer;
    }
    for (int b = 0; b < 17; b++) {
        if (!(used & (1u << b))) continue;
        if (k->constant[b] || !k->stride[b]) {
            vd.layouts[b].stepFunction = MTLVertexStepFunctionConstant;
            vd.layouts[b].stepRate = 0;
            vd.layouts[b].stride = k->stride[b] ? k->stride[b] : 16;
        } else {
            vd.layouts[b].stride = k->stride[b];
        }
    }
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = (MTLPixelFormat)k->color_format;
    if (k->color_format) {
        MTLRenderPipelineColorAttachmentDescriptor *c = d.colorAttachments[0];
        c.blendingEnabled = k->blend[0] != 0;
        c.sourceRGBBlendFactor = blend_factor(k->blend[1], 0);
        c.destinationRGBBlendFactor = blend_factor(k->blend[2], 0);
        c.rgbBlendOperation = blend_op(k->blend[3]);
        c.sourceAlphaBlendFactor = blend_factor(k->blend[4], 1);
        c.destinationAlphaBlendFactor = blend_factor(k->blend[5], 1);
        c.alphaBlendOperation = blend_op(k->blend[6]);
        MTLColorWriteMask m = 0;
        if (k->write_mask & 1) m |= MTLColorWriteMaskRed;
        if (k->write_mask & 2) m |= MTLColorWriteMaskGreen;
        if (k->write_mask & 4) m |= MTLColorWriteMaskBlue;
        if (k->write_mask & 8) m |= MTLColorWriteMaskAlpha;
        c.writeMask = m;
    }
    d.depthAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.stencilAttachmentPixelFormat = (MTLPixelFormat)k->depth_format;
    d.inputPrimitiveTopology = k->point ? MTLPrimitiveTopologyClassPoint : MTLPrimitiveTopologyClassUnspecified;
    d.rasterSampleCount = k->samples ? k->samples : 1;
    d.alphaToCoverageEnabled = k->alpha_to_coverage != 0;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) {
        fprintf(stderr, "[metal] pipeline failed, its draws are skipped: %s\n", error.localizedDescription.UTF8String);
        return nil;  // not cached: rare, and the log says each time
    }
    pipelines[key] = p;
    return p;
}

static id<MTLDepthStencilState> depth_state(struct d3d_state *s, int has_depth)
{
    const uint32_t *rs = s->rs;
    uint32_t k[16] = {0};
    if (has_depth) {
        k[0] = rs[7] ? 1 : 0;           // ZENABLE
        k[1] = rs[14];                  // ZWRITEENABLE
        k[2] = rs[23];                  // ZFUNC
        k[3] = rs[52];                  // STENCILENABLE
        if (k[3]) {
            k[4] = rs[53], k[5] = rs[54], k[6] = rs[55], k[7] = rs[56];  // FAIL, ZFAIL, PASS, FUNC
            k[8] = rs[58], k[9] = rs[59];                                // MASK, WRITEMASK
            k[10] = rs[185];                                             // TWOSIDEDSTENCILMODE
            if (k[10]) k[11] = rs[186], k[12] = rs[187], k[13] = rs[188], k[14] = rs[189];
        }
    }
    NSData *key = [NSData dataWithBytes:k length:sizeof k];
    id<MTLDepthStencilState> d = depth_states[key];
    if (d) return d;
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
    dd.depthCompareFunction = k[0] ? compare(k[2]) : MTLCompareFunctionAlways;
    dd.depthWriteEnabled = k[0] && k[1];
    if (k[3]) {
        MTLStencilDescriptor *front = [MTLStencilDescriptor new];
        front.stencilFailureOperation = stencil_op(k[4]);
        front.depthFailureOperation = stencil_op(k[5]);
        front.depthStencilPassOperation = stencil_op(k[6]);
        front.stencilCompareFunction = compare(k[7]);
        front.readMask = k[8] & 0xFF;
        front.writeMask = k[9] & 0xFF;
        dd.frontFaceStencil = front;
        if (k[10]) {
            MTLStencilDescriptor *back = [MTLStencilDescriptor new];
            back.stencilFailureOperation = stencil_op(k[11]);
            back.depthFailureOperation = stencil_op(k[12]);
            back.depthStencilPassOperation = stencil_op(k[13]);
            back.stencilCompareFunction = compare(k[14]);
            back.readMask = k[8] & 0xFF;
            back.writeMask = k[9] & 0xFF;
            dd.backFaceStencil = back;
        } else {
            dd.backFaceStencil = front;
        }
    }
    d = [mtl newDepthStencilStateWithDescriptor:dd];
    depth_states[key] = d;
    return d;
}

static MTLSamplerAddressMode address_mode(uint32_t m)
{
    switch (m) {
    case 2: return MTLSamplerAddressModeMirrorRepeat;
    case 3: return MTLSamplerAddressModeClampToEdge;
    case 4: return MTLSamplerAddressModeClampToBorderColor;
    case 5: return MTLSamplerAddressModeMirrorClampToEdge;
    default: return MTLSamplerAddressModeRepeat;
    }
}

static id<MTLSamplerState> sampler_state(const uint32_t *ss, int mipmapped)
{
    uint32_t k[8] = {ss[1], ss[2], ss[3], ss[5], ss[6], mipmapped ? ss[7] : 0, ss[9], ss[10]};
    uint32_t border = ss[4];
    k[0] |= (border == 0xFFFFFFFFu ? 1u : border >> 24 ? 2u : 0u) << 8;  // border: opaque white/black or transparent
    NSData *key = [NSData dataWithBytes:k length:sizeof k];
    id<MTLSamplerState> st = samplers[key];
    if (st) return st;
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.sAddressMode = address_mode(ss[1]);
    d.tAddressMode = address_mode(ss[2]);
    d.rAddressMode = address_mode(ss[3]);
    d.borderColor = border == 0xFFFFFFFFu ? MTLSamplerBorderColorOpaqueWhite
                  : border >> 24 ? MTLSamplerBorderColorOpaqueBlack : MTLSamplerBorderColorTransparentBlack;
    d.magFilter = ss[5] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = ss[6] >= 2 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.mipFilter = !mipmapped || ss[7] == 0 ? MTLSamplerMipFilterNotMipmapped
                : ss[7] == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterLinear;
    d.lodMinClamp = ss[9];  // MAXMIPLEVEL: the largest level used
    if (ss[5] == 3 || ss[6] == 3) d.maxAnisotropy = ss[10] < 1 ? 1 : ss[10] > 16 ? 16 : ss[10];
    // The game asks for trilinear at most; filtered mipmapped textures also get
    // anisotropic filtering (BL_ANISO, default 16, 1 turns it off).
    if (d.minFilter == MTLSamplerMinMagFilterLinear && d.mipFilter != MTLSamplerMipFilterNotMipmapped &&
        env_aniso > d.maxAnisotropy)
        d.maxAnisotropy = env_aniso;
    st = [mtl newSamplerStateWithDescriptor:d];
    samplers[key] = st;
    return st;
}

// Placeholder for unbound samplers: D3D9 reads (0, 0, 0, 1).
static id<MTLTexture> dummy_texture(int kind)
{
    static id<MTLTexture> t[5];
    if (t[kind]) return t[kind];
    MTLTextureDescriptor *d = [MTLTextureDescriptor new];
    d.textureType = kind == D3D_TEX_CUBE ? MTLTextureTypeCube : kind == D3D_TEX_3D ? MTLTextureType3D : MTLTextureType2D;
    d.pixelFormat = MTLPixelFormatBGRA8Unorm;
    d.width = d.height = 1;
    d.storageMode = MTLStorageModeShared;
    t[kind] = [mtl newTextureWithDescriptor:d];
    uint32_t black = 0xFF000000u;
    for (NSUInteger slice = 0; slice < (kind == D3D_TEX_CUBE ? 6u : 1u); slice++)
        [t[kind] replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:slice withBytes:&black bytesPerRow:4
                 bytesPerImage:4];
    return t[kind];
}

static int tex_kind_of(struct obj *t)
{
    if (!t) return D3D_TEX_2D;
    return t->type == OBJ_CUBETEXTURE ? D3D_TEX_CUBE : t->type == OBJ_VOLUMETEXTURE ? D3D_TEX_3D : D3D_TEX_2D;
}

// --- passes ----------------------------------------------------------------------

static void ensure_device(void)
{
    if (mtl) return;
    mtl = MTLCreateSystemDefaultDevice();
    if (!mtl) bl_fatal("no Metal device");
    queue = [mtl newCommandQueue];
    in_flight = dispatch_semaphore_create(FRAMES_IN_FLIGHT);
    for (int i = 0; i < FRAMES_IN_FLIGHT; i++) chunks[i] = [NSMutableArray new];
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    pipelines = [NSMutableDictionary new];
    depth_states = [NSMutableDictionary new];
    samplers = [NSMutableDictionary new];
    static const float zero[4] = {0, 0, 0, 0};
    zero_buffer = [mtl newBufferWithBytes:zero length:sizeof zero options:MTLResourceStorageModeShared];
    const char *m = getenv("BL_MAX_FRAMES");
    if (m) max_frames = atol(m);
    draw_stats = getenv("BL_DRAW_STATS") != NULL;
    draw_stats_frame = draw_stats ? atol(getenv("BL_DRAW_STATS")) : -1;
    if (draw_stats && strchr(getenv("BL_DRAW_STATS"), '+')) draw_stats_count = atol(strchr(getenv("BL_DRAW_STATS"), '+') + 1);
    env_draw_dump = getenv("BL_DRAW_DUMP");
    env_dump_dir = getenv("BL_DUMP_DIR");
    env_tex_stats = getenv("BL_TEX_STATS") != NULL;
    env_shadow_show = getenv("BL_SHADOW_SHOW") != NULL;
    fps_max = getenv("BL_FPS_MAX") ? atof(getenv("BL_FPS_MAX")) : 60;
    env_pacing = !(getenv("BL_PACING") && !strcmp(getenv("BL_PACING"), "0"));
    env_pacing_stats = getenv("BL_PACING_STATS") != NULL;
    env_aniso = getenv("BL_ANISO") ? atoi(getenv("BL_ANISO")) : 16;
    env_aniso = env_aniso < 1 ? 1 : env_aniso > 16 ? 16 : env_aniso;
    msaa = getenv("BL_MSAA") ? atoi(getenv("BL_MSAA")) : 2;
    env_widescreen = !(getenv("BL_WIDESCREEN") && !strcmp(getenv("BL_WIDESCREEN"), "stretch"));
    if (msaa < 1 || ![mtl supportsTextureSampleCount:(NSUInteger)msaa]) msaa = 1;
}

static id<MTLCommandBuffer> command_buffer(void)
{
    if (!cmd) cmd = [queue commandBuffer];
    return cmd;
}

static void end_pass(void)
{
    if (!enc) return;
    [enc endEncoding];
    enc = nil;
    enc_color = enc_depth = NULL;
}

// Opens a pass on the bound targets (render_target[0], depth_stencil), applying
// pending clears for them.
static void write_png(id<MTLBuffer> b, NSUInteger w, NSUInteger h, const char *path);
static struct obj *last_offscreen_target;  // for BL_DUMP_FRAME: the last non-back-buffer color target

// Copies a surface's texture into its multisampled copy, after something other than a
// multisampled pass wrote it (StretchRect, a pass that could not be multisampled).
static void restore_ms(struct obj *o, id<MTLTexture> ms)
{
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = ms;
    rp.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:stretch_pipeline(ms.pixelFormat, (int)ms.sampleCount)];
    [e setViewport:(MTLViewport){0, 0, ms.width, ms.height, 0, 1}];
    float p[4] = {0, 0, 1, 1};
    [e setVertexBytes:p length:sizeof p atIndex:0];
    [e setFragmentTexture:target_texture(o) atIndex:0];
    static id<MTLSamplerState> nearest;
    if (!nearest) nearest = [mtl newSamplerStateWithDescriptor:[MTLSamplerDescriptor new]];
    [e setFragmentSamplerState:nearest atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

static id<MTLRenderCommandEncoder> pass(struct d3d_state *s)
{
    struct obj *color = s->render_target[0], *depth = s->depth_stencil;
    if (enc && enc_color == color && enc_depth == depth) return enc;
    end_pass();
    if (color && color != s->back_buffer) last_offscreen_target = color;
    int samples = multisampled(color ? color : depth) ? msaa : 1;
    if (samples > 1 && color && depth && !multisampled(depth)) {
        LOG_ONCE("[metal] back buffer with a depth surface of its own: not multisampled\n");
        samples = 1;
    }
    MTLRenderPassDescriptor *d = [MTLRenderPassDescriptor renderPassDescriptor];
    if (color) {
        if (samples > 1) {
            id<MTLTexture> ms = ms_texture(color);
            if (color->ms_stale && clear_color_target != color) restore_ms(color, ms);
            color->ms_stale = 0;
            d.colorAttachments[0].texture = ms;
            d.colorAttachments[0].resolveTexture = target_texture(color);
            d.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        } else {
            d.colorAttachments[0].texture = target_texture(color);
            d.colorAttachments[0].storeAction = MTLStoreActionStore;
            if (multisampled(color)) color->ms_stale = 1;
        }
        if (clear_color_target == color) {
            d.colorAttachments[0].loadAction = MTLLoadActionClear;
            d.colorAttachments[0].clearColor = clear_color;
            clear_color_target = NULL;
        } else {
            d.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }
    }
    if (depth) {
        id<MTLTexture> t = samples > 1 ? ms_texture(depth) : target_texture(depth);
        d.depthAttachment.texture = t;
        d.stencilAttachment.texture = t;
        d.depthAttachment.storeAction = d.stencilAttachment.storeAction = MTLStoreActionStore;
        d.depthAttachment.loadAction = d.stencilAttachment.loadAction = MTLLoadActionLoad;
        if (clear_depth_target == depth) {
            d.depthAttachment.loadAction = MTLLoadActionClear;
            d.depthAttachment.clearDepth = clear_depth;
            if (clear_has_stencil) {
                d.stencilAttachment.loadAction = MTLLoadActionClear;
                d.stencilAttachment.clearStencil = clear_stencil;
            }
            clear_depth_target = NULL;
        }
    }
    enc = [command_buffer() renderCommandEncoderWithDescriptor:d];
    enc_color = color, enc_depth = depth, enc_samples = samples;
    return enc;
}

// Runs clears that no draw picked up.
static void flush_clears(struct d3d_state *s)
{
    if ((clear_color_target && clear_color_target == s->render_target[0]) ||
        (clear_depth_target && clear_depth_target == s->depth_stencil))
        pass(s);
    end_pass();
}

void d3d_render_free(struct obj *o)
{
    if (o->gpu_ms) {
        id m = (__bridge_transfer id)o->gpu_ms;
        (void)m;
        o->gpu_ms = NULL;
    }
    if (!o->gpu) return;
    id t = (__bridge_transfer id)o->gpu;  // released when t goes out of scope
    (void)t;
    o->gpu = NULL;
    if (enc_color == o || enc_depth == o) end_pass();
    if (clear_color_target == o) clear_color_target = NULL;
    if (clear_depth_target == o) clear_depth_target = NULL;
}

// Full screen when the game asks for it (no -window), unless BL_FULLSCREEN says otherwise.
static int game_windowed = 1;
static int full_screen(void)
{
    const char *f = getenv("BL_FULLSCREEN");
    return f && *f ? f[0] != '0' : !game_windowed;
}

void d3d_render_init(uint32_t window)
{
    ensure_device();
    if (getenv("BL_WINDOW")) {
        uint32_t w = resized_w ? resized_w : 1024, h = resized_h ? resized_h : 768;
        layer = bl_cocoa_open_window(w, h, "Vampire: The Masquerade – Bloodlines", window);
        if (layer) {
            layer.device = mtl;
            layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            layer.framebufferOnly = NO;
            layer.drawableSize = CGSizeMake(w, h);
            bl_cocoa_set_fullscreen(full_screen());
        }
    }
}

void d3d_render_windowed(int windowed)
{
    // Only a change of the game's setting moves the window; Cmd+Ctrl+F in between stays.
    if (windowed == game_windowed) return;
    game_windowed = windowed;
    if (layer) bl_cocoa_set_fullscreen(full_screen());
}

void d3d_render_resize(uint32_t width, uint32_t height)
{
    ensure_device();
    resized_w = width, resized_h = height;
    if (layer) {
        layer.drawableSize = CGSizeMake(width, height);
        bl_cocoa_set_content_size(width, height);
    }
}

// Viewport and scissor for the bound target.
static void set_viewport(struct d3d_state *s, id<MTLRenderCommandEncoder> e, uint32_t tw, uint32_t th)
{
    const uint32_t *vp = s->viewport;
    static uint32_t full[6];
    static int force = -1;
    if (force < 0) force = getenv("BL_FORCE_VIEWPORT") != NULL;
    if (force) {  // debugging: draw everything to the whole target
        full[2] = tw, full[3] = th, full[4] = vp[4], full[5] = vp[5];
        vp = full;
    }
    [e setViewport:(MTLViewport){vp[0], vp[1], vp[2], vp[3], u2f(vp[4]), u2f(vp[5])}];
    int32_t x0 = (int32_t)vp[0], y0 = (int32_t)vp[1], x1 = x0 + (int32_t)vp[2], y1 = y0 + (int32_t)vp[3];
    if (s->rs[174]) {  // SCISSORTESTENABLE
        const int32_t *r = (const int32_t *)s->scissor;
        if (r[0] > x0) x0 = r[0];
        if (r[1] > y0) y0 = r[1];
        if (r[2] < x1) x1 = r[2];
        if (r[3] < y1) y1 = r[3];
    }
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > (int32_t)tw) x1 = (int32_t)tw;
    if (y1 > (int32_t)th) y1 = (int32_t)th;
    if (x1 <= x0 || y1 <= y0) x0 = y0 = 0, x1 = y1 = 0;
    [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
}

void d3d_render_clear(struct d3d_state *s, uint32_t count, uint32_t rects, uint32_t flags, uint32_t color, float z,
                      uint32_t stencil)
{
    ensure_device();
    struct obj *rt = s->render_target[0], *ds = s->depth_stencil;
    if (!rt) return;
    const uint32_t *vp = s->viewport;
    int full = count == 0 && vp[0] == 0 && vp[1] == 0 && vp[2] >= rt->width && vp[3] >= rt->height &&
               (!s->rs[174] || (s->scissor[0] == 0 && s->scissor[1] == 0 && s->scissor[2] >= rt->width &&
                                s->scissor[3] >= rt->height));
    MTLClearColor cc = MTLClearColorMake((color >> 16 & 255) / 255.0, (color >> 8 & 255) / 255.0,
                                         (color & 255) / 255.0, (color >> 24) / 255.0);
    if (full) {
        end_pass();
        if (flags & 1) clear_color_target = rt, clear_color = cc;  // D3DCLEAR_TARGET
        if ((flags & 6) && ds) {                                    // D3DCLEAR_ZBUFFER | D3DCLEAR_STENCIL
            if (clear_depth_target != ds) clear_has_stencil = 0;
            clear_depth_target = ds;
            if (flags & 2) clear_depth = z;
            if (flags & 4) clear_stencil = stencil, clear_has_stencil = 1;
        }
        return;
    }
    // Partial clear: a quad per rectangle, inside the viewport.
    id<MTLRenderCommandEncoder> e = pass(s);
    id<MTLTexture> t = target_texture(rt);
    MTLPixelFormat dfmt = ds ? MTLPixelFormatDepth32Float_Stencil8 : MTLPixelFormatInvalid;
    uint32_t mask = (flags & 1 ? 1u : 0u) | (flags & 2 && ds ? 2u : 0u) | (flags & 4 && ds ? 4u : 0u);
    if (!mask) return;
    [e setRenderPipelineState:clear_pipeline(t.pixelFormat, dfmt, mask, enc_samples)];
    static NSMutableDictionary *clear_depth_states;
    if (!clear_depth_states) clear_depth_states = [NSMutableDictionary new];
    NSNumber *dk = @(mask);
    id<MTLDepthStencilState> dss = clear_depth_states[dk];
    if (!dss) {
        MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new];
        dd.depthCompareFunction = MTLCompareFunctionAlways;
        dd.depthWriteEnabled = (mask & 2) != 0;
        if (mask & 4) {
            MTLStencilDescriptor *sd = [MTLStencilDescriptor new];
            sd.depthStencilPassOperation = MTLStencilOperationReplace;
            dd.frontFaceStencil = dd.backFaceStencil = sd;
        }
        dss = [mtl newDepthStencilStateWithDescriptor:dd];
        clear_depth_states[dk] = dss;
    }
    [e setDepthStencilState:dss];
    [e setStencilReferenceValue:stencil & 0xFF];
    [e setCullMode:MTLCullModeNone];
    [e setTriangleFillMode:MTLTriangleFillModeFill];
    [e setDepthBias:0 slopeScale:0 clamp:0];
    [e setViewport:(MTLViewport){0, 0, t.width, t.height, 0, 1}];
    float params[5] = {(float)cc.red, (float)cc.green, (float)cc.blue, (float)cc.alpha, z};
    [e setFragmentBytes:params length:sizeof params atIndex:0];
    [e setVertexBytes:params length:sizeof params atIndex:0];
    int32_t vx0 = (int32_t)vp[0], vy0 = (int32_t)vp[1], vx1 = vx0 + (int32_t)vp[2], vy1 = vy0 + (int32_t)vp[3];
    uint32_t n = count ? count : 1;
    for (uint32_t i = 0; i < n; i++) {
        int32_t x0 = vx0, y0 = vy0, x1 = vx1, y1 = vy1;
        if (count) {
            const int32_t *r = bl_g2h(rects + 16 * i);
            if (r[0] > x0) x0 = r[0];
            if (r[1] > y0) y0 = r[1];
            if (r[2] < x1) x1 = r[2];
            if (r[3] < y1) y1 = r[3];
        }
        if (s->rs[174]) {
            const int32_t *r = (const int32_t *)s->scissor;
            if (r[0] > x0) x0 = r[0];
            if (r[1] > y0) y0 = r[1];
            if (r[2] < x1) x1 = r[2];
            if (r[3] < y1) y1 = r[3];
        }
        if (x0 < 0) x0 = 0;
        if (y0 < 0) y0 = 0;
        if (x1 > (int32_t)t.width) x1 = (int32_t)t.width;
        if (y1 > (int32_t)t.height) y1 = (int32_t)t.height;
        if (x1 <= x0 || y1 <= y0) continue;
        [e setScissorRect:(MTLScissorRect){(NSUInteger)x0, (NSUInteger)y0, (NSUInteger)(x1 - x0), (NSUInteger)(y1 - y0)}];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
}

static id<MTLRenderPipelineState> clear_pipeline(MTLPixelFormat color, MTLPixelFormat depth, uint32_t mask,
                                                 int samples)
{
    static NSMutableDictionary<NSString *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSString *src = @"#include <metal_stdlib>\n"
                         "using namespace metal;\n"
                         "struct V { float4 pos [[position]]; };\n"
                         "vertex V clear_vs(uint id [[vertex_id]], constant float *p [[buffer(0)]]) {\n"
                         "    V v; float2 uv = float2((id << 1) & 2, id & 2);\n"
                         "    v.pos = float4(uv * 2.0 - 1.0, p[4], 1.0); return v; }\n"
                         "struct F { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
                         "fragment F clear_fs(V in [[stage_in]], constant float *p [[buffer(0)]]) {\n"
                         "    F f; f.c = float4(p[0], p[1], p[2], p[3]); f.d = p[4]; return f; }\n";
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:src options:nil error:&error];
        if (!lib) bl_fatal("clear shader: %s", error.localizedDescription.UTF8String);
    }
    NSString *key = [NSString stringWithFormat:@"%lu/%lu/%u/%d", (unsigned long)color, (unsigned long)depth, mask,
                                               samples];
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"clear_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"clear_fs"];
    d.colorAttachments[0].pixelFormat = color;
    d.colorAttachments[0].writeMask = mask & 1 ? MTLColorWriteMaskAll : MTLColorWriteMaskNone;
    d.rasterSampleCount = (NSUInteger)samples;
    d.depthAttachmentPixelFormat = depth;
    d.stencilAttachmentPixelFormat = depth;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("clear pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

// Scaled StretchRect: one triangle covering the destination rectangle (set as the
// viewport) samples the source rectangle. p = {u0, v0, u1, v1} in normalized coordinates.
static id<MTLRenderPipelineState> stretch_pipeline(MTLPixelFormat color, int samples)
{
    static NSMutableDictionary<NSNumber *, id<MTLRenderPipelineState>> *cache;
    static id<MTLLibrary> lib;
    if (!cache) {
        cache = [NSMutableDictionary new];
        NSString *src = @"#include <metal_stdlib>\n"
                         "using namespace metal;\n"
                         "struct V { float4 pos [[position]]; float2 uv; };\n"
                         "vertex V stretch_vs(uint id [[vertex_id]], constant float4 &p [[buffer(0)]]) {\n"
                         "    V v; float2 t = float2((id << 1) & 2, id & 2);\n"
                         "    v.pos = float4(t.x * 2.0 - 1.0, 1.0 - t.y * 2.0, 0.0, 1.0);\n"
                         "    v.uv = mix(p.xy, p.zw, t); return v; }\n"
                         "fragment float4 stretch_fs(V in [[stage_in]], texture2d<float> t [[texture(0)]],\n"
                         "                           sampler s [[sampler(0)]]) { return t.sample(s, in.uv); }\n";
        NSError *error = nil;
        lib = [mtl newLibraryWithSource:src options:nil error:&error];
        if (!lib) bl_fatal("stretch shader: %s", error.localizedDescription.UTF8String);
    }
    NSNumber *key = @(color * 64 + (NSUInteger)samples);
    id<MTLRenderPipelineState> p = cache[key];
    if (p) return p;
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = [lib newFunctionWithName:@"stretch_vs"];
    d.fragmentFunction = [lib newFunctionWithName:@"stretch_fs"];
    d.colorAttachments[0].pixelFormat = color;
    d.rasterSampleCount = (NSUInteger)samples;
    NSError *error = nil;
    p = [mtl newRenderPipelineStateWithDescriptor:d error:&error];
    if (!p) bl_fatal("stretch pipeline: %s", error.localizedDescription.UTF8String);
    cache[key] = p;
    return p;
}

static void stretch_draw(id<MTLTexture> a, const uint32_t sr[4], id<MTLTexture> b, const uint32_t dr[4], int linear)
{
    if (a == b) {  // a pass cannot sample its own target: copy the source first
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:a.pixelFormat
                                                                                     width:a.width height:a.height
                                                                                 mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> copy = [mtl newTextureWithDescriptor:td];
        id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
        [blit copyFromTexture:a toTexture:copy];
        [blit endEncoding];
        a = copy;
    }
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = b;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e = [command_buffer() renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:stretch_pipeline(b.pixelFormat, 1)];
    [e setViewport:(MTLViewport){dr[0], dr[1], dr[2] - dr[0], dr[3] - dr[1], 0, 1}];
    float p[4] = {(float)sr[0] / a.width, (float)sr[1] / a.height, (float)sr[2] / a.width, (float)sr[3] / a.height};
    [e setVertexBytes:p length:sizeof p atIndex:0];
    [e setFragmentTexture:a atIndex:0];
    static id<MTLSamplerState> samp[2];
    if (!samp[linear]) {
        MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
        sd.minFilter = sd.magFilter = linear ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
        sd.sAddressMode = sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
        samp[linear] = [mtl newSamplerStateWithDescriptor:sd];
    }
    [e setFragmentSamplerState:samp[linear] atIndex:0];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
}

// --- draws -------------------------------------------------------------------------

static uint32_t index_count(uint32_t type, uint32_t prims)
{
    switch (type) {
    case 1: return prims;          // POINTLIST
    case 2: return 2 * prims;      // LINELIST
    case 3: return prims + 1;      // LINESTRIP
    case 4: return 3 * prims;      // TRIANGLELIST
    case 5: return prims + 2;      // TRIANGLESTRIP
    case 6: return 3 * prims;      // TRIANGLEFAN, drawn as a list
    default: return 0;
    }
}

static MTLPrimitiveType primitive(uint32_t type)
{
    switch (type) {
    case 1: return MTLPrimitiveTypePoint;
    case 2: return MTLPrimitiveTypeLine;
    case 3: return MTLPrimitiveTypeLineStrip;
    case 5: return MTLPrimitiveTypeTriangleStrip;
    default: return MTLPrimitiveTypeTriangle;
    }
}

// Where a stream's vertices come from for this draw.
struct stream_src { id<MTLBuffer> buf; NSUInteger offset; uint32_t stride; };

// A stream's data for vertices [first, first + count): a static buffer in place, or a
// copy of the range from a dynamic one. The offset is that of vertex 0 for static
// buffers and of vertex `first` for copies (*rebased set).
static struct stream_src stream_data(struct obj *vb, uint32_t offset, uint32_t stride, uint32_t first, uint32_t count,
                                     int *rebased)
{
    struct stream_src r = {nil, 0, stride};
    if (!vb) return r;
    int dynamic = (vb->usage & 0x200) != 0;  // D3DUSAGE_DYNAMIC
    if (!dynamic) {
        id<MTLBuffer> b = (__bridge id<MTLBuffer>)vb->gpu;
        if (!b) {
            b = [mtl newBufferWithBytes:bl_g2h(vb->mem) length:vb->size ? vb->size : 4
                                options:MTLResourceStorageModeShared];
            vb->gpu = (__bridge_retained void *)b;
            vb->dirty = 0;
        } else if (vb->dirty) {
            memcpy(b.contents, bl_g2h(vb->mem), vb->size);
            vb->dirty = 0;
        }
        r.buf = b, r.offset = offset;
        *rebased = 0;
        return r;
    }
    uint64_t start = (uint64_t)offset + (uint64_t)first * stride, len = (uint64_t)count * stride;
    if (start > vb->size) start = vb->size, len = 0;
    if (start + len > vb->size) len = vb->size - start;
    r.buf = upload((const uint8_t *)bl_g2h(vb->mem) + start, len ? len : 4, &r.offset);
    *rebased = 1;
    return r;
}

// Whether n is in a comma-separated list of numbers.
static int listed(const char *list, unsigned long n)
{
    for (const char *p = list; p; p = strchr(p, ','), p = p ? p + 1 : NULL)
        if (strtoul(p, NULL, 10) == n) return 1;
    return 0;
}

static void log_draw(struct d3d_state *s, const char *what, uint32_t type, uint32_t count)
{
    if (!draw_stats || (long)frames < draw_stats_frame || (long)frames >= draw_stats_frame + draw_stats_count) return;
    struct obj *t = s->texture[0];
    fprintf(stderr, "[%s] #%lu type %u prims %u vs %d ps %d fvf 0x%x rt %ux%u vp %u,%u %ux%u tex0 %ux%u fmt %u blend %u z %u\n",
            what, draws, type, count, s->vs != NULL, s->ps != NULL, s->fvf,
            s->render_target[0] ? s->render_target[0]->width : 0, s->render_target[0] ? s->render_target[0]->height : 0,
            s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3], t ? t->width : 0, t ? t->height : 0,
            t ? t->format : 0, s->rs[27], s->rs[7]);
}

// Everything a draw needs except vertex and index data; returns 0 if it cannot draw.
static int setup_draw(struct d3d_state *s, id<MTLRenderCommandEncoder> e, uint32_t type, struct element *el, int nel,
                      struct pipe_key *k)
{
    BLShader *vs = s->vs ? shader_of(s->vs) : ff_vertex_shader(el, nel);
    BLShader *ps = s->ps ? shader_of(s->ps) : ff_pixel_shader(s);
    memset(k, 0, sizeof *k);
    k->vs = vs->serial, k->ps = ps->serial;
    // Vertex inputs: match the shader's dcl_<usage><index> against the declaration.
    for (int i = 0; i < 16; i++) {
        if (!(vs->info.input_mask & (1u << i))) continue;
        int found = -1;
        for (int j = 0; j < nel; j++)
            if (el[j].usage == vs->info.input_usage[i] && el[j].index == vs->info.input_index[i]) found = j;
        if (found < 0) {
            k->attr[i].format = (uint8_t)MTLVertexFormatFloat4;
            k->attr[i].buffer = 16;
            k->constant[16] = 1;
            k->vsv.input_kind[i] = D3D_IN_FLOAT;
            continue;
        }
        uint8_t kind;
        k->attr[i].format = (uint8_t)decl_format(el[found].type, &kind);
        k->attr[i].offset = el[found].offset;
        k->attr[i].buffer = (uint8_t)el[found].stream;
        k->vsv.input_kind[i] = kind;
    }
    // Pixel shader samplers: texture types (ps_1_x does not declare them) and projection.
    for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
        if (!(ps->info.sampler_mask & (1u << i))) continue;
        k->psv.tex_kind[i] = (uint8_t)(ps->info.sampler_type[i] ? ps->info.sampler_type[i] : tex_kind_of(s->texture[i]));
        if (ps->info.major == 1 && i < 8 && (s->tss[i][24] & 256)) {  // TEXTURETRANSFORMFLAGS: PROJECTED
            uint32_t n = s->tss[i][24] & 255;
            k->psv.projected[i] = (uint8_t)(n == 3 ? 3 : 4);
        }
    }
    struct obj *rt = s->render_target[0];
    id<MTLTexture> rtt = target_texture(rt);
    k->color_format = (uint16_t)rtt.pixelFormat;
    k->depth_format = s->depth_stencil ? (uint16_t)MTLPixelFormatDepth32Float_Stencil8 : 0;
    const uint32_t *rs = s->rs;
    if (rs[27]) {  // ALPHABLENDENABLE
        uint32_t src = rs[19], dst = rs[20];
        if (src == 12) src = 5, dst = 6;   // BOTHSRCALPHA
        if (src == 13) src = 6, dst = 5;   // BOTHINVSRCALPHA
        if (src == 1 && dst == 4 && env_shadow_show) src = 2, dst = 1;  // debugging: draw shadows opaque
        k->blend[0] = 1, k->blend[1] = src, k->blend[2] = dst, k->blend[3] = rs[171];
        if (rs[206]) {  // SEPARATEALPHABLENDENABLE
            k->blend[4] = rs[207], k->blend[5] = rs[208], k->blend[6] = rs[209];
        } else {
            k->blend[4] = src, k->blend[5] = dst, k->blend[6] = rs[171];
        }
    }
    k->write_mask = rs[168] & 15;
    k->point = type == 1;
    k->samples = (uint8_t)enc_samples;
    // Alpha-tested cut-outs (fences, foliage, hair) get soft edges from the samples.
    k->alpha_to_coverage = enc_samples > 1 && rs[15] && !rs[27];  // ALPHATESTENABLE, no blending
    for (int b = 0; b < 16; b++) k->stride[b] = (uint16_t)s->stream_stride[b];
    k->stride[16] = 16;

    id<MTLFunction> vf = shader_function(vs, &k->vsv), pf = shader_function(ps, &k->psv);
    id<MTLRenderPipelineState> pso = vf && pf ? pipeline(k, vf, pf) : nil;
    if (!pso) return 0;
    [e setRenderPipelineState:pso];
    [e setDepthStencilState:depth_state(s, s->depth_stencil != NULL)];
    [e setStencilReferenceValue:rs[57] & 0xFF];
    uint32_t bf = rs[193];
    [e setBlendColorRed:(bf >> 16 & 255) / 255.0f green:(bf >> 8 & 255) / 255.0f blue:(bf & 255) / 255.0f
                  alpha:(bf >> 24) / 255.0f];
    [e setFrontFacingWinding:MTLWindingClockwise];
    [e setCullMode:rs[22] == 2 ? MTLCullModeFront : rs[22] == 3 ? MTLCullModeBack : MTLCullModeNone];
    [e setTriangleFillMode:rs[8] == 2 ? MTLTriangleFillModeLines : MTLTriangleFillModeFill];
    [e setDepthBias:u2f(rs[195]) * 16777215.0f slopeScale:u2f(rs[175]) clamp:0];
    set_viewport(s, e, (uint32_t)rtt.width, (uint32_t)rtt.height);

    // Constants: the game's, with the shader's own definitions on top.
    float vc[256][4];
    memcpy(vc, s->vs_f, sizeof vc);
    for (int i = 0; i < vs->info.ndefs; i++)
        if (vs->info.defs[i].reg < 256) memcpy(vc[vs->info.defs[i].reg], vs->info.defs[i].value, 16);
    if (vs->ff_vertex) {
        float m[16], t[16];
        if (vs->ffv.positiont) {
            vc[0][0] = (float)s->viewport[0], vc[0][1] = (float)s->viewport[1];
            vc[0][2] = s->viewport[2] ? 1.0f / s->viewport[2] : 0, vc[0][3] = s->viewport[3] ? 1.0f / s->viewport[3] : 0;
        } else {
            mat_mul((const float *)s->transform[24], (const float *)s->transform[2], t);  // WORLD * VIEW
            mat_mul(t, (const float *)s->transform[3], m);                              // * PROJECTION
            for (int j = 0; j < 4; j++)
                for (int i = 0; i < 4; i++) vc[j][i] = m[4 * i + j];  // columns
        }
    }
    [e setVertexBytes:vc length:sizeof vc atIndex:20];
    struct d3d_vs_params vp;
    memset(&vp, 0, sizeof vp);
    memcpy(vp.i, s->vs_i, sizeof vp.i);
    memcpy(vp.b, s->vs_b, sizeof vp.b);
    for (int i = 0; i < vs->info.ndefis; i++)
        if (vs->info.defis[i].reg < 16) memcpy(vp.i[vs->info.defis[i].reg], vs->info.defis[i].value, 16);
    for (int i = 0; i < vs->info.ndefbs; i++)
        if (vs->info.defbs[i].reg < 16) vp.b[vs->info.defbs[i].reg] = vs->info.defbs[i].value;
    vp.inv_viewport[0] = s->viewport[2] ? 1.0f / s->viewport[2] : 0;
    vp.inv_viewport[1] = s->viewport[3] ? 1.0f / s->viewport[3] : 0;
    // The game projects 3D views for a 4:3 screen whatever the resolution, so wider
    // modes come out stretched sideways. Perspective draws whose projection aspect is
    // narrower than the viewport are scaled up vertically to undo it (the view keeps
    // its width and loses some height), so the game's culling, made for that width,
    // still matches. The projection aspect is the ratio of the y and x scales: rows
    // c9 and c8 of the view-projection (Source's cViewProj), or PROJECTION _22/_11 for
    // fixed-function draws. 2D draws (last row 0 0 0 1) are left alone.
    // BL_WIDESCREEN=stretch keeps the game's own picture.
    vp.clip_y = 1;
    float aspect = s->viewport[3] ? (float)s->viewport[2] / (float)s->viewport[3] : 0;
    if (env_widescreen && aspect > 4.0f / 3.0f + 0.01f && !(vs->ff_vertex && vs->ffv.positiont)) {
        const float *w_row = vs->ff_vertex ? vc[3] : vc[11];
        float proj = 0;
        if (vs->ff_vertex) {
            const float *p = (const float *)s->transform[3];
            if (p[0] != 0) proj = p[5] / p[0];
        } else {
            float lx = sqrtf(vc[8][0] * vc[8][0] + vc[8][1] * vc[8][1] + vc[8][2] * vc[8][2]);
            float ly = sqrtf(vc[9][0] * vc[9][0] + vc[9][1] * vc[9][1] + vc[9][2] * vc[9][2]);
            if (lx != 0) proj = ly / lx;
        }
        int perspective = w_row[0] != 0 || w_row[1] != 0 || w_row[2] != 0 || w_row[3] != 1;
        if (perspective && proj > 0 && aspect > proj * 1.01f) vp.clip_y = aspect / proj;
    }
    [e setVertexBytes:&vp length:sizeof vp atIndex:21];

    float pc[224][4];
    memcpy(pc, s->ps_f, sizeof pc);
    for (int i = 0; i < ps->info.ndefs; i++)
        if (ps->info.defs[i].reg < 224) memcpy(pc[ps->info.defs[i].reg], ps->info.defs[i].value, 16);
    if (!ps->code) {  // fixed-function stages read TEXTUREFACTOR from c0
        uint32_t f = rs[60];
        pc[0][0] = (f >> 16 & 255) / 255.0f, pc[0][1] = (f >> 8 & 255) / 255.0f;
        pc[0][2] = (f & 255) / 255.0f, pc[0][3] = (f >> 24) / 255.0f;
    }
    [e setFragmentBytes:pc length:sizeof pc atIndex:0];
    struct d3d_ps_params pp;
    memset(&pp, 0, sizeof pp);
    memcpy(pp.i, s->ps_i, sizeof pp.i);
    memcpy(pp.b, s->ps_b, sizeof pp.b);
    for (int i = 0; i < ps->info.ndefis; i++)
        if (ps->info.defis[i].reg < 16) memcpy(pp.i[ps->info.defis[i].reg], ps->info.defis[i].value, 16);
    for (int i = 0; i < ps->info.ndefbs; i++)
        if (ps->info.defbs[i].reg < 16) pp.b[ps->info.defbs[i].reg] = ps->info.defbs[i].value;
    for (int i = 0; i < 8; i++) {
        for (int j = 0; j < 4; j++) pp.bumpenv[i][j] = u2f(s->tss[i][7 + j]);  // BUMPENVMAT00..11
        pp.bumpenv_l[i][0] = u2f(s->tss[i][22]), pp.bumpenv_l[i][1] = u2f(s->tss[i][23]);
    }
    pp.alpha_func = rs[15] ? rs[25] : 8;  // ALPHATESTENABLE, ALPHAFUNC
    pp.alpha_ref = (rs[24] & 255) / 255.0f;
    if (rs[28]) {  // FOGENABLE
        uint32_t c = rs[34];
        pp.fog_color[0] = (c >> 16 & 255) / 255.0f, pp.fog_color[1] = (c >> 8 & 255) / 255.0f;
        pp.fog_color[2] = (c & 255) / 255.0f, pp.fog_color[3] = 1;
        uint32_t table = rs[35];  // FOGTABLEMODE: 0 none, 1 exp, 2 exp2, 3 linear
        pp.fog_mode = table == 3 ? 2 : table == 1 ? 3 : table == 2 ? 4 : 1;
        pp.fog_start = u2f(rs[36]), pp.fog_end = u2f(rs[37]), pp.fog_density = u2f(rs[38]);
    }
    [e setFragmentBytes:&pp length:sizeof pp atIndex:1];

    for (uint32_t i = 0; i < D3D_SHADER_MAX_SAMPLERS; i++) {
        if (!(ps->info.sampler_mask & (1u << i))) continue;
        struct obj *t = s->texture[i];
        id<MTLTexture> mt = t ? texture_of(t) : dummy_texture(k->psv.tex_kind[i]);
        if (tex_kind_of(t) != k->psv.tex_kind[i]) mt = dummy_texture(k->psv.tex_kind[i]);
        [e setFragmentTexture:mt atIndex:i];
        [e setFragmentSamplerState:sampler_state(s->ss[i], mt.mipmapLevelCount > 1) atIndex:i];
    }
    [e setVertexBuffer:zero_buffer offset:0 atIndex:16];
    return 1;
}

// Index data for a draw, as 16- or 32-bit indices in upload space. Triangle fans
// become lists.
static id<MTLBuffer> index_data(uint32_t type, const void *src, int is32, uint32_t prims, uint32_t *count,
                                NSUInteger *offset, MTLIndexType *itype)
{
    uint32_t n = index_count(type, prims);
    *count = n;
    *itype = is32 ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
    if (type != 6) return upload(src, (NSUInteger)n * (is32 ? 4 : 2), offset);
    id<MTLBuffer> b = upload(NULL, (NSUInteger)n * 4, offset);
    uint32_t *out = (uint32_t *)((uint8_t *)b.contents + *offset);
    for (uint32_t i = 0; i < prims; i++) {
        uint32_t a = 0, c = i + 1, d = i + 2;
        if (src) {
            a = is32 ? ((const uint32_t *)src)[0] : ((const uint16_t *)src)[0];
            c = is32 ? ((const uint32_t *)src)[i + 1] : ((const uint16_t *)src)[i + 1];
            d = is32 ? ((const uint32_t *)src)[i + 2] : ((const uint16_t *)src)[i + 2];
        }
        out[3 * i] = a, out[3 * i + 1] = c, out[3 * i + 2] = d;
    }
    *itype = MTLIndexTypeUInt32;
    return b;
}

void d3d_render_draw(struct d3d_state *s, uint32_t type, int32_t base_vertex, uint32_t min_index, uint32_t nverts,
                     uint32_t start, uint32_t count, int indexed, uint32_t unused0, uint32_t unused1)
{
    (void)unused0, (void)unused1;
    ensure_device();
    draws++, frame_draws++;
    log_draw(s, indexed ? "drawindexed" : "draw", type, count);
    if (draw_stats && (long)frames >= draw_stats_frame && (long)frames < draw_stats_frame + draw_stats_count)
        fprintf(stderr, "[drawsrc] f%lu #%lu vb %#x+%u ib %#x start %u base %d min %u n %u vs %#x c11 %g %g %g %g zw %u\n", frames, draws,
                s->stream[0] ? s->stream[0]->guest : 0, s->stream_offset[0], s->indices ? s->indices->guest : 0, start,
                base_vertex, min_index, nverts, s->vs ? s->vs->guest : 0, u2f(s->vs_f[11][0]), u2f(s->vs_f[11][1]),
                u2f(s->vs_f[11][2]), u2f(s->vs_f[11][3]), s->rs[14]);
    if (!s->render_target[0] || !count) return;
    struct element el[64];
    int nel = vertex_elements(s, el, 64);
    id<MTLRenderCommandEncoder> e = pass(s);
    struct pipe_key k;
    if (!setup_draw(s, e, type, el, nel, &k)) return;
    if (env_tex_stats && (long)frames == draw_stats_frame) {
        // debugging: brightness of each plain 32-bit texture the frame samples, once per texture
        static void *seen[256];
        static int nseen;
        for (int i = 0; i < 8; i++) {
            struct obj *t = s->texture[i];
            if (!t || t->type != OBJ_TEXTURE || (t->usage & 1) || t->format != 21) continue;
            int known = 0;
            for (int j = 0; j < nseen; j++) known |= seen[j] == t;
            if (known || nseen == 256) continue;
            seen[nseen++] = t;
            const uint8_t *px = bl_g2h(t->subs[0]->mem);
            unsigned long sum[3] = {0}, n = 0, sat = 0;
            for (uint32_t y = 0; y < t->height; y++)
                for (uint32_t x = 0; x < t->width; x++, n++) {
                    const uint8_t *q = px + y * t->subs[0]->pitch + x * 4;
                    for (int c = 0; c < 3; c++) sum[c] += q[c];
                    sat += q[0] == 255 && q[1] == 255 && q[2] == 255;
                }
            fprintf(stderr, "[texstats] draw %lu stage %d %ux%u mem %#x mean bgr %lu %lu %lu, white %lu of %lu\n", draws, i,
                    t->width, t->height, t->subs[0]->mem, sum[0] / n, sum[1] / n, sum[2] / n, sat, n);
        }
    }
    const char *dd = env_draw_dump;
    static int dumped_by_prims;
    int dump = dd && (dd[0] == 'p' ? (long)frames == draw_stats_frame &&
                                         (uint32_t)atol(dd + 1) == count &&
                                         ++dumped_by_prims == (strchr(dd, ':') ? atoi(strchr(dd, ':') + 1) : 1)
                                   : listed(dd, draws));
    if (dump) {
        fprintf(stderr, "[dump] draw %lu: base %d min %u nverts %u start %u prims %u\n", draws, base_vertex, min_index,
                nverts, start, count);
        for (int i = 0; i < nel; i++)
            fprintf(stderr, "[dump]   element stream %u offset %u type %u usage %u index %u\n", el[i].stream,
                    el[i].offset, el[i].type, el[i].usage, el[i].index);
        for (int b = 0; b < 2; b++)
            if (s->stream[b]) {
                const float *f = (const float *)((const uint8_t *)bl_g2h(s->stream[b]->mem) + s->stream_offset[b] +
                                                 (size_t)(base_vertex + (int32_t)min_index) * s->stream_stride[b]);
                for (uint32_t v = 0; v < 4 && v < nverts; v++) {
                    fprintf(stderr, "[dump]   s%d v%u:", b, v);
                    for (uint32_t j = 0; j < s->stream_stride[b] / 4 && j < 12; j++)
                        fprintf(stderr, " %g", f[v * s->stream_stride[b] / 4 + j]);
                    fprintf(stderr, "\n");
                }
            }
        for (int i = 0; i < 96; i++)
            fprintf(stderr, "[dump]   c%d = %g %g %g %g\n", i, u2f(s->vs_f[i][0]), u2f(s->vs_f[i][1]),
                    u2f(s->vs_f[i][2]), u2f(s->vs_f[i][3]));
        for (int i = 0; i < 32; i++)
            fprintf(stderr, "[dump]   pc%d = %g %g %g %g\n", i, u2f(s->ps_f[i][0]), u2f(s->ps_f[i][1]),
                    u2f(s->ps_f[i][2]), u2f(s->ps_f[i][3]));
        fprintf(stderr, "[dump]   blend %u src %u dst %u op %u, alphatest %u ref %u func %u, wmask %#x, z %u/%u\n", s->rs[27],
                s->rs[19], s->rs[20], s->rs[171], s->rs[15], s->rs[24], s->rs[25], s->rs[168], s->rs[7], s->rs[14]);
        fprintf(stderr, "[dump]   viewport %u %u %u %u\n", s->viewport[0], s->viewport[1], s->viewport[2], s->viewport[3]);
        if (s->vs)
            for (int i = 0; i < 16; i++)
                if (shader_of(s->vs)->info.input_mask & (1u << i))
                    fprintf(stderr, "[dump]   vs input v%d usage %u index %u\n", i, shader_of(s->vs)->info.input_usage[i],
                            shader_of(s->vs)->info.input_index[i]);
        fprintf(stderr, "[dump]   zfunc %u, depth bias %g slope %g, cull %u\n", s->rs[23], u2f(s->rs[195]), u2f(s->rs[175]),
                s->rs[22]);
        for (int i = 0; i < 8; i++)
            if (s->texture[i])
                fprintf(stderr, "[dump]   tex%d %ux%u fmt %u usage %#x levels %u mtl %p\n", i, s->texture[i]->width,
                        s->texture[i]->height, s->texture[i]->format, s->texture[i]->usage, s->texture[i]->levels,
                        s->texture[i]->gpu);
        for (int i = 0; i < 8 && env_dump_dir; i++) {  // plain 32-bit textures as PNGs
            struct obj *t = s->texture[i];
            if (!t || t->type != OBJ_TEXTURE || (t->usage & 1) || (t->format != 21 && t->format != 22)) continue;
            id<MTLTexture> mt = texture_of(t);
            id<MTLBuffer> b = [mtl newBufferWithLength:mt.width * mt.height * 4 options:MTLResourceStorageModeShared];
            [mt getBytes:b.contents bytesPerRow:mt.width * 4 fromRegion:MTLRegionMake2D(0, 0, mt.width, mt.height)
             mipmapLevel:0];
            char path[1024];
            snprintf(path, sizeof path, "%s/draw_%lu_tex%d.png", env_dump_dir, draws, i);
            write_png(b, mt.width, mt.height, path);
        }
        if (s->render_target[0])
            fprintf(stderr, "[dump]   last offscreen target %p parent %p\n", last_offscreen_target,
                    last_offscreen_target ? (__bridge void *)target_texture(last_offscreen_target).parentTexture : NULL);
        char err[256];
        char *msl = s->vs ? d3d_shader_msl(shader_of(s->vs)->code, &k.vsv, err, sizeof err) : NULL;
        fprintf(stderr, "%s\n", msl ? strstr(msl, "vertex BLVSOut") : err);
        free(msl);
        msl = s->ps ? d3d_shader_msl(shader_of(s->ps)->code, &k.psv, err, sizeof err) : NULL;
        fprintf(stderr, "%s\n", msl ? strstr(msl, "fragment BLPSOut") : err);
        free(msl);
    }
    // Vertex range read by this draw.
    uint32_t first, nv;
    if (indexed) {
        first = (uint32_t)base_vertex + min_index, nv = nverts;
    } else {
        first = (uint32_t)base_vertex, nv = type == 6 ? count + 2 : index_count(type, count);
    }
    int any_rebased = 0, all_rebased = 1;
    struct stream_src src[16];
    for (int b = 0; b < 16; b++) {
        int used = 0;
        for (int i = 0; i < 16; i++)
            if (k.attr[i].format && k.attr[i].buffer == b) used = 1;
        if (!used) continue;
        int rebased;
        src[b] = stream_data(s->stream[b], s->stream_offset[b], s->stream_stride[b], first, nv, &rebased);
        if (!src[b].buf) {
            LOG_ONCE("[metal] draw without a vertex buffer on stream %d\n", b);
            return;
        }
        any_rebased |= rebased, all_rebased &= rebased;
        [e setVertexBuffer:src[b].buf offset:src[b].offset atIndex:(NSUInteger)b];
    }
    if (any_rebased && !all_rebased) {
        // Mixed static and dynamic streams: express everything relative to `first`.
        for (int b = 0; b < 16; b++) {
            int used = 0;
            for (int i = 0; i < 16; i++)
                if (k.attr[i].format && k.attr[i].buffer == b) used = 1;
            if (!used || !s->stream[b] || (s->stream[b]->usage & 0x200)) continue;
            [e setVertexBuffer:src[b].buf offset:src[b].offset + (NSUInteger)first * src[b].stride atIndex:(NSUInteger)b];
        }
    }
    int rel = any_rebased;  // vertex 0 of the bound buffers is vertex `first`
    if (!indexed) {
        if (type == 6) {
            uint32_t ic;
            NSUInteger io;
            MTLIndexType it;
            id<MTLBuffer> ib = index_data(type, NULL, 1, count, &ic, &io, &it);
            [e drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:ic indexType:it indexBuffer:ib
                   indexBufferOffset:io instanceCount:1 baseVertex:rel ? 0 : (NSInteger)first baseInstance:0];
        } else {
            [e drawPrimitives:primitive(type) vertexStart:rel ? 0 : first vertexCount:nv];
        }
        return;
    }
    struct obj *ibo = s->indices;
    if (!ibo) return;
    int is32 = ibo->format == 102;  // D3DFMT_INDEX32
    uint32_t isz = is32 ? 4 : 2, ic;
    if ((uint64_t)start * isz + (uint64_t)index_count(type, count) * isz > ibo->size) {
        LOG_ONCE("[metal] index range past the end of the index buffer\n");
        return;
    }
    NSUInteger io;
    MTLIndexType it;
    id<MTLBuffer> ib = index_data(type, (const uint8_t *)bl_g2h(ibo->mem) + (size_t)start * isz, is32, count, &ic, &io, &it);
    NSInteger bv = rel ? -(NSInteger)min_index : base_vertex;
    [e drawIndexedPrimitives:primitive(type) indexCount:ic indexType:it indexBuffer:ib indexBufferOffset:io
               instanceCount:1 baseVertex:bv baseInstance:0];
}

void d3d_render_draw_up(struct d3d_state *s, uint32_t type, uint32_t min_index, uint32_t nverts, uint32_t count,
                        uint32_t indices, uint32_t index_format, uint32_t data, uint32_t stride)
{
    ensure_device();
    draws++, frame_draws++;
    log_draw(s, indices ? "drawindexedup" : "drawup", type, count);
    if (!s->render_target[0] || !count || !stride) return;
    struct element el[64];
    int nel = vertex_elements(s, el, 64);
    id<MTLRenderCommandEncoder> e = pass(s);
    struct pipe_key k;
    // UP draws read stream 0 with the given stride.
    uint32_t saved_stride = s->stream_stride[0];
    s->stream_stride[0] = stride;
    int ok = setup_draw(s, e, type, el, nel, &k);
    s->stream_stride[0] = saved_stride;
    if (!ok) return;
    uint32_t nv = indices ? min_index + nverts : (type == 6 ? count + 2 : index_count(type, count));
    NSUInteger vo;
    id<MTLBuffer> vb = upload(bl_g2h(data), (NSUInteger)nv * stride, &vo);
    [e setVertexBuffer:vb offset:vo atIndex:0];
    if (!indices && type != 6) {
        [e drawPrimitives:primitive(type) vertexStart:0 vertexCount:nv];
        return;
    }
    uint32_t ic;
    NSUInteger io;
    MTLIndexType it;
    id<MTLBuffer> ib = index_data(type, indices ? bl_g2h(indices) : NULL, index_format == 102, count, &ic, &io, &it);
    [e drawIndexedPrimitives:primitive(type) indexCount:ic indexType:it indexBuffer:ib indexBufferOffset:io
               instanceCount:1 baseVertex:0 baseInstance:0];
}

// --- copies, read back and frame dumps -------------------------------------------------

// Copies a BGRA8 target into a shared buffer and waits; returns its contents.
static id<MTLBuffer> read_target(id<MTLTexture> t)
{
    NSUInteger row = t.width * 4;
    id<MTLBuffer> b = [mtl newBufferWithLength:row * t.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
               sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0
      destinationBytesPerRow:row destinationBytesPerImage:row * t.height];
    [blit endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    cmd = nil;
    return b;
}

static void write_png(id<MTLBuffer> b, NSUInteger w, NSUInteger h, const char *path)
{
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithData(NULL, b.contents, w * h * 4, NULL);
    CGImageRef img = CGImageCreate(w, h, 8, 32, w * 4, cs,
                                   kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, dp, NULL,
                                   false, kCGRenderingIntentDefault);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, (CFIndex)strlen(path), false);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL(url, CFSTR("public.png"), 1, NULL);
    if (dst) {
        CGImageDestinationAddImage(dst, img, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst);
    }
    CFRelease(url);
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    fprintf(stderr, "[metal] wrote %s\n", dst ? path : "(failed)");
}

static int dump_this_frame(unsigned long n)
{
    const char *list = getenv("BL_DUMP_FRAME");
    if (!list) return 0;
    for (const char *p = list; *p;) {
        char *end;
        unsigned long v = strtoul(p, &end, 10);
        if (end == p) break;
        if (v == n) return 1;
        p = *end ? end + 1 : end;
    }
    return 0;
}

void d3d_render_read_back(struct obj *rt)
{
    // GetRenderTargetData: the guest copy of a render target after GPU rendering.
    if (!rt->gpu || !rt->mem || target_format(rt->format) != MTLPixelFormatBGRA8Unorm) return;
    end_pass();
    id<MTLBuffer> b = read_target((__bridge id<MTLTexture>)rt->gpu);
    for (uint32_t y = 0; y < rt->height; y++)
        memcpy((uint8_t *)bl_g2h(rt->mem) + y * rt->pitch, (uint8_t *)b.contents + y * rt->width * 4, rt->width * 4);
}

static void next_frame(void)
{
    __block dispatch_semaphore_t sem = in_flight;
    [command_buffer() addCompletedHandler:^(id<MTLCommandBuffer> b) {
      (void)b;
      dispatch_semaphore_signal(sem);
    }];
    [cmd commit];
    cmd = nil;
    dispatch_semaphore_wait(in_flight, DISPATCH_TIME_FOREVER);
    frame_slot = (frame_slot + 1) % FRAMES_IN_FLIGHT;
    chunk_index = chunk_used = 0;
}

// Frame pacing. The game is capped at fps_max (its physics and scripts expect 60), but
// a plain present shows each frame at the next refresh after the GPU finishes, so on a
// 120 Hz ProMotion screen the small jitter of the cap's sleep makes frames alternate
// between one and three refreshes. When the refresh rate is a whole multiple of the cap,
// each frame is instead held for at least 1/fps_max (two refreshes at 120 Hz), which
// gives an even cadence. Other rates (144 Hz, say) keep the plain present: holding a
// frame for whole refreshes there would slow the game below the cap.
static int paced_present(void)
{
    static int checked_at = -1000, paced = -1;
    if (env_pacing && fps_max > 0 && (long)frames - checked_at >= 120) {  // the window may change screens
        checked_at = (int)frames;
        int hz = bl_cocoa_refresh_rate();
        double ratio = hz / fps_max;
        int whole = (int)(ratio + 0.5);
        int now = whole >= 1 && fabs(ratio - whole) < 0.01;
        if (now != paced)
            fprintf(stderr, "[present] screen %d Hz, cap %g: %s\n", hz, fps_max,
                    now ? "holding each frame for whole refreshes" : "plain present");
        paced = now;
    }
    return paced > 0;
}

// BL_PACING_STATS=1 logs how many refreshes apart frames actually reached the screen.
static void count_presented(id<CAMetalDrawable> drawable)
{
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    static double last;
    static unsigned hist[5], total;
    double hz = bl_cocoa_refresh_rate();
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
      double t = d.presentedTime;
      if (t <= 0 || hz <= 0) return;  // dropped
      os_unfair_lock_lock(&lock);
      if (last > 0) {
          int n = (int)((t - last) * hz + 0.5);
          hist[n < 1 ? 0 : n > 4 ? 4 : n]++;
          if (++total == 600) {
              fprintf(stderr, "[pacing] last 600 frames, refreshes apart: 1:%u 2:%u 3:%u 4+:%u (dropped/odd %u)\n",
                      hist[1], hist[2], hist[3], hist[4], hist[0]);
              memset(hist, 0, sizeof hist), total = 0;
          }
      }
      last = t;
      os_unfair_lock_unlock(&lock);
    }];
}

static void present(id<CAMetalDrawable> drawable)
{
    if (env_pacing_stats) count_presented(drawable);
    if (paced_present())
        [command_buffer() presentDrawable:drawable afterMinimumDuration:1.0 / fps_max];
    else
        [command_buffer() presentDrawable:drawable];
}

void d3d_render_present(struct d3d_state *s)
{
    ensure_device();
    flush_clears(s);
    frames++;
    struct obj *bb = s->back_buffer;
    id<MTLTexture> back = bb ? target_texture(bb) : nil;
    if (back && dump_this_frame(frames)) {
        const char *dir = getenv("BL_DUMP_DIR") ? getenv("BL_DUMP_DIR") : ".";
        char path[1024];
        snprintf(path, sizeof path, "%s/frame_%lu.png", dir, frames);
        write_png(read_target(back), back.width, back.height, path);
        id<MTLTexture> off = last_offscreen_target ? target_texture(last_offscreen_target) : nil;
        if (off && off.pixelFormat == MTLPixelFormatBGRA8Unorm) {
            snprintf(path, sizeof path, "%s/frame_%lu_rt.png", dir, frames);
            write_png(read_target(off), off.width, off.height, path);
        }
    }
    if (layer && back) {
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (drawable && drawable.texture.width == back.width && drawable.texture.height == back.height) {
                id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
                [blit copyFromTexture:back toTexture:drawable.texture];
                [blit endEncoding];
                present(drawable);
            }
            next_frame();
        }
    } else {
        next_frame();
    }
    if (layer && fps_max > 0) {
        // The game runs its loop flat out; with a window, wait out the rest of the frame
        // instead of burning a core on frames nobody sees.
        static uint64_t next_ns;
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW), period = (uint64_t)(1e9 / fps_max);
        if (next_ns > now && next_ns - now <= period) {
            struct timespec ts = {0, (long)(next_ns - now)};
            nanosleep(&ts, NULL);
            next_ns += period;
        } else {
            next_ns = now + period;  // first frame, or behind by more than a frame
        }
    }
    if (frames == 1 || frames % 100 == 0)
        fprintf(stderr, "[d3d9] frame %lu: %lu draws (%lu total)\n", frames, frame_draws, draws);
    frame_draws = 0;
    if (max_frames >= 0 && (long)frames >= max_frames) {
        fprintf(stderr, "[d3d9] %lu frames presented, stopping (BL_MAX_FRAMES)\n", frames);
        exit(0);
    }
}

// GDI blits to the window (Bink draws movie frames this way when it has no DirectDraw
// surface). The pixels are 32-bit BGRX rows from a DIB section; `bottom_up` flips them.
// They are scaled into a persistent window-sized image, which is then presented, so
// the parts of the window a movie does not cover stay black.
void d3d_render_present_pixels(const void *pixels, uint32_t w, uint32_t h, int bottom_up, const int32_t sr[4],
                               const int32_t dr[4])
{
    ensure_device();
    if (!layer) return;
    end_pass();
    static id<MTLTexture> src, screen;
    if (!src || src.width != w || src.height != h) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead;
        src = [mtl newTextureWithDescriptor:td];
    }
    NSUInteger sw = (NSUInteger)layer.drawableSize.width, sh = (NSUInteger)layer.drawableSize.height;
    if (!sw || !sh) return;
    if (!screen || screen.width != sw || screen.height != sh) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:sw height:sh mipmapped:NO];
        td.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        td.storageMode = MTLStorageModePrivate;
        screen = [mtl newTextureWithDescriptor:td];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = screen;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        [[command_buffer() renderCommandEncoderWithDescriptor:rp] endEncoding];
    }
    // Overwriting src while the GPU still reads the previous frame from it would tear
    // that frame; at movie frame rates the GPU has long finished.
    for (uint32_t y = 0; y < h; y++)
        [src replaceRegion:MTLRegionMake2D(0, y, w, 1) mipmapLevel:0
                 withBytes:(const uint8_t *)pixels + (size_t)(bottom_up ? h - 1 - y : y) * w * 4 bytesPerRow:w * 4];
    // Clip both rectangles to their images, scaling the source with the destination.
    int32_t s0[4] = {sr[0], sr[1], sr[2], sr[3]}, d0[4] = {dr[0], dr[1], dr[2], dr[3]};
    if (d0[2] <= d0[0] || d0[3] <= d0[1] || s0[2] <= s0[0] || s0[3] <= s0[1]) return;
    float kx = (float)(s0[2] - s0[0]) / (d0[2] - d0[0]), ky = (float)(s0[3] - s0[1]) / (d0[3] - d0[1]);
    if (d0[0] < 0) s0[0] -= (int32_t)(d0[0] * kx), d0[0] = 0;
    if (d0[1] < 0) s0[1] -= (int32_t)(d0[1] * ky), d0[1] = 0;
    if (d0[2] > (int32_t)sw) s0[2] -= (int32_t)((d0[2] - (int32_t)sw) * kx), d0[2] = (int32_t)sw;
    if (d0[3] > (int32_t)sh) s0[3] -= (int32_t)((d0[3] - (int32_t)sh) * ky), d0[3] = (int32_t)sh;
    for (int i = 0; i < 4; i++) {
        if (s0[i] < 0) s0[i] = 0;
        if (s0[i] > (int32_t)(i & 1 ? h : w)) s0[i] = (int32_t)(i & 1 ? h : w);
    }
    if (d0[2] <= d0[0] || d0[3] <= d0[1] || s0[2] <= s0[0] || s0[3] <= s0[1]) return;
    uint32_t su[4] = {(uint32_t)s0[0], (uint32_t)s0[1], (uint32_t)s0[2], (uint32_t)s0[3]};
    uint32_t du[4] = {(uint32_t)d0[0], (uint32_t)d0[1], (uint32_t)d0[2], (uint32_t)d0[3]};
    stretch_draw(src, su, screen, du, 1);
    @autoreleasepool {
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (drawable && drawable.texture.width == sw && drawable.texture.height == sh) {
            id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
            [blit copyFromTexture:screen toTexture:drawable.texture];
            [blit endEncoding];
            present(drawable);
        }
        next_frame();
    }
}

void d3d_render_stretch(struct obj *src, uint32_t src_rect, struct obj *dst, uint32_t dst_rect, uint32_t filter)
{
    if (!src || !dst) return;
    ensure_device();
    end_pass();
    // Only GPU-side surfaces (render targets) are copied here.
    id<MTLTexture> a = src->gpu || (src->usage & 1) || (src->owner && src->owner->type == OBJ_DEVICE)
                       ? target_texture(src) : nil;
    id<MTLTexture> b = target_texture(dst);
    if (!a || a.pixelFormat != b.pixelFormat) {
        LOG_ONCE("[metal] StretchRect between these surfaces is not supported yet\n");
        return;
    }
    uint32_t sr[4] = {0, 0, (uint32_t)a.width, (uint32_t)a.height}, dr[4] = {0, 0, (uint32_t)b.width, (uint32_t)b.height};
    if (src_rect) memcpy(sr, bl_g2h(src_rect), 16);
    if (dst_rect) memcpy(dr, bl_g2h(dst_rect), 16);
    if (multisampled(dst)) dst->ms_stale = 1;  // written outside its multisampled copy
    if (sr[2] - sr[0] != dr[2] - dr[0] || sr[3] - sr[1] != dr[3] - dr[1]) {
        stretch_draw(a, sr, b, dr, filter != 1);  // D3DTEXF_POINT is 1; NONE and LINEAR filter
        return;
    }
    uint32_t w = sr[2] - sr[0] < dr[2] - dr[0] ? sr[2] - sr[0] : dr[2] - dr[0];
    uint32_t h = sr[3] - sr[1] < dr[3] - dr[1] ? sr[3] - sr[1] : dr[3] - dr[1];
    id<MTLBlitCommandEncoder> blit = [command_buffer() blitCommandEncoder];
    [blit copyFromTexture:a sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(sr[0], sr[1], 0)
               sourceSize:MTLSizeMake(w, h, 1) toTexture:b destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(dr[0], dr[1], 0)];
    [blit endEncoding];
}

void d3d_render_color_fill(struct obj *surf, uint32_t rect, uint32_t color)
{
    (void)rect;
    if (!surf) return;
    ensure_device();
    // Whole-surface fills only, as a clear of the next pass on it.
    end_pass();
    clear_color_target = surf;
    clear_color = MTLClearColorMake((color >> 16 & 255) / 255.0, (color >> 8 & 255) / 255.0, (color & 255) / 255.0,
                                    (color >> 24) / 255.0);
    struct d3d_state tmp;
    memset(&tmp, 0, sizeof tmp);
    tmp.render_target[0] = surf;
    pass(&tmp);
    end_pass();
}

void d3d_image_changed(struct obj *surface)
{
    surface->dirty = 1;
    if (surface->owner && surface->owner->type != OBJ_DEVICE) surface->owner->dirty = 1;
}

void d3d_buffer_changed(struct obj *buffer) { buffer->dirty = 1; }
