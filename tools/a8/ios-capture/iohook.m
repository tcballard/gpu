// Logs this process's own IOKit user-client calls. The dyld shared cache binds
// calls between system libraries directly, so imports cannot be rebound.
// Instead, the entries of IOConnectCallMethod and IOConnectCallAsyncMethod are
// patched to jump here; trampolines run the saved prologue and continue. The
// struct/scalar wrappers call these two inside IOKit, so they are covered too.
// While gHookDir is set, each call's selector, scalars and struct
// input/output are saved as call_NNN_*.bin.

#include <dlfcn.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>

static NSString *gHookDir;
typedef struct needle needle_t;
static int scan_and_dump(NSString *dir, NSString *phase, needle_t *needles, int nneedles);
static void prepare_post(NSString *dir);
static void copy_post(void);
static void prepare_late(NSString *dir);
static void copy_late(double seconds);
static int gCallNo;
static int gTotalCalls, gTotalTraps;
static BOOL gExitAfterTrap = YES;

typedef kern_return_t (*call_method_t)(mach_port_t, uint32_t, const uint64_t *, uint32_t,
                                       const void *, size_t, uint64_t *, uint32_t *, void *, size_t *);
typedef kern_return_t (*call_async_t)(mach_port_t, uint32_t, mach_port_t, uint64_t *, uint32_t,
                                      const uint64_t *, uint32_t, const void *, size_t,
                                      uint64_t *, uint32_t *, void *, size_t *);
static call_method_t real_call;  // trampolines: original prologue + jump back
static call_async_t real_async;

static void save(NSString *name, const void *p, size_t n) {
    if (p && n)
        [[NSData dataWithBytes:p length:n] writeToFile:[gHookDir stringByAppendingPathComponent:name]
                                            atomically:NO];
}

static void log_call(const char *kind, mach_port_t conn, uint32_t sel, const uint64_t *in,
                     uint32_t nin, const void *sin, size_t nsin, kern_return_t kr,
                     const uint64_t *out, uint32_t nout, const void *sout, size_t nsout) {
    gTotalCalls++;
    if (!gHookDir)
        return;
    int n = gCallNo++;
    NSMutableString *s = [NSMutableString stringWithFormat:@"call %03d %s conn 0x%x sel %u kr 0x%x in[",
                                                           n, kind, conn, sel, kr];
    for (uint32_t i = 0; i < nin; i++)
        [s appendFormat:@" 0x%llx", in[i]];
    [s appendString:@" ] out["];
    for (uint32_t i = 0; i < nout; i++)
        [s appendFormat:@" 0x%llx", out[i]];
    [s appendFormat:@" ] struct_in %zu struct_out %zu", nsin, nsout];
    logf_(@"%@", s);
    save([NSString stringWithFormat:@"call_%03d_in.bin", n], sin, nsin);
    save([NSString stringWithFormat:@"call_%03d_out.bin", n], sout, nsout);
}

static kern_return_t hook_call(mach_port_t c, uint32_t sel, const uint64_t *in, uint32_t nin,
                               const void *sin, size_t nsin, uint64_t *out, uint32_t *nout,
                               void *sout, size_t *nsout) {
    kern_return_t kr = real_call(c, sel, in, nin, sin, nsin, out, nout, sout, nsout);
    log_call("sync", c, sel, in, nin, sin, nsin, kr, out, nout ? *nout : 0, sout, nsout ? *nsout : 0);
    return kr;
}

static kern_return_t hook_async(mach_port_t c, uint32_t sel, mach_port_t wake, uint64_t *ref,
                                uint32_t nref, const uint64_t *in, uint32_t nin, const void *sin,
                                size_t nsin, uint64_t *out, uint32_t *nout, void *sout,
                                size_t *nsout) {
    kern_return_t kr = real_async(c, sel, wake, ref, nref, in, nin, sin, nsin, out, nout, sout, nsout);
    log_call("async", c, sel, in, nin, sin, nsin, kr, out, nout ? *nout : 0, sout, nsout ? *nsout : 0);
    return kr;
}

// IOConnectTrap0..6 end in the iokit_user_client_trap syscall stub
// (mov x16, #-100; svc; ret), so hooking the stub sees every fast trap.
typedef kern_return_t (*uc_trap_t)(mach_port_t, uint32_t, uintptr_t, uintptr_t, uintptr_t,
                                   uintptr_t, uintptr_t, uintptr_t);
static uc_trap_t real_uc_trap;

// Saves `len` bytes at addr, then (depth permitting) every pointer-looking
// 64-bit value inside it, so the submit record's command data is captured.
static void dump_tree(NSString *prefix, uintptr_t addr, vm_size_t len, int depth, int *budget) {
    static uint8_t buf[0x10000];
    vm_size_t got = 0;
    if (*budget <= 0 || addr < 0x100000000 || addr >= 0x1000000000 ||
        vm_read_overwrite(mach_task_self(), addr, len, (vm_address_t)buf, &got) != KERN_SUCCESS)
        return;
    (*budget)--;
    save([NSString stringWithFormat:@"%@_%lx.bin", prefix, addr], buf, got);
    if (!depth)
        return;
    NSData *copy = [NSData dataWithBytes:buf length:got];
    const uint64_t *w = copy.bytes;
    for (vm_size_t i = 0; i < got / 8 && i < 512; i++)
        if (w[i] >= 0x100000000 && w[i] < 0x1000000000 && !(w[i] & 3))
            dump_tree([NSString stringWithFormat:@"%@.%zx", prefix, i * 8], w[i], 0x4000, depth - 1, budget);
}

static kern_return_t hook_uc_trap(mach_port_t c, uint32_t idx, uintptr_t a0, uintptr_t a1,
                                  uintptr_t a2, uintptr_t a3, uintptr_t a4, uintptr_t a5) {
    uintptr_t args[6] = { a0, a1, a2, a3, a4, a5 };
    gTotalTraps++;
    if (!gHookDir)
        return real_uc_trap(c, idx, a0, a1, a2, a3, a4, a5);
    int no = gCallNo++;
    logf_(@"call %03d trap conn 0x%x index %u args[ 0x%lx 0x%lx 0x%lx 0x%lx 0x%lx 0x%lx ]",
          no, c, idx, a0, a1, a2, a3, a4, a5);
    // The submit record and two levels of what it points to: the submission
    // descriptors name each command's buffers (render: TA and 3D commands).
    int budget = 96;
    for (int i = 0; i < 6; i++)
        dump_tree([NSString stringWithFormat:@"call_%03d_pre_arg%d", no, i], args[i], 0x1000, 2, &budget);
    // Metal fills the shared command memory at commit: snapshot it here.
    scan_and_dump(gHookDir, [NSString stringWithFormat:@"call_%03d_regions", no], NULL, 0);
    prepare_post(gHookDir);
    prepare_late(gHookDir);
    kern_return_t kr = real_uc_trap(c, idx, a0, a1, a2, a3, a4, a5);
    // The kernel patches the shared command records during submission.
    copy_post();
    copy_late(0.3);
    logf_(@"call %03d kr 0x%x", no, kr);
    budget = 1;
    for (int i = 0; i < 6; i++)
        dump_tree([NSString stringWithFormat:@"call_%03d_post_arg%d", no, i], args[i], 0x1000, 0, &budget);
    [gLog writeToFile:[gHookDir stringByAppendingPathComponent:@"trap-log.txt"] atomically:YES
             encoding:NSUTF8StringEncoding error:nil];
    if (gExitAfterTrap)
        _exit(0);  // the patched IOKit pages later fault on the completion thread
    return kr;
}

static BOOL pc_relative(uint32_t w) {
    return (w & 0x1f000000) == 0x10000000 ||  // adr/adrp
           (w & 0x7c000000) == 0x14000000 ||  // b/bl
           (w & 0xff000010) == 0x54000000 ||  // b.cond
           (w & 0x7e000000) == 0x34000000 ||  // cbz/cbnz
           (w & 0x7e000000) == 0x36000000 ||  // tbz/tbnz
           (w & 0x3b000000) == 0x18000000;    // ldr literal
}

// Returns a trampoline running fn's first four instructions, then fn+16.
static void *make_trampoline(void *fn) {
    uint32_t code[8];
    memcpy(code, fn, 16);
    for (int i = 0; i < 4; i++)
        if (pc_relative(code[i])) {
            logf_(@"iohooks: %p prologue word %d 0x%08x is PC-relative", fn, i, code[i]);
            return NULL;
        }
    void *back = (uint8_t *)fn + 16;
    code[4] = 0x58000050;  // ldr x16, #8
    code[5] = 0xd61f0200;  // br x16
    memcpy(&code[6], &back, sizeof(back));
    vm_address_t page = 0;
    if (vm_allocate(mach_task_self(), &page, vm_page_size, VM_FLAGS_ANYWHERE))
        return NULL;
    memcpy((void *)page, code, sizeof(code));
    if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE))
        return NULL;
    sys_icache_invalidate((void *)page, sizeof(code));
    return (void *)page;
}

// ldr x16, #8; br x16; .quad target
static BOOL patch_entry(void *fn, void *target) {
    uint32_t code[4] = { 0x58000050, 0xd61f0200 };
    memcpy(&code[2], &target, sizeof(target));
    vm_address_t page = trunc_page((vm_address_t)fn);
    vm_size_t len = round_page((vm_address_t)fn + sizeof(code)) - page;
    if (vm_protect(mach_task_self(), page, len, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY))
        return NO;
    memcpy(fn, code, sizeof(code));
    if (vm_protect(mach_task_self(), page, len, 0, VM_PROT_READ | VM_PROT_EXECUTE))
        return NO;
    sys_icache_invalidate(fn, sizeof(code));
    return YES;
}

static void install_iohooks(void) {
    static BOOL done;
    if (done)
        return;
    done = YES;
    void *uc = dlsym(RTLD_DEFAULT, "iokit_user_client_trap");
    real_uc_trap = uc ? (uc_trap_t)make_trampoline(uc) : NULL;
    logf_(@"iohooks: iokit_user_client_trap %s",
          real_uc_trap && patch_entry(uc, (void *)hook_uc_trap) ? "patched" : "not hooked");
    // Resource creation replies carry each buffer's CPU and GPU address.
    void *call = dlsym(RTLD_DEFAULT, "IOConnectCallMethod");
    real_call = call ? (call_method_t)make_trampoline(call) : NULL;
    logf_(@"iohooks: IOConnectCallMethod %s",
          real_call && patch_entry(call, (void *)hook_call) ? "patched" : "not hooked");
    void *async = dlsym(RTLD_DEFAULT, "IOConnectCallAsyncMethod");
    real_async = async ? (call_async_t)make_trampoline(async) : NULL;
    logf_(@"iohooks: IOConnectCallAsyncMethod %s",
          real_async && patch_entry(async, (void *)hook_async) ? "patched" : "not hooked");
}
