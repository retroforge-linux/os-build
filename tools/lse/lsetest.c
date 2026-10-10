/* LSE emulation test: every op/size/ordering against a C reference, plus a
 * contended multi-threaded counter. Build: gcc -O2 -march=armv8.1-a -pthread */
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int fails, checks;
#define CHECK(name, got, want) do { checks++; if ((uint64_t)(got) != (uint64_t)(want)) { fails++; \
	printf("FAIL %-22s got %#llx want %#llx\n", name, (unsigned long long)(got), (unsigned long long)(want)); } } while (0)

static int64_t sx(uint64_t v, int bits) { return (int64_t)(v << (64 - bits)) >> (64 - bits); }
static uint64_t ref(int op, uint64_t o, uint64_t v, int bits) {
	uint64_t m = bits == 64 ? ~0ULL : (1ULL << bits) - 1; o &= m; v &= m;
	switch (op) { case 0: return (o + v) & m; case 1: return o & ~v & m; case 2: return (o ^ v) & m; case 3: return (o | v) & m;
	case 4: return sx(o,bits) > sx(v,bits) ? o : v; case 5: return sx(o,bits) < sx(v,bits) ? o : v;
	case 6: return o > v ? o : v; default: return o < v ? o : v; }
}

/* one macro per size: op mnemonic stem, suffix, register width */
#define T_OP(stem, ord, sfx, R, type, bits, opn) do { \
	type mem = (type)init, out; uint64_t val = (uint64_t)arg; \
	asm volatile(stem ord sfx " %" R "[v], %" R "[o], %[m]" : [o] "=&r" (out), [m] "+Q" (mem) : [v] "r" ((type)val) : "memory"); \
	CHECK(stem ord sfx " old", out, (type)init); CHECK(stem ord sfx " mem", mem, (type)ref(opn, init, val, bits)); } while (0)

#define ALL_ORD(stem, sfx, R, type, bits, opn) do { T_OP(stem, "", sfx, R, type, bits, opn); T_OP(stem, "a", sfx, R, type, bits, opn); \
	T_OP(stem, "l", sfx, R, type, bits, opn); T_OP(stem, "al", sfx, R, type, bits, opn); } while (0)

static const char *names[] = { "ldadd", "ldclr", "ldeor", "ldset", "ldsmax", "ldsmin", "ldumax", "ldumin" };

static void memops(uint64_t init, uint64_t arg) {
	ALL_ORD("ldadd", "b", "w", uint8_t, 8, 0);  ALL_ORD("ldadd", "h", "w", uint16_t, 16, 0); ALL_ORD("ldadd", "", "w", uint32_t, 32, 0); ALL_ORD("ldadd", "", "x", uint64_t, 64, 0);
	ALL_ORD("ldclr", "b", "w", uint8_t, 8, 1);  ALL_ORD("ldclr", "h", "w", uint16_t, 16, 1); ALL_ORD("ldclr", "", "w", uint32_t, 32, 1); ALL_ORD("ldclr", "", "x", uint64_t, 64, 1);
	ALL_ORD("ldeor", "b", "w", uint8_t, 8, 2);  ALL_ORD("ldeor", "h", "w", uint16_t, 16, 2); ALL_ORD("ldeor", "", "w", uint32_t, 32, 2); ALL_ORD("ldeor", "", "x", uint64_t, 64, 2);
	ALL_ORD("ldset", "b", "w", uint8_t, 8, 3);  ALL_ORD("ldset", "h", "w", uint16_t, 16, 3); ALL_ORD("ldset", "", "w", uint32_t, 32, 3); ALL_ORD("ldset", "", "x", uint64_t, 64, 3);
	ALL_ORD("ldsmax", "b", "w", uint8_t, 8, 4); ALL_ORD("ldsmax", "h", "w", uint16_t, 16, 4); ALL_ORD("ldsmax", "", "w", uint32_t, 32, 4); ALL_ORD("ldsmax", "", "x", uint64_t, 64, 4);
	ALL_ORD("ldsmin", "b", "w", uint8_t, 8, 5); ALL_ORD("ldsmin", "h", "w", uint16_t, 16, 5); ALL_ORD("ldsmin", "", "w", uint32_t, 32, 5); ALL_ORD("ldsmin", "", "x", uint64_t, 64, 5);
	ALL_ORD("ldumax", "b", "w", uint8_t, 8, 6); ALL_ORD("ldumax", "h", "w", uint16_t, 16, 6); ALL_ORD("ldumax", "", "w", uint32_t, 32, 6); ALL_ORD("ldumax", "", "x", uint64_t, 64, 6);
	ALL_ORD("ldumin", "b", "w", uint8_t, 8, 7); ALL_ORD("ldumin", "h", "w", uint16_t, 16, 7); ALL_ORD("ldumin", "", "w", uint32_t, 32, 7); ALL_ORD("ldumin", "", "x", uint64_t, 64, 7);
	(void)names;
}

#define T_SWP(ord, sfx, R, type) do { type mem = (type)init, out; \
	asm volatile("swp" ord sfx " %" R "[v], %" R "[o], %[m]" : [o] "=&r" (out), [m] "+Q" (mem) : [v] "r" ((type)arg) : "memory"); \
	CHECK("swp" ord sfx " old", out, (type)init); CHECK("swp" ord sfx " mem", mem, (type)arg); } while (0)
#define T_CAS(ord, sfx, R, type, cmpv) do { type mem = (type)init, rs = (type)(cmpv); \
	asm volatile("cas" ord sfx " %" R "[s], %" R "[t], %[m]" : [s] "+&r" (rs), [m] "+Q" (mem) : [t] "r" ((type)arg) : "memory"); \
	CHECK("cas" ord sfx " old", rs, (type)init); CHECK("cas" ord sfx " mem", mem, (type)(cmpv) == (type)init ? (type)arg : (type)init); } while (0)

static void swpcas(uint64_t init, uint64_t arg) {
	const char *o[] = {"", "a", "l", "al"}; (void)o;
	T_SWP("", "b", "w", uint8_t); T_SWP("al", "h", "w", uint16_t); T_SWP("a", "", "w", uint32_t); T_SWP("l", "", "x", uint64_t); T_SWP("al", "", "x", uint64_t);
	T_CAS("", "b", "w", uint8_t, init); T_CAS("al", "h", "w", uint16_t, init); T_CAS("a", "", "w", uint32_t, init); T_CAS("al", "", "x", uint64_t, init);
	T_CAS("", "b", "w", uint8_t, init + 1); T_CAS("l", "h", "w", uint16_t, init + 1); T_CAS("al", "", "w", uint32_t, init ^ 5); T_CAS("al", "", "x", uint64_t, ~init);
}

static void casp(uint64_t a0, uint64_t a1, int match) {
	__uint128_t mem __attribute__((aligned(16)));
	register uint64_t s0 asm("x0"), s1 asm("x1"), t0 asm("x2"), t1 asm("x3");
	uint64_t m[2] __attribute__((aligned(16))) = { a0, a1 };
	s0 = match ? a0 : a0 + 1; s1 = a1; t0 = 0x1111; t1 = 0x2222;
	asm volatile("caspal x0, x1, x2, x3, %[m]" : "+r" (s0), "+r" (s1), [m] "+Q" (*(__uint128_t *)m) : "r" (t0), "r" (t1) : "memory");
	CHECK("caspal old0", s0, a0); CHECK("caspal old1", s1, a1);
	CHECK("caspal mem0", m[0], match ? 0x1111 : a0); CHECK("caspal mem1", m[1], match ? 0x2222 : a1); (void)mem;
	uint32_t w[2] __attribute__((aligned(8))) = { (uint32_t)a0, (uint32_t)a1 };
	register uint64_t ws0 asm("x4"), ws1 asm("x5"), wt0 asm("x6"), wt1 asm("x7");
	ws0 = match ? (uint32_t)a0 : (uint32_t)a0 + 1; ws1 = (uint32_t)a1; wt0 = 0x33; wt1 = 0x44;
	asm volatile("casp w4, w5, w6, w7, %[m]" : "+r" (ws0), "+r" (ws1), [m] "+Q" (*(uint64_t *)w) : "r" (wt0), "r" (wt1) : "memory");
	CHECK("casp old0", ws0, (uint32_t)a0); CHECK("casp old1", ws1, (uint32_t)a1);
	CHECK("casp mem0", w[0], match ? 0x33 : (uint32_t)a0); CHECK("casp mem1", w[1], match ? 0x44 : (uint32_t)a1);
}

#define THREADS 4
#define ITERS 200000
static uint64_t counter; static uint32_t lockword; static uint64_t plain;
static void *worker(void *p) {
	for (int i = 0; i < ITERS; i++) {
		uint64_t one = 1, old;
		asm volatile("ldaddal %[v], %[o], %[m]" : [o] "=&r" (old), [m] "+Q" (counter) : [v] "r" (one) : "memory");
		/* a CAS spinlock protecting a plain increment */
		uint32_t z;
		do { z = 0; asm volatile("casa %w[s], %w[t], %[m]" : [s] "+&r" (z), [m] "+Q" (lockword) : [t] "r" (1) : "memory"); } while (z != 0);
		plain++;
		asm volatile("stlr wzr, %[m]" : [m] "=Q" (lockword) :: "memory");
	}
	return p;
}

int main(void) {
	uint64_t vals[] = { 0, 1, 0x7f, 0x80, 0xff, 0x7fff, 0x8000, 0xffff, 0x7fffffff, 0x80000000, 0xffffffff, 0x123456789abcdef0ULL, 0x8000000000000000ULL, ~0ULL };
	int n = sizeof(vals) / sizeof(vals[0]);
	for (int i = 0; i < n; i++) for (int j = 0; j < n; j++) { memops(vals[i], vals[j]); swpcas(vals[i], vals[j]); }
	casp(0x0123456789abcdefULL, 0xfedcba9876543210ULL, 1); casp(5, 6, 0);
	printf("single-thread: %d checks, %d failures\n", checks, fails);

	struct timespec a, b; pthread_t t[THREADS];
	clock_gettime(CLOCK_MONOTONIC, &a);
	for (int i = 0; i < THREADS; i++) pthread_create(&t[i], 0, worker, 0);
	for (int i = 0; i < THREADS; i++) pthread_join(t[i], 0);
	clock_gettime(CLOCK_MONOTONIC, &b);
	double secs = (b.tv_sec - a.tv_sec) + (b.tv_nsec - a.tv_nsec) / 1e9;
	uint64_t want = (uint64_t)THREADS * ITERS;
	printf("contended: ldaddal counter %llu (want %llu), CAS-locked plain counter %llu (want %llu), %.2f s, %.2f us per atomic\n",
	       (unsigned long long)counter, (unsigned long long)want, (unsigned long long)plain, (unsigned long long)want, secs, secs * 1e6 / (want * 3.0));
	if (counter != want || plain != want) fails++;
	printf("%s\n", fails ? "RESULT: FAIL" : "RESULT: PASS");
	return fails != 0;
}
