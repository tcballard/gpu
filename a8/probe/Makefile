# Out-of-tree build against the J96 kernel build directory (same release as the running kernel):
#   make            -> apple-j96-gpudump.ko, apple-j96-gpubridge.ko
#   make clean
obj-m := apple-j96-gpudump.o apple-j96-gpubridge.o

KDIR ?= /home/tcballard/Projects/iomarchy-j96-tNPWSDe4/build/linux-j96dev
# The kernel is built with clang (CONFIG_CC_IS_CLANG), so build the module with LLVM too.

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR) ARCH=arm64 LLVM=1 clean
