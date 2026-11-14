/*
 * TurboLock.c -- a minimal, self-contained kernel extension that switches
 * Intel Turbo Boost off and on.
 *
 * Turbo Boost is one bit of one model-specific register (Intel SDM Vol. 4,
 * IA32_MISC_ENABLE, MSR 0x1A0):
 *
 *     bit 38 : Turbo Mode Disable   (1 = no turbo ratios, 0 = turbo allowed)
 *
 * MSRs are ring-0, and macOS exposes no sysctl, no pmset knob and no IOKit
 * user-space API for this, so ring-0 code is mandatory. This is the minimum
 * amount of it.
 *
 * Load   -> set bit 38 on every core   => Turbo Boost disabled
 * Unload -> clear bit 38 on every core => Turbo Boost enabled
 *
 * The bit is per-core, so both directions run through mp_rendezvous_no_intrs(),
 * which executes the callback on all CPUs with interrupts blocked.
 *
 * Firmware is permitted to restore this MSR across S3 resume, which is why
 * turbod re-applies the state after every wake.
 *
 * LICENSE: MIT. Written from the public Intel SDM; no third-party code.
 */

#include <mach/mach_types.h>
#include <mach/kmod.h>
#include <sys/systm.h>

#define MSR_IA32_MISC_ENABLE 0x1A0u
#define TURBO_MODE_DISABLE   (1ULL << 38)

/* Declared by the kernel (osfmk/i386/mp.c); not in a public KPI header. */
extern void mp_rendezvous_no_intrs(void (*action_func)(void *), void *arg);

static inline uint64_t
rdmsr64(uint32_t msr)
{
	uint32_t lo, hi;

	__asm__ volatile ("rdmsr" : "=a" (lo), "=d" (hi) : "c" (msr));
	return ((uint64_t)hi << 32) | lo;
}

static inline void
wrmsr64(uint32_t msr, uint64_t value)
{
	uint32_t lo = (uint32_t)value;
	uint32_t hi = (uint32_t)(value >> 32);

	__asm__ volatile ("wrmsr" : : "c" (msr), "a" (lo), "d" (hi));
}

/* Runs on every CPU. arg != NULL means "disable turbo". */
static void
turbo_set(void *arg)
{
	uint64_t want = (arg != NULL);
	uint64_t cur  = rdmsr64(MSR_IA32_MISC_ENABLE);
	uint64_t next = want ? (cur | TURBO_MODE_DISABLE)
	                     : (cur & ~TURBO_MODE_DISABLE);

	if (next != cur) {
		wrmsr64(MSR_IA32_MISC_ENABLE, next);
	}
}

static kern_return_t
TurboLock_start(kmod_info_t *ki, void *data)
{
	(void)ki;
	(void)data;

	mp_rendezvous_no_intrs(turbo_set, (void *)1);

	printf("TurboLock: turbo disabled (IA32_MISC_ENABLE=0x%llx)\n",
	       (unsigned long long)rdmsr64(MSR_IA32_MISC_ENABLE));
	return KERN_SUCCESS;
}

static kern_return_t
TurboLock_stop(kmod_info_t *ki, void *data)
{
	(void)ki;
	(void)data;

	mp_rendezvous_no_intrs(turbo_set, NULL);

	printf("TurboLock: turbo re-enabled (IA32_MISC_ENABLE=0x%llx)\n",
	       (unsigned long long)rdmsr64(MSR_IA32_MISC_ENABLE));
	return KERN_SUCCESS;
}

KMOD_EXPLICIT_DECL(com.turbodisable.TurboLock, "1.0.0",
                   TurboLock_start, TurboLock_stop)
