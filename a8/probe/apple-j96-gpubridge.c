// SPDX-License-Identifier: GPL-2.0-only
/*
 * J96 (iPad mini 4, A8/t7000) GPU bridge-settings probe: the stage after apple-j96-gpudump.
 * Not a GPU driver.
 *
 * Why: the first RGX read (RGX+0x20) froze the SoC twice although Fender reported GPC state 1
 * and ps_gfx was fully on, and nothing Fender reports changes over the next second
 * (gpu/m1-staged-20261103.log, gpu/m1-gpc1-dump-20261109.log). iPadOS's ApplePMGR rewrites a
 * device's "bridge settings" every time the device reaches power state 0xf; GFX owns two
 * bridges, at 0x201f00000 and 0x201f80000, that nothing on the Linux side has ever written
 * (gpu/M1-BRIDGE-FINDINGS.md). This module does the same writes after ps_gfx on, then repeats
 * stage 4 of the built-in probe.
 *
 * Three tokens on the "attempt" attribute, each at most once per module load and only if ps_gfx
 * reads fully off:
 *
 *   gpu-bridge-write: ps_gfx on -> the 33 bridge writes, each announced first (300 ms each) ->
 *     ps_gfx off. No Fender access, no RGX access. Shows whether the writes themselves are
 *     survivable, and a hang names the register.
 *   gpu-bridge-id: ps_gfx on (forced on, as every earlier stage) -> the 33 bridge writes back
 *     to back -> Fender dump -> Fender+0x10000 = 0xffff0000 -> Fender+0x0 = 0x40000000 ->
 *     Fender+0x1000 = 0x11, poll bit 4 -> 10 us -> read RGX+0x20 then RGX+0x18 -> Fender dump
 *     -> Fender+0x1000 = 0x10, poll bit 4 -> ps_gfx off. Differs from the twice-frozen stage 4
 *     by one variable, the bridge writes.
 *   gpu-bridge-id-auto: the iOS-exact path: the same, but ps_gfx gets AUTO_ENABLE (bit 28) as
 *     ApplePMGR sets it once the state reads 0xf (0x66e42c0-0x66e435c), and from that write to
 *     the GPC 0 write nothing sleeps and nothing is printed. At the end bit 28 is cleared with
 *     the target still 0xf before the domain is turned off, as iOS does.
 * Order on one boot: write, id, then id-auto (only if id returned).
 *
 * Two diagnostic tokens, added after gpu-bridge-id froze on the RGX read (10 Nov 2026,
 * gpu/m1-bridge-20261110.log). Neither touches Fender or RGX:
 *
 *   gpu-ps-auto-watch: ps_gfx on -> AUTO_ENABLE set as iOS does -> sample ps_gfx for 3 s ->
 *     AUTO_ENABLE cleared -> ps_gfx off. PMGR accesses only: shows whether the domain gates
 *     itself under AUTO_ENABLE, and how fast.
 *   gpu-bridge-readback: ps_gfx on (forced) -> read the 33 bridge registers, each announced ->
 *     the 33 writes back to back -> read them again -> ps_gfx off. Shows whether the writes
 *     take effect. The reads are OUTSIDE the iOS path (iOS never reads these registers), so a
 *     hang on the first read is possible; the announce line names the register.
 *
 * One more diagnostic token, added after gpu-bridge-id-auto froze as well (10 Nov 2026):
 *
 *   gpu-fender-scan: is there a per-state clock table in Fender, and is it empty? ps_gfx on
 *     (forced) -> the 33 bridge writes -> scan A: read Fender +0x0-0x3c, +0x1000-0x11fc,
 *     +0x2000-0x203c, +0x3000-0x303c, +0x4000-0x403c, +0x10000-0x1001c, +0x20000-0x2003c, eight
 *     registers per announce -> 12 s pause -> the Fender probe writes and GPC 1 -> scan B ->
 *     GPC 0 -> ps_gfx off. No RGX access. Reads only, but almost all of these offsets are
 *     OUTSIDE anything the iOS host driver reads (it maps 0x5000 bytes of Fender for the
 *     firmware and itself reads seven registers), so a hang or a read side effect is possible;
 *     the announce line names the eight registers being read.
 *
 * And one more, after the J81 (A8X) research showed the same hang (12 Nov 2026,
 * gpu/M1-BRIDGE-FINDINGS.md "External evidence"):
 *
 *   gpu-pmgr-clock-snapshot: read-only PMGR snapshots of the GFX perf-slot table
 *     (pmgr+0x1c000 + n*0x10, +0 and +4, n = 0..15), its control words (+0x1c200, +0x1c300),
 *     +0/+4/+8 of the six clock-like pages at pmgr+0x0000..0x5000, and ps_gfx. Taken with GFX
 *     off, after ps_gfx on, after the bridge writes, at GPC 1 at once and after 1 s, after
 *     GPC 0, and after ps_gfx off. Fender and bridge accesses are exactly gpu-fender-scan's
 *     (minus its scans); no RGX access. On J81 these PMGR words were read under Linux without
 *     trouble, and pmgr+0x5004 bit 30 was set under iPadOS at GPC 1 but not under Linux.
 *     Each PMGR group is announced before it is read.
 *
 * Access envelope:
 *   - Bridges: only the (offset, value) pairs of the ADT pmgr properties bridge-settings-10 and
 *     bridge-settings-11, in list order, 32-bit, bridge 10 then bridge 11 (the order of the GFX
 *     device entry). Writes only, except in gpu-bridge-readback, which also reads those same
 *     33 offsets (iOS does not read these registers back on this path).
 *   - Fender: exactly as apple-j96-gpudump (M0-STATIC-RE.md section 4), and every Fender write
 *     is preceded by a read of +0x1000 that must not show a pending transition.
 *   - PMGR: only ps_gfx (pmgr+0x20320): target on/off as before, plus bit 28 in the -auto token.
 *     ps_gfx must read target and actual 0xf right before every group of GFX accesses (after
 *     every announce pause; in the -auto token before the bridge writes, the first Fender read,
 *     the RGX read and the GPC 0 write), or the run stops without touching GFX registers.
 *   - RGX: two 32-bit reads, CORE_REVISION (+0x20) then CORE_ID (+0x18), only after Fender
 *     reported GPC state 1. No RGX write of any kind.
 * No interrupt is requested. All mappings are non-posted. Every poll is bounded. Results are
 * printed at KERN_EMERG so they reach the screen.
 *
 * ps_gfx is driven directly, behind genpd: safe only while no device tree node consumes
 * &ps_gfx (none does) and with pd_ignore_unused.
 *
 * Use (whichever probe driver owns the node must be unbound first; this driver then binds):
 *   echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind
 *   insmod apple-j96-gpubridge.ko
 *   echo gpu-bridge-write > /sys/bus/platform/devices/201000000.gpu-probe/attempt
 */
#include <linux/atomic.h>
#include <linux/bitfield.h>
#include <linux/build_bug.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/ioport.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/sysfs.h>

enum { J96GB_WRITE = 1, J96GB_ID_AUTO, J96GB_ID, J96GB_READBACK, J96GB_AUTO_WATCH, J96GB_FENDER_SCAN, J96GB_CLOCK_SNAP };
static const char *const j96gb_tokens[] = {
	[J96GB_WRITE] = "gpu-bridge-write",
	[J96GB_ID_AUTO] = "gpu-bridge-id-auto",
	[J96GB_ID] = "gpu-bridge-id",
	[J96GB_READBACK] = "gpu-bridge-readback",
	[J96GB_AUTO_WATCH] = "gpu-ps-auto-watch",
	[J96GB_FENDER_SCAN] = "gpu-fender-scan",
	[J96GB_CLOCK_SNAP] = "gpu-pmgr-clock-snapshot",
};

/* PMGR power-state register (drivers/pmdomain/apple/pmgr-pwrstate.c). */
#define J96GB_PS_GFX		0x20320
#define J96GB_PS_RESET		BIT(31)
#define J96GB_PS_AUTO_ENABLE	BIT(28)
#define J96GB_PS_DEV_DISABLE	BIT(10)
#define J96GB_PS_FLAGS		(BIT(9) | BIT(8))
#define J96GB_PS_ACTUAL		GENMASK(7, 4)
#define J96GB_PS_TARGET		GENMASK(3, 0)
#define J96GB_PS_ACTIVE		0xf
#define J96GB_PS_PWRGATE	0x0

/* Fender (GPC) registers, names from AGXG4P's own state dump (M0 section 2). */
#define FNDR_SLEEP_CONTROL	0x0
#define FNDR_KICK_STATUS	0x8
#define FNDR_INT_ENABLE		0x10
#define FNDR_INT_STATUS		0x14
#define FNDR_PERF_CONTROL	0x1000
#define FNDR_PERF_NEXT		0x1004
#define FNDR_SEQ_PROGRAM	0x10000
#define FNDR_PERF_OVERRIDE	0x20000
#define FNDR_PERF_STATE		GENMASK(3, 0)
#define FNDR_PERF_PENDING	BIT(4)
#define FNDR_SEQ_END		0xffff0000
#define FNDR_SLEEP_RUN		0x40000000
#define FNDR_SIZE		0x21000

/* RGX core identity (read only, iOS order: revision first). */
#define RGX_CORE_ID		0x18
#define RGX_CORE_REVISION	0x20
#define RGX_SIZE		0x1000

/*
 * GFX bridges: ADT pmgr reg[12] and reg[13] (bridge-reg-index 2, bridges 10 and 11 of the GFX
 * device entry), child addresses 0x01f00000 and 0x01f80000 in arm-io (PA base 0x200000000).
 */
#define J96GB_BRIDGE10_PA	0x201f00000ULL
#define J96GB_BRIDGE11_PA	0x201f80000ULL
#define J96GB_BRIDGE_SIZE	0x1000

#define J96GB_POLL_US		100000
#define J96GB_NREGS		7

struct j96gb_pair {
	u32 off;
	u32 val;
};

/* ADT pmgr bridge-settings-10: one (offset, value) pair. */
static const struct j96gb_pair j96gb_bridge10[] = {
	{ 0x18, 0x80010004 },
};

/* ADT pmgr bridge-settings-11: 32 (offset, value) pairs, in list order. */
static const struct j96gb_pair j96gb_bridge11[] = {
	{ 0x00, 0x007c7c01 }, { 0x04, 0x007c7c01 }, { 0x08, 0x007c7c01 }, { 0x0c, 0x007c7901 },
	{ 0x10, 0x007c7901 }, { 0x14, 0x007c7c01 }, { 0x18, 0x007c7c01 }, { 0x1c, 0x007c7c01 },
	{ 0x20, 0x007c7c01 }, { 0x24, 0x007c7c01 }, { 0x28, 0x007c7c01 }, { 0x2c, 0x007c7c01 },
	{ 0x30, 0x006c6901 }, { 0x34, 0x007c7901 }, { 0x38, 0x007c7c01 }, { 0x3c, 0x007c7c01 },
	{ 0x40, 0x00747201 }, { 0x44, 0x00747201 }, { 0x48, 0x00747201 }, { 0x4c, 0x00747201 },
	{ 0x50, 0x007c7c01 }, { 0x54, 0x007c7c01 }, { 0x58, 0x007c7c01 }, { 0x5c, 0x006c6901 },
	{ 0x60, 0x007c7c01 }, { 0x64, 0x00797901 }, { 0x68, 0x00797901 }, { 0x6c, 0x007c7c01 },
	{ 0x70, 0x006c6901 }, { 0x74, 0x00797901 }, { 0x78, 0x00797901 }, { 0x7c, 0x00797901 },
};
static_assert(ARRAY_SIZE(j96gb_bridge10) == 1);
static_assert(ARRAY_SIZE(j96gb_bridge11) == 32);

static const u32 j96gb_fndr_regs[J96GB_NREGS] = {
	FNDR_SLEEP_CONTROL, FNDR_KICK_STATUS, FNDR_INT_ENABLE, FNDR_INT_STATUS,
	FNDR_PERF_CONTROL, FNDR_PERF_NEXT, FNDR_PERF_OVERRIDE,
};

struct j96gb_sample {
	u32 ps;
	u32 f[J96GB_NREGS];
};

struct j96_gpubridge {
	struct device *dev;
	struct regmap *pmgr;
	void __iomem *rgx;
	void __iomem *fndr;
	void __iomem *bridge10;
	void __iomem *bridge11;
	struct mutex lock;
	bool boot_off;
};

/* Each token at most once per module load, even across unbind/rebind. */
static atomic_t j96gb_used[ARRAY_SIZE(j96gb_tokens)];

/* Say what is about to happen, and give the console time to show it. */
#define J96GB_ANNOUNCE(gb, fmt, ...) do {						\
	dev_emerg((gb)->dev, "J96GB_NEXT " fmt "\n", ##__VA_ARGS__);			\
	msleep(300);									\
} while (0)

/* As apple_pmgr_ps_set(): keep other bits, clear auto-enable and the was-gated flags. */
static int j96gb_ps_set(struct j96_gpubridge *gb, u32 pstate)
{
	u32 v;
	int ret;

	J96GB_ANNOUNCE(gb, "pmgr ps_gfx set target 0x%x and poll", pstate);
	ret = regmap_read(gb->pmgr, J96GB_PS_GFX, &v);
	if (ret)
		return ret;
	v &= ~(J96GB_PS_AUTO_ENABLE | J96GB_PS_FLAGS | J96GB_PS_TARGET);
	v |= FIELD_PREP(J96GB_PS_TARGET, pstate);
	ret = regmap_write(gb->pmgr, J96GB_PS_GFX, v);
	if (ret)
		return ret;
	ret = regmap_read_poll_timeout(gb->pmgr, J96GB_PS_GFX, v,
				       FIELD_GET(J96GB_PS_ACTUAL, v) == pstate, 10, J96GB_POLL_US);
	dev_emerg(gb->dev, "J96GB_PS gfx target 0x%x -> reg 0x%08x%s\n", pstate, v,
		  ret ? " (TIMEOUT)" : "");
	return ret;
}

/* True while ps_gfx reads target and actual 0xf: the only state in which GFX MMIO is touched. */
static bool j96gb_ps_is_on(struct j96_gpubridge *gb, const char *before)
{
	u32 v = 0;

	if (!regmap_read(gb->pmgr, J96GB_PS_GFX, &v) &&
	    FIELD_GET(J96GB_PS_ACTUAL, v) == J96GB_PS_ACTIVE &&
	    FIELD_GET(J96GB_PS_TARGET, v) == J96GB_PS_ACTIVE)
		return true;
	dev_emerg(gb->dev, "J96GB_ABORT ps_gfx reads 0x%08x before %s; no access\n", v, before);
	return false;
}

/* True if Fender shows no pending transition: checked right before every Fender write. */
static bool j96gb_fender_idle(struct j96_gpubridge *gb, const char *before)
{
	u32 v = readl(gb->fndr + FNDR_PERF_CONTROL);

	if (v != 0xffffffff && !(v & FNDR_PERF_PENDING))
		return true;
	dev_emerg(gb->dev, "J96GB_ABORT Fender perf=0x%08x before %s; no Fender write\n", v, before);
	return false;
}

/*
 * The iOS bridge apply for one bridge: plain 32-bit writes at base + offset, in list order.
 * ps_gfx is checked after every announce pause, right before the write(s) that follow it.
 */
static int j96gb_bridge_apply(struct j96_gpubridge *gb, int bridge, void __iomem *base,
			      const struct j96gb_pair *p, int n, bool each)
{
	int i;

	if (!each) {
		J96GB_ANNOUNCE(gb, "write the %d bridge %d register(s), no pauses", n, bridge);
		if (!j96gb_ps_is_on(gb, "the bridge writes"))
			return -EIO;
	}
	for (i = 0; i < n; i++) {
		if (each) {
			J96GB_ANNOUNCE(gb, "write bridge %d +0x%02x = 0x%08x", bridge, p[i].off,
				       p[i].val);
			if (!j96gb_ps_is_on(gb, "a bridge write"))
				return -EIO;
		}
		writel(p[i].val, base + p[i].off);
	}
	dev_emerg(gb->dev, "J96GB_BRIDGE %d: %d write(s) done\n", bridge, n);
	return 0;
}

/* The seven Fender registers of the iOS state dump (all proven readable at GPC 0 and 1). */
static void j96gb_capture(struct j96_gpubridge *gb, struct j96gb_sample *s)
{
	int i;

	for (i = 0; i < J96GB_NREGS; i++)
		s->f[i] = readl(gb->fndr + j96gb_fndr_regs[i]);
	s->ps = 0xdeaddead;
	regmap_read(gb->pmgr, J96GB_PS_GFX, &s->ps);
}

static void j96gb_print(struct j96_gpubridge *gb, const char *when, const struct j96gb_sample *s)
{
	dev_emerg(gb->dev,
		  "J96GB_DUMP %s ps=%08x sleep=%08x kick=%08x inten=%08x intst=%08x perf=%08x next=%08x ovr=%08x\n",
		  when, s->ps, s->f[0], s->f[1], s->f[2], s->f[3], s->f[4], s->f[5], s->f[6]);
}

static void j96gb_dump(struct j96_gpubridge *gb, const char *when)
{
	struct j96gb_sample s;

	j96gb_capture(gb, &s);
	j96gb_print(gb, when, &s);
}

static void j96gb_print_id(struct j96_gpubridge *gb, u32 rev, u32 id, u32 perf)
{
	struct device *dev = gb->dev;

	dev_emerg(dev, "J96GB_ID core_revision=0x%08x core_id=0x%08x (gpc1 perf=%08x)\n", rev, id,
		  perf);
	if ((rev & 0xff0000) == 0x30000 &&
	    (FIELD_GET(GENMASK(15, 8), rev) == 0x8 || FIELD_GET(GENMASK(15, 8), rev) == 0xa) &&
	    FIELD_GET(GENMASK(15, 8), id))
		dev_emerg(dev, "J96GB_ID_OK G4P %s, %lu cores (iOS AGXG4P acceptance)\n",
			  FIELD_GET(GENMASK(15, 8), rev) == 0xa ? "B1" : "B0",
			  FIELD_GET(GENMASK(15, 8), id));
	else
		dev_emerg(dev, "J96GB_ID_UNEXPECTED values outside iOS AGXG4P acceptance\n");
}

static int j96gb_wait_not_pending(struct j96_gpubridge *gb, u32 *v)
{
	return readl_poll_timeout(gb->fndr + FNDR_PERF_CONTROL, *v, !(*v & FNDR_PERF_PENDING),
				  10, J96GB_POLL_US);
}

static int j96gb_run(struct j96_gpubridge *gb, int mode)
{
	struct device *dev = gb->dev;
	bool each = mode == J96GB_WRITE;
	u32 v, rev, id, ps = 0xdeaddead;
	int ret;

	dev_emerg(dev, "J96GB_BEGIN %s\n", j96gb_tokens[mode]);
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto ps_off;

	/* iOS order: right after the device reaches 0xf, its bridges in device-entry order. */
	ret = j96gb_bridge_apply(gb, 10, gb->bridge10, j96gb_bridge10,
				 ARRAY_SIZE(j96gb_bridge10), each);
	if (ret)
		goto ps_off;
	ret = j96gb_bridge_apply(gb, 11, gb->bridge11, j96gb_bridge11,
				 ARRAY_SIZE(j96gb_bridge11), each);
	if (ret || mode == J96GB_WRITE)
		goto ps_off;

	/* From here on: stage 4 of the built-in probe. */
	J96GB_ANNOUNCE(gb, "read Fender+0x1000 (perf)");
	if (!j96gb_ps_is_on(gb, "the first Fender read")) {
		ret = -EIO;
		goto ps_off;
	}
	v = readl(gb->fndr + FNDR_PERF_CONTROL);
	dev_emerg(dev, "J96GB_FENDER powered perf=%08x\n", v);
	if (v == 0xffffffff) {
		dev_emerg(dev, "J96GB_ABORT Fender reads all-ones\n");
		ret = -EIO;
		goto ps_off;
	}
	if (v & FNDR_PERF_PENDING && j96gb_wait_not_pending(gb, &v)) {
		dev_emerg(dev, "J96GB_ABORT Fender transition pending at start (0x%08x)\n", v);
		ret = -ETIMEDOUT;
		goto ps_off;
	}
	J96GB_ANNOUNCE(gb, "dump A: ps_gfx and the seven Fender status registers");
	if (!j96gb_ps_is_on(gb, "dump A")) {
		ret = -EIO;
		goto ps_off;
	}
	j96gb_dump(gb, "A-bridged");

	/*
	 * Each Fender write: announce, then check ps_gfx and Fender's pending bit, then write.
	 * Never write Fender while a transition is pending.
	 */
	J96GB_ANNOUNCE(gb, "write Fender+0x10000 = 0x%08x", FNDR_SEQ_END);
	if (!j96gb_ps_is_on(gb, "the sequencer write") ||
	    !j96gb_fender_idle(gb, "the sequencer write")) {
		ret = -EIO;
		goto ps_off;
	}
	writel(FNDR_SEQ_END, gb->fndr + FNDR_SEQ_PROGRAM);
	J96GB_ANNOUNCE(gb, "write Fender+0x0 = 0x%08x", FNDR_SLEEP_RUN);
	if (!j96gb_ps_is_on(gb, "the sleep-control write") ||
	    !j96gb_fender_idle(gb, "the sleep-control write")) {
		ret = -EIO;
		goto ps_off;
	}
	writel(FNDR_SLEEP_RUN, gb->fndr + FNDR_SLEEP_CONTROL);
	J96GB_ANNOUNCE(gb, "write Fender+0x1000 = 0x11 and poll bit 4, then at once read RGX+0x20 and RGX+0x18");
	if (!j96gb_ps_is_on(gb, "the GPC 1 write") || !j96gb_fender_idle(gb, "the GPC 1 write")) {
		ret = -EIO;
		goto ps_off;
	}
	writel(FNDR_PERF_PENDING | 1, gb->fndr + FNDR_PERF_CONTROL);
	ret = j96gb_wait_not_pending(gb, &v);
	if (ret) {
		/* iOS never writes Fender while a transition is pending: only drop the domain. */
		regmap_read(gb->pmgr, J96GB_PS_GFX, &ps);
		dev_emerg(dev, "J96GB_ABORT GPC state 1 did not complete (perf=0x%08x ps=0x%08x)\n",
			  v, ps);
		goto ps_off;
	}
	if (FIELD_GET(FNDR_PERF_STATE, v) != 1) {
		dev_emerg(dev, "J96GB_ABORT GPC state is %lu, not 1 (perf=0x%08x); no RGX access\n",
			  FIELD_GET(FNDR_PERF_STATE, v), v);
		ret = -EIO;
		goto gpc_off;
	}
	/*
	 * As iOS: the identity reads follow the poll after 10 us, with nothing printed in
	 * between. A hang with the "0x11" announce as the last line on screen is the RGX read.
	 */
	udelay(10);

	rev = readl(gb->rgx + RGX_CORE_REVISION);
	id = readl(gb->rgx + RGX_CORE_ID);
	j96gb_print_id(gb, rev, id, v);
	j96gb_dump(gb, "B-after-id");

gpc_off:
	/* Never write Fender while a transition is pending: check again right before the write. */
	J96GB_ANNOUNCE(gb, "read Fender+0x1000, then write 0x10 and poll bit 4");
	if (!j96gb_ps_is_on(gb, "the GPC 0 write")) {
		if (!ret)
			ret = -EIO;
		goto ps_off;
	}
	v = readl(gb->fndr + FNDR_PERF_CONTROL);
	if (v & FNDR_PERF_PENDING && j96gb_wait_not_pending(gb, &v)) {
		dev_emerg(dev, "J96GB_ABORT transition pending before GPC 0 (0x%08x); no Fender write\n",
			  v);
		if (!ret)
			ret = -ETIMEDOUT;
		goto ps_off;
	}
	writel(FNDR_PERF_PENDING | 0, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v) || FIELD_GET(FNDR_PERF_STATE, v) != 0) {
		dev_emerg(dev, "J96GB GPC state 0 not confirmed (0x%08x)\n", v);
		if (!ret)
			ret = -EIO;
	}
	j96gb_dump(gb, "G-gpc0");
ps_off:
	if (j96gb_ps_set(gb, J96GB_PS_PWRGATE)) {
		dev_emerg(dev, "J96GB ps_gfx did not report off\n");
		if (!ret)
			ret = -EIO;
	}
	dev_emerg(dev, "J96GB_STOP %s result=%d\n", j96gb_tokens[mode], ret);
	return ret;
}

/*
 * gpu-bridge-id-auto: the iOS-exact path. From the AUTO_ENABLE write to the GPC 0 write nothing
 * sleeps and nothing is printed (iOS has no pauses there, and with AUTO_ENABLE set the domain
 * may gate itself when idle); the results are printed afterwards. The ps_gfx and Fender-pending
 * checks stay, and print only when they abort.
 */
static int j96gb_run_auto(struct j96_gpubridge *gb)
{
	struct device *dev = gb->dev;
	struct j96gb_sample a, b, g;
	bool have_a = false, have_id = false, have_g = false, auto_set = false;
	u32 v, rev = 0, id = 0, perf1 = 0, ps_auto = 0xdeaddead;
	int i, ret;

	dev_emerg(dev, "J96GB_BEGIN %s\n", j96gb_tokens[J96GB_ID_AUTO]);
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto ps_off;
	J96GB_ANNOUNCE(gb, "AUTO_ENABLE, 33 bridge writes, 3 Fender writes, poll, read RGX+0x20 and RGX+0x18, GPC 0: no pauses, nothing printed until done");

	/* As ApplePMGR 0x66e42c0-0x66e435c: was-gated flags masked, bit 28 set, one write, no poll. */
	ret = regmap_read(gb->pmgr, J96GB_PS_GFX, &v);
	if (ret)
		goto ps_off;
	auto_set = true;
	ret = regmap_write(gb->pmgr, J96GB_PS_GFX, (v & ~J96GB_PS_FLAGS) | J96GB_PS_AUTO_ENABLE);
	if (ret)
		goto ps_off;

	ret = -EIO;
	if (!j96gb_ps_is_on(gb, "the bridge writes"))
		goto report;
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++)
		writel(j96gb_bridge10[i].val, gb->bridge10 + j96gb_bridge10[i].off);
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++)
		writel(j96gb_bridge11[i].val, gb->bridge11 + j96gb_bridge11[i].off);

	if (!j96gb_ps_is_on(gb, "the first Fender read"))
		goto report;
	j96gb_capture(gb, &a);
	have_a = true;
	ps_auto = a.ps;
	if (a.f[4] == 0xffffffff || a.f[4] & FNDR_PERF_PENDING) {
		dev_emerg(dev, "J96GB_ABORT Fender perf=0x%08x before the sequencer write; no Fender write\n",
			  a.f[4]);
		goto report;
	}
	writel(FNDR_SEQ_END, gb->fndr + FNDR_SEQ_PROGRAM);
	if (!j96gb_fender_idle(gb, "the sleep-control write"))
		goto report;
	writel(FNDR_SLEEP_RUN, gb->fndr + FNDR_SLEEP_CONTROL);
	if (!j96gb_fender_idle(gb, "the GPC 1 write"))
		goto report;
	writel(FNDR_PERF_PENDING | 1, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v)) {
		/* iOS never writes Fender while a transition is pending: only drop the domain. */
		dev_emerg(dev, "J96GB_ABORT GPC state 1 did not complete (perf=0x%08x)\n", v);
		ret = -ETIMEDOUT;
		goto report;
	}
	perf1 = v;
	if (FIELD_GET(FNDR_PERF_STATE, v) != 1) {
		dev_emerg(dev, "J96GB_ABORT GPC state is %lu, not 1 (perf=0x%08x); no RGX access\n",
			  FIELD_GET(FNDR_PERF_STATE, v), v);
		goto gpc_off;
	}
	if (!j96gb_ps_is_on(gb, "the RGX read"))
		goto report;
	udelay(10);

	rev = readl(gb->rgx + RGX_CORE_REVISION);
	id = readl(gb->rgx + RGX_CORE_ID);
	have_id = true;
	j96gb_capture(gb, &b);
	ret = 0;

gpc_off:
	if (!j96gb_ps_is_on(gb, "the GPC 0 write")) {
		if (!ret)
			ret = -EIO;
		goto report;
	}
	v = readl(gb->fndr + FNDR_PERF_CONTROL);
	if (v & FNDR_PERF_PENDING && j96gb_wait_not_pending(gb, &v)) {
		dev_emerg(dev, "J96GB_ABORT transition pending before GPC 0 (0x%08x); no Fender write\n",
			  v);
		if (!ret)
			ret = -ETIMEDOUT;
		goto report;
	}
	writel(FNDR_PERF_PENDING | 0, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v) || FIELD_GET(FNDR_PERF_STATE, v) != 0) {
		dev_emerg(dev, "J96GB GPC state 0 not confirmed (0x%08x)\n", v);
		if (!ret)
			ret = -EIO;
	}
	j96gb_capture(gb, &g);
	have_g = true;
report:
	dev_emerg(dev, "J96GB_PS gfx with auto-enable, after the bridge writes: reg 0x%08x\n", ps_auto);
	if (have_a)
		j96gb_print(gb, "A-bridged", &a);
	if (have_id) {
		j96gb_print_id(gb, rev, id, perf1);
		j96gb_print(gb, "B-after-id", &b);
	}
	if (have_g)
		j96gb_print(gb, "G-gpc0", &g);
ps_off:
	/* As iOS when bit 28 is set: first back to forced-on (clears bit 28, polls 0xf), then off. */
	if (auto_set && j96gb_ps_set(gb, J96GB_PS_ACTIVE))
		dev_emerg(dev, "J96GB ps_gfx did not return to forced-on\n");
	if (j96gb_ps_set(gb, J96GB_PS_PWRGATE)) {
		dev_emerg(dev, "J96GB ps_gfx did not report off\n");
		if (!ret)
			ret = -EIO;
	}
	dev_emerg(dev, "J96GB_STOP %s result=%d\n", j96gb_tokens[J96GB_ID_AUTO], ret);
	return ret;
}

/* Common tail: with @auto_set first back to forced-on (clears bit 28, polls 0xf), then off. */
static int j96gb_power_down(struct j96_gpubridge *gb, int mode, bool auto_set, int ret)
{
	if (auto_set && j96gb_ps_set(gb, J96GB_PS_ACTIVE))
		dev_emerg(gb->dev, "J96GB ps_gfx did not return to forced-on\n");
	if (j96gb_ps_set(gb, J96GB_PS_PWRGATE)) {
		dev_emerg(gb->dev, "J96GB ps_gfx did not report off\n");
		if (!ret)
			ret = -EIO;
	}
	dev_emerg(gb->dev, "J96GB_STOP %s result=%d\n", j96gb_tokens[mode], ret);
	return ret;
}

/*
 * gpu-ps-auto-watch: what does ps_gfx do under AUTO_ENABLE with nothing using the GPU?
 * PMGR accesses only (ps_gfx); no bridge, Fender or RGX access.
 */
static int j96gb_run_auto_watch(struct j96_gpubridge *gb)
{
	static const unsigned int at_us[] = { 0, 100, 1000, 10000, 100000, 1000000, 3000000 };
	struct device *dev = gb->dev;
	u32 v, ps[ARRAY_SIZE(at_us)];
	s64 us[ARRAY_SIZE(at_us)];
	bool auto_set = false;
	ktime_t t0;
	int i, ret;

	dev_emerg(dev, "J96GB_BEGIN %s\n", j96gb_tokens[J96GB_AUTO_WATCH]);
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto out;
	J96GB_ANNOUNCE(gb, "pmgr ps_gfx set AUTO_ENABLE (flags masked), then sample ps_gfx for 3 s; no GFX access");
	ret = regmap_read(gb->pmgr, J96GB_PS_GFX, &v);
	if (ret)
		goto out;
	auto_set = true;
	ret = regmap_write(gb->pmgr, J96GB_PS_GFX, (v & ~J96GB_PS_FLAGS) | J96GB_PS_AUTO_ENABLE);
	if (ret)
		goto out;
	t0 = ktime_get();
	for (i = 0; i < ARRAY_SIZE(at_us); i++) {
		s64 left = (s64)at_us[i] - ktime_us_delta(ktime_get(), t0);

		if (left >= 20000)
			msleep(left / 1000);
		else if (left > 0)
			usleep_range(left, left + left / 10 + 1);
		us[i] = ktime_us_delta(ktime_get(), t0);
		ps[i] = 0xdeaddead;
		regmap_read(gb->pmgr, J96GB_PS_GFX, &ps[i]);
	}
	for (i = 0; i < ARRAY_SIZE(at_us); i++)
		dev_emerg(dev, "J96GB_AUTO +%lldus ps=%08x (target %lx actual %lx)\n", us[i], ps[i],
			  FIELD_GET(J96GB_PS_TARGET, ps[i]), FIELD_GET(J96GB_PS_ACTUAL, ps[i]));
out:
	return j96gb_power_down(gb, J96GB_AUTO_WATCH, auto_set, ret);
}

/* One line per 8 registers: "J96GB_RB <when> b<bridge> +0x<first offset>: v v v ...". */
static void j96gb_rb_print(struct j96_gpubridge *gb, const char *when, int bridge,
			   const struct j96gb_pair *p, const u32 *vals, int n)
{
	char line[96];
	int i, len = 0;

	for (i = 0; i < n; i++) {
		len += scnprintf(line + len, sizeof(line) - len, " %08x", vals[i]);
		if ((i & 7) == 7 || i == n - 1) {
			dev_emerg(gb->dev, "J96GB_RB %s b%d +0x%02x:%s\n", when, bridge,
				  p[i & ~7].off, line);
			len = 0;
		}
	}
}

/*
 * gpu-bridge-readback: do the bridge writes take effect? Domain forced on. The first pass
 * announces every read (these registers have never been read; iOS does not read them).
 */
static int j96gb_run_readback(struct j96_gpubridge *gb)
{
	struct device *dev = gb->dev;
	u32 b10[2][ARRAY_SIZE(j96gb_bridge10)], b11[2][ARRAY_SIZE(j96gb_bridge11)];
	int i, match = 0, ret;

	dev_emerg(dev, "J96GB_BEGIN %s\n", j96gb_tokens[J96GB_READBACK]);
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto out;

	ret = -EIO;
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++) {
		J96GB_ANNOUNCE(gb, "read bridge 10 +0x%02x", j96gb_bridge10[i].off);
		if (!j96gb_ps_is_on(gb, "a bridge read"))
			goto out;
		b10[0][i] = readl(gb->bridge10 + j96gb_bridge10[i].off);
	}
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++) {
		J96GB_ANNOUNCE(gb, "read bridge 11 +0x%02x", j96gb_bridge11[i].off);
		if (!j96gb_ps_is_on(gb, "a bridge read"))
			goto out;
		b11[0][i] = readl(gb->bridge11 + j96gb_bridge11[i].off);
	}
	j96gb_rb_print(gb, "before", 10, j96gb_bridge10, b10[0], ARRAY_SIZE(j96gb_bridge10));
	j96gb_rb_print(gb, "before", 11, j96gb_bridge11, b11[0], ARRAY_SIZE(j96gb_bridge11));

	J96GB_ANNOUNCE(gb, "write the 33 bridge registers, no pauses, then read them back");
	if (!j96gb_ps_is_on(gb, "the bridge writes"))
		goto out;
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++)
		writel(j96gb_bridge10[i].val, gb->bridge10 + j96gb_bridge10[i].off);
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++)
		writel(j96gb_bridge11[i].val, gb->bridge11 + j96gb_bridge11[i].off);
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++) {
		b10[1][i] = readl(gb->bridge10 + j96gb_bridge10[i].off);
		match += b10[1][i] == j96gb_bridge10[i].val;
	}
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++) {
		b11[1][i] = readl(gb->bridge11 + j96gb_bridge11[i].off);
		match += b11[1][i] == j96gb_bridge11[i].val;
	}
	j96gb_rb_print(gb, "after", 10, j96gb_bridge10, b10[1], ARRAY_SIZE(j96gb_bridge10));
	j96gb_rb_print(gb, "after", 11, j96gb_bridge11, b11[1], ARRAY_SIZE(j96gb_bridge11));
	dev_emerg(dev, "J96GB_RB %d of 33 registers read back the written value\n", match);
	ret = 0;
out:
	return j96gb_power_down(gb, J96GB_READBACK, false, ret);
}

/* Fender ranges for gpu-fender-scan: start offset and number of 32-bit registers (multiples of 8). */
static const struct {
	u32 start;
	u32 count;
} j96gb_scan_ranges[] = {
	/* Ranges the iOS host driver touches first; the firmware-only ones last. */
	{ 0x0, 16 }, { 0x1000, 128 }, { 0x20000, 16 }, { 0x10000, 8 },
	{ 0x2000, 16 }, { 0x3000, 16 }, { 0x4000, 16 },
};

/* One scan: every range, eight registers per announce, printed as soon as they are read. */
static int j96gb_fender_scan(struct j96_gpubridge *gb, const char *when)
{
	u32 v[8], any;
	int r, i, j;

	for (r = 0; r < ARRAY_SIZE(j96gb_scan_ranges); r++) {
		for (i = 0; i < j96gb_scan_ranges[r].count; i += 8) {
			u32 off = j96gb_scan_ranges[r].start + i * 4;

			if (WARN_ON(off + 0x20 > FNDR_SIZE))
				return -EINVAL;
			J96GB_ANNOUNCE(gb, "scan %s: read Fender+0x%05x..+0x%05x", when, off,
				       off + 0x1c);
			if (!j96gb_ps_is_on(gb, "a Fender scan read"))
				return -EIO;
			for (j = 0, any = 0; j < 8; j++) {
				v[j] = readl(gb->fndr + off + j * 4);
				any |= v[j];
			}
			if (any)
				dev_emerg(gb->dev,
					  "J96GB_FS %s +0x%05x: %08x %08x %08x %08x %08x %08x %08x %08x\n",
					  when, off, v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7]);
			else
				dev_emerg(gb->dev, "J96GB_FS %s +0x%05x: all 8 zero\n", when, off);
		}
	}
	return 0;
}

/*
 * gpu-fender-scan: look for a per-state clock/voltage table in Fender, before any Fender write
 * and again at GPC 1. Bridges are configured first so the state matches the frozen id runs.
 * No RGX access.
 */
static int j96gb_run_fender_scan(struct j96_gpubridge *gb)
{
	struct device *dev = gb->dev;
	u32 v;
	int i, ret;

	dev_emerg(dev, "J96GB_BEGIN %s (no RGX access)\n", j96gb_tokens[J96GB_FENDER_SCAN]);
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto out;
	J96GB_ANNOUNCE(gb, "write the 33 bridge registers, no pauses");
	ret = -EIO;
	if (!j96gb_ps_is_on(gb, "the bridge writes"))
		goto out;
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++)
		writel(j96gb_bridge10[i].val, gb->bridge10 + j96gb_bridge10[i].off);
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++)
		writel(j96gb_bridge11[i].val, gb->bridge11 + j96gb_bridge11[i].off);

	ret = j96gb_fender_scan(gb, "A-powered");
	if (ret)
		goto out;
	/* Scan B scrolls scan A off the screen: time to photograph it (the domain is forced on). */
	dev_emerg(dev, "J96GB_NEXT scan A done: PHOTOGRAPH THE SCREEN NOW, 12 s pause\n");
	msleep(12000);

	ret = -EIO;
	J96GB_ANNOUNCE(gb, "write Fender+0x10000 = 0x%08x", FNDR_SEQ_END);
	if (!j96gb_ps_is_on(gb, "the sequencer write") ||
	    !j96gb_fender_idle(gb, "the sequencer write"))
		goto out;
	writel(FNDR_SEQ_END, gb->fndr + FNDR_SEQ_PROGRAM);
	J96GB_ANNOUNCE(gb, "write Fender+0x0 = 0x%08x", FNDR_SLEEP_RUN);
	if (!j96gb_ps_is_on(gb, "the sleep-control write") ||
	    !j96gb_fender_idle(gb, "the sleep-control write"))
		goto out;
	writel(FNDR_SLEEP_RUN, gb->fndr + FNDR_SLEEP_CONTROL);
	J96GB_ANNOUNCE(gb, "write Fender+0x1000 = 0x11 and poll bit 4");
	if (!j96gb_ps_is_on(gb, "the GPC 1 write") || !j96gb_fender_idle(gb, "the GPC 1 write"))
		goto out;
	writel(FNDR_PERF_PENDING | 1, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v)) {
		/* iOS never writes Fender while a transition is pending: only drop the domain. */
		dev_emerg(dev, "J96GB_ABORT GPC state 1 did not complete (perf=0x%08x)\n", v);
		ret = -ETIMEDOUT;
		goto out;
	}
	dev_emerg(dev, "J96GB_GPC perf=%08x after the state 1 request\n", v);
	if (FIELD_GET(FNDR_PERF_STATE, v) == 1)
		ret = j96gb_fender_scan(gb, "B-gpc1");

	/* Never write Fender while a transition is pending: check again right before the write. */
	J96GB_ANNOUNCE(gb, "read Fender+0x1000, then write 0x10 and poll bit 4");
	if (!j96gb_ps_is_on(gb, "the GPC 0 write")) {
		if (!ret)
			ret = -EIO;
		goto out;
	}
	v = readl(gb->fndr + FNDR_PERF_CONTROL);
	if (v & FNDR_PERF_PENDING && j96gb_wait_not_pending(gb, &v)) {
		dev_emerg(dev, "J96GB_ABORT transition pending before GPC 0 (0x%08x); no Fender write\n",
			  v);
		if (!ret)
			ret = -ETIMEDOUT;
		goto out;
	}
	writel(FNDR_PERF_PENDING | 0, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v) || FIELD_GET(FNDR_PERF_STATE, v) != 0) {
		dev_emerg(dev, "J96GB GPC state 0 not confirmed (0x%08x)\n", v);
		if (!ret)
			ret = -EIO;
	}
out:
	return j96gb_power_down(gb, J96GB_FENDER_SCAN, false, ret);
}

/* PMGR words for gpu-pmgr-clock-snapshot (offsets in the pmgr syscon, size 0x24000). */
#define J96GB_PERF_SLOTS	0x1c000
#define J96GB_PERF_NSLOTS	16
#define J96GB_PERF_CTRL0	0x1c200
#define J96GB_PERF_CTRL1	0x1c300
#define J96GB_CLK_PAGES		6

struct j96gb_clock_snap {
	u32 ps;
	u32 slot[J96GB_PERF_NSLOTS][2];
	u32 ctrl[2];
	u32 page[J96GB_CLK_PAGES][3];
};

static int j96gb_pmgr_rd(struct j96_gpubridge *gb, u32 off, u32 *v)
{
	*v = 0xdeaddead;
	return regmap_read(gb->pmgr, off, v);
}

/* Read and print one snapshot; every PMGR group is announced before it is read. */
static int j96gb_clock_snapshot(struct j96_gpubridge *gb, const char *when, bool announce)
{
	struct j96gb_clock_snap c;
	int i, ret = 0;

	/* Page 5 first: in the post-poll snapshot it is then the closest sample to the poll. */
	if (announce)
		J96GB_ANNOUNCE(gb, "snap %s: read pmgr clock page 5 +0x5000, +0x5004, +0x5008", when);
	ret |= j96gb_pmgr_rd(gb, 5 * 0x1000, &c.page[5][0]);
	ret |= j96gb_pmgr_rd(gb, 5 * 0x1000 + 4, &c.page[5][1]);
	ret |= j96gb_pmgr_rd(gb, 5 * 0x1000 + 8, &c.page[5][2]);
	if (announce)
		J96GB_ANNOUNCE(gb, "snap %s: read pmgr GFX perf slots +0x1c000..+0x1c0f4", when);
	for (i = 0; i < J96GB_PERF_NSLOTS; i++) {
		ret |= j96gb_pmgr_rd(gb, J96GB_PERF_SLOTS + i * 0x10, &c.slot[i][0]);
		ret |= j96gb_pmgr_rd(gb, J96GB_PERF_SLOTS + i * 0x10 + 4, &c.slot[i][1]);
	}
	if (announce)
		J96GB_ANNOUNCE(gb, "snap %s: read pmgr +0x1c200, +0x1c300", when);
	ret |= j96gb_pmgr_rd(gb, J96GB_PERF_CTRL0, &c.ctrl[0]);
	ret |= j96gb_pmgr_rd(gb, J96GB_PERF_CTRL1, &c.ctrl[1]);
	for (i = 0; i < J96GB_CLK_PAGES - 1; i++) {
		if (announce)
			J96GB_ANNOUNCE(gb, "snap %s: read pmgr clock page %d +0x%x (+0, +4, +8)", when, i,
				       i * 0x1000);
		ret |= j96gb_pmgr_rd(gb, i * 0x1000, &c.page[i][0]);
		ret |= j96gb_pmgr_rd(gb, i * 0x1000 + 4, &c.page[i][1]);
		ret |= j96gb_pmgr_rd(gb, i * 0x1000 + 8, &c.page[i][2]);
	}
	ret |= j96gb_pmgr_rd(gb, J96GB_PS_GFX, &c.ps);

	dev_emerg(gb->dev, "J96GB_CS %s ps=%08x ctrl=%08x %08x\n", when, c.ps, c.ctrl[0], c.ctrl[1]);
	for (i = 0; i < J96GB_CLK_PAGES; i++)
		dev_emerg(gb->dev, "J96GB_CS %s page%d +0=%08x +4=%08x +8=%08x\n", when, i,
			  c.page[i][0], c.page[i][1], c.page[i][2]);
	for (i = 0; i < J96GB_PERF_NSLOTS; i += 4)
		dev_emerg(gb->dev,
			  "J96GB_CS %s slot%02d-%02d: %08x/%08x %08x/%08x %08x/%08x %08x/%08x\n",
			  when, i, i + 3, c.slot[i][0], c.slot[i][1], c.slot[i + 1][0], c.slot[i + 1][1],
			  c.slot[i + 2][0], c.slot[i + 2][1], c.slot[i + 3][0], c.slot[i + 3][1]);
	if (ret)
		dev_emerg(gb->dev, "J96GB_CS %s: a regmap read failed (%d)\n", when, ret);
	return ret ? -EIO : 0;
}

/*
 * gpu-pmgr-clock-snapshot: compare the J96's PMGR clock words with J81's, around the GFX power-on
 * and the GPC 0 -> 1 transition. Fender and bridges exactly as gpu-fender-scan; no RGX access.
 */
static int j96gb_run_clock_snap(struct j96_gpubridge *gb)
{
	struct device *dev = gb->dev;
	u32 v;
	int i, ret;

	dev_emerg(dev, "J96GB_BEGIN %s (PMGR reads; no RGX access)\n", j96gb_tokens[J96GB_CLOCK_SNAP]);
	ret = j96gb_clock_snapshot(gb, "0-gfx-off", true);
	if (ret)
		goto out;
	ret = j96gb_ps_set(gb, J96GB_PS_ACTIVE);
	if (ret)
		goto out;
	ret = j96gb_clock_snapshot(gb, "1-ps-on", false);
	if (ret)
		goto out;

	J96GB_ANNOUNCE(gb, "write the 33 bridge registers, no pauses");
	ret = -EIO;
	if (!j96gb_ps_is_on(gb, "the bridge writes"))
		goto out;
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge10); i++)
		writel(j96gb_bridge10[i].val, gb->bridge10 + j96gb_bridge10[i].off);
	for (i = 0; i < ARRAY_SIZE(j96gb_bridge11); i++)
		writel(j96gb_bridge11[i].val, gb->bridge11 + j96gb_bridge11[i].off);
	ret = j96gb_clock_snapshot(gb, "2-bridged", false);
	if (ret)
		goto out;

	ret = -EIO;
	J96GB_ANNOUNCE(gb, "write Fender+0x10000 = 0x%08x", FNDR_SEQ_END);
	if (!j96gb_ps_is_on(gb, "the sequencer write") ||
	    !j96gb_fender_idle(gb, "the sequencer write"))
		goto out;
	writel(FNDR_SEQ_END, gb->fndr + FNDR_SEQ_PROGRAM);
	J96GB_ANNOUNCE(gb, "write Fender+0x0 = 0x%08x", FNDR_SLEEP_RUN);
	if (!j96gb_ps_is_on(gb, "the sleep-control write") ||
	    !j96gb_fender_idle(gb, "the sleep-control write"))
		goto out;
	writel(FNDR_SLEEP_RUN, gb->fndr + FNDR_SLEEP_CONTROL);
	J96GB_ANNOUNCE(gb, "write Fender+0x1000 = 0x11 and poll bit 4, then snapshot at once");
	if (!j96gb_ps_is_on(gb, "the GPC 1 write") || !j96gb_fender_idle(gb, "the GPC 1 write"))
		goto out;
	writel(FNDR_PERF_PENDING | 1, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v)) {
		/* iOS never writes Fender while a transition is pending: only drop the domain. */
		dev_emerg(dev, "J96GB_ABORT GPC state 1 did not complete (perf=0x%08x)\n", v);
		ret = -ETIMEDOUT;
		goto out;
	}
	/* The PMGR snapshot right after the poll, as J81's iPadOS capture did. */
	ret = j96gb_clock_snapshot(gb, "3-gpc1", false);
	dev_emerg(dev, "J96GB_GPC perf=%08x after the state 1 request\n", v);
	if (!ret && FIELD_GET(FNDR_PERF_STATE, v) == 1) {
		msleep(1000);
		ret = j96gb_clock_snapshot(gb, "4-gpc1+1s", false);
	}

	/* Never write Fender while a transition is pending: check again right before the write. */
	J96GB_ANNOUNCE(gb, "read Fender+0x1000, then write 0x10 and poll bit 4");
	if (!j96gb_ps_is_on(gb, "the GPC 0 write")) {
		if (!ret)
			ret = -EIO;
		goto out;
	}
	v = readl(gb->fndr + FNDR_PERF_CONTROL);
	if (v & FNDR_PERF_PENDING && j96gb_wait_not_pending(gb, &v)) {
		dev_emerg(dev, "J96GB_ABORT transition pending before GPC 0 (0x%08x); no Fender write\n",
			  v);
		if (!ret)
			ret = -ETIMEDOUT;
		goto out;
	}
	writel(FNDR_PERF_PENDING | 0, gb->fndr + FNDR_PERF_CONTROL);
	if (j96gb_wait_not_pending(gb, &v) || FIELD_GET(FNDR_PERF_STATE, v) != 0) {
		dev_emerg(dev, "J96GB GPC state 0 not confirmed (0x%08x)\n", v);
		if (!ret)
			ret = -EIO;
	}
	if (j96gb_clock_snapshot(gb, "5-gpc0", false) && !ret)
		ret = -EIO;
out:
	ret = j96gb_power_down(gb, J96GB_CLOCK_SNAP, false, ret);
	j96gb_clock_snapshot(gb, "6-ps-off", false);
	return ret;
}

static bool j96gb_ps_off(u32 v)
{
	return !FIELD_GET(J96GB_PS_TARGET, v) && !FIELD_GET(J96GB_PS_ACTUAL, v) &&
	       !(v & (J96GB_PS_RESET | J96GB_PS_DEV_DISABLE));
}

static ssize_t attempt_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct j96_gpubridge *gb = dev_get_drvdata(dev);
	int mode = 0;
	u32 v = 0;
	int ret;

	for (int i = 1; i < ARRAY_SIZE(j96gb_tokens); i++)
		if (sysfs_streq(buf, j96gb_tokens[i]))
			mode = i;
	if (!mode)
		return -EINVAL;
	mutex_lock(&gb->lock);
	ret = regmap_read(gb->pmgr, J96GB_PS_GFX, &v);
	if (ret || !gb->boot_off || !j96gb_ps_off(v)) {
		dev_err(dev, "J96GB_REFUSED ps_gfx not verified off (0x%08x)\n", v);
		ret = -EPERM;
	} else if (atomic_cmpxchg(&j96gb_used[mode], 0, 1)) {
		dev_err(dev, "J96GB_REFUSED %s already used on this load\n", j96gb_tokens[mode]);
		ret = -EPERM;
	} else {
		switch (mode) {
		case J96GB_ID_AUTO:
			ret = j96gb_run_auto(gb);
			break;
		case J96GB_READBACK:
			ret = j96gb_run_readback(gb);
			break;
		case J96GB_AUTO_WATCH:
			ret = j96gb_run_auto_watch(gb);
			break;
		case J96GB_FENDER_SCAN:
			ret = j96gb_run_fender_scan(gb);
			break;
		case J96GB_CLOCK_SNAP:
			ret = j96gb_run_clock_snap(gb);
			break;
		default:
			ret = j96gb_run(gb, mode);
		}
	}
	mutex_unlock(&gb->lock);
	return ret ? ret : count;
}

static ssize_t attempt_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct j96_gpubridge *gb = dev_get_drvdata(dev);
	int n = 0;

	if (!gb->boot_off)
		return sysfs_emit(buf, "refused-load-state\n");
	for (int i = 1; i < ARRAY_SIZE(j96gb_tokens); i++)
		n += sysfs_emit_at(buf, n, "%s %s\n", j96gb_tokens[i],
				   atomic_read(&j96gb_used[i]) ? "used" : "available");
	return n;
}
static DEVICE_ATTR_RW(attempt);

static struct attribute *j96gb_attrs[] = {
	&dev_attr_attempt.attr,
	NULL
};
ATTRIBUTE_GROUPS(j96gb);

/* Non-posted mapping of a window that is not in the device tree node. No hardware access. */
static void __iomem *j96gb_map(struct device *dev, resource_size_t pa, const char *name)
{
	struct resource res = {
		.start = pa,
		.end = pa + J96GB_BRIDGE_SIZE - 1,
		.name = name,
		.flags = IORESOURCE_MEM | IORESOURCE_MEM_NONPOSTED,
	};

	return devm_ioremap_resource(dev, &res);
}

static int j96gb_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct j96_gpubridge *gb;
	struct resource *res;
	u32 v = 0;
	int ret;

	if (!of_machine_is_compatible("apple,j96"))
		return -ENODEV;
	gb = devm_kzalloc(dev, sizeof(*gb), GFP_KERNEL);
	if (!gb)
		return -ENOMEM;
	gb->dev = dev;
	mutex_init(&gb->lock);

	gb->pmgr = syscon_regmap_lookup_by_phandle(dev->of_node, "apple,pmgr");
	if (IS_ERR(gb->pmgr))
		return dev_err_probe(dev, PTR_ERR(gb->pmgr), "pmgr syscon unavailable\n");

	/* Mapping does not access the hardware; size-checked against the M0 windows. */
	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "rgx");
	if (!res || res->start != 0x201000000ULL || resource_size(res) != RGX_SIZE)
		return dev_err_probe(dev, -EINVAL, "unexpected rgx window\n");
	gb->rgx = devm_ioremap_resource(dev, res);
	if (IS_ERR(gb->rgx))
		return PTR_ERR(gb->rgx);
	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "fender");
	if (!res || res->start != 0x201e00000ULL || resource_size(res) != FNDR_SIZE)
		return dev_err_probe(dev, -EINVAL, "unexpected fender window\n");
	gb->fndr = devm_ioremap_resource(dev, res);
	if (IS_ERR(gb->fndr))
		return PTR_ERR(gb->fndr);
	gb->bridge10 = j96gb_map(dev, J96GB_BRIDGE10_PA, "gfx-bridge10");
	if (IS_ERR(gb->bridge10))
		return PTR_ERR(gb->bridge10);
	gb->bridge11 = j96gb_map(dev, J96GB_BRIDGE11_PA, "gfx-bridge11");
	if (IS_ERR(gb->bridge11))
		return PTR_ERR(gb->bridge11);

	platform_set_drvdata(pdev, gb);
	ret = regmap_read(gb->pmgr, J96GB_PS_GFX, &v);
	gb->boot_off = !ret && j96gb_ps_off(v);
	dev_info(dev, "J96GB_READY ps_gfx=%s0x%08x; bridge probe %s (see 'attempt')\n",
		 ret ? "ERR " : "", v, gb->boot_off ? "available" : "refused: ps_gfx not off");
	return 0;
}

static const struct of_device_id j96gb_match[] = {
	{ .compatible = "apple,j96-gpuprobe" },
	{ }
};
MODULE_DEVICE_TABLE(of, j96gb_match);

static struct platform_driver j96gb_driver = {
	.probe = j96gb_probe,
	.driver = {
		.name = "apple-j96-gpubridge",
		.of_match_table = j96gb_match,
		.dev_groups = j96gb_groups,
	},
};
module_platform_driver(j96gb_driver);
MODULE_DESCRIPTION("J96 GPU bridge-settings and identity probe (bring-up, gated)");
MODULE_LICENSE("GPL");
