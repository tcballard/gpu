/*
 * J96 (iPad mini 4, A8/T7000, iPadOS 15.8.3 19H386) full-state planned-panic
 * KPF component (this PongoOS checkout's kpf.h API).
 *
 * Two hooks, read-only (no MMIO store):
 *   capture  ApplePMGR ps-poll `blr x8` (0x66e4294)  -> save PMGR object and
 *            snapshot the six clock pages' +0x04 (the ps_gfx-on time point)
 *   read     AGXG4P post-GPC-poll `mov w0,#0xa` (0x6695a44) -> dump the six
 *            clock pages' +0x04 (post-GPC), ps_gfx, the GFX perf-state control
 *            words, 0x2300c and the page-5 diff words into x2..x21, plus the
 *            capture-time six pages' +0x04 into x22..x27, then fault.
 *
 * The dump lands in the panic report's x2..x27 (register map in
 * j96_page5_shell.S); x18 is skipped (Darwin platform register).
 */
#include "kpf.h"
#include <pongo.h>
#include <xnu/xnu.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern uint32_t j96_page5_start[], j96_page5_end[];
extern uint32_t j96_page5_poll_capture[], j96_page5_read[], j96_page5_write_trace[];
extern uint32_t j96_page5_buffer[];

/*
 * PORTING CONFIG ------------------------------------------------------------
 * Everything device-specific is below and in j96_page5_shell.S. This probe is
 * derived for the A8/T7000 (iPad5,1) on iPadOS 15.8.3 (19H386). To port to
 * another SoC or OS build, re-derive (by disassembling the target kernelcache):
 *   1. cap_sig / CAP_SITE  -- the capture site (ApplePMGR ps-poll `blr x8`).
 *   2. rd_sig  / RD_SITE   -- the read site (AGXG4P post-GPC-poll `mov w0,#0xa`).
 *   3. the kernel UUID in uuid_ok()  -- LC_UUID of the target kernelcache.
 *   4. the kext bundle IDs in .patches -- swap AGXG4P for the target's GPU
 *      driver; ApplePMGR usually stays the same.
 *   5. the PMGR offsets in j96_page5_shell.S -- region-0 base (pmgr+0xa70),
 *      clock pages, ps_gfx, perf-state control, 0x2300c. PMGR layout differs
 *      between SoCs.
 * The framework below (emit/finish/branch/buffer) is SoC-agnostic.
 * verify_sites.py checks items 1-3 offline against the target kernelcache.
 * ---------------------------------------------------------------------------
 */

/* capture signature: 11 words ending at `blr x8` (0x66e4294). */
static const uint32_t cap_sig[11] = {
    0x531c6f24,  /* 0x66e426c  lsl w4, w25, #4            */
    0xf9400288,  /* 0x66e4270  ldr x8, [x20]              */
    0xf944c908,  /* 0x66e4274  ldr x8, [x8, #0x990]       */
    0xaa1403e0,  /* 0x66e4278  mov x0, x20                */
    0xaa1503e1,  /* 0x66e427c  mov x1, x21                */
    0xaa1703e2,  /* 0x66e4280  mov x2, x23                */
    0x52801e03,  /* 0x66e4284  mov w3, #0xf0              */
    0x529dc005,  /* 0x66e4288  mov w5, #0xee00            */
    0x72a00045,  /* 0x66e428c  movk w5, #2, lsl #16       */
    0xaa1303e6,  /* 0x66e4290  mov x6, x19                */
    0xd63f0100,  /* 0x66e4294  blr x8  <- site            */
};
#define CAP_LEN 11
#define CAP_SITE 10

/* read signature: 8 words ending at `mov w0,#0xa` (0x6695a44). */
static const uint32_t rd_sig[8] = {
    0x52a80008,  /* 0x6695a2c  mov w8, #0x40000000        */
    0xb9000008,  /* 0x6695a30  str w8, [x0]               */
    0x52800228,  /* 0x6695a34  mov w8, #0x11               */
    0xb9100008,  /* 0x6695a38  str w8, [x0, #0x1000]       */
    0xb9500008,  /* 0x6695a3c  ldr w8, [x0, #0x1000]       */
    0x3727ffe8,  /* 0x6695a40  tbnz w8, #4, -0xc           */
    0x52800140,  /* 0x6695a44  mov w0, #0xa   <- site       */
    0x9400b3d1,  /* 0x6695a48  bl _IODelay                 */
};
#define RD_LEN 8
#define RD_SITE 6

/* write signature: 6 words ending at `str w21,[x8,w19,uxtw]` (0x66ed538). */
static const uint32_t wr_sig[6] = {
    0xaa1703e0,  /* 0x66ed524  mov x0, x23                */
    0xaa1603e1,  /* 0x66ed528  mov x1, x22                */
    0xaa1403e2,  /* 0x66ed52c  mov x2, x20                */
    0x97ffdc2d,  /* 0x66ed530  bl 0x66e45e4               */
    0xf9400c08,  /* 0x66ed534  ldr x8, [x0, #0x18]        */
    0xb8334915,  /* 0x66ed538  str w21, [x8, w19, uxtw]  <- site */
};
#define WR_LEN 6
#define WR_SITE 5

static struct mach_header_64 *kernel;
static uint32_t *cap_site;
static uint32_t *rd_site;
static uint32_t *wr_site;
static uint32_t *my_shellcode;
static unsigned cap_count, rd_count, wr_count;
static bool armed;

static bool f_capture(struct xnu_pf_patch *patch, void *stream) {
    (void)patch;
    cap_count++;
    cap_site = (uint32_t *)stream + CAP_SITE;
    return true;
}

static bool f_read(struct xnu_pf_patch *patch, void *stream) {
    (void)patch;
    rd_count++;
    rd_site = (uint32_t *)stream + RD_SITE;
    return true;
}

static bool f_write(struct xnu_pf_patch *patch, void *stream) {
    (void)patch;
    wr_count++;
    wr_site = (uint32_t *)stream + WR_SITE;
    return true;
}

static void capture_p(xnu_pf_patchset_t *set) {
    uint64_t v[CAP_LEN], m[CAP_LEN];
    for (unsigned k = 0; k < CAP_LEN; k++) { v[k] = cap_sig[k]; m[k] = 0xffffffff; }
    xnu_pf_maskmatch(set, "j96_page5_capture", v, m, CAP_LEN, true, f_capture);
}

static void read_p(xnu_pf_patchset_t *set) {
    uint64_t v[RD_LEN], m[RD_LEN];
    for (unsigned k = 0; k < RD_LEN; k++) { v[k] = rd_sig[k]; m[k] = 0xffffffff; }
    xnu_pf_maskmatch(set, "j96_page5_read", v, m, RD_LEN, true, f_read);
}

static void write_p(xnu_pf_patchset_t *set) {
    uint64_t v[WR_LEN], m[WR_LEN];
    for (unsigned k = 0; k < WR_LEN; k++) { v[k] = wr_sig[k]; m[k] = 0xffffffff; }
    xnu_pf_maskmatch(set, "j96_page5_write", v, m, WR_LEN, true, f_write);
}

static void init(struct mach_header_64 *hdr, xnu_pf_range_t *cstring,
                 checkrain_option_t kpf_flags, checkrain_option_t checkra1n_flags) {
    (void)cstring;
    (void)kpf_flags;
    (void)checkra1n_flags;
    kernel = hdr;
}

static bool uuid_ok(struct mach_header_64 *h) {
    static const unsigned char u[] = {
        0xcc, 0x26, 0xbe, 0x6a, 0x29, 0x2b, 0x37, 0x59,
        0x9e, 0xd0, 0x29, 0x0b, 0xcf, 0x18, 0xb0, 0x90
    };
    uint8_t *p = (uint8_t *)(h + 1);
    uint8_t *end = p + h->sizeofcmds;
    for (uint32_t i = 0; i < h->ncmds && (size_t)(end - p) >= sizeof(struct load_command); i++) {
        struct load_command *c = (struct load_command *)p;
        if (c->cmdsize < sizeof(*c) || c->cmdsize > (size_t)(end - p))
            return false;
        if (c->cmd == LC_UUID && c->cmdsize >= sizeof(struct uuid_command))
            return !memcmp(((struct uuid_command *)c)->uuid, u, sizeof(u));
        p += c->cmdsize;
    }
    return false;
}

static bool target_ok(void) {
    if (!uuid_ok(kernel))
        return false;
    if (cap_count != 1 || !cap_site || memcmp(cap_site - CAP_SITE, cap_sig, CAP_LEN * 4))
        return false;
    if (rd_count != 1 || !rd_site || memcmp(rd_site - RD_SITE, rd_sig, RD_LEN * 4))
        return false;
    if (wr_count != 1 || !wr_site || memcmp(wr_site - WR_SITE, wr_sig, WR_LEN * 4))
        return false;
    return true;
}

static bool branch(uint32_t *from, uint32_t *to, bool link, uint32_t *out) {
    int64_t off = (int64_t)(to - from);  /* word difference == VA diff >> 2 */
    if (off < -0x2000000LL || off > 0x1ffffffLL)  /* +/-128 MiB in words */
        return false;
    *out = (link ? 0x94000000U : 0x14000000U) | ((uint32_t)off & 0x03ffffffU);
    return true;
}

static uint32_t size(void) {
    return (uint32_t)(j96_page5_end - j96_page5_start);
}

static uint32_t emit(uint32_t *area) {
    my_shellcode = area;
    if (!target_ok()) {
        printf("J96_PAGE5_EMIT prepared=0 cap=%u rd=%u wr=%u\n", cap_count, rd_count, wr_count);
        return 0;
    }
    memcpy(area, j96_page5_start, (size_t)size() * 4);
    void *buf = alloc_static(4096);
    if (!buf) {
        printf("J96_PAGE5_EMIT alloc_failed\n");
        return 0;
    }
    memset(buf, 0, 4096);
    uint64_t buf_va = xnu_ptr_to_va(buf);
    memcpy(area + (j96_page5_buffer - j96_page5_start), &buf_va, 8);
    armed = true;
    printf("J96_PAGE5_EMIT prepared=1 words=%u\n", size());
    return size();
}

static void finish(struct mach_header_64 *hdr, checkrain_option_t *checkra1n_flags) {
    (void)checkra1n_flags;
    uint32_t bc, br, bw;
    bool ok = armed && target_ok() && my_shellcode && cap_site && rd_site && wr_site &&
              branch(cap_site, my_shellcode + (j96_page5_poll_capture - j96_page5_start), true, &bc) &&
              branch(rd_site,  my_shellcode + (j96_page5_read - j96_page5_start),     true, &br) &&
              branch(wr_site,  my_shellcode + (j96_page5_write_trace - j96_page5_start), true, &bw);
    if (ok) {
        cap_site[0] = bc;
        rd_site[0] = br;
        wr_site[0] = bw;
    }
    printf("J96_PAGE5_PATCH applied=%d\n", ok ? 1 : 0);
}

kpf_component_t j96_page5_capture = {
    .init = init,
    .finish = finish,
    .shc_size = size,
    .shc_emit = emit,
    .patches = {
        { "com.apple.driver.ApplePMGR", "__TEXT_EXEC", "__text", XNU_PF_ACCESS_32BIT, capture_p },
        { "com.apple.driver.ApplePMGR", "__TEXT_EXEC", "__text", XNU_PF_ACCESS_32BIT, write_p },
        { "com.apple.AGXG4P", "__TEXT_EXEC", "__text", XNU_PF_ACCESS_32BIT, read_p },
        {}
    },
};
