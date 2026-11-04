// Two worker threads each run a calibrated CPU burst of burst_us, then block on their own eventfd. A waker thread
// pinned to waker_cpu (outside the workers' CPU set) busy-polls and writes each worker's eventfd gap_us after its
// burst ended. Handoff: the waker's clock just before that write -> the worker's read() returning; a handoff of at
// least half a burst counts as "stacked" (the worker sat behind another running task). One SUMMARY line is printed;
// waker_wait% is the waker's own run-queue wait share (a control), itmt/delay_dequeue come from debugfs ("?" without root).
//   gcc -O2 -Wall -Wextra -pthread -o asym_min asym_min.c
//   taskset -c 4-7 ./asym_min 1000 10 30 2          # burst_us gap_us seconds waker_cpu
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <time.h>
#include <unistd.h>

#define MAX_SAMPLES (1 << 22)
#define die(what) (perror(what), exit(1))

struct worker {
	int efd;
	_Atomic uint64_t ready_at;	// end of the worker's burst, just before it blocks; 0 while it runs
	_Atomic uint64_t signaled_at;	// waker's clock just before its eventfd write; 0 for the release at stop
	uint32_t *handoff_ns;
	long wakes, stacked;
} __attribute__((aligned(64)));

static struct worker ws[2];
static long iters;
static uint64_t gap_ns, stacked_ns;
static int waker_cpu;
static atomic_int stop;
static double waker_wait_pct;

static uint64_t now_ns(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static uint64_t burst(uint64_t x, long n)
{
	for (long i = 0; i < n; i++)
		x = x * 6364136223846793005ull + 1442695040888963407ull;
	return x;
}

// run time and run-queue wait time of the calling thread, ns
static void schedstat(unsigned long long st[2])
{
	FILE *f = fopen("/proc/thread-self/schedstat", "r");
	if (!f || fscanf(f, "%llu %llu", &st[0], &st[1]) != 2)
		die("schedstat");
	fclose(f);
}

// first line of a file, or "?" when it cannot be read
static char *read_line(const char *path, char *buf, int n)
{
	FILE *f = fopen(path, "r");
	if (!f || !fgets(buf, n, f))
		strcpy(buf, "?");
	if (f)
		fclose(f);
	buf[strcspn(buf, "\n")] = 0;
	return buf;
}

static void *worker(void *arg)
{
	struct worker *w = arg;
	uint64_t x = 1, s, d;
	pthread_setname_np(pthread_self(), "asym-worker");
	while (!stop) {
		x = burst(x, iters);
		atomic_store_explicit(&w->ready_at, now_ns(), memory_order_release);
		if (read(w->efd, &d, 8) != 8)
			die("read eventfd");
		s = atomic_load_explicit(&w->signaled_at, memory_order_acquire);
		if (!s)
			continue;
		d = now_ns() - s;
		w->stacked += d >= stacked_ns;
		if (w->wakes < MAX_SAMPLES)
			w->handoff_ns[w->wakes++] = d > UINT32_MAX ? UINT32_MAX : d;
	}
	return (void *) x;	// keeps the burst from being optimized away
}

// Polls the workers and signals each one gap_us after its burst ended.
static void *waker(void *arg)
{
	uint64_t one = 1, r, t;
	unsigned long long st0[2], st1[2];
	cpu_set_t set;
	int i;
	pthread_setname_np(pthread_self(), "asym-waker");
	CPU_ZERO(&set);
	CPU_SET(waker_cpu, &set);
	if (sched_setaffinity(0, sizeof(set), &set))
		die("sched_setaffinity");
	schedstat(st0);
	while (!stop)
		for (i = 0; i < 2; i++) {
			r = atomic_load_explicit(&ws[i].ready_at, memory_order_acquire);
			t = now_ns();
			if (!r || t < r || t - r < gap_ns)
				continue;
			atomic_store_explicit(&ws[i].ready_at, 0, memory_order_relaxed);
			atomic_store_explicit(&ws[i].signaled_at, now_ns(), memory_order_release);
			if (write(ws[i].efd, &one, 8) != 8)
				die("write eventfd");
		}
	for (i = 0; i < 2; i++) {	// release workers blocked in read()
		atomic_store_explicit(&ws[i].signaled_at, 0, memory_order_release);
		if (write(ws[i].efd, &one, 8) != 8)
			die("write eventfd");
	}
	schedstat(st1);
	waker_wait_pct = 100.0 * (st1[1] - st0[1]) / (st1[0] - st0[0] + st1[1] - st0[1]);
	return arg;
}

static int cmp_u32(const void *a, const void *b)
{
	uint32_t x = *(const uint32_t *) a, y = *(const uint32_t *) b;
	return x < y ? -1 : x > y;
}

// permille-th handoff of worker i in ms (sorted samples; 1000 = max), 0 without samples
static double pct(int i, long permille)
{
	long n = ws[i].wakes;
	return n ? ws[i].handoff_ns[permille == 1000 ? n - 1 : n * permille / 1000] * 1e-6 : 0;
}

int main(int argc, char **argv)
{
	uint64_t best = UINT64_MAX, x = 1, t0, dt;
	pthread_t th[3];
	cpu_set_t allowed;
	char buf[1024];
	int burst_us, seconds, i, n = 0;
	if (argc != 5) {
		fprintf(stderr, "usage: %s <burst_us> <gap_us> <seconds> <waker_cpu>\n", argv[0]);
		return 2;
	}
	burst_us = atoi(argv[1]);
	gap_ns = atoi(argv[2]) * 1000ull;
	seconds = atoi(argv[3]);
	waker_cpu = atoi(argv[4]);
	stacked_ns = burst_us * 500ull;

	// calibrate the burst alone, before any thread starts: best of 20 probes
	for (i = 0; i < 20; i++) {
		t0 = now_ns();
		x = burst(x, 1000000);
		dt = now_ns() - t0;
		best = dt < best ? dt : best;
	}
	iters = (long) (1e6 * burst_us * 1000.0 / best) + (x == 42);
	if (getenv("ASYM_ITERS"))	// fixed work per burst, e.g. to compare throughput across clock settings
		iters = atol(getenv("ASYM_ITERS"));

	if (sched_getaffinity(0, sizeof(allowed), &allowed))
		die("sched_getaffinity");
	for (i = 0; i < 2; i++) {
		if ((ws[i].efd = eventfd(0, 0)) < 0)
			die("eventfd");
		ws[i].handoff_ns = malloc(MAX_SAMPLES * sizeof(uint32_t));
		pthread_create(&th[i], NULL, worker, &ws[i]);
	}
	pthread_create(&th[2], NULL, waker, NULL);
	sleep(seconds);
	stop = 1;
	for (i = 2; i >= 0; i--)	// the waker first: it releases the workers
		pthread_join(th[i], NULL);

	const char *dd = strstr(read_line("/sys/kernel/debug/sched/features", buf, sizeof(buf)), "NO_DELAY_DEQUEUE")
			 ? "N" : strstr(buf, "DELAY_DEQUEUE") ? "Y" : "?";
	printf("SUMMARY itmt=%s delay_dequeue=%s allowed_cpus=",
	       read_line("/sys/kernel/debug/x86/sched_itmt_enabled", buf, sizeof(buf)), dd);
	for (i = 0; i < CPU_SETSIZE; i++)
		if (CPU_ISSET(i, &allowed))
			printf("%s%d", n++ ? "," : "", i);
	for (i = 0; i < 2; i++)
		qsort(ws[i].handoff_ns, ws[i].wakes, sizeof(uint32_t), cmp_u32);
	printf(" waker_cpu=%d seconds=%d stacked=%ld,%ld wakes=%ld,%ld handoff_p50_ms=%.3f,%.3f handoff_p99_ms=%.3f,%.3f"
	       " handoff_p999_ms=%.3f,%.3f handoff_max_ms=%.3f,%.3f waker_wait%%=%.3f burst_iters=%ld\n", waker_cpu, seconds,
	       ws[0].stacked, ws[1].stacked, ws[0].wakes, ws[1].wakes, pct(0, 500), pct(1, 500), pct(0, 990), pct(1, 990),
	       pct(0, 999), pct(1, 999), pct(0, 1000), pct(1, 1000), waker_wait_pct, iters);
	return 0;
}
