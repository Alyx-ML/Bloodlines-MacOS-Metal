// Metal 4 encoders that take the Metal 3 calls the renderer (metal_render.m) was written
// with. Bindings go into argument tables, small constants into the frame's upload space,
// and blits into compute encoders. Metal 4 command buffers neither retain nor track what
// they use, so everything bound is kept resident (one residency set) and alive while it
// is in use, and each pass waits on a fence for the one before it (MetalFX takes the same
// fence), so passes run in order as they did with Metal 3's tracking.
#import <Metal/Metal.h>

typedef id<MTLBuffer> (*mtl4_upload_fn)(const void *data, NSUInteger n, NSUInteger *offset);

void mtl4_setup(id<MTLDevice> device, id<MTL4CommandQueue> queue, mtl4_upload_fn upload);
id<MTLFence> mtl4_fence(void);
// Keeps a texture or buffer resident and alive until it has gone unused for a while.
void mtl4_track(id<MTLResource> r);
// The drawable's texture: resident through the layer's own set, and never held.
void mtl4_untracked(id<MTLTexture> t);
// Before each commit: residency changes take effect.
void mtl4_before_commit(void);
// After each frame: drops what has not been used for a while.
void mtl4_end_frame(unsigned long frame);

__attribute__((objc_direct_members))
@interface BLRender : NSObject
// Pass timestamps (BL_GPU_STATS=2) go to heap at 2 * stat and 2 * stat + 1 (stat >= 0).
- (instancetype)initWithEncoder:(id<MTL4RenderCommandEncoder>)e heap:(id<MTL4CounterHeap>)heap stat:(NSInteger)stat;
@property (readonly, nonatomic) id<MTL4RenderCommandEncoder> encoder;
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)p;
- (void)setDepthStencilState:(id<MTLDepthStencilState>)d;
- (void)setCullMode:(MTLCullMode)m;
- (void)setFrontFacingWinding:(MTLWinding)w;
- (void)setTriangleFillMode:(MTLTriangleFillMode)m;
- (void)setViewport:(MTLViewport)v;
- (void)setScissorRect:(MTLScissorRect)r;
- (void)setDepthBias:(float)bias slopeScale:(float)slope clamp:(float)clamp;
- (void)setStencilReferenceValue:(uint32_t)v;
- (void)setBlendColorRed:(float)r green:(float)g blue:(float)b alpha:(float)a;
- (void)setVertexBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i;
- (void)setVertexBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i;
- (void)setFragmentBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i;
- (void)setFragmentBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i;
- (void)setFragmentTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i;
- (void)setFragmentSamplerState:(id<MTLSamplerState>)s atIndex:(NSUInteger)i;
- (void)drawPrimitives:(MTLPrimitiveType)type vertexStart:(NSUInteger)start vertexCount:(NSUInteger)count;
- (void)drawIndexedPrimitives:(MTLPrimitiveType)type indexCount:(NSUInteger)count indexType:(MTLIndexType)it
                  indexBuffer:(id<MTLBuffer>)ib indexBufferOffset:(NSUInteger)io instanceCount:(NSUInteger)instances
                   baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi;
// Vertex-stage writes of the draws so far are seen by the vertex stage of later ones.
- (void)vertexBarrier;
- (void)endEncoding;
@end

__attribute__((objc_direct_members))
@interface BLCompute : NSObject
- (instancetype)initWithEncoder:(id<MTL4ComputeCommandEncoder>)e heap:(id<MTL4CounterHeap>)heap stat:(NSInteger)stat;
- (void)setComputePipelineState:(id<MTLComputePipelineState>)p;
- (void)setTexture:(id<MTLTexture>)t atIndex:(NSUInteger)i;
- (void)setBuffer:(id<MTLBuffer>)b offset:(NSUInteger)o atIndex:(NSUInteger)i;
- (void)setBytes:(const void *)p length:(NSUInteger)n atIndex:(NSUInteger)i;
- (void)dispatchThreadgroups:(MTLSize)groups threadsPerThreadgroup:(MTLSize)threads;
- (void)copyFromTexture:(id<MTLTexture>)src toTexture:(id<MTLTexture>)dst;
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toTexture:(id<MTLTexture>)dst
       destinationSlice:(NSUInteger)ds destinationLevel:(NSUInteger)dl destinationOrigin:(MTLOrigin)dorg;
- (void)copyFromTexture:(id<MTLTexture>)src sourceSlice:(NSUInteger)ss sourceLevel:(NSUInteger)sl
           sourceOrigin:(MTLOrigin)so sourceSize:(MTLSize)size toBuffer:(id<MTLBuffer>)dst
      destinationOffset:(NSUInteger)off destinationBytesPerRow:(NSUInteger)row
destinationBytesPerImage:(NSUInteger)image;
- (void)generateMipmapsForTexture:(id<MTLTexture>)t;
- (void)endEncoding;
@end
