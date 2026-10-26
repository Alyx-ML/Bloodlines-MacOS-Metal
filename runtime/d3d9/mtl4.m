// Metal 4 encoders taking the renderer's Metal 3 calls (mtl4.h).
#include <stdint.h>
#include <stdlib.h>

#include "mtl4.h"

static id<MTLFence> fence;
static id<MTL4ArgumentTable> vertex_table, fragment_table, compute_table;
static mtl4_upload_fn upload;

// --- residency -------------------------------------------------------------------
// Everything bound since it was last dropped: an open-addressed table of the objects
// (each retained) and the frame each was last used in. Texture views and textures on a
// buffer also keep what they view resident (`also`, refreshed with them).

#define KEEP_FRAMES 300  // unused this long: dropped
static struct entry {
    void *obj, *also;
    unsigned long last;
} *table;
static size_t cap, used;
static unsigned long now_frame;
static void *skip;
static id<MTLResidencySet> set;
static int dirty;

static size_t hash(const void *p) { return (size_t)(((uintptr_t)p >> 4) * 0x9E3779B97F4A7C15ull >> 24); }

static struct entry *find(const void *p)
{
    size_t m = cap - 1, h = hash(p) & m;
    while (table[h].obj && table[h].obj != p) h = (h + 1) & m;
    return &table[h];
}

static void rebuild(size_t ncap, int sweep)
{
    struct entry *old = table;
    size_t ocap = cap;
    table = calloc(ncap, sizeof *table), cap = ncap, used = 0;
    for (size_t i = 0; i < ocap; i++) {
        if (!old[i].obj) continue;
        if (sweep && now_frame - old[i].last > KEEP_FRAMES) {
            [set removeAllocation:(__bridge id<MTLAllocation>)old[i].obj];
            CFRelease(old[i].obj);
            dirty = 1;
            continue;
        }
        *find(old[i].obj) = old[i], used++;
    }
    free(old);
}

static void touch(void *p)
{
    struct entry *e = find(p);
    if (!e->obj) return;
    e->last = now_frame;
    if (e->also) touch(e->also);
}

static __attribute__((noinline)) void add(id<MTLResource> r)
{
    if (2 * (used + 1) > cap) rebuild(cap * 2, 0);
    void *also = NULL;
    if ([(id)r respondsToSelector:@selector(parentTexture)]) {
        id<MTLTexture> t = (id<MTLTexture>)r;
        id<MTLResource> under = t.parentTexture ? (id<MTLResource>)t.parentTexture : t.buffer;
        if (under) mtl4_track(under), also = (__bridge void *)under;
    }
    struct entry *e = find((__bridge void *)r);
    *e = (struct entry){(void *)CFBridgingRetain(r), also, now_frame};
    used++;
    [set addAllocation:r];
    dirty = 1;
}

void mtl4_track(id<MTLResource> r)
{
    void *p = (__bridge void *)r;
    if (!p || p == skip) return;
    struct entry *e = find(p);
    if (!e->obj) {
        add(r);
        return;
    }
    e->last = now_frame;
    if (e->also) touch(e->also);
}

void mtl4_untracked(id<MTLTexture> t) { skip = (__bridge void *)t; }

void mtl4_before_commit(void)
{
    if (dirty) [set commit], dirty = 0;
}

void mtl4_end_frame(unsigned long frame)
{
    now_frame = frame;
    if (frame % 64 == 0) rebuild(cap, 1);
}

// --- setup -------------------------------------------------------------------------

void mtl4_setup(id<MTLDevice> device, id<MTL4CommandQueue> queue, mtl4_upload_fn fn)
{
    upload = fn;
    fence = [device newFence];
    MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
    d.maxBufferBindCount = 31;
    d.maxTextureBindCount = 32;
    d.maxSamplerStateBindCount = 16;
    d.initializeBindings = YES;
    NSError *error = nil;
    vertex_table = [device newArgumentTableWithDescriptor:d error:&error];
    fragment_table = [device newArgumentTableWithDescriptor:d error:&error];
    compute_table = [device newArgumentTableWithDescriptor:d error:&error];
    if (!vertex_table || !fragment_table || !compute_table)
        NSLog(@"Metal 4: no argument tables: %@", error), abort();
    MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new];
    rd.initialCapacity = 4096;
    set = [device newResidencySetWithDescriptor:rd error:&error];
    if (!set) NSLog(@"Metal 4: no residency set: %@", error), abort();
    [queue addResidencySet:set];
    cap = 4096;
    table = calloc(cap, sizeof *table);
}

id<MTLFence> mtl4_fence(void) { return fence; }

// --- render passes -------------------------------------------------------------------

#define RENDER_STAGES (MTLStageVertex | MTLStageFragment)

@implementation BLRender {
    id<MTL4RenderCommandEncoder> _e;
    id<MTL4CounterHeap> _heap;
    NSInteger _stat;
}

- (instancetype)initWithEncoder:(id<MTL4RenderCommandEncoder>)e heap:(id<MTL4CounterHeap>)heap stat:(NSInteger)stat
{
    self = [super init];
    _e = e, _heap = heap, _stat = stat;
    [e waitForFence:fence beforeEncoderStages:RENDER_STAGES];
    [e setArgumentTable:vertex_table atStages:MTLRenderStageVertex];
    [e setArgumentTable:fragment_table atStages:MTLRenderStageFragment];
    if (stat >= 0)
        [e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise afterStage:MTLRenderStageVertex intoHeap:heap
                                 atIndex:2 * (NSUInteger)stat];
    return self;
}

- (id<MTL4RenderCommandEncoder>)encoder { return _e; }
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p { [_e setRenderPipelineState:p]; }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d { [_e setDepthStencilState:d]; }
- (void)setCullMode:(MTLCullMode)m { [_e setCullMode:m]; }
- (void)setFrontFacingWinding:(MTLWinding)w { [_e setFrontFacingWinding:w]; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { [_e setTriangleFillMode:m]; }
- (void)setViewport:(MTLViewport)v { [_e setViewport:v]; }
- (void)setScissorRect:(MTLScissorRect)r { [_e setScissorRect:r]; }
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp
{
    [_e setDepthBias:bias slopeScale:slope clamp:clamp];
}
- (void)setStencilReferenceValue:(uint32_t)v { [_e setStencilReferenceValue:v]; }
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a
{
    [_e setBlendColorRed:r green:g blue:b alpha:a];
}

- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
    if (!b) return;
    mtl4_track(b);
    [vertex_table setAddress:b.gpuAddress + o atIndex:i];
}

- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i
{
    NSUInteger o;
    [self setVertexBuffer:upload(p, n, &o) offset:o atIndex:i];
}

- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
    if (!b) return;
    mtl4_track(b);
    [fragment_table setAddress:b.gpuAddress + o atIndex:i];
}

- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i
{
    NSUInteger o;
    [self setFragmentBuffer:upload(p, n, &o) offset:o atIndex:i];
}

- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i
{
    mtl4_track(t);
    [fragment_table setTexture:t ? t.gpuResourceID : (MTLResourceID){0} atIndex:i];
}

- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i
{
    [fragment_table setSamplerState:s.gpuResourceID atIndex:i];
}

- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count
{
    [_e drawPrimitives:type vertexStart:start vertexCount:count];
}

- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)io instanceCount:(NSUInteger)instances
                   baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi
{
    mtl4_track(ib);
    [_e drawIndexedPrimitives:type indexCount:count indexType:it indexBuffer:ib.gpuAddress + io
            indexBufferLength:ib.length - io instanceCount:instances baseVertex:bv baseInstance:bi];
}

- (void)vertexBarrier
{
    [_e barrierAfterEncoderStages:MTLStageVertex beforeEncoderStages:MTLStageVertex
                visibilityOptions:MTL4VisibilityOptionDevice];
}

- (void)endEncoding
{
    if (_stat >= 0)
        [_e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise afterStage:MTLRenderStageFragment
                                 intoHeap:_heap atIndex:2 * (NSUInteger)_stat + 1];
    [_e updateFence:fence afterEncoderStages:RENDER_STAGES];
    [_e endEncoding];
}

@end

// --- compute passes and copies --------------------------------------------------------
// Commands in one compute encoder may overlap; each waits for the ones before it, as
// they did in Metal 3's serial encoders.

#define COMPUTE_STAGES (MTLStageDispatch | MTLStageBlit)

@implementation BLCompute {
    id<MTL4ComputeCommandEncoder> _e;
    id<MTL4CounterHeap> _heap;
    NSInteger _stat;
    int _commands;
}

- (instancetype)initWithEncoder:(id<MTL4ComputeCommandEncoder>)e heap:(id<MTL4CounterHeap>)heap stat:(NSInteger)stat
{
    self = [super init];
    _e = e, _heap = heap, _stat = stat;
    [e waitForFence:fence beforeEncoderStages:COMPUTE_STAGES];
    [e setArgumentTable:compute_table];
    if (stat >= 0)
        [e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:heap atIndex:2 * (NSUInteger)stat];
    return self;
}

- (void)next
{
    if (_commands++)
        [_e barrierAfterEncoderStages:COMPUTE_STAGES beforeEncoderStages:COMPUTE_STAGES
                    visibilityOptions:MTL4VisibilityOptionDevice];
}

- (void)setComputePipelineState:(id<MTLComputePipelineState>)p { [_e setComputePipelineState:p]; }

- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i
{
    mtl4_track(t);
    [compute_table setTexture:t ? t.gpuResourceID : (MTLResourceID){0} atIndex:i];
}

- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i
{
    if (!b) return;
    mtl4_track(b);
    [compute_table setAddress:b.gpuAddress + o atIndex:i];
}

- (void)setBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i
{
    NSUInteger o;
    [self setBuffer:upload(p, n, &o) offset:o atIndex:i];
}

- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads
{
    [self next];
    [_e dispatchThreadgroups:groups threadsPerThreadgroup:threads];
}

- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst
{
    mtl4_track(src), mtl4_track(dst);
    [self next];
    [_e copyFromTexture:src toTexture:dst];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg
{
    mtl4_track(src), mtl4_track(dst);
    [self next];
    [_e copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toTexture:dst
        destinationSlice:ds destinationLevel:dl destinationOrigin:dorg];
}

- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)off destinationBytesPerRow:(NSUInteger)row
destinationBytesPerImage:(NSUInteger)image
{
    mtl4_track(src), mtl4_track(dst);
    [self next];
    [_e copyFromTexture:src sourceSlice:ss sourceLevel:sl sourceOrigin:so sourceSize:size toBuffer:dst
        destinationOffset:off destinationBytesPerRow:row destinationBytesPerImage:image];
}

- (void)generateMipmapsForTexture:(id<MTLTexture>)t
{
    mtl4_track(t);
    [self next];
    [_e generateMipmapsForTexture:t];
}

- (void)endEncoding
{
    if (_stat >= 0)
        [_e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:_heap
                                  atIndex:2 * (NSUInteger)_stat + 1];
    [_e updateFence:fence afterEncoderStages:COMPUTE_STAGES];
    [_e endEncoding];
}

@end
