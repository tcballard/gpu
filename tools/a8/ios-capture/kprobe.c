// SPDX-License-Identifier: GPL-2.0-or-later
// kprobe: is kernel memory readable from a root process on this jailbreak boot?
// Step 1 of the J96 register capture (gpu/M1-BRIDGE-FINDINGS.md): READ-ONLY. It never writes
// kernel memory and never calls into the kernel beyond the Mach calls below.
//
//   kprobe                 report whether a kernel task port is obtainable, and the slide
//   kprobe read ADDR LEN   hex-dump LEN bytes (max 4096) of kernel virtual memory at ADDR
//
// Ways tried for the kernel task port, in order: task_for_pid(0), host special port 4
// (the classic "hsp4" a jailbreak may publish). Neither is expected on stock iPadOS.
// A wrong ADDR makes the read fail with an error; it does not panic. Reading a device
// (MMIO) mapping through this path is NOT known to be safe: do not point it at one.
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

static int kread(mach_port_t kt, uint64_t addr, void *buf, size_t len) {
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
static int find_slide(mach_port_t kt, uint64_t *slide) {
    for (uint64_t s = 0; s < 0x40000000ULL; s += 0x200000) {
        uint32_t magic = 0;
        mach_vm_size_t got = 0;
        if (mach_vm_read_overwrite(kt, KERNEL_UNSLID_BASE + s, 4, (mach_vm_address_t)&magic, &got) ==
                KERN_SUCCESS && got == 4 && magic == 0xfeedfacf) {
            *slide = s;
            return 0;
        }
    }
    return -1;
}

int main(int argc, char **argv) {
    printf("kprobe: uid=%d euid=%d\n", getuid(), geteuid());
    const char *how = "none";
    mach_port_t kt = kernel_task_port(&how);
    if (!MACH_PORT_VALID(kt)) {
        printf("RESULT: no kernel task port. Kernel memory is not readable this way on this boot.\n");
        return 2;
    }
    printf("kernel task port via %s\n", how);
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
    if (find_slide(kt, &slide)) {
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
