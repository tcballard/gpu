#include <sys/mman.h>
#include <fcntl.h>
#include <unistd.h>
// Ground-truth capture of an A10 compute dispatch under iOS.
//
// Runs two one-thread compute kernels that each store a marker, keeps the
// command buffers alive, then scans this process's own readable memory (the
// Metal driver maps its GPU-visible heaps here) for known needles: the output
// buffers' GPU addresses and the offline-compiled G9P USC code. Every region
// with a hit and every GPU-shared region are saved per kernel, before commit and
// after completion, to the output directory (default /var/tmp/gpu-capture). Runs as root from the palera1n overlay.

#import <Metal/Metal.h>
#include <mach/mach.h>
#include <mach/mach_time.h>

static NSString *const kSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void store_marker(device uint *out [[buffer(0)]]) { out[0] = 0x1357u; }\n"
     "kernel void store_marker2(device uint *out [[buffer(0)]]) { out[1] = 0x2468u; }\n"
     "kernel void empty_kernel() {}\n";

// Grid mode (--grid): light mode with a kernel that reads its IDs, dispatched
// twice with different sizes so that the size fields can be located by diff.
static NSString *const kGridSource =
    @"#include <metal_stdlib>\n"
     "using namespace metal;\n"
     "kernel void grid(device uint4 *o [[buffer(0)]], uint2 t [[thread_position_in_grid]],\n"
     "                 uint2 l [[thread_position_in_threadgroup]],\n"
     "                 uint2 g [[threadgroup_position_in_grid]],\n"
     "                 uint2 n [[threads_per_threadgroup]], uint2 s [[threads_per_grid]]) {\n"
     "    uint i = t.y * s.x + t.x;\n"
     "    o[2 * i] = uint4(t.x, t.y, l.x, l.y);\n"
     "    o[2 * i + 1] = uint4(g.x, g.y, n.x | n.y << 16, s.x | s.y << 16);\n"
     "}\n";
static BOOL gGrid;

static NSMutableString *gLog;
// Light mode: first kernel only, one pre-commit snapshot of every shared
// region up to 2 MiB, no needle scan (the full scan once panicked the device).
static BOOL gLight;

static void logf_(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void logf_(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    printf("%s\n", s.UTF8String);
    fflush(stdout);
    [gLog appendFormat:@"%@\n", s];
}

#include "iohook.m"

struct needle {
    const char *name;
    uint8_t bytes[16];
    size_t len;
};

// Dumps every GPU-shared (IOAccelerator, tag 100) region, plus other regions
// up to 1 MiB that contain a needle, into dir/phase/.
// Regions saved by the last scan, for a fast re-read right after a submit.
static vm_address_t gScanStart[256];
static vm_size_t gScanSize[256];
static int gScanCount;

// Post-submit snapshot that survives the process dying right after the submit:
// a MAP_SHARED file prepared beforehand, filled by plain memcpy (no syscalls)
// once the submit returns. Layout: the last scan's regions back to back, in
// order; post.idx lists "start size" per region.
static uint8_t *gPostMap;

static void prepare_post(NSString *dir) {
    vm_size_t total = 0;
    NSMutableString *idx = [NSMutableString string];
    for (int i = 0; i < gScanCount; i++) {
        [idx appendFormat:@"%lx %lx\n", (unsigned long)gScanStart[i], (unsigned long)gScanSize[i]];
        total += gScanSize[i];
    }
    [idx writeToFile:[dir stringByAppendingPathComponent:@"post.idx"] atomically:NO
            encoding:NSUTF8StringEncoding error:nil];
    int fd = open([dir stringByAppendingPathComponent:@"post.bin"].UTF8String, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, total) != 0)
        return;
    void *map = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map != MAP_FAILED) {
        memset(map, 0, total);  // fault the pages in now
        gPostMap = map;
    }
}

// The same regions again, re-copied for a while after the submit into
// late.bin: the kernel or firmware may patch the command records after the
// trap returns. Only regions up to 64 KiB (the command records, not the big
// buffers), so each pass is fast.
static uint8_t *gLateMap;

static void prepare_late(NSString *dir) {
    vm_size_t total = 0;
    for (int i = 0; i < gScanCount; i++)
        total += gScanSize[i];
    int fd = open([dir stringByAppendingPathComponent:@"late.bin"].UTF8String, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0 || ftruncate(fd, total) != 0)
        return;
    void *map = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (map != MAP_FAILED) {
        memset(map, 0, total);
        gLateMap = map;
    }
}

static void copy_late(double seconds) {
    if (!gLateMap)
        return;
    mach_timebase_info_data_t tb;
    mach_timebase_info(&tb);
    uint64_t end = mach_absolute_time() + (uint64_t)(seconds * 1e9 * tb.denom / tb.numer);
    do {
        vm_size_t at = 0;
        for (int i = 0; i < gScanCount; i++) {
            if (gScanSize[i] <= 0x10000)
                memcpy(gLateMap + at, (const void *)gScanStart[i], gScanSize[i]);
            at += gScanSize[i];
        }
    } while (mach_absolute_time() < end);
}

static void copy_post(void) {
    if (!gPostMap)
        return;
    vm_size_t at = 0;
    for (int i = 0; i < gScanCount; i++) {
        memcpy(gPostMap + at, (const void *)gScanStart[i], gScanSize[i]);
        at += gScanSize[i];
    }
}

static int scan_and_dump(NSString *dir, NSString *phase, needle_t *needles, int nneedles) {
    mach_port_t task = mach_task_self();
    vm_address_t addr = 0, last = (vm_address_t)-1;
    gScanCount = 0;
    dir = [dir stringByAppendingPathComponent:phase];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    uint64_t dumped = 0;
    int regions = 0;
    for (;;) {
        vm_size_t size = 0;
        natural_t depth = 1;
        struct vm_region_submap_info_64 info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(task, &addr, &size, &depth,
                                 (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS)
            break;
        if (info.is_submap) {
            depth++;
            continue;
        }
        vm_address_t start = addr;
        addr += size;
        if (start == last || !(info.protection & VM_PROT_READ))
            continue;
        BOOL gpu = info.user_tag == 100;
        if (size > (64u << 20)) {
            // Grid mode: large GPU regions (internal heaps reserve big ranges)
            // are read in 1 MiB chunks; only chunks with data are kept.
            if (gGrid && gpu) {
                last = start;
                NSMutableData *chunk = [NSMutableData dataWithLength:1u << 20];
                for (vm_size_t off = 0; off < size && off < (512u << 20); off += 1u << 20) {
                    vm_size_t got = 0;
                    if (vm_read_overwrite(task, start + off, 1u << 20,
                                          (vm_address_t)chunk.mutableBytes, &got) != KERN_SUCCESS)
                        continue;
                    const uint64_t *q = chunk.bytes;
                    BOOL any = NO;
                    for (vm_size_t k = 0; k < got / 8 && !any; k++)
                        any = q[k] != 0;
                    if (!any)
                        continue;
                    [chunk writeToFile:[dir stringByAppendingPathComponent:
                                        [NSString stringWithFormat:@"r_%011lx.bin",
                                         (unsigned long)(start + off)]] atomically:NO];
                    dumped += got;
                    regions++;
                }
                logf_(@"%@ large region 0x%011lx size 0x%lx tag %u (chunked)", phase,
                      (unsigned long)start, (unsigned long)size, info.user_tag);
            }
            continue;
        }
        last = start;
        // Light mode reads only GPU-shared memory and never holds more than one
        // region at a time: a broad scan once drove the iPad into jetsam.
        if (gLight && !gpu)
            continue;
        @autoreleasepool {
        NSMutableData *buf = [NSMutableData dataWithLength:size];
        vm_size_t got = 0;
        if (vm_read_overwrite(task, start, size, (vm_address_t)buf.mutableBytes, &got) != KERN_SUCCESS)
            continue;
        const uint8_t *p = buf.bytes;
        NSMutableString *hits = [NSMutableString string];
        for (int n = 0; n < (gLight ? 0 : nneedles); n++) {
            for (vm_size_t off = 0; off + needles[n].len <= got; off += 4) {
                if (memcmp(p + off, needles[n].bytes, needles[n].len) == 0)
                    [hits appendFormat:@" %s@+0x%lx", needles[n].name, (unsigned long)off];
            }
        }
        if (!gLight && !gpu && (hits.length == 0 || got > (1u << 20)))
            continue;
        NSString *file = [dir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"r_%011lx.bin", (unsigned long)start]];
        [buf writeToFile:file atomically:NO];
        if (gScanCount < 256) {
            gScanStart[gScanCount] = start;
            gScanSize[gScanCount++] = got;
        }
        dumped += got;
        regions++;
        logf_(@"%@ region 0x%011lx size 0x%lx prot %d tag %u share %d%@",
              phase, (unsigned long)start, (unsigned long)size, info.protection,
              info.user_tag, info.share_mode, hits);
        }
    }
    logf_(@"%@: dumped %d regions, %llu bytes", phase, regions, dumped);
    return regions;
}

static void capture(NSString *dir) {
    gLog = [NSMutableString string];
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];

    install_iohooks();
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    logf_(@"device %@", dev.name);
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:gGrid ? kGridSource : kSource options:nil
                                             error:&err];
    if (!lib) {
        logf_(@"compile failed: %@", err);
        return;
    }
    install_iohooks(); // the AGX driver bundle is loaded now
    id<MTLCommandQueue> q = [dev newCommandQueue];
    NSArray *names = gGrid ? @[ @"grid" ] : @[ @"store_marker", @"store_marker2", @"empty_kernel" ];
    NSMutableArray *keep = [NSMutableArray array];
    needle_t needles[16];
    int nn = 0;
    // Offline applegpu_g9p store_marker prefix (metal-tt); may differ at runtime.
    needles[nn++] = (needle_t){ "usc_store_offline",
        { 0x81, 0x11, 0x89, 0x81, 0x00, 0x41, 0xb7, 0xac }, 8 };
    needles[nn++] = (needle_t){ "usc_empty_offline",
        { 0x00, 0x01, 0x40, 0x01, 0x00, 0x00, 0x00, 0xc0 }, 8 };
    for (NSUInteger i = 0; i < names.count; i++) {
        id<MTLFunction> fn = [lib newFunctionWithName:names[i]];
        id<MTLComputePipelineState> ps = [dev newComputePipelineStateWithFunction:fn error:&err];
        if (!ps) {
            logf_(@"pipeline %@ failed: %@", names[i], err);
            return;
        }
        id<MTLBuffer> out = [dev newBufferWithLength:0x4000 options:MTLResourceStorageModeShared];
        uint32_t *o = out.contents;
        for (int k = 0; k < 0x1000; k++)
            o[k] = 0xabadbeef;
        uint64_t gva = out.gpuAddress;
        needle_t n64 = { NULL, { 0 }, 8 };
        memcpy(n64.bytes, &gva, 8);
        n64.name = strdup([NSString stringWithFormat:@"out%lu_va64", (unsigned long)i].UTF8String);
        needles[nn++] = n64;
        needle_t n32 = { NULL, { 0 }, 4 };
        memcpy(n32.bytes, &gva, 4);
        n32.name = strdup([NSString stringWithFormat:@"out%lu_va32", (unsigned long)i].UTF8String);
        needles[nn++] = n32;
        id<MTLCommandBuffer> cb = [q commandBuffer];
        id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
        [enc setComputePipelineState:ps];
        [enc setBuffer:out offset:0 atIndex:0];
        if (gGrid)
            [enc dispatchThreadgroups:MTLSizeMake(3, 1, 1) threadsPerThreadgroup:MTLSizeMake(8, 1, 1)];
        else
            [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        // Light mode: a second dispatch of the same kernel into another buffer, in
        // the same submit, so the two CDM records differ only in the binding.
        id<MTLBuffer> out2 = nil;
        if (gLight) {
            out2 = [dev newBufferWithLength:0x4000 options:MTLResourceStorageModeShared];
            memset(out2.contents, 0xee, 0x4000);
            [enc setBuffer:out2 offset:0 atIndex:0];
            if (gGrid)
                [enc dispatchThreadgroups:MTLSizeMake(5, 2, 1) threadsPerThreadgroup:MTLSizeMake(4, 2, 1)];
            else
                [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
            logf_(@"second dispatch: out2 gpu 0x%llx cpu %p", out2.gpuAddress, out2.contents);
        }
        [enc endEncoding];
        if (gLight) {
            gHookDir = [dir stringByAppendingPathComponent:@"iocalls"];
            [[NSFileManager defaultManager] createDirectoryAtPath:gHookDir withIntermediateDirectories:YES
                                                       attributes:nil error:nil];
        }
        // The encoded command stream is recycled after completion: snapshot
        // GPU memory before commit as well as after.
        if (!gLight)
            scan_and_dump(dir, [NSString stringWithFormat:@"k%lu_pre", (unsigned long)i], needles, nn);
        [cb commit];
        [cb waitUntilCompleted];
        gHookDir = nil;
        logf_(@"iohooks: %d IOConnectCall* and %d IOConnectTrap* calls so far", gTotalCalls, gTotalTraps);
        if (!gLight)
            scan_and_dump(dir, [NSString stringWithFormat:@"k%lu_post", (unsigned long)i], needles, nn);
        logf_(@"%@: status %ld out[0..1] = 0x%08x 0x%08x, out gpu 0x%llx cpu %p, "
              @"pipeline resid 0x%llx, max threads %lu",
              names[i], (long)cb.status, o[0], o[1], gva, out.contents,
              ps.gpuResourceID._impl, (unsigned long)ps.maxTotalThreadsPerThreadgroup);
        if (gGrid) {
            // Results, to check the dispatch and to decode the IDs against
            [[NSData dataWithBytes:out.contents length:0x4000]
                writeToFile:[dir stringByAppendingPathComponent:@"out1.bin"] atomically:YES];
            [[NSData dataWithBytes:out2.contents length:0x4000]
                writeToFile:[dir stringByAppendingPathComponent:@"out2.bin"] atomically:YES];
        }
        [keep addObjectsFromArray:@[ ps, out, cb ]];
        if (gLight)
            break;
    }
    [gLog writeToFile:[dir stringByAppendingPathComponent:@"index.txt"] atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    logf_(@"capture done: %@", dir);
}

// Render mode: one triangle in a constant color into a 64x64 BGRA8 texture.
// The submit trap snapshots GPU memory (TA/3D command data) and exits; as in
// light mode, only GPU-shared regions are read.
typedef struct {
    const char *name;
    int width, height, vertices, draws;
    double clear[4];
    BOOL load;              // MTLLoadActionLoad instead of Clear
    const char *color;      // fragment shader constant
    int kind;               // 0 constant colour, 1 colour varying, 2 colour + uv, 3 texture
    int flags;              // RV_* below
    MTLPixelFormat format;  // target format, 0: BGRA8Unorm
} RenderVariant;

enum {
    RV_LINEAR_TARGET = 1,   // target texture backed by a buffer (linear layout)
    RV_BLEND = 2,           // source-over alpha blending
    RV_CULL = 4,            // cull front faces (the triangle is back-facing: still drawn)
    RV_DEPTH = 8,           // Depth32Float attachment, compare less, write
    RV_TEX_LINEAR = 16,     // texture variant: linear filter, repeat
    RV_TEX_LINEAR_LAYOUT = 32, // texture variant: buffer-backed (linear) source
    RV_SCISSOR = 64,        // scissor rect (8, 8, 40, 40)
    RV_INDEXED = 128,       // drawIndexedPrimitives, uint16 indices 0, 1, 2
    RV_INSTANCED = 256,     // 2 instances; kind 0 shifts instance 1 by instance_id
    RV_ODD_VIEWPORT = 512,  // viewport (3, 5, 32, 32): quads cut at its edges
    RV_STENCIL = 1024,      // dsreload: Depth32Float_Stencil8, stencil kept too
    RV_D16 = 2048,          // dsreload: Depth16Unorm
    RV_S8 = 4096,           // dsreload: Stencil8 only
    RV_MSAA = 8192,         // 4 samples, resolved into the target
    // bits 16-18: kind 18's target count
};

// Each variant changes one parameter of "base", so diffs isolate its fields.
// "base2" repeats base to show what differs between identical runs.
static const RenderVariant kVariants[] = {
    {"base", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"base2", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"verts6", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"draws2", 64, 64, 3, 2, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"size128x32", 128, 32, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"clear", 64, 64, 3, 1, {1, 0.5, 0.25, 0.125}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"load", 64, 64, 3, 1, {0, 0, 0, 1}, YES, "0.25, 0.5, 0.75, 1.0"},
    {"color", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "1.0, 0.0, 0.0, 1.0"},
    // graphics ISA and state: varyings and textures (one change each from base)
    {"vary", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 1},
    {"vary2", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 2},
    {"tex", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 3},
    {"vary3", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 4},
    {"flat", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 5},
    {"noperspective", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 6},
    // render targets, state and textures for the Mesa path (one change each)
    {"nodraw", 64, 64, 3, 0, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"linear", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_LINEAR_TARGET},
    {"linear100", 100, 60, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_LINEAR_TARGET},
    {"npot", 100, 60, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"screen", 1536, 2048, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0"},
    {"rgba8", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, 0, MTLPixelFormatRGBA8Unorm},
    {"rgba16f", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, 0, MTLPixelFormatRGBA16Float},
    {"blend", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 0.5", 0, RV_BLEND},
    {"cull", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_CULL},
    {"depth", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_DEPTH},
    {"scissor", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_SCISSOR},
    {"texfilter", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 3, RV_TEX_LINEAR},
    {"texlinear", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 3, RV_TEX_LINEAR_LAYOUT},
    {"indexed", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_INDEXED},
    {"instanced", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_INSTANCED},
    {"fragcoord", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 7},
    {"discard", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 8},
    {"fubo", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 9},
    // GLES 2 open problems: run with GC_REPEAT=1, which saves pixels.raw of a finished render.
    // A mipmapped texture whose levels are solid colours: at LOD 0 only level 0 shows.
    {"mip", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 10, RV_ODD_VIEWPORT},
    {"miptri", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 10},
    {"mipd", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 10, RV_ODD_VIEWPORT | RV_DEPTH},
    // Depth (and stencil) stored by one render and loaded by the next
    {"dsreload", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 11},
    {"dsreload8", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 11, RV_STENCIL},
    {"dsreload16", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 11, RV_D16},
    {"dsreloads8", 64, 64, 6, 1, {0, 0, 0, 1}, NO, "", 11, RV_S8 | RV_STENCIL},
    // A cube map sampled in the vertex shader
    {"vscube", 64, 64, 30, 1, {0, 0, 0, 1}, NO, "", 12},
    // Vertex shaders that store to memory: drawn, without rasterization, and the
    // same shader without the store, for the diff (transform feedback)
    {"store", 64, 64, 30, 1, {0, 0, 0, 1}, NO, "", 13},
    {"storenr", 64, 64, 30, 1, {0, 0, 0, 1}, NO, "", 14},
    {"storeref", 64, 64, 30, 1, {0, 0, 0, 1}, NO, "", 15},
    // A compare sample of Depth32Float_Stencil8, and of Depth32Float for the diff
    {"shadowds", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 16},
    {"shadowd32", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 17},
    // Several targets: the output words past the first ones
    {"mrt1", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 18, 1 << 16, MTLPixelFormatRGBA8Unorm},
    {"mrt2", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 18, 2 << 16, MTLPixelFormatRGBA8Unorm},
    {"mrt3", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 18, 3 << 16, MTLPixelFormatRGBA8Unorm},
    {"mrt4", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 18, 4 << 16, MTLPixelFormatRGBA8Unorm},
    // Targets of 32-bit channels
    {"rgba32f", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, 0, MTLPixelFormatRGBA32Float},
    {"rg32f", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, 0, MTLPixelFormatRG32Float},
    // A fragment shader writing depth, and multisampling
    {"fragdepth", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "", 19, RV_DEPTH},
    {"msaa4", 64, 64, 3, 1, {0, 0, 0, 1}, NO, "0.25, 0.5, 0.75, 1.0", 0, RV_MSAA},
};

static NSString *render_source(const RenderVariant *v) {
    if (v->kind >= 13 && v->kind <= 15) {
        const BOOL store = v->kind != 15;
        return [NSString stringWithFormat:
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "%s tri_vs(uint vid [[vertex_id]], device float4 *o [[buffer(1)]]) {\n"
             "    float x = float(vid %% 3) * 0.5 - 0.5, y = float(vid) * 0.03 - 0.5;\n"
             "    %s\n"
             "    %s\n"
             "}\n"
             "fragment float4 tri_fs() { return float4(0.25, 0.5, 0.75, 1.0); }\n",
            v->kind == 14 ? "vertex void" : "vertex float4",
            store ? "o[vid] = float4(float(vid), x, y, 1.0);" : "",
            v->kind == 14 ? "" : "return float4(x, y, 0.0, 1.0);"];
    }
    if (v->kind == 18) {
        const int n = (v->flags >> 16) & 7;
        NSMutableString *fields = [NSMutableString string], *sets = [NSMutableString string];
        for (int i = 0; i < n; i++) {
            [fields appendFormat:@"float4 c%d [[color(%d)]]; ", i, i];
            [sets appendFormat:@"o.c%d = float4(0.1 * %d, 0.25, 0.5, 1.0); ", i, i + 1];
        }
        return [NSString stringWithFormat:
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "struct O { %@ };\n"
             "vertex float4 tri_vs(uint vid [[vertex_id]]) {\n"
             "    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };\n"
             "    return float4(p[vid], 0.0, 1.0);\n"
             "}\n"
             "fragment O tri_fs() { O o; %@ return o; }\n", fields, sets];
    }
    if (v->kind == 19)
        return @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct O { float4 c [[color(0)]]; float d [[depth(any)]]; };\n"
                "vertex float4 tri_vs(uint vid [[vertex_id]]) {\n"
                "    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };\n"
                "    return float4(p[vid], 0.0, 1.0);\n"
                "}\n"
                "fragment O tri_fs(float4 f [[position]]) {\n"
                "    O o; o.c = float4(0.25, 0.5, 0.75, 1.0); o.d = f.x / 64.0; return o;\n"
                "}\n";
    if (v->kind == 16 || v->kind == 17)
        return @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "vertex float4 tri_vs(uint vid [[vertex_id]]) {\n"
                "    float2 p[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };\n"
                "    return float4(p[vid], 0.0, 1.0);\n"
                "}\n"
                "fragment float4 tri_fs(depth2d<float> d [[texture(0)]], sampler s [[sampler(0)]]) {\n"
                "    return float4(d.sample_compare(s, float2(0.5), 0.5));\n"
                "}\n";
    if (v->kind == 10)
        return @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct V { float4 pos [[position]]; float2 uv; };\n"
                "vertex V tri_vs(uint vid [[vertex_id]]) {\n"
                "    float2 p[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),\n"
                "                    float2(-1, 1), float2(1, -1), float2(1, 1) };\n"
                "    V o; o.pos = float4(p[vid], 0.0, 1.0); o.uv = p[vid] * 0.5 + 0.5; return o;\n"
                "}\n"
                "fragment float4 tri_fs(V v [[stage_in]], texture2d<float> t [[texture(0)]],\n"
                "                       sampler s [[sampler(0)]]) { return t.sample(s, v.uv); }\n";
    if (v->kind == 11)
        return @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "vertex float4 tri_vs(uint vid [[vertex_id]], constant float4 &c [[buffer(0)]]) {\n"
                "    float2 p[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),\n"
                "                    float2(-1, 1), float2(1, -1), float2(1, 1) };\n"
                "    return float4(p[vid].x * c.x + c.y, p[vid].y, c.z, 1.0);\n"
                "}\n"
                "fragment float4 tri_fs(constant float4 &c [[buffer(0)]]) { return c; }\n";
    if (v->kind == 12)
        return @"#include <metal_stdlib>\n"
                "using namespace metal;\n"
                "struct V { float4 pos [[position]]; float4 c; };\n"
                "vertex V tri_vs(uint vid [[vertex_id]], texturecube<float> t [[texture(0)]],\n"
                "                sampler s [[sampler(0)]]) {\n"
                "    float2 q[6] = { float2(0, 0), float2(1, 0), float2(0, 1),\n"
                "                    float2(0, 1), float2(1, 0), float2(1, 1) };\n"
                "    float3 d[5] = { float3(1, 0, 0), float3(-1, 0, 0), float3(0, 1, 0),\n"
                "                    float3(0, -1, 0), float3(0, 0, 1) };\n"
                "    uint cell = vid / 6;\n"
                "    float2 p = q[vid % 6];\n"
                "    V o; o.pos = float4((p.x + float(cell)) * 0.4 - 1.0, p.y * 2.0 - 1.0, 0.0, 1.0);\n"
                "    o.c = t.sample(s, d[cell], level(0.0)); return o;\n"
                "}\n"
                "fragment float4 tri_fs(V v [[stage_in]]) { return v.c; }\n";
    if (v->kind == 0)
        return [NSString stringWithFormat:
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "vertex float4 tri_vs(uint vid [[vertex_id]], uint iid [[instance_id]]) {\n"
             "    float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };\n"
             "    return float4(p[vid %% 3] * (vid < 3 ? 1.0 : 0.5) + float2(%@, 0.0), 0.0, 1.0);\n"
             "}\n"
             "fragment float4 tri_fs() { return float4(%s); }\n",
             (v->flags & RV_INSTANCED) ? @"float(iid) * 0.25" : @"0.0", v->color];
    // Fragment position, discard, a fragment constant buffer
    if (v->kind >= 7)
        return [NSString stringWithFormat:
            @"#include <metal_stdlib>\n"
             "using namespace metal;\n"
             "struct C { float4 c; };\n"
             "vertex float4 tri_vs(uint vid [[vertex_id]]) {\n"
             "    float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };\n"
             "    return float4(p[vid %% 3], 0.0, 1.0);\n"
             "}\n"
             "fragment float4 tri_fs(float4 pos [[position]], constant C &c [[buffer(0)]]) {\n"
             "    %@\n"
             "}\n",
             v->kind == 7 ? @"return float4(pos.x / 64.0, pos.y / 64.0, 0.0, 1.0);" :
             v->kind == 8 ? @"if (pos.x < 32.0) discard_fragment(); return float4(0.25, 0.5, 0.75, 1.0);" :
                            @"return c.c;"];
    // Varyings: a colour per vertex (red, green, blue) and a uv; the texture
    // variant samples a 4x4 texture with the uv. vary3 uses three varyings
    // of different sizes (all components), flat and noperspective change
    // the colour's interpolation.
    NSString *col = v->kind == 5 ? @"float4 col [[flat]];" :
                    v->kind == 6 ? @"float4 col [[center_no_perspective]];" : @"float4 col;";
    NSString *frag =
        v->kind == 1 || v->kind == 5 || v->kind == 6 ? @"return v.col;" :
        v->kind == 2 ? @"return float4(v.col.rg, v.uv);" :
        v->kind == 3 ? @"return t.sample(s, v.uv);" :
                       @"return v.col * v.uv.x + float4(v.k, v.uv.y, 0.0, 0.0);";
    return [NSString stringWithFormat:
        @"#include <metal_stdlib>\n"
         "using namespace metal;\n"
         "struct V { float4 pos [[position]]; %@ float2 uv; float k; };\n"
         "vertex V tri_vs(uint vid [[vertex_id]]) {\n"
         "    float2 p[3] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.0, 0.5) };\n"
         "    float4 c[3] = { float4(1, 0, 0, 1), float4(0, 1, 0, 1), float4(0, 0, 1, 1) };\n"
         "    V o; o.pos = float4(p[vid %% 3], 0.0, 1.0); o.col = c[vid %% 3];\n"
         "    o.uv = p[vid %% 3] + 0.5; o.k = float(vid) * 0.25; return o;\n"
         "}\n"
         "fragment float4 tri_fs(V v [[stage_in]], texture2d<float> t [[texture(0)]],\n"
         "                       sampler s [[sampler(0)]]) {\n"
         "    %@\n"
         "}\n", col, frag];
}

static void capture_render(NSString *dir, const RenderVariant *v) {
    gLog = [NSMutableString string];
    gLight = YES;
    gExitAfterTrap = NO;  // a render pass may submit TA and 3D separately
    [[NSFileManager defaultManager] removeItemAtPath:dir error:nil];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    // Log every IOKit call from device creation on: resource creation replies
    // carry each buffer's CPU and GPU address (needed to replay the submit).
    // With GC_REPEAT the hooks go in only before the captured render: once
    // IOKit is patched, a render's completion faults (as after the trap).
    const int repeat = getenv("GC_REPEAT") ? atoi(getenv("GC_REPEAT")) : 0;
    NSString *hookDir = [dir stringByAppendingPathComponent:@"iocalls"];
    [[NSFileManager defaultManager] createDirectoryAtPath:hookDir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    if (!repeat) {
        install_iohooks();
        gHookDir = hookDir;
    }
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:render_source(v) options:nil error:&err];
    if (!lib) {
        logf_(@"compile failed: %@", err);
        return;
    }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"tri_vs"];
    pd.fragmentFunction = [lib newFunctionWithName:@"tri_fs"];
    MTLPixelFormat format = v->format ? v->format : MTLPixelFormatBGRA8Unorm;
    pd.colorAttachments[0].pixelFormat = format;
    for (int i = 1; i < ((v->flags >> 16) & 7); i++)
        pd.colorAttachments[i].pixelFormat = format;
    if (v->flags & RV_MSAA)
        pd.rasterSampleCount = 4;
    if (v->kind == 14) {
        pd.fragmentFunction = nil;
        pd.rasterizationEnabled = NO;
    }
    if (v->flags & RV_BLEND) {
        pd.colorAttachments[0].blendingEnabled = YES;
        pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pd.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        pd.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    }
    if (v->flags & RV_DEPTH)
        pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    if (v->kind == 11) {
        pd.depthAttachmentPixelFormat = (v->flags & RV_S8) ? MTLPixelFormatInvalid :
                                        (v->flags & RV_D16) ? MTLPixelFormatDepth16Unorm :
                                        (v->flags & RV_STENCIL) ? MTLPixelFormatDepth32Float_Stencil8
                                                                : MTLPixelFormatDepth32Float;
        if (v->flags & RV_STENCIL)
            pd.stencilAttachmentPixelFormat = (v->flags & RV_S8) ? MTLPixelFormatStencil8
                                                                 : MTLPixelFormatDepth32Float_Stencil8;
    }
    id<MTLRenderPipelineState> ps = [dev newRenderPipelineStateWithDescriptor:pd error:&err];
    if (!ps) {
        logf_(@"pipeline failed: %@", err);
        return;
    }
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format
                                                                                 width:v->width height:v->height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex;
    if (v->flags & RV_LINEAR_TARGET) {
        // linear: a texture over a buffer, rows 256-byte aligned
        NSUInteger row = ((NSUInteger)v->width * 4 + 255) & ~(NSUInteger)255;
        id<MTLBuffer> back = [dev newBufferWithLength:row * v->height
                                              options:MTLResourceStorageModeShared];
        tex = [back newTextureWithDescriptor:td offset:0 bytesPerRow:row];
        logf_(@"linear target: buffer gpu 0x%llx, %lu bytes per row", back.gpuAddress,
              (unsigned long)row);
    } else {
        tex = [dev newTextureWithDescriptor:td];
    }
    logf_(@"variant %s: device %@, target texture gpu resource 0x%llx", v->name, dev.name,
          tex.gpuResourceID._impl);
    id<MTLCommandQueue> q = [dev newCommandQueue];
    // GC_REPEAT renders before the captured one: what iPadOS changes from one
    // render to the next (the A10 geometry stall, 2026-11-02)
    id<MTLCommandBuffer> cb = nil;
    for (int r = 0; r <= repeat; r++) {
        if (r == repeat && repeat) {
            install_iohooks();
            gHookDir = hookDir;
        }
        const unsigned traps = gTotalTraps;
        const double t0 = CFAbsoluteTimeGetCurrent();
        cb = [q commandBuffer];
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = tex;
        rp.colorAttachments[0].loadAction = v->load ? MTLLoadActionLoad : MTLLoadActionClear;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(v->clear[0], v->clear[1], v->clear[2],
                                                              v->clear[3]);
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        for (int i = 1; i < ((v->flags >> 16) & 7); i++) {
            rp.colorAttachments[i].texture = [dev newTextureWithDescriptor:td];
            rp.colorAttachments[i].loadAction = MTLLoadActionClear;
            rp.colorAttachments[i].storeAction = MTLStoreActionStore;
        }
        if (v->flags & RV_MSAA) {
            MTLTextureDescriptor *ms = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:format width:v->width height:v->height mipmapped:NO];
            ms.textureType = MTLTextureType2DMultisample;
            ms.sampleCount = 4;
            ms.usage = MTLTextureUsageRenderTarget;
            ms.storageMode = MTLStorageModePrivate;
            rp.colorAttachments[0].texture = [dev newTextureWithDescriptor:ms];
            rp.colorAttachments[0].resolveTexture = tex;
            rp.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        }
        if (v->flags & RV_DEPTH) {
            MTLTextureDescriptor *dd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:v->width
                                             height:v->height mipmapped:NO];
            dd.usage = MTLTextureUsageRenderTarget;
            dd.storageMode = MTLStorageModePrivate;
            rp.depthAttachment.texture = [dev newTextureWithDescriptor:dd];
            rp.depthAttachment.loadAction = MTLLoadActionClear;
            rp.depthAttachment.storeAction = MTLStoreActionStore;
            rp.depthAttachment.clearDepth = 1.0;
        }
        if (v->kind == 11) {
            // First render: left half at depth 0.25, stencil 7. Second render loads both and
            // draws the whole target at depth 0.5, compare less: only the right half draws if
            // the depth came back. With stencil, the second draw also needs stencil == 7, and
            // so draws only the left half if the depth is ignored.
            const MTLPixelFormat dsf = (v->flags & RV_S8) ? MTLPixelFormatStencil8 :
                                       (v->flags & RV_D16) ? MTLPixelFormatDepth16Unorm :
                                       (v->flags & RV_STENCIL) ? MTLPixelFormatDepth32Float_Stencil8
                                                               : MTLPixelFormatDepth32Float;
            MTLTextureDescriptor *dd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:dsf width:v->width height:v->height mipmapped:NO];
            dd.usage = MTLTextureUsageRenderTarget;
            dd.storageMode = MTLStorageModePrivate;
            id<MTLTexture> ds = [dev newTextureWithDescriptor:dd];
            if (!(v->flags & RV_S8)) {
                rp.depthAttachment.texture = ds;
                rp.depthAttachment.loadAction = MTLLoadActionClear;
                rp.depthAttachment.storeAction = MTLStoreActionStore;
                rp.depthAttachment.clearDepth = 1.0;
            }
            if (v->flags & RV_STENCIL) {
                rp.stencilAttachment.texture = ds;
                rp.stencilAttachment.loadAction = MTLLoadActionClear;
                rp.stencilAttachment.storeAction = MTLStoreActionStore;
                rp.stencilAttachment.clearStencil = 0;
            }
            id<MTLRenderCommandEncoder> first = [cb renderCommandEncoderWithDescriptor:rp];
            [first setRenderPipelineState:ps];
            MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
            dsd.depthCompareFunction = MTLCompareFunctionAlways;
            dsd.depthWriteEnabled = YES;
            if (v->flags & RV_STENCIL) {
                MTLStencilDescriptor *st = [MTLStencilDescriptor new];
                st.stencilCompareFunction = MTLCompareFunctionAlways;
                st.depthStencilPassOperation = MTLStencilOperationReplace;
                dsd.frontFaceStencil = dsd.backFaceStencil = st;
                [first setStencilReferenceValue:7];
            }
            [first setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dsd]];
            const float a[4] = { 0.5f, -0.5f, 0.25f, 1.0f };
            [first setVertexBytes:a length:sizeof(a) atIndex:0];
            [first setFragmentBytes:a length:sizeof(a) atIndex:0];
            [first drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [first endEncoding];
            rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
            if (!(v->flags & RV_S8))
                rp.depthAttachment.loadAction = MTLLoadActionLoad;
            if (v->flags & RV_STENCIL)
                rp.stencilAttachment.loadAction = MTLLoadActionLoad;
        }
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
        [enc setRenderPipelineState:ps];
        if (v->flags & RV_ODD_VIEWPORT)
            [enc setViewport:(MTLViewport){ 3, 5, 32, 32, 0, 1 }];
        if (v->kind == 11) {
            MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
            dsd.depthCompareFunction = MTLCompareFunctionLess;
            dsd.depthWriteEnabled = NO;
            if (v->flags & RV_STENCIL) {
                MTLStencilDescriptor *st = [MTLStencilDescriptor new];
                st.stencilCompareFunction = MTLCompareFunctionEqual;
                dsd.frontFaceStencil = dsd.backFaceStencil = st;
                dsd.depthCompareFunction = MTLCompareFunctionAlways;
                [enc setStencilReferenceValue:7];
            }
            [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dsd]];
            const float b[4] = { 1.0f, 0.0f, 0.5f, 1.0f };
            [enc setVertexBytes:b length:sizeof(b) atIndex:0];
            [enc setFragmentBytes:b length:sizeof(b) atIndex:0];
        }
        if (v->kind == 10) {
            // Level n of a 32x32 texture is the solid colour n
            static const uint32_t level[6] = { 0xff102030u, 0xffff0000u, 0xff00ff00u,
                                               0xff0000ffu, 0xffffff00u, 0xffffffffu };
            MTLTextureDescriptor *sd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:32 height:32 mipmapped:YES];
            sd.storageMode = MTLStorageModeShared;
            id<MTLTexture> src = [dev newTextureWithDescriptor:sd];
            for (int l = 0; l < 6; l++) {
                const int n = 32 >> l;
                uint32_t texels[32 * 32];

                for (int i = 0; i < n * n; i++)
                    texels[i] = level[l];
                [src replaceRegion:MTLRegionMake2D(0, 0, n, n) mipmapLevel:l withBytes:texels
                       bytesPerRow:4 * n];
            }
            MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
            smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterNearest;
            smp.mipFilter = MTLSamplerMipFilterNearest;
            [enc setFragmentTexture:src atIndex:0];
            [enc setFragmentSamplerState:[dev newSamplerStateWithDescriptor:smp] atIndex:0];
            logf_(@"mip texture gpu resource 0x%llx", src.gpuResourceID._impl);
        }
        if (v->kind == 12) {
            static const uint32_t face[6] = { 0xffff0000u, 0xff00ff00u, 0xff0000ffu,
                                              0xffffff00u, 0xffff00ffu, 0xff00ffffu };
            MTLTextureDescriptor *sd = [MTLTextureDescriptor
                textureCubeDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm size:4 mipmapped:NO];
            sd.storageMode = MTLStorageModeShared;
            id<MTLTexture> src = [dev newTextureWithDescriptor:sd];
            for (int f = 0; f < 6; f++) {
                uint32_t texels[16];

                for (int i = 0; i < 16; i++)
                    texels[i] = face[f];
                [src replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 slice:f withBytes:texels
                       bytesPerRow:16 bytesPerImage:64];
            }
            MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
            smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterNearest;
            [enc setVertexTexture:src atIndex:0];
            [enc setVertexSamplerState:[dev newSamplerStateWithDescriptor:smp] atIndex:0];
        }
        if (v->flags & RV_DEPTH) {
            MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new];
            dsd.depthCompareFunction = MTLCompareFunctionLess;
            dsd.depthWriteEnabled = YES;
            [enc setDepthStencilState:[dev newDepthStencilStateWithDescriptor:dsd]];
        }
        if (v->flags & RV_CULL)
            [enc setCullMode:MTLCullModeFront];
        if (v->flags & RV_SCISSOR)
            [enc setScissorRect:(MTLScissorRect){ 8, 8, 40, 40 }];
        if (v->kind == 3) {
            // A 4x4 RGBA8 texture with distinct texels, nearest sampling
            MTLTextureDescriptor *sd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
            sd.storageMode = MTLStorageModeShared;
            id<MTLTexture> src;
            if (v->flags & RV_TEX_LINEAR_LAYOUT) {
                id<MTLBuffer> back = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
                src = [back newTextureWithDescriptor:sd offset:0 bytesPerRow:256];
                logf_(@"linear texture: buffer gpu 0x%llx", back.gpuAddress);
            } else {
                src = [dev newTextureWithDescriptor:sd];
            }
            uint32_t texels[16];
            for (int i = 0; i < 16; i++)
                texels[i] = 0xff000000u | (uint32_t)(i * 16) << 16 | (uint32_t)(255 - i * 16) << 8 | 0x40;
            [src replaceRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0 withBytes:texels bytesPerRow:16];
            MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
            smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterNearest;
            if (v->flags & RV_TEX_LINEAR) {
                smp.minFilter = smp.magFilter = MTLSamplerMinMagFilterLinear;
                smp.sAddressMode = smp.tAddressMode = MTLSamplerAddressModeRepeat;
            }
            [enc setFragmentTexture:src atIndex:0];
            [enc setFragmentSamplerState:[dev newSamplerStateWithDescriptor:smp] atIndex:0];
            logf_(@"texture source gpu resource 0x%llx", src.gpuResourceID._impl);
        }
        if (v->kind == 9) {
            float c[4] = { 0.25f, 0.5f, 0.75f, 1.0f };
            id<MTLBuffer> cbuf = [dev newBufferWithBytes:c length:sizeof(c)
                                                 options:MTLResourceStorageModeShared];
            [enc setFragmentBuffer:cbuf offset:0 atIndex:0];
            logf_(@"fragment constant buffer gpu 0x%llx", cbuf.gpuAddress);
        }
        id<MTLBuffer> storebuf = nil;
        if (v->kind >= 13 && v->kind <= 15) {
            storebuf = [dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
            memset(storebuf.contents, 0xcd, 4096);
            [enc setVertexBuffer:storebuf offset:0 atIndex:1];
            logf_(@"store buffer gpu 0x%llx", storebuf.gpuAddress);
        }
        if (v->kind == 16 || v->kind == 17) {
            MTLTextureDescriptor *dd = [MTLTextureDescriptor
                texture2DDescriptorWithPixelFormat:v->kind == 16 ? MTLPixelFormatDepth32Float_Stencil8
                                                                 : MTLPixelFormatDepth32Float
                                             width:64 height:64 mipmapped:NO];
            dd.storageMode = MTLStorageModePrivate;
            dd.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
            MTLSamplerDescriptor *smp = [MTLSamplerDescriptor new];
            smp.compareFunction = MTLCompareFunctionLess;
            id<MTLTexture> depth = [dev newTextureWithDescriptor:dd];
            [enc setFragmentTexture:depth atIndex:0];
            [enc setFragmentSamplerState:[dev newSamplerStateWithDescriptor:smp] atIndex:0];
            logf_(@"depth texture gpu resource 0x%llx", depth.gpuResourceID._impl);
        }
        id<MTLBuffer> ibuf = nil;
        if (v->flags & RV_INDEXED) {
            uint16_t idx[4] = { 0, 1, 2, 0 };
            ibuf = [dev newBufferWithBytes:idx length:sizeof(idx) options:MTLResourceStorageModeShared];
            logf_(@"index buffer gpu 0x%llx", ibuf.gpuAddress);
        }
        const NSUInteger instances = getenv("GC_INSTANCES") ? strtoul(getenv("GC_INSTANCES"), NULL, 0) : 2;
        for (int i = 0; i < v->draws; i++) {
            if (ibuf)
                [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:3
                                 indexType:MTLIndexTypeUInt16 indexBuffer:ibuf indexBufferOffset:0];
            else
                [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:v->vertices
                      instanceCount:(v->flags & RV_INSTANCED) ? instances : 1];
        }
        [enc endEncoding];
        logf_(@"render: committing");
        [cb commit];
        [cb waitUntilCompleted];
        // What iOS actually drew: the hooks are not in yet in this render
        if (r == 0 && repeat && !(v->flags & RV_LINEAR_TARGET) && !v->format) {
            NSMutableData *px = [NSMutableData dataWithLength:4 * v->width * v->height];
            [tex getBytes:px.mutableBytes bytesPerRow:4 * v->width
               fromRegion:MTLRegionMake2D(0, 0, v->width, v->height) mipmapLevel:0];
            [px writeToFile:[dir stringByAppendingPathComponent:@"pixels.raw"] atomically:YES];
            if (storebuf)
                [[NSData dataWithBytes:storebuf.contents length:4096]
                    writeToFile:[dir stringByAppendingPathComponent:@"stored.raw"] atomically:YES];
        }
        if (r < repeat && (r < 4 || r % 25 == 0 || cb.status != MTLCommandBufferStatusCompleted))
            logf_(@"render %d: status %ld, %u traps, %.2f ms", r, (long)cb.status,
                  gTotalTraps - traps, (CFAbsoluteTimeGetCurrent() - t0) * 1e3);
    }
    gHookDir = nil;
    logf_(@"render: status %ld (no submit trap seen if this prints)", (long)cb.status);
    [gLog writeToFile:[dir stringByAppendingPathComponent:@"index.txt"] atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
}

// Peek mode (--peek OUT GPUVA BYTES): a kernel copies BYTES from an arbitrary
// GPU address (indexing from one of our buffers; Metal does no bounds check)
// into a shared buffer, saved to OUT. Reads GPU-private memory such as the
// driver-internal shader heap.
static int peek(const char *out, uint64_t target, uint32_t bytes) {
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();
    NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\n"
                     "using namespace metal;\n"
                     "kernel void peek(device uint *o [[buffer(0)]], device const uint *s [[buffer(1)]],\n"
                     "                 constant long &delta [[buffer(2)]], uint t [[thread_position_in_grid]]) {\n"
                     "    o[t] = s[delta + long(t)];\n"
                     "}\n";
    id<MTLLibrary> lib = [dev newLibraryWithSource:src options:nil error:&err];
    id<MTLComputePipelineState> ps =
        lib ? [dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"peek"] error:&err] : nil;
    if (!ps) {
        fprintf(stderr, "peek pipeline: %s\n", err.description.UTF8String);
        return 1;
    }
    id<MTLBuffer> o = [dev newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    id<MTLBuffer> s = [dev newBufferWithLength:0x4000 options:MTLResourceStorageModeShared];
    memset(o.contents, 0xee, bytes);
    long delta = (long)(target - s.gpuAddress) / 4;
    printf("peek 0x%llx (+%u): source buffer at 0x%llx, delta %ld words\n",
           (unsigned long long)target, bytes, s.gpuAddress, delta);
    id<MTLCommandBuffer> cb = [[dev newCommandQueue] commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cb computeCommandEncoder];
    [enc setComputePipelineState:ps];
    [enc setBuffer:o offset:0 atIndex:0];
    [enc setBuffer:s offset:0 atIndex:1];
    [enc setBytes:&delta length:sizeof(delta) atIndex:2];
    [enc dispatchThreadgroups:MTLSizeMake(bytes / 256, 1, 1) threadsPerThreadgroup:MTLSizeMake(64, 1, 1)];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    printf("status %ld error %s\n", (long)cb.status, cb.error.description.UTF8String ?: "none");
    [[NSData dataWithBytes:o.contents length:bytes] writeToFile:@(out) atomically:YES];
    return 0;
}

#ifndef CAPTURE_APP
int main(int argc, char *argv[]) {
    @autoreleasepool {
        int a = 1;
        if (argc > a + 3 && !strcmp(argv[a], "--peek"))
            return peek(argv[a + 1], strtoull(argv[a + 2], NULL, 0), strtoul(argv[a + 3], NULL, 0));
        if (argc > a && !strcmp(argv[a], "--render")) {
            // gpu-capture --render [DIR [VARIANT]]; one variant per process
            const char *name = argc > a + 2 ? argv[a + 2] : "base";
            for (size_t i = 0; i < sizeof(kVariants) / sizeof(kVariants[0]); i++)
                if (!strcmp(kVariants[i].name, name)) {
                    capture_render(argc > a + 1 ? @(argv[a + 1]) : @"/var/tmp/gpu-render",
                                   &kVariants[i]);
                    return 0;
                }
            fprintf(stderr, "unknown render variant %s\n", name);
            return 2;
        }
        if (argc > a && !strcmp(argv[a], "--light")) {
            gLight = YES;
            a++;
        }
        if (argc > a && !strcmp(argv[a], "--grid")) {
            gLight = gGrid = YES;
            a++;
        }
        capture(argc > a ? @(argv[a]) : @"/var/tmp/gpu-capture");
    }
    return 0;
}
#endif
