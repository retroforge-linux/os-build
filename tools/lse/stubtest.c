// SPDX-License-Identifier: GPL-2.0-only
/*
 * Checks the stubs kernel patch 0026 writes over emulated LSE sites against
 * the real instructions. Run it on a CPU WITH LSE (any ARMv8.1+ core; an
 * Apple Silicon Mac's arm64 Docker works): every case runs the instruction
 * natively and through its stub on the same registers, flags and memory,
 * and all 31 registers, NZCV and memory must come out identical.
 *
 * Cases: every LD<op>/SWP/CAS/CASP form, size and ordering, with random
 * and edge values, random register choices including overlaps (Rs = Rt,
 * Rt = Rn, ...), XZR operands and registers inside the stubs' x9-x17
 * scratch range; equal compares for half the CAS/CASP cases. Then threads
 * hammer LDADDAL, CASAL and CASPAL stubs on shared words: totals must be
 * exact. `stubtest dump FILE` writes sample stubs and the LDAPR->LDAR words
 * for objdump. Build with tools/lse/stubtest.sh, which takes lse_stub.h
 * from the patch so the test cannot drift from it.
 */
#define _GNU_SOURCE
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/mman.h>

#include "lse_stub.h"

#ifndef HWCAP_ATOMICS
#define HWCAP_ATOMICS (1 << 8)
#endif

/*
 * x0 = ctx (struct ctx.in), 16-aligned: [0,248) registers in, [248] NZCV
 * in, [256,504) registers out, [504] NZCV out; caller's x19-x30 and sp at
 * [-224,-120). SP is ctx while the instruction runs, so a stub's 32-byte
 * spill lands in [-32,0), inside ctx.pad.
 */
asm(".text\n"
    ".globl tmpl_start, tmpl_slot, tmpl_end\n"
    ".hidden tmpl_start, tmpl_slot, tmpl_end\n"
    ".p2align 4\n"
    "tmpl_start:\n"
    "	stp x19, x20, [x0, #-224]\n"
    "	stp x21, x22, [x0, #-208]\n"
    "	stp x23, x24, [x0, #-192]\n"
    "	stp x25, x26, [x0, #-176]\n"
    "	stp x27, x28, [x0, #-160]\n"
    "	stp x29, x30, [x0, #-144]\n"
    "	mov x1, sp\n"
    "	stur x1, [x0, #-128]\n"
    "	mov sp, x0\n"
    "	ldr x0, [sp, #248]\n"
    "	msr nzcv, x0\n"
    "	ldp x0, x1, [sp, #0]\n	ldp x2, x3, [sp, #16]\n"
    "	ldp x4, x5, [sp, #32]\n	ldp x6, x7, [sp, #48]\n"
    "	ldp x8, x9, [sp, #64]\n	ldp x10, x11, [sp, #80]\n"
    "	ldp x12, x13, [sp, #96]\n	ldp x14, x15, [sp, #112]\n"
    "	ldp x16, x17, [sp, #128]\n	ldp x18, x19, [sp, #144]\n"
    "	ldp x20, x21, [sp, #160]\n	ldp x22, x23, [sp, #176]\n"
    "	ldp x24, x25, [sp, #192]\n	ldp x26, x27, [sp, #208]\n"
    "	ldp x28, x29, [sp, #224]\n	ldr x30, [sp, #240]\n"
    "tmpl_slot:\n"
    "	nop\n"
    "	stp x0, x1, [sp, #256]\n	stp x2, x3, [sp, #272]\n"
    "	stp x4, x5, [sp, #288]\n	stp x6, x7, [sp, #304]\n"
    "	stp x8, x9, [sp, #320]\n	stp x10, x11, [sp, #336]\n"
    "	stp x12, x13, [sp, #352]\n	stp x14, x15, [sp, #368]\n"
    "	stp x16, x17, [sp, #384]\n	stp x18, x19, [sp, #400]\n"
    "	stp x20, x21, [sp, #416]\n	stp x22, x23, [sp, #432]\n"
    "	stp x24, x25, [sp, #448]\n	stp x26, x27, [sp, #464]\n"
    "	stp x28, x29, [sp, #480]\n	str x30, [sp, #496]\n"
    "	mrs x0, nzcv\n"
    "	str x0, [sp, #504]\n"
    "	ldp x19, x20, [sp, #-224]\n"
    "	ldp x21, x22, [sp, #-208]\n"
    "	ldp x23, x24, [sp, #-192]\n"
    "	ldp x25, x26, [sp, #-176]\n"
    "	ldp x27, x28, [sp, #-160]\n"
    "	ldp x29, x30, [sp, #-144]\n"
    "	ldur x1, [sp, #-128]\n"
    "	mov sp, x1\n"
    "	ret\n"
    "tmpl_end:\n");
extern const char tmpl_start[], tmpl_slot[], tmpl_end[];

struct ctx {
	uint64_t pad[2048];		/* caller state, the stub spill, room for a signal frame */
	uint64_t in[31], nzcv_in, out[31], nzcv_out;
} __attribute__((aligned(16)));

#define STUB_OFF	4096
#define PAGE_BYTES	8192

static uint64_t rng = 0x9e3779b97f4a7c15ull;

static uint64_t rnd(void)
{
	rng ^= rng << 13;
	rng ^= rng >> 7;
	rng ^= rng << 17;
	return rng;
}

static uint64_t value(void)
{
	static const uint64_t edge[] = {
		0, 1, 2, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x7fffffff,
		0x80000000, 0xffffffff, 0x7fffffffffffffffull,
		0x8000000000000000ull, ~0ull, 0x0123456789abcdefull,
	};

	return rnd() & 1 ? edge[rnd() % (sizeof(edge) / sizeof(edge[0]))] : rnd();
}

/* A page with the harness at 0 and room for a stub at STUB_OFF. */
static char *new_page(void)
{
	char *p = mmap(NULL, PAGE_BYTES, PROT_READ | PROT_WRITE | PROT_EXEC,
		       MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);

	if (p == MAP_FAILED) {
		perror("mmap");
		exit(2);
	}
	memcpy(p, tmpl_start, tmpl_end - tmpl_start);
	__builtin___clear_cache(p, p + (tmpl_end - tmpl_start));
	return p;
}

static void set_slot(char *page, uint32_t word)
{
	uint32_t *slot = (uint32_t *)(page + (tmpl_slot - tmpl_start));

	*slot = word;
	__builtin___clear_cache((char *)slot, (char *)(slot + 1));
}

/* Put insn's stub on the page and the B to it in the slot. 0 = not patched. */
static int install_stub(char *page, uint32_t insn)
{
	unsigned long slot = (unsigned long)(page + (tmpl_slot - tmpl_start));
	unsigned long stub = (unsigned long)(page + STUB_OFF);
	unsigned int w[LSE_STUB_WORDS];
	int n = lse_stub_gen(insn, stub, slot + 4, w);

	if (!n)
		return 0;
	if (n > LSE_STUB_WORDS) {
		fprintf(stderr, "stub too long: %d words for %08x\n", n, insn);
		exit(1);
	}
	memset(page + STUB_OFF, 0, LSE_STUB_WORDS * 4);
	memcpy(page + STUB_OFF, w, 4 * n);
	__builtin___clear_cache(page + STUB_OFF, page + STUB_OFF + 4 * n);
	set_slot(page, lse_i_b(slot, stub));
	return n;
}

static void run(char *page, struct ctx *c)
{
	((void (*)(uint64_t *))page)(c->in);
}

static unsigned int reg(void)
{
	static const unsigned int edge[] = { 0, 8, 18, 29, 30, 31 };

	/* weight the stub scratch range and the edges */
	switch (rnd() % 4) {
	case 0:
		return 9 + rnd() % 9;
	case 1:
		return edge[rnd() % 6];
	default:
		return rnd() % 32;
	}
}

/* A random LSE instruction (never SP-based); its kind and size out. */
static uint32_t random_insn(int *kind, unsigned int *sz)
{
	unsigned int size = rnd() % 4, a = rnd() & 1, r = rnd() & 1;
	unsigned int rs, rt, rn;

	do
		rn = reg();
	while (rn == 31);
	switch (rnd() % 5) {
	case 0: case 1: {		/* LD<op> (opc 0-7) and SWP */
		unsigned int swp = rnd() % 9 == 0, opc = swp ? 0 : rnd() % 8;

		rs = reg();
		rt = reg();
		*kind = swp ? LSE_K_SWP : opc < 4 ? LSE_K_OP : LSE_K_MINMAX;
		*sz = size;
		return 0x38200000u | size << 30 | a << 23 | r << 22 | rs << 16 |
		       swp << 15 | opc << 12 | rn << 5 | rt;
	}
	case 2: case 3:			/* CAS */
		rs = reg();
		rt = reg();
		*kind = LSE_K_CAS;
		*sz = size;
		return 0x08a07c00u | size << 30 | a << 22 | rs << 16 | r << 15 |
		       rn << 5 | rt;
	default:			/* CASP, pairs clear of Rn */
		size &= 1;
		do {
			rs = (rnd() % 16) * 2;
			rt = (rnd() % 16) * 2;
		} while (rn == rs || rn == rs + 1 || rn == rt || rn == rt + 1);
		*kind = LSE_K_CASP;
		*sz = size;
		return 0x08207c00u | size << 30 | a << 22 | rs << 16 | r << 15 |
		       rn << 5 | rt;
	}
}

static uint64_t mem[4] __attribute__((aligned(64)));

static void report(unsigned long i, uint32_t insn, int kind, unsigned int sz,
		   struct ctx *nat, struct ctx *stb, uint64_t *memn)
{
	unsigned int k;

	fprintf(stderr, "case %lu: MISMATCH insn %08x (kind %d size %u)\n", i, insn, kind, sz);
	for (k = 0; k < 31; k++)
		if (nat->out[k] != stb->out[k])
			fprintf(stderr, "  x%u native %016llx stub %016llx (in %016llx)\n", k,
				(unsigned long long)nat->out[k], (unsigned long long)stb->out[k],
				(unsigned long long)nat->in[k]);
	if (nat->nzcv_out != stb->nzcv_out)
		fprintf(stderr, "  nzcv native %llx stub %llx\n",
			(unsigned long long)nat->nzcv_out, (unsigned long long)stb->nzcv_out);
	for (k = 0; k < 4; k++)
		if (memn[k] != mem[k])
			fprintf(stderr, "  mem[%u] native %016llx stub %016llx\n", k,
				(unsigned long long)memn[k], (unsigned long long)mem[k]);
}

static int one_case(char *page, unsigned long i)
{
	static struct ctx nat, stb;
	uint64_t mem0[4], memn[4], *m;
	unsigned int sz, rs, rn, k;
	int kind;
	uint32_t insn = random_insn(&kind, &sz);

	rs = (insn >> 16) & 31;
	rn = (insn >> 5) & 31;
	for (k = 0; k < 31; k++)
		nat.in[k] = value();
	nat.nzcv_in = (rnd() & 0xf) << 28;
	for (k = 0; k < 4; k++)
		mem0[k] = value();
	/* 8-aligned for single registers and W pairs; 16 for X pairs */
	nat.in[rn] = (uint64_t)(kind == LSE_K_CASP && sz ? &mem[0] : &mem[1]);
	m = mem0 + ((uint64_t *)nat.in[rn] - mem);
	if (rnd() & 1) {		/* make a compare succeed */
		if (kind == LSE_K_CAS && rs != 31 && rs != rn) {
			uint64_t mask = sz == 3 ? ~0ull : (1ull << (8 << sz)) - 1;

			nat.in[rs] = (nat.in[rs] & ~mask) | (m[0] & mask);
		} else if (kind == LSE_K_CASP && sz) {
			nat.in[rs] = m[0];
			if (rs + 1 != 31)
				nat.in[rs + 1] = m[1];
		} else if (kind == LSE_K_CASP) {
			nat.in[rs] = (uint32_t)m[0];
			if (rs + 1 != 31)
				nat.in[rs + 1] = m[0] >> 32;
		}
	}
	stb = nat;

	memcpy(mem, mem0, sizeof(mem));
	set_slot(page, insn);
	run(page, &nat);
	memcpy(memn, mem, sizeof(mem));

	memcpy(mem, mem0, sizeof(mem));
	if (!install_stub(page, insn)) {
		fprintf(stderr, "case %lu: %08x not patched\n", i, insn);
		return 1;
	}
	run(page, &stb);

	if (memcmp(nat.out, stb.out, sizeof(nat.out)) || nat.nzcv_out != stb.nzcv_out ||
	    memcmp(memn, mem, sizeof(mem))) {
		report(i, insn, kind, sz, &nat, &stb, memn);
		return 1;
	}
	return 0;
}

/* ---- contention: threads run one stub on shared memory ---- */

#define THREADS		4
#define ITERS		200000

static uint64_t shared[2] __attribute__((aligned(64)));

struct hammer {
	uint32_t insn;
	char *page;
};

static void *hammer_thread(void *arg)
{
	struct hammer *h = arg;
	struct ctx *c = aligned_alloc(16, sizeof(*c));
	int i;

	for (i = 0; i < ITERS; i++) {
		memset(c->in, 0, sizeof(c->in));
		c->nzcv_in = 0;
		c->in[2] = (uint64_t)shared;
		if ((h->insn & 0x3fa07c00u) == 0x08a07c00u) {	/* CASAL x0, x1, [x2] */
			do {
				c->in[0] = __atomic_load_n(&shared[0], __ATOMIC_RELAXED);
				c->in[1] = c->in[0] + 1;
				run(h->page, c);
			} while (c->out[0] != c->in[0]);
		} else if ((h->insn & 0xbfa07c00u) == 0x08207c00u) {	/* CASPAL x4, x5, x6, x7, [x2] */
			do {
				c->in[4] = __atomic_load_n(&shared[0], __ATOMIC_RELAXED);
				c->in[5] = __atomic_load_n(&shared[1], __ATOMIC_RELAXED);
				c->in[6] = c->in[4] + 1;
				c->in[7] = c->in[5] + 3;
				run(h->page, c);
			} while (c->out[4] != c->in[4] || c->out[5] != c->in[5]);
		} else {			/* LDADDAL x1, x0, [x2] */
			c->in[1] = 1;
			run(h->page, c);
		}
	}
	free(c);
	return NULL;
}

static int hammer(const char *name, uint32_t insn, uint64_t want0, uint64_t want1)
{
	pthread_t th[THREADS];
	struct hammer h = { insn, new_page() };
	int i;

	install_stub(h.page, insn);
	shared[0] = shared[1] = 0;
	for (i = 0; i < THREADS; i++)
		pthread_create(&th[i], NULL, hammer_thread, &h);
	for (i = 0; i < THREADS; i++)
		pthread_join(th[i], NULL);
	munmap(h.page, PAGE_BYTES);
	if (shared[0] != want0 || shared[1] != want1) {
		fprintf(stderr, "%s: got %llu/%llu, want %llu/%llu\n", name,
			(unsigned long long)shared[0], (unsigned long long)shared[1],
			(unsigned long long)want0, (unsigned long long)want1);
		return 1;
	}
	printf("%s stub: %d threads x %d, exact\n", name, THREADS, ITERS);
	return 0;
}

/* Stubs for one instruction of each kind, and LDAPR->LDAR, for objdump. */
static int dump(const char *path)
{
	static const uint32_t sample[] = {
		0xf8e10040u,	/* ldaddal x1, x0, [x2] */
		0x38a1500au,	/* ldsminab w1, w10, [x0] */
		0x787f3020u,	/* ldsetlh wzr, w0, [x1] */
		0xb8e18062u,	/* swpal w1, w2, [x3] */
		0xc8e0fc41u,	/* casal x0, x1, [x2] */
		0x48a17c62u,	/* cash w1, w2, [x3] */
		0x4864fc46u,	/* caspal x4, x5, x6, x7, [x2] */
		0x08207c62u,	/* casp w0, w1, w2, w3, [x3] */
	};
	unsigned int w[LSE_STUB_WORDS];
	FILE *f = fopen(path, "wb");
	unsigned int i, s;
	int n;

	if (!f)
		return 2;
	for (i = 0; i < sizeof(sample) / sizeof(sample[0]); i++) {
		n = lse_stub_gen(sample[i], 0x100000, 0x200000, w);
		fwrite(w, 4, n, f);
	}
	for (s = 0; s < 4; s++) {	/* ldapr{b,h,,} w/x0, [x1] */
		uint32_t ldapr = 0x38bfc020u | s << 30;

		w[0] = lse_stub_inplace(ldapr);
		fwrite(w, 4, 1, f);
	}
	fclose(f);
	return 0;
}

int main(int argc, char **argv)
{
	unsigned long cases = 500000, i, fails = 0;
	char *page;

	if (argc > 2 && !strcmp(argv[1], "dump"))
		return dump(argv[2]);
	if (argc > 1)
		cases = strtoul(argv[1], NULL, 0);
	if (!(getauxval(AT_HWCAP) & HWCAP_ATOMICS)) {
		fprintf(stderr, "this CPU has no LSE: run stubtest where it does\n");
		return 2;
	}
	page = new_page();
	for (i = 0; i < cases && fails < 20; i++)
		fails += one_case(page, i);
	printf("%lu cases, %lu mismatches\n", i, fails);

	fails += hammer("LDADDAL", 0xf8e10040u, (uint64_t)THREADS * ITERS, 0);
	fails += hammer("CASAL", 0xc8e0fc41u, (uint64_t)THREADS * ITERS, 0);
	fails += hammer("CASPAL", 0x4864fc46u, (uint64_t)THREADS * ITERS,
			3ull * THREADS * ITERS);
	return fails ? 1 : 0;
}
