// SPDX-License-Identifier: GPL-2.0-or-later
// kprobe: is kernel memory readable from a root process on this jailbreak boot?
// Step 1 of the J96 register capture (gpu/M1-BRIDGE-FINDINGS.md): READ-ONLY. It never writes
// kernel memory and never calls into the kernel beyond the Mach calls below.
//
//   kprobe regions         list kernel map regions from the unslid base (map queries only, no reads)
//   kprobe                 report whether a kernel task port is obtainable, and the slide
//   kprobe read ADDR LEN   hex-dump LEN bytes (max 4096) of kernel virtual memory at ADDR
//
// Ways tried for the kernel task port, in order: task_for_pid(0), host special port 4
// (the classic "hsp4" a jailbreak may publish). Neither is expected on stock iPadOS.
// WARNING: on palera1n (15.8.3, J96) a read of an UNMAPPED kernel address through this port
// PANICS the kernel (data abort, far = the address; panic-full-2026-11-09-230600 and again on
// 16 Nov). So every read is first checked with mach_vm_region (a map query that touches no
// target memory) and is done only inside one region the kernel reports as readable. Reading a
// device (MMIO) mapping is NOT known to be safe either: do not point it at one.
#include <errno.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Not in the iOS SDK headers.
extern kern_return_t mach_vm_read_overwrite(vm_map_t task, mach_vm_address_t addr, mach_vm_size_t size,
                                            mach_vm_address_t data, mach_vm_size_t *outsize);
extern kern_return_t mach_vm_region(vm_map_t task, mach_vm_address_t *addr, mach_vm_size_t *size,
                                    vm_region_flavor_t flavor, vm_region_info_t info,
                                    mach_msg_type_number_t *count, mach_port_t *object);

extern kern_return_t mach_vm_region_recurse(vm_map_t task, mach_vm_address_t *addr,
                                            mach_vm_size_t *size, natural_t *depth,
                                            vm_region_recurse_info_t info,
                                            mach_msg_type_number_t *count);

// Deepest map entry at or above *a (descends into submaps). Map query only; no memory access.
static kern_return_t region_at(mach_port_t kt, mach_vm_address_t *a, mach_vm_size_t *size,
                               vm_prot_t *prot, natural_t *depth_out) {
    natural_t depth = 0;
    for (;;) {
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        mach_vm_address_t addr = *a;
        mach_vm_size_t sz = 0;
        natural_t d = depth;
        kern_return_t kr = mach_vm_region_recurse(kt, &addr, &sz, &d,
                                                  (vm_region_recurse_info_t)&info, &count);
        if (kr != KERN_SUCCESS)
            return kr;
        if (info.is_submap && depth < 8) {
            depth++;
            continue;  // look again one level deeper at the same address
        }
        *a = addr;
        *size = sz;
        *prot = info.protection;
        *depth_out = d;
        return KERN_SUCCESS;
    }
}

#define KERNEL_UNSLID_BASE 0xfffffff007004000ULL  // __TEXT of the 15.8.3 iPad5,1 kernelcache

static mach_port_t kernel_task_port(const char **how) {
    mach_port_t port = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), 0, &port);
    printf("task_for_pid(0): kr=0x%x (%s) port=0x%x\n", kr, mach_error_string(kr), port);
    if (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) {
        *how = "task_for_pid(0)";
        return port;
    }
    port = MACH_PORT_NULL;
    kr = host_get_special_port(mach_host_self(), HOST_LOCAL_NODE, 4, &port);
    printf("host_get_special_port(4): kr=0x%x (%s) port=0x%x\n", kr, mach_error_string(kr), port);
    if (kr == KERN_SUCCESS && MACH_PORT_VALID(port)) {
        *how = "host special port 4";
        return port;
    }
    return MACH_PORT_NULL;
}

// Is [addr, addr+len) inside one mapped region with read permission? Map query only.
static int readable(mach_port_t kt, uint64_t addr, size_t len) {
    mach_vm_address_t a = addr;
    mach_vm_size_t size = 0;
    vm_prot_t prot = 0;
    natural_t depth = 0;
    if (region_at(kt, &a, &size, &prot, &depth) != KERN_SUCCESS)
        return 0;
    return a <= addr && addr + len <= a + size && (prot & VM_PROT_READ);
}

static int kread(mach_port_t kt, uint64_t addr, void *buf, size_t len) {
    if (!readable(kt, addr, len)) {
        printf("kread 0x%llx len %zu: refused, not inside one readable kernel region\n",
               (unsigned long long)addr, len);
        return -1;
    }
    mach_vm_size_t got = 0;
    kern_return_t kr = mach_vm_read_overwrite(kt, addr, len, (mach_vm_address_t)buf, &got);
    if (kr != KERN_SUCCESS || got != len) {
        printf("kread 0x%llx len %zu: kr=0x%x (%s) got %llu\n", (unsigned long long)addr, len, kr,
               mach_error_string(kr), (unsigned long long)got);
        return -1;
    }
    return 0;
}

// The kernel's Mach-O header sits at KERNEL_UNSLID_BASE + slide; the slide is a multiple of 2 MiB.
// Walk the kernel map with mach_vm_region (it returns the next mapped region at or above the
// address) and read only 2 MiB-aligned candidates inside readable regions.
static int find_slide(mach_port_t kt, uint64_t *slide, int list_only) {
    mach_vm_address_t a = KERNEL_UNSLID_BASE;
    const uint64_t end = KERNEL_UNSLID_BASE + 0x40000000ULL;
    for (int n = 0; n < 65536 && a < end; n++) {
        mach_vm_size_t size = 0;
        vm_prot_t prot = 0;
        natural_t depth = 0;
        kern_return_t kr = region_at(kt, &a, &size, &prot, &depth);
        if (kr != KERN_SUCCESS) {
            printf("region query at 0x%llx: kr=0x%x (%s)\n", (unsigned long long)a, kr,
                   mach_error_string(kr));
            return -1;
        }
        if ((list_only && n < 64) || n < 8)
            printf("region 0x%llx size 0x%llx prot %d depth %u\n", (unsigned long long)a,
                   (unsigned long long)size, prot, depth);
        if (a >= end || size == 0)
            break;
        // Only a region START that is a possible kernel base (unslid base + n * 2 MiB): the
        // header is the first page of its mapping, and a page inside a readable region can
        // still be unbacked.
        if (!list_only && (prot & VM_PROT_READ) && a >= KERNEL_UNSLID_BASE &&
            !((a - KERNEL_UNSLID_BASE) & 0x1fffff)) {
            uint32_t magic = 0;
            mach_vm_size_t got = 0;
            printf("candidate 0x%llx: reading 4 bytes\n", (unsigned long long)a);
            if (mach_vm_read_overwrite(kt, a, 4, (mach_vm_address_t)&magic, &got) ==
                    KERN_SUCCESS && got == 4 && magic == 0xfeedfacf) {
                *slide = a - KERNEL_UNSLID_BASE;
                return 0;
            }
        }
        a += size;
    }
    return -1;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);  // every line reaches the host before a possible panic
    printf("kprobe: uid=%d euid=%d\n", getuid(), geteuid());
    const char *how = "none";
    mach_port_t kt = kernel_task_port(&how);
    if (!MACH_PORT_VALID(kt)) {
        printf("RESULT: no kernel task port. Kernel memory is not readable this way on this boot.\n");
        return 2;
    }
    printf("kernel task port via %s\n", how);
    struct task_dyld_info dyld = {0};
    mach_msg_type_number_t dcount = TASK_DYLD_INFO_COUNT;
    kern_return_t dkr = task_info(kt, TASK_DYLD_INFO, (task_info_t)&dyld, &dcount);
    printf("TASK_DYLD_INFO: kr=0x%x addr=0x%llx size=0x%llx\n", dkr,
           (unsigned long long)dyld.all_image_info_addr, (unsigned long long)dyld.all_image_info_size);
    if (argc == 4 && !strcmp(argv[1], "read")) {
        uint64_t addr = strtoull(argv[2], NULL, 0);
        size_t len = strtoul(argv[3], NULL, 0);
        if (len == 0 || len > 4096) {
            fprintf(stderr, "LEN must be 1..4096\n");
            return 1;
        }
        uint8_t *buf = malloc(len);
        if (kread(kt, addr, buf, len))
            return 3;
        for (size_t i = 0; i < len; i += 16) {
            printf("%016llx:", (unsigned long long)(addr + i));
            for (size_t j = i; j < i + 16 && j < len; j++)
                printf(" %02x", buf[j]);
            printf("\n");
        }
        return 0;
    }
    uint64_t slide = 0;
    if (argc == 2 && !strcmp(argv[1], "regions")) {
        find_slide(kt, &slide, 1);  // list the kernel map from the unslid base; no reads
        printf("RESULT: regions listed (no kernel memory read).\n");
        return 0;
    }
    if (find_slide(kt, &slide, 0)) {
        printf("RESULT: have a port, but could not read the kernel header at any slide.\n");
        return 3;
    }
    uint8_t hdr[32];
    if (kread(kt, KERNEL_UNSLID_BASE + slide, hdr, sizeof(hdr)))
        return 3;
    printf("kernel base 0x%llx slide 0x%llx header:", (unsigned long long)(KERNEL_UNSLID_BASE + slide),
           (unsigned long long)slide);
    for (size_t i = 0; i < sizeof(hdr); i++)
        printf(" %02x", hdr[i]);
    printf("\nRESULT: kernel virtual memory is readable (via %s).\n", how);
    return 0;
}
