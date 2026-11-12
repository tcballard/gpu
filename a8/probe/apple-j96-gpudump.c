// SPDX-License-Identifier: GPL-2.0-only
/*
 * J96 (iPad mini 4, A8/t7000) GPU power-state dump: the stage after the built-in
 * apple-j96-gpuprobe (drivers/misc/apple-j96-gpuprobe.c). Not a GPU driver.
 *
 * Why: stage 4 of the built-in probe froze the SoC twice (3 and 8 Nov 2026) on its first RGX
 * read, RGX+0x20, 10 us after Fender reported GPC state 1 (gpu/m1-staged-20261103.log). Stage 3
 * (the same power-on and Fender GPC 1 without RGX) passes every time. So GPC 1 as Fender reports
 * it is not enough for the RGX CR window to answer. This module looks at what Fender and PMGR say
 * around that transition, and NEVER touches the RGX window (it does not even map it).
 *
 * Two tokens on the "attempt" attribute, each at most once per module load and only if ps_gfx
 * reads fully off. Both do:
 *
 *   ps_gfx on -> read Fender+0x1000 -> dump A (each register announced, before any write) ->
 *   Fender+0x10000 = 0xffff0000 -> Fender+0x0 = 0x40000000 -> Fender+0x1000 = 0x11, poll bit 4 ->
 *   dumps at GPC 1 (below) -> read Fender+0x1000 -> Fender+0x1000 = 0x10, poll bit 4 -> dump G ->
 *   ps_gfx off.
 *
 *   gpu-gpc1-dump-slow: at GPC 1 every register read is announced first (300 ms each), so a
 *     hang names the register. Only +0x1000 is known to be readable at GPC 1 (stage 3 polls
 *     it); the other six have never been read on this hardware in any state. Then dump F.
 *   gpu-gpc1-dump: at GPC 1 dumps B (at once, the moment stage 4 read RGX), C (+1 ms) and
 *     D (+10 ms) are read with nothing printed in between, then printed; then E (+100 ms) and
 *     F (+1 s). Each line carries the measured offset from GPC 1. A hang with the "0x11"
 *     announce as the last line on screen is one of the B/C/D reads.
 *
 * Every access is inside the envelope of M0-STATIC-RE.md section 4: Fender writes only the three
 * iOS probe writes and the iOS teardown write, never while a transition is pending; Fender reads
 * only the seven registers iOS's own state dump reads; PMGR only ps_gfx. No interrupt is
 * requested. All accesses are 32-bit on non-posted mappings (the soc bus has nonposted-mmio).
 * Every poll is bounded. Results are printed at KERN_EMERG so they reach the screen.
 *
 * ps_gfx is driven directly, behind genpd: safe only while no device tree node consumes
 * &ps_gfx (none does) and with pd_ignore_unused.
 *
 * Use (the built-in probe owns the node, so unbind it first; this driver then binds itself):
 *   echo 201000000.gpu-probe > /sys/bus/platform/drivers/apple-j96-gpuprobe/unbind
 *   insmod apple-j96-gpudump.ko
 *   echo gpu-gpc1-dump-slow > /sys/bus/platform/devices/201000000.gpu-probe/attempt
 */
#include <linux/atomic.h>
#include <linux/bitfield.h>
#include <linux/build_bug.h>
#include <linux/delay.h>
#include <linux/io.h>
#include <linux/iopoll.h>
#include <linux/kernel.h>
#include <linux/ktime.h>
#include <linux/mfd/syscon.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/platform_device.h>
#include <linux/regmap.h>
#include <linux/sysfs.h>

enum { J96GD_FAST = 1, J96GD_SLOW };
static const char *const j96gd_tokens[] = {
	[J96GD_FAST] = "gpu-gpc1-dump",
	[J96GD_SLOW] = "gpu-gpc1-dump-slow",
};

/* PMGR power-state register (drivers/pmdomain/apple/pmgr-pwrstate.c). */
#define J96GD_PS_GFX		0x20320
#define J96GD_PS_RESET		BIT(31)
#define J96GD_PS_AUTO_ENABLE	BIT(28)
#define J96GD_PS_DEV_DISABLE	BIT(10)
#define J96GD_PS_FLAGS		(BIT(9) | BIT(8))
#define J96GD_PS_ACTUAL		GENMASK(7, 4)
#define J96GD_PS_TARGET		GENMASK(3, 0)
#define J96GD_PS_ACTIVE		0xf
#define J96GD_PS_PWRGATE	0x0

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

#define J96GD_POLL_US		100000
#define J96GD_NREGS		7

static const struct {
	u32 off;
	const char *name;
} j96gd_fndr_regs[] = {
	{ FNDR_SLEEP_CONTROL, "sleep" },
	{ FNDR_KICK_STATUS, "kick" },
	{ FNDR_INT_ENABLE, "inten" },
	{ FNDR_INT_STATUS, "intst" },
	{ FNDR_PERF_CONTROL, "perf" },
	{ FNDR_PERF_NEXT, "next" },
	{ FNDR_PERF_OVERRIDE, "ovr" },
};
static_assert(ARRAY_SIZE(j96gd_fndr_regs) == J96GD_NREGS);

struct j96gd_sample {
	s64 us;		/* offset from GPC 1, or -1 when not timed */
	u32 ps;
	u32 f[J96GD_NREGS];
};

struct j96_gpudump {
	struct device *dev;
	struct regmap *pmgr;
	void __iomem *fndr;
	struct mutex lock;
	bool boot_off;
};

/* Each token at most once per module load, even across unbind/rebind. */
static atomic_t j96gd_used[ARRAY_SIZE(j96gd_tokens)];

/* Say what is about to happen, and give the console time to show it. */
#define J96GD_ANNOUNCE(gd, fmt, ...) do {						\
	dev_emerg((gd)->dev, "J96GD_NEXT " fmt "\n", ##__VA_ARGS__);			\
	msleep(300);									\
} while (0)

/* As apple_pmgr_ps_set(): keep other bits, clear auto-enable and the was-gated flags. */
static int j96gd_ps_set(struct j96_gpudump *gd, u32 pstate)
{
	u32 v;
	int ret;

	J96GD_ANNOUNCE(gd, "pmgr ps_gfx set target 0x%x and poll", pstate);
	ret = regmap_read(gd->pmgr, J96GD_PS_GFX, &v);
	if (ret)
		return ret;
	v &= ~(J96GD_PS_AUTO_ENABLE | J96GD_PS_FLAGS | J96GD_PS_TARGET);
	v |= FIELD_PREP(J96GD_PS_TARGET, pstate);
	ret = regmap_write(gd->pmgr, J96GD_PS_GFX, v);
	if (ret)
		return ret;
	ret = regmap_read_poll_timeout(gd->pmgr, J96GD_PS_GFX, v,
				       FIELD_GET(J96GD_PS_ACTUAL, v) == pstate, 10, J96GD_POLL_US);
	dev_emerg(gd->dev, "J96GD_PS gfx target 0x%x -> reg 0x%08x%s\n", pstate, v,
		  ret ? " (TIMEOUT)" : "");
	return ret;
}

/*
 * Read the seven Fender registers and ps_gfx into @s; nothing is printed unless @each, which
 * announces every Fender read on its own first so that a hang names the register.
 */
static void j96gd_capture(struct j96_gpudump *gd, struct j96gd_sample *s, const char *when,
			  ktime_t t0, bool timed, bool each)
{
	int i;

	/* An announced capture spans seconds, so it carries no single offset. */
	s->us = timed && !each ? ktime_us_delta(ktime_get(), t0) : -1;
	for (i = 0; i < J96GD_NREGS; i++) {
		if (each)
			J96GD_ANNOUNCE(gd, "dump %s: read Fender+0x%x (%s)", when,
				       j96gd_fndr_regs[i].off, j96gd_fndr_regs[i].name);
		s->f[i] = readl(gd->fndr + j96gd_fndr_regs[i].off);
	}
	s->ps = 0xdeaddead;
	regmap_read(gd->pmgr, J96GD_PS_GFX, &s->ps);
}

static void j96gd_print(struct j96_gpudump *gd, const char *when, const struct j96gd_sample *s)
{
	char t[24];

	if (s->us >= 0)
		scnprintf(t, sizeof(t), "+%lldus", s->us);
	else
		scnprintf(t, sizeof(t), "-");
	dev_emerg(gd->dev,
		  "J96GD_DUMP %s %s ps=%08x sleep=%08x kick=%08x inten=%08x intst=%08x perf=%08x next=%08x ovr=%08x\n",
		  when, t, s->ps, s->f[0], s->f[1], s->f[2], s->f[3], s->f[4], s->f[5], s->f[6]);
}

static int j96gd_wait_not_pending(struct j96_gpudump *gd, u32 *v)
{
	return readl_poll_timeout(gd->fndr + FNDR_PERF_CONTROL, *v, !(*v & FNDR_PERF_PENDING),
				  10, J96GD_POLL_US);
}

/* Sleep until @ms after @t0; returns at once if that has passed. */
static void j96gd_sleep_until(ktime_t t0, unsigned int ms)
{
	s64 left = (s64)ms - ktime_ms_delta(ktime_get(), t0);

	if (left > 0)
		msleep(left);
}

static int j96gd_run(struct j96_gpudump *gd, int mode)
{
	struct device *dev = gd->dev;
	bool slow = mode == J96GD_SLOW;
	struct j96gd_sample s[3];
	u32 v, ps = 0xdeaddead;
	ktime_t t0;
	int ret;

	dev_emerg(dev, "J96GD_BEGIN %s (no RGX access)\n", j96gd_tokens[mode]);
	ret = j96gd_ps_set(gd, J96GD_PS_ACTIVE);
	if (ret)
		goto ps_off;

	/* First the one Fender register stage 3 has already read while powered. */
	J96GD_ANNOUNCE(gd, "read Fender+0x1000 (perf)");
	v = readl(gd->fndr + FNDR_PERF_CONTROL);
	dev_emerg(dev, "J96GD_FENDER powered perf=%08x\n", v);
	if (v == 0xffffffff) {
		dev_emerg(dev, "J96GD_ABORT Fender reads all-ones\n");
		ret = -EIO;
		goto ps_off;
	}
	if (v & FNDR_PERF_PENDING && j96gd_wait_not_pending(gd, &v)) {
		dev_emerg(dev, "J96GD_ABORT Fender transition pending at start (0x%08x)\n", v);
		ret = -ETIMEDOUT;
		goto ps_off;
	}

	/* Every register of the iOS state dump, once, while powered and before any write. */
	j96gd_capture(gd, &s[0], "A", 0, false, true);
	j96gd_print(gd, "A-powered", &s[0]);
	/* Dump A took about 2 s: look at its +0x1000 value again right before the writes. */
	v = s[0].f[4];
	if (v == 0xffffffff || v & FNDR_PERF_PENDING) {
		dev_emerg(dev, "J96GD_ABORT Fender perf=0x%08x after dump A; no Fender write\n", v);
		ret = -EIO;
		goto ps_off;
	}

	/* iOS probe writes, as stage 3 of the built-in probe. */
	J96GD_ANNOUNCE(gd, "write Fender+0x10000 = 0x%08x", FNDR_SEQ_END);
	writel(FNDR_SEQ_END, gd->fndr + FNDR_SEQ_PROGRAM);
	J96GD_ANNOUNCE(gd, "write Fender+0x0 = 0x%08x", FNDR_SLEEP_RUN);
	writel(FNDR_SLEEP_RUN, gd->fndr + FNDR_SLEEP_CONTROL);
	J96GD_ANNOUNCE(gd, "write Fender+0x1000 = 0x11 and poll bit 4, then %s",
		       slow ? "read each register, announced" :
			      "read dumps B, C, D with nothing printed (a hang here is one of those reads)");
	writel(FNDR_PERF_PENDING | 1, gd->fndr + FNDR_PERF_CONTROL);
	ret = j96gd_wait_not_pending(gd, &v);
	if (ret) {
		/* iOS never writes Fender while a transition is pending: only drop the domain. */
		regmap_read(gd->pmgr, J96GD_PS_GFX, &ps);
		dev_emerg(dev, "J96GD_ABORT GPC state 1 did not complete (perf=0x%08x ps=0x%08x)\n",
			  v, ps);
		goto ps_off;
	}
	t0 = ktime_get();
	if (FIELD_GET(FNDR_PERF_STATE, v) != 1) {
		dev_emerg(dev, "J96GD_ABORT GPC state is %lu, not 1 (perf=0x%08x)\n",
			  FIELD_GET(FNDR_PERF_STATE, v), v);
		j96gd_capture(gd, &s[0], "X", t0, true, true);
		j96gd_print(gd, "X-not-gpc1", &s[0]);
		ret = -EIO;
		goto gpc_off;
	}

	if (slow) {
		j96gd_capture(gd, &s[0], "B", t0, true, true);
		j96gd_print(gd, "B-gpc1", &s[0]);
	} else {
		/* Nothing is printed between the poll and the end of dump D. */
		j96gd_capture(gd, &s[0], "B", t0, true, false);
		usleep_range(1000, 1100);
		j96gd_capture(gd, &s[1], "C", t0, true, false);
		usleep_range(9000, 9500);
		j96gd_capture(gd, &s[2], "D", t0, true, false);
		j96gd_print(gd, "B-gpc1", &s[0]);
		j96gd_print(gd, "C-gpc1", &s[1]);
		j96gd_print(gd, "D-gpc1", &s[2]);
		j96gd_sleep_until(t0, 100);
		j96gd_capture(gd, &s[0], "E", t0, true, false);
		j96gd_print(gd, "E-gpc1", &s[0]);
	}
	j96gd_sleep_until(t0, 1000);
	j96gd_capture(gd, &s[0], "F", t0, true, false);
	j96gd_print(gd, "F-gpc1", &s[0]);

gpc_off:
	/* Never write Fender while a transition is pending: check again right before the write. */
	J96GD_ANNOUNCE(gd, "read Fender+0x1000, then write 0x10 and poll bit 4");
	v = readl(gd->fndr + FNDR_PERF_CONTROL);
	if (v & FNDR_PERF_PENDING && j96gd_wait_not_pending(gd, &v)) {
		dev_emerg(dev, "J96GD_ABORT transition pending before GPC 0 (0x%08x); no Fender write\n",
			  v);
		if (!ret)
			ret = -ETIMEDOUT;
		goto ps_off;
	}
	writel(FNDR_PERF_PENDING | 0, gd->fndr + FNDR_PERF_CONTROL);
	if (j96gd_wait_not_pending(gd, &v) || FIELD_GET(FNDR_PERF_STATE, v) != 0) {
		dev_emerg(dev, "J96GD GPC state 0 not confirmed (0x%08x)\n", v);
		if (!ret)
			ret = -EIO;
	}
	j96gd_capture(gd, &s[0], "G", 0, false, false);
	j96gd_print(gd, "G-gpc0", &s[0]);
ps_off:
	if (j96gd_ps_set(gd, J96GD_PS_PWRGATE)) {
		dev_emerg(dev, "J96GD ps_gfx did not report off\n");
		if (!ret)
			ret = -EIO;
	}
	dev_emerg(dev, "J96GD_STOP %s result=%d\n", j96gd_tokens[mode], ret);
	return ret;
}

static bool j96gd_ps_off(u32 v)
{
	return !FIELD_GET(J96GD_PS_TARGET, v) && !FIELD_GET(J96GD_PS_ACTUAL, v) &&
	       !(v & (J96GD_PS_RESET | J96GD_PS_DEV_DISABLE));
}

static ssize_t attempt_store(struct device *dev, struct device_attribute *attr,
			     const char *buf, size_t count)
{
	struct j96_gpudump *gd = dev_get_drvdata(dev);
	int mode = 0;
	u32 v = 0;
	int ret;

	for (int i = 1; i < ARRAY_SIZE(j96gd_tokens); i++)
		if (sysfs_streq(buf, j96gd_tokens[i]))
			mode = i;
	if (!mode)
		return -EINVAL;
	mutex_lock(&gd->lock);
	ret = regmap_read(gd->pmgr, J96GD_PS_GFX, &v);
	if (ret || !gd->boot_off || !j96gd_ps_off(v)) {
		dev_err(dev, "J96GD_REFUSED ps_gfx not verified off (0x%08x)\n", v);
		ret = -EPERM;
	} else if (atomic_cmpxchg(&j96gd_used[mode], 0, 1)) {
		dev_err(dev, "J96GD_REFUSED %s already used on this load\n", j96gd_tokens[mode]);
		ret = -EPERM;
	} else {
		ret = j96gd_run(gd, mode);
	}
	mutex_unlock(&gd->lock);
	return ret ? ret : count;
}

static ssize_t attempt_show(struct device *dev, struct device_attribute *attr, char *buf)
{
	struct j96_gpudump *gd = dev_get_drvdata(dev);
	int n = 0;

	if (!gd->boot_off)
		return sysfs_emit(buf, "refused-load-state\n");
	for (int i = 1; i < ARRAY_SIZE(j96gd_tokens); i++)
		n += sysfs_emit_at(buf, n, "%s %s\n", j96gd_tokens[i],
				   atomic_read(&j96gd_used[i]) ? "used" : "available");
	return n;
}
static DEVICE_ATTR_RW(attempt);

static struct attribute *j96gd_attrs[] = {
	&dev_attr_attempt.attr,
	NULL
};
ATTRIBUTE_GROUPS(j96gd);

static int j96gd_probe(struct platform_device *pdev)
{
	struct device *dev = &pdev->dev;
	struct j96_gpudump *gd;
	struct resource *res;
	u32 v = 0;
	int ret;

	if (!of_machine_is_compatible("apple,j96"))
		return -ENODEV;
	gd = devm_kzalloc(dev, sizeof(*gd), GFP_KERNEL);
	if (!gd)
		return -ENOMEM;
	gd->dev = dev;
	mutex_init(&gd->lock);

	gd->pmgr = syscon_regmap_lookup_by_phandle(dev->of_node, "apple,pmgr");
	if (IS_ERR(gd->pmgr))
		return dev_err_probe(dev, PTR_ERR(gd->pmgr), "pmgr syscon unavailable\n");

	/* Only Fender is mapped; the RGX window is deliberately left alone. */
	res = platform_get_resource_byname(pdev, IORESOURCE_MEM, "fender");
	if (!res || res->start != 0x201e00000ULL || resource_size(res) != FNDR_SIZE)
		return dev_err_probe(dev, -EINVAL, "unexpected fender window\n");
	gd->fndr = devm_ioremap_resource(dev, res);
	if (IS_ERR(gd->fndr))
		return PTR_ERR(gd->fndr);

	platform_set_drvdata(pdev, gd);
	ret = regmap_read(gd->pmgr, J96GD_PS_GFX, &v);
	gd->boot_off = !ret && j96gd_ps_off(v);
	dev_info(dev, "J96GD_READY ps_gfx=%s0x%08x; dump %s (see 'attempt')\n",
		 ret ? "ERR " : "", v, gd->boot_off ? "available" : "refused: ps_gfx not off");
	return 0;
}

static const struct of_device_id j96gd_match[] = {
	{ .compatible = "apple,j96-gpuprobe" },
	{ }
};
MODULE_DEVICE_TABLE(of, j96gd_match);

static struct platform_driver j96gd_driver = {
	.probe = j96gd_probe,
	.driver = {
		.name = "apple-j96-gpudump",
		.of_match_table = j96gd_match,
		.dev_groups = j96gd_groups,
	},
};
module_platform_driver(j96gd_driver);
MODULE_DESCRIPTION("J96 GPU GPC 1 power-state dump (Fender and PMGR reads only, no RGX)");
MODULE_LICENSE("GPL");
