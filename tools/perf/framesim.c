/* framesim: a 60 fps game-loop stand-in. Each frame does a fixed amount of integer + memory work,
 * then sleeps to the next 16.67 ms deadline. Reports per-frame work time percentiles, deadline
 * misses and which CPUs ran the work.  usage: framesim <seconds> <work-units> [threads]  */
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec / 1e9; }
static uint32_t buf[1 << 18];   /* 1 MiB: spills L1/L2 on little cores, like a game's working set */
static volatile uint64_t sink;
static int units, secs;

static void work(int n) {
	uint64_t x = 0x9e3779b97f4a7c15ULL;
	for (int u = 0; u < n; u++)
		for (int i = 0; i < 4096; i++) {
			x ^= x << 13; x ^= x >> 7; x ^= x << 17;
			uint32_t j = x & ((1 << 18) - 1);
			buf[j] += (uint32_t)x;
			sink += buf[(j * 7) & ((1 << 18) - 1)];
		}
}
static int cmp(const void *a, const void *b) { double d = *(double *)a - *(double *)b; return (d > 0) - (d < 0); }

struct res { double *t; int n, miss, cpus[8]; };
static void *loop(void *arg) {
	struct res *r = arg;
	int frames = secs * 60; r->t = calloc(frames, sizeof(double));
	double next = now();
	for (int f = 0; f < frames; f++) {
		double a = now(); work(units); double b = now();
		r->t[r->n++] = (b - a) * 1e3; r->cpus[sched_getcpu() & 7]++;
		next += 1.0 / 60; if (b > next) { r->miss++; next = b; }
		double d = next - now(); if (d > 0) { struct timespec s = { 0, (long)(d * 1e9) }; nanosleep(&s, 0); }
	}
	return 0;
}
int main(int argc, char **argv) {
	secs = argc > 1 ? atoi(argv[1]) : 10; units = argc > 2 ? atoi(argv[2]) : 40; int th = argc > 3 ? atoi(argv[3]) : 1;
	struct res r[8] = {0}; pthread_t t[8];
	work(units * 30);   /* warm up */
	for (int i = 0; i < th; i++) pthread_create(&t[i], 0, loop, &r[i]);
	for (int i = 0; i < th; i++) pthread_join(t[i], 0);
	for (int i = 0; i < th; i++) {
		qsort(r[i].t, r[i].n, sizeof(double), cmp);
		printf("thread %d: work ms p50 %.2f p95 %.2f p99 %.2f max %.2f | missed %d/%d | cpus", i,
		       r[i].t[r[i].n / 2], r[i].t[r[i].n * 95 / 100], r[i].t[r[i].n * 99 / 100], r[i].t[r[i].n - 1], r[i].miss, r[i].n);
		for (int c = 0; c < 8; c++) if (r[i].cpus[c]) printf(" %d:%d%%", c, r[i].cpus[c] * 100 / r[i].n);
		printf("\n");
	}
	return 0;
}
