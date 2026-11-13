#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <TargetConditionals.h>

#include <math.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "fb_display.h"

static NSString *const kFbShaderSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "struct VOut {\n"
     "    float4 pos [[position]];\n"
     "    float2 uv;\n"
     "};\n"
     "vertex VOut fb_vs(uint vid [[vertex_id]], constant float2 &scale [[buffer(0)]]) {\n"
     "    const float2 quad[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };\n"
     "    const float2 uvs[4]  = { float2(0,1),   float2(1,1),  float2(0,0),  float2(1,0) };\n"
     "    VOut o;\n"
     "    o.pos = float4(quad[vid] * scale, 0.0, 1.0);\n"
     "    o.uv  = uvs[vid];\n"
     "    return o;\n"
     "}\n"
     "fragment float4 fb_fs(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);\n"
     "    float4 c = tex.sample(s, in.uv);\n"
     "    return float4(c.rgb, 1.0);\n"
     "}\n"
     "fragment float4 fb_fs_nearest(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {\n"
     "    constexpr sampler s(mag_filter::nearest, min_filter::nearest, address::clamp_to_edge);\n"
     "    float4 c = tex.sample(s, in.uv);\n"
     "    return float4(c.rgb, 1.0);\n"
     "}\n";

@interface HvFbMetalPresenter : NSObject {
@public
    HvFbDisplay *fb;
    os_unfair_lock lock;
    CAMetalLayer *layer;
    id<MTLDevice> device;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLTexture> texture;
    uint32_t texW, texH;
    dispatch_source_t timer;
    _Atomic(uint64_t) framesPresented;
    uint64_t lastHash;
    CGSize lastDrawableSize;
    /* iPad addition (sharp, smooth display): */
    id<MTLRenderPipelineState> pipelineNearest; /* for whole-number scale factors: crisp pixels */
    id<MTLBuffer> fbBuffer;                     /* guest framebuffer seen directly by the GPU, no copy */
    const uint8_t *texSrc;                      /* framebuffer the texture was made for */
    uint32_t texStride;
    BOOL zeroCopy;
    uint64_t lastPresentNs;
    dispatch_queue_t tickQueue;
#if TARGET_OS_IPHONE
    CADisplayLink *displayLink;                 /* up to 120 Hz on ProMotion screens */
    _Atomic(int) tickPending;
#endif
}
- (instancetype)initWithDisplay:(HvFbDisplay *)display;
- (void)setTargetLayer:(CAMetalLayer *)newLayer;
- (void)tick;
@end

@implementation HvFbMetalPresenter

- (instancetype)initWithDisplay:(HvFbDisplay *)display {
    if ((self = [super init])) {
        fb = display;
        lock = OS_UNFAIR_LOCK_INIT;
        device = MTLCreateSystemDefaultDevice();
        if (device) {
            queue = [device newCommandQueue];
            NSError *err = nil;
            id<MTLLibrary> lib = [device newLibraryWithSource:kFbShaderSource options:nil error:&err];
            if (lib) {
                MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
                pd.vertexFunction = [lib newFunctionWithName:@"fb_vs"];
                pd.fragmentFunction = [lib newFunctionWithName:@"fb_fs"];
                pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
                pipeline = [device newRenderPipelineStateWithDescriptor:pd error:&err];
                pd.fragmentFunction = [lib newFunctionWithName:@"fb_fs_nearest"];
                pipelineNearest = [device newRenderPipelineStateWithDescriptor:pd error:&err];
            }
        }
    }
    return self;
}

- (void)setTargetLayer:(CAMetalLayer *)newLayer {
    os_unfair_lock_lock(&lock);
    layer = newLayer;
    lastHash = 0;
    lastDrawableSize = CGSizeZero;
    if (layer && device) {
        dispatch_block_t cfg = ^{
            newLayer.device = self->device;
            newLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
            newLayer.framebufferOnly = YES;
        };
        if ([NSThread isMainThread]) cfg();
        else dispatch_async(dispatch_get_main_queue(), cfg);

        if (!tickQueue) tickQueue = dispatch_queue_create("me.ammaar.windowsios.fbmetal", DISPATCH_QUEUE_SERIAL);
#if TARGET_OS_IPHONE
        /* iPad addition: frames paced by the display (up to 120 Hz on ProMotion) instead of a 60 Hz timer. */
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->displayLink) return;
            self->displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
            self->displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 120, 120);
            [self->displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
        });
#else
        if (!timer) {
            timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, tickQueue);
            dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 60, 2 * NSEC_PER_MSEC);
            __weak HvFbMetalPresenter *weakSelf = self;
            dispatch_source_set_event_handler(timer, ^{
                [weakSelf tick];
            });
            dispatch_resume(timer);
        }
#endif
    } else if (!layer) {
#if TARGET_OS_IPHONE
        dispatch_async(dispatch_get_main_queue(), ^{
            [self->displayLink invalidate];
            self->displayLink = nil;
        });
#else
        if (timer) {
            dispatch_source_cancel(timer);
            timer = nil;
        }
#endif
    }
    os_unfair_lock_unlock(&lock);
}

#if TARGET_OS_IPHONE
- (void)displayLinkFired:(CADisplayLink *)link {
    (void)link;
    int expected = 0;
    if (!atomic_compare_exchange_strong(&tickPending, &expected, 1)) return; /* previous frame still drawing */
    dispatch_async(tickQueue, ^{
        [self tick];
        atomic_store(&self->tickPending, 0);
    });
}
#endif

/* iPad addition: a texture for the guest framebuffer. Where Metal accepts the guest memory as a
   buffer, the texture reads it directly (no per-frame copy of up to 22 MB); otherwise a copy is made. */
- (void)rebuildTextureFor:(const uint8_t *)px width:(uint32_t)w height:(uint32_t)h stride:(uint32_t)stride {
    texture = nil;
    fbBuffer = nil;
    zeroCopy = NO;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:w
                                                                                 height:h
                                                                              mipmapped:NO];
    td.usage = MTLTextureUsageShaderRead;
    if (!getenv("HV_FB_COPY")) {
        uintptr_t page = (uintptr_t)getpagesize();
        uintptr_t start = (uintptr_t)px & ~(page - 1);
        size_t offset = (size_t)((uintptr_t)px - start);
        size_t len = offset + (size_t)stride * (h - 1) + (size_t)w * 4;
        len = (len + page - 1) & ~(size_t)(page - 1);
        NSUInteger align = [device minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatBGRA8Unorm];
        if (align && stride % align == 0 && offset % align == 0) {
            fbBuffer = [device newBufferWithBytesNoCopy:(void *)start
                                                 length:len
                                                options:MTLResourceStorageModeShared
                                            deallocator:nil];
            if (fbBuffer) {
                td.storageMode = MTLStorageModeShared;
                texture = [fbBuffer newTextureWithDescriptor:td offset:offset bytesPerRow:stride];
                zeroCopy = texture != nil;
                if (!zeroCopy) fbBuffer = nil;
            }
        }
    }
    if (!texture) {
        MTLTextureDescriptor *plain = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                         width:w
                                                                                        height:h
                                                                                     mipmapped:NO];
        plain.usage = MTLTextureUsageShaderRead;
        texture = [device newTextureWithDescriptor:plain];
    }
    texSrc = px;
    texW = w;
    texH = h;
    texStride = stride;
    fprintf(stderr, "winvm: display %ux%u, %s\n", w, h, zeroCopy ? "zero-copy" : "copied each frame");
}

static uint64_t quick_frame_hash(const uint8_t *px, uint32_t w, uint32_t h, uint32_t stride) {
    uint64_t hash = ((uint64_t)w << 32) ^ h ^ stride;
    uint32_t step_y = h > 128 ? h / 128 : 1;
    for (uint32_t y = 0; y < h; y += step_y) {
        const uint64_t *row = (const uint64_t *)(px + (size_t)y * stride);
        uint32_t qwords = (w * 4) / 8;
        uint32_t step_x = qwords > 64 ? qwords / 64 : 1;
        for (uint32_t x = 0; x < qwords; x += step_x) {
            hash = (hash ^ row[x]) * 0x9e3779b97f4a7c15ull;
        }
    }
    return hash ? hash : 1;
}

- (void)tick {
    @autoreleasepool {
        const uint8_t *px = NULL;
        uint32_t w = 0, h = 0, stride = 0;
        if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) {
            /* No framebuffer (VM stopped or not started): let go of any view of guest memory. */
            os_unfair_lock_lock(&lock);
            if (fbBuffer) {
                texture = nil;
                fbBuffer = nil;
                texSrc = NULL;
                zeroCopy = NO;
            }
            os_unfair_lock_unlock(&lock);
            return;
        }

        os_unfair_lock_lock(&lock);
        CAMetalLayer *curLayer = layer;
        if (!curLayer || !device || !pipeline || !queue) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        CGSize dsize = curLayer.drawableSize;
        if (dsize.width < 4 || dsize.height < 4) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        BOOL configChanged = !texture || px != texSrc || w != texW || h != texH || stride != texStride;
        if (configChanged) [self rebuildTextureFor:px width:w height:h stride:stride];
        if (!texture) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        /* Present when the sampled hash changes. The hash only samples the screen, so small changes
           (a typed letter, a caret) could slip through; a regular refresh catches those too. */
        uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        uint64_t hval = quick_frame_hash(px, w, h, stride);
        BOOL sizeChanged = !CGSizeEqualToSize(dsize, lastDrawableSize);
        uint64_t refreshNs = zeroCopy ? 33000000ull : 100000000ull;
        if (!configChanged && !sizeChanged && hval == lastHash && now - lastPresentNs < refreshNs) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        if (!zeroCopy) {
            [texture replaceRegion:MTLRegionMake2D(0, 0, w, h)
                       mipmapLevel:0
                         withBytes:px
                       bytesPerRow:stride];
        }

        id<CAMetalDrawable> drawable = [curLayer nextDrawable];
        if (!drawable) {
            os_unfair_lock_unlock(&lock);
            return;
        }

        float dstAspect = (float)(dsize.width / dsize.height);
        float srcAspect = (float)w / (float)h;
        float scale[2] = {1.0f, 1.0f};
        if (dstAspect > srcAspect) {
            scale[0] = srcAspect / dstAspect;
        } else {
            scale[1] = dstAspect / srcAspect;
        }

        /* Whole-number scale factors (Sharp at 1x, Smooth at 2x) get nearest-neighbour sampling, so
           each Windows pixel stays crisp instead of being blurred across its neighbours. */
        double rx = dsize.width * scale[0] / w, ry = dsize.height * scale[1] / h, ri = round(rx);
        BOOL whole = ri >= 1.0 && fabs(rx - ri) < 0.004 && fabs(ry - ri) < 0.004;
        id<MTLRenderPipelineState> pso = (whole && pipelineNearest) ? pipelineNearest : pipeline;

        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [queue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:pso];
        [enc setVertexBytes:scale length:sizeof(scale) atIndex:0];
        [enc setFragmentTexture:texture atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
        [enc endEncoding];
        [cb presentDrawable:drawable];
        [cb commit];

        lastHash = hval;
        lastDrawableSize = dsize;
        lastPresentNs = now;
        atomic_fetch_add_explicit(&framesPresented, 1, memory_order_relaxed);
        os_unfair_lock_unlock(&lock);
    }
}

@end

static HvFbMetalPresenter *ensure_presenter(HvFbDisplay *fb) {
    if (!fb) return nil;
    pthread_mutex_lock(&fb->mu);
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    if (!p) {
        p = [[HvFbMetalPresenter alloc] initWithDisplay:fb];
        fb->metal = (__bridge_retained void *)p;
    }
    pthread_mutex_unlock(&fb->mu);
    return p;
}

void hv_fb_metal_set_layer(HvFbDisplay *fb, void *ca_metal_layer) {
    HvFbMetalPresenter *p = ensure_presenter(fb);
    if (!p) return;
    [p setTargetLayer:(__bridge CAMetalLayer *)ca_metal_layer];
}

uint64_t hv_fb_metal_frames(HvFbDisplay *fb) {
    if (!fb || !fb->metal) return 0;
    HvFbMetalPresenter *p = (__bridge HvFbMetalPresenter *)fb->metal;
    return atomic_load_explicit(&p->framesPresented, memory_order_relaxed);
}

int hv_fb_save_png(HvFbDisplay *fb, const char *path) {
    if (!fb || !path) return -1;
    const uint8_t *px = NULL;
    uint32_t w = 0, h = 0, stride = 0;
    if (hv_fb_display_get_frame(fb, &px, &w, &h, &stride) != 0) return -1;

    @autoreleasepool {
        size_t total = (size_t)stride * h;
        uint8_t *copy = malloc(total);
        if (!copy) return -1;
        memcpy(copy, px, total);
        /* Ensure alpha byte is 0xff (XRGB8888 leaves X=0x00) */
        for (uint32_t y = 0; y < h; y++) {
            uint8_t *row = copy + (size_t)y * stride;
            for (uint32_t x = 0; x < w; x++) row[x * 4 + 3] = 0xff;
        }

        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGDataProviderRef prov = CGDataProviderCreateWithData(NULL, copy, total, NULL);
        CGBitmapInfo bmi = kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst;
        CGImageRef img = CGImageCreate(w, h, 8, 32, stride, cs, bmi, prov, NULL, false, kCGRenderingIntentDefault);
        int rc = -1;
        if (img) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
            CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
            if (dst) {
                CGImageDestinationAddImage(dst, img, NULL);
                if (CGImageDestinationFinalize(dst)) rc = 0;
                CFRelease(dst);
            }
            CGImageRelease(img);
        }
        CGDataProviderRelease(prov);
        CGColorSpaceRelease(cs);
        free(copy);
        return rc;
    }
}
