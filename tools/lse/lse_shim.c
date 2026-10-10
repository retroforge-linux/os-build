/* lse_shim: userspace twin of kernel/patches/0025 (arm64 LSE emulation), for testing on a kernel
 * without it. LD_PRELOAD=lse_shim.so: a SIGILL handler that decodes LDADD..LDUMIN, SWP, CAS, CASP
 * (and LDAPR) exactly as the kernel patch does and runs each as an LDXR/STXR compare-exchange loop
 * between full barriers. Keeps itself first in line for SIGILL (interposes sigaction/signal and
 * chains to the application's handler for anything that is not LSE).
 * QFORGE_LSE_STATS=1 prints the emulation count per process at exit. */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ucontext.h>
#include <unistd.h>

#define LSE_MEMOP_MASK 0x3f200c00u
#define LSE_MEMOP_VAL  0x38200000u
#define LSE_CAS_MASK   0x3fa07c00u
#define LSE_CAS_VAL    0x08a07c00u
#define LSE_CASP_MASK  0xbfa07c00u
#define LSE_CASP_VAL   0x08207c00u

static struct sigaction app_ill;          /* the application's own SIGILL disposition */
static unsigned long long emulated;

#define CMPXCHG(sfx, w, addr, old, nw, prev) do { unsigned long t; \
	asm volatile("1: ldxr" sfx " %" w "[p], [%[a]]\n cmp %" w "[p], %" w "[o]\n b.ne 2f\n" \
		     " stxr" sfx " %w[t], %" w "[n], [%[a]]\n cbnz %w[t], 1b\n2:\n" \
		     : [p] "=&r" (prev), [t] "=&r" (t) : [a] "r" (addr), [o] "r" (old), [n] "r" (nw) : "cc", "memory"); } while (0)

static uint64_t cmpxchg(uintptr_t a, unsigned size, uint64_t old, uint64_t nw) {
	uint64_t p = 0;
	switch (size) {
	case 0: CMPXCHG("b", "w", a, old, nw, p); break;
	case 1: CMPXCHG("h", "w", a, old, nw, p); break;
	case 2: CMPXCHG("", "w", a, old, nw, p); break;
	default: CMPXCHG("", "x", a, old, nw, p); break;
	}
	return p;
}
#define CMPXCHGP(w, a, o0, o1, n0, n1, p0, p1) do { unsigned long t, s0, s1; \
	asm volatile("1: ldxp %" w "[p0], %" w "[p1], [%[a]]\n cmp %" w "[p0], %" w "[o0]\n ccmp %" w "[p1], %" w "[o1], #0, eq\n" \
		     " csel %" w "[s0], %" w "[n0], %" w "[p0], eq\n csel %" w "[s1], %" w "[n1], %" w "[p1], eq\n" \
		     " stxp %w[t], %" w "[s0], %" w "[s1], [%[a]]\n cbnz %w[t], 1b\n" \
		     : [p0] "=&r" (p0), [p1] "=&r" (p1), [s0] "=&r" (s0), [s1] "=&r" (s1), [t] "=&r" (t) \
		     : [a] "r" (a), [o0] "r" (o0), [o1] "r" (o1), [n0] "r" (n0), [n1] "r" (n1) : "cc", "memory"); } while (0)

static int64_t sx(uint64_t v, unsigned size) { unsigned s = 64 - (8u << size); return (int64_t)(v << s) >> s; }
static uint64_t op(unsigned opc, uint64_t o, uint64_t v, unsigned size) {
	switch (opc) { case 0: return o + v; case 1: return o & ~v; case 2: return o ^ v; case 3: return o | v;
	case 4: return sx(o, size) > sx(v, size) ? o : v; case 5: return sx(o, size) < sx(v, size) ? o : v;
	case 6: return o > v ? o : v; default: return o < v ? o : v; }
}
static uint64_t rd(mcontext_t *m, unsigned r) { return r == 31 ? 0 : m->regs[r]; }
static void wr(mcontext_t *m, unsigned r, uint64_t v) { if (r != 31) m->regs[r] = v; }

/* 1 = emulated, 0 = not ours */
static int emulate(mcontext_t *m, uint32_t insn) {
	unsigned size = insn >> 30, rt = insn & 31, rs = (insn >> 16) & 31, rn = (insn >> 5) & 31;
	uintptr_t a = rn == 31 ? m->sp : m->regs[rn];
	uint64_t mask, val, cur, prev;
	if ((insn & LSE_CASP_MASK) == LSE_CASP_VAL) {
		int is64 = size & 1; uint64_t mk = is64 ? ~0ULL : 0xffffffffULL, p0, p1;
		if ((rs & 1) || (rt & 1)) return 0;
		uint64_t o0 = rd(m, rs) & mk, o1 = rd(m, rs + 1) & mk, n0 = rd(m, rt) & mk, n1 = rd(m, rt + 1) & mk;
		__sync_synchronize();
		if (is64) CMPXCHGP("x", a, o0, o1, n0, n1, p0, p1); else CMPXCHGP("w", a, o0, o1, n0, n1, p0, p1);
		__sync_synchronize();
		wr(m, rs, p0); wr(m, rs + 1, p1); return 1;
	}
	mask = size == 3 ? ~0ULL : (1ULL << (8u << size)) - 1;
	if ((insn & LSE_CAS_MASK) == LSE_CAS_VAL) {
		__sync_synchronize();
		prev = cmpxchg(a, size, rd(m, rs) & mask, rd(m, rt) & mask);
		__sync_synchronize();
		wr(m, rs, prev); return 1;
	}
	if ((insn & LSE_MEMOP_MASK) == LSE_MEMOP_VAL) {
		unsigned o3 = (insn >> 15) & 1, opc = (insn >> 12) & 7;
		if (o3 && opc == 4) {               /* LDAPR */
			if (rs != 31) return 0;
			switch (size) { case 0: val = *(volatile uint8_t *)a; break; case 1: val = *(volatile uint16_t *)a; break;
			case 2: val = *(volatile uint32_t *)a; break; default: val = *(volatile uint64_t *)a; }
			__sync_synchronize(); wr(m, rt, val); return 1;
		}
		if (o3 && opc != 0) return 0;
		val = rd(m, rs) & mask; cur = 0;
		__sync_synchronize();
		for (;;) {
			uint64_t nv = o3 ? val : op(opc, cur, val, size) & mask;
			prev = cmpxchg(a, size, cur, nv);
			if (prev == cur) break;
			cur = prev;
		}
		__sync_synchronize();
		wr(m, rt, cur); return 1;
	}
	return 0;
}

static void on_sigill(int sig, siginfo_t *si, void *ctx) {
	ucontext_t *uc = ctx; mcontext_t *m = &uc->uc_mcontext;
	if (emulate(m, *(uint32_t *)m->pc)) { m->pc += 4; __atomic_add_fetch(&emulated, 1, __ATOMIC_RELAXED); return; }
	/* not LSE: hand it to the application, or die as the instruction would have */
	if (app_ill.sa_flags & SA_SIGINFO && app_ill.sa_sigaction) { app_ill.sa_sigaction(sig, si, ctx); return; }
	if (app_ill.sa_handler != SIG_DFL && app_ill.sa_handler != SIG_IGN && app_ill.sa_handler) { app_ill.sa_handler(sig); return; }
	signal(SIGILL, SIG_DFL); raise(SIGILL);
}

static int (*real_sigaction)(int, const struct sigaction *, struct sigaction *);
static void install(void) {
	struct sigaction sa; memset(&sa, 0, sizeof sa);
	sa.sa_sigaction = on_sigill; sa.sa_flags = SA_SIGINFO | SA_ONSTACK | SA_NODEFER; sigemptyset(&sa.sa_mask);
	real_sigaction(SIGILL, &sa, NULL);
}
int sigaction(int sig, const struct sigaction *act, struct sigaction *old) {
	if (!real_sigaction) real_sigaction = dlsym(RTLD_NEXT, "sigaction");
	if (sig != SIGILL) return real_sigaction(sig, act, old);
	if (old) *old = app_ill;
	if (act) app_ill = *act;           /* keep ours installed; chain to theirs */
	return 0;
}
sighandler_t signal(int sig, sighandler_t h) {
	if (sig != SIGILL) { struct sigaction a, o; memset(&a, 0, sizeof a); a.sa_handler = h; a.sa_flags = SA_RESTART;
		if (!real_sigaction) real_sigaction = dlsym(RTLD_NEXT, "sigaction");
		return real_sigaction(sig, &a, &o) ? SIG_ERR : o.sa_handler; }
	sighandler_t prev = app_ill.sa_handler; memset(&app_ill, 0, sizeof app_ill); app_ill.sa_handler = h; return prev;
}
/* A CPU-raised SIGILL in a thread that blocks it is fatal: the kernel resets the handler and kills
 * the process (libpulse starts its threads with every signal blocked). Never let SIGILL be blocked. */
static int (*real_pthread_sigmask)(int, const sigset_t *, sigset_t *);
static int (*real_sigprocmask)(int, const sigset_t *, sigset_t *);
static const sigset_t *keep_ill(int how, const sigset_t *set, sigset_t *copy) {
	if (!set || how == SIG_UNBLOCK) return set;
	*copy = *set; sigdelset(copy, SIGILL); return copy;
}
int pthread_sigmask(int how, const sigset_t *set, sigset_t *old) {
	sigset_t c; if (!real_pthread_sigmask) real_pthread_sigmask = dlsym(RTLD_NEXT, "pthread_sigmask");
	return real_pthread_sigmask(how, keep_ill(how, set, &c), old);
}
int sigprocmask(int how, const sigset_t *set, sigset_t *old) {
	sigset_t c; if (!real_sigprocmask) real_sigprocmask = dlsym(RTLD_NEXT, "sigprocmask");
	return real_sigprocmask(how, keep_ill(how, set, &c), old);
}
static void stats(void) { if (getenv("QFORGE_LSE_STATS")) fprintf(stderr, "lse_shim[%d %s]: %llu LSE instructions emulated\n", getpid(), program_invocation_short_name, emulated); }
__attribute__((constructor)) static void init(void) {
	real_sigaction = dlsym(RTLD_NEXT, "sigaction"); install(); atexit(stats);
}
