// Busy threads woken from another CPU: each worker runs a calibrated CPU burst, then blocks on its own eventfd
// until a waker thread (pinned to waker_cpu, outside the workers' CPU set) signals it gap_us later. This mimics
// event loops woken by network softirq on other CPUs. Without waker_cpu the worker sleeps with nanosleep(gap_us)
// instead (a timer wakeup on its own CPU).
//
// usage: asym_stack2 <threads> <burst_us> <gap_us> <seconds> [waker_cpu|-1]
// Run under taskset (e.g. taskset -c 4-7). A preflight line (stderr, and in SUMMARY) reports the preferred-core
// ranks of the allowed set, SMT siblings in it and the clock settings; see README "What a run needs".
// Per worker it prints the run-queue wait share from /proc/thread-self/schedstat (wait / (run + wait)), the wall
// duration of each burst, voluntary context switches (a proxy for how often it blocked) and, with a waker, the
// end-to-end handoff time: the waker's timestamp just before its eventfd write -> the worker's read returning, and
// how many handoffs took at least half a burst ("stacked": the worker sat behind another running task).
// The last line is a one-line SUMMARY: ITMT and DELAY_DEQUEUE state (from debugfs, "?" if unreadable), the per-worker
// wait share, stacked handoff count, longest handoff and longest burst, and the waker's own run-queue wait share
// (a delayed waker would inflate the handoff times).
// Placement proxy, without any tracing: at each burst start the worker publishes sched_getcpu() (-1 again before it
// blocks) and counts a burst start on a CPU equal to another worker's published burst-start CPU, plus the burst
// starts per CPU. Not proof that both were runnable on that CPU at that instant: a worker can be moved while
// descheduled, and its published CPU only changes when it runs again.
#define _GNU_SOURCE
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/eventfd.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <time.h>
#include <unistd.h>

#define MAX_SAMPLES (1 << 22)
#define MAX_CPUS 64

static long iters_per_burst;
static int gap_us, seconds, waker_cpu = -1;
static uint64_t stacked_ns;   // a handoff at least this long counts as stacked (half a burst)
static atomic_int stop;
static int nworkers;
static struct worker *all;
static uint64_t waker_run_ns, waker_wait_ns;

struct worker {
    pthread_t th;
    int efd;
    _Atomic uint64_t ready_at;   // end of the worker's burst, just before it blocks; 0 while it runs
    _Atomic uint64_t signaled_at;
    _Atomic int cpu;   // sched_getcpu() at the start of the current burst; -1 outside the burst phase
    long overlap;   // bursts whose start CPU equals another worker's published burst-start CPU
    long bursts_on[MAX_CPUS];   // bursts started per CPU (sched_getcpu() at burst start)
    uint64_t wait_ns, run_ns;
    long nvcsw;   // voluntary context switches during the run: a proxy for how often it blocked
    uint32_t *burst_ns, *wake_ns;
    long bursts, wakes;
    long stacked;   // handoffs >= stacked_ns
};

static uint64_t now_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t) ts.tv_sec * 1000000000ull + ts.tv_nsec;
}

static void schedstat(uint64_t *run, uint64_t *wait) {
    FILE *f = fopen("/proc/thread-self/schedstat", "r");
    unsigned long long r = 0, w = 0;
    if (!f || fscanf(f, "%llu %llu", &r, &w) != 2) {
        perror("schedstat");
        exit(1);
    }
    fclose(f);
    *run = r;
    *wait = w;
}

// First line of a (debugfs) file, or "?" when it cannot be read (needs root).
static const char *read_line(const char *path, char *buf, size_t n) {
    FILE *f = fopen(path, "r");
    if (!f || !fgets(buf, n, f)) {
        if (f) {
            fclose(f);
        }
        return "?";
    }
    fclose(f);
    buf[strcspn(buf, "\n")] = 0;
    return buf;
}

// Integer from a sysfs file, or -1.
static long read_long(const char *fmt, int cpu) {
    char path[256], buf[64];
    snprintf(path, sizeof(path), fmt, cpu);
    const char *s = read_line(path, buf, sizeof(buf));
    return s[0] == '?' ? -1 : atol(s);
}

// Parses a sysfs CPU list ("4,20" or "0-3,16-19").
static void parse_cpulist(const char *s, cpu_set_t *set) {
    CPU_ZERO(set);
    while (*s) {
        char *end;
        long a = strtol(s, &end, 10), b = a;
        if (end == s) {
            break;
        }
        if (*end == '-') {
            s = end + 1;
            b = strtol(s, &end, 10);
        }
        for (long c = a; c <= b && c < CPU_SETSIZE; c++) {
            CPU_SET(c, set);
        }
        s = *end == ',' ? end + 1 : end;
    }
}

// Preconditions, without root. Asym packing only moves work towards a CPU whose preferred-core rank is strictly
// higher (sched_asym_prefer() compares with '>'), so the workers are expected to share a run queue only when the
// highest rank in the allowed set belongs to exactly one CPU. Ranks are read from amd_pstate_prefcore_ranking
// (AMD only; "?" elsewhere). Also reports SMT siblings inside the set and the clock settings of the allowed CPUs.
static char pre_summary[512];

static void preflight(const cpu_set_t *allowed) {
    long top = -1;
    int top_cpu = -1, ntop = 0, nrank = 0, smt_pairs = 0, waker_sib_in_set = 0, pinned = 1, n = 0;
    char gov0[32] = "?", tops[128] = "";
    for (int c = 0; c < CPU_SETSIZE; c++) {
        if (!CPU_ISSET(c, allowed)) {
            continue;
        }
        n++;
        long r = read_long("/sys/devices/system/cpu/cpu%d/cpufreq/amd_pstate_prefcore_ranking", c);
        if (r >= 0) {
            nrank++;
            if (r > top) {
                top = r, top_cpu = c;
            }
        }
        char path[128], buf[256];
        cpu_set_t sib;
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", c);
        parse_cpulist(read_line(path, buf, sizeof(buf)), &sib);
        for (int s = c + 1; s < CPU_SETSIZE; s++) {
            smt_pairs += CPU_ISSET(s, &sib) && CPU_ISSET(s, allowed);
        }
        if (waker_cpu >= 0 && waker_cpu != c && CPU_ISSET(waker_cpu, &sib)) {
            waker_sib_in_set = 1;
        }
        long lo = read_long("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_min_freq", c);
        long hi = read_long("/sys/devices/system/cpu/cpu%d/cpufreq/scaling_max_freq", c);
        pinned &= lo > 0 && lo == hi;
        if (gov0[0] == '?') {
            snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/cpufreq/scaling_governor", c);
            snprintf(gov0, sizeof(gov0), "%s", read_line(path, buf, sizeof(buf)));
        }
    }
    // A tie between SMT siblings of one core is not a tie between cores: count distinct cores at the top rank.
    cpu_set_t seen;
    CPU_ZERO(&seen);
    ntop = 0;
    for (int c = 0; top >= 0 && c < CPU_SETSIZE; c++) {
        if (!CPU_ISSET(c, allowed) || CPU_ISSET(c, &seen) ||
            read_long("/sys/devices/system/cpu/cpu%d/cpufreq/amd_pstate_prefcore_ranking", c) != top) {
            continue;
        }
        char path[128], buf[256];
        cpu_set_t sib;
        snprintf(path, sizeof(path), "/sys/devices/system/cpu/cpu%d/topology/thread_siblings_list", c);
        parse_cpulist(read_line(path, buf, sizeof(buf)), &sib);
        CPU_OR(&seen, &seen, &sib);
        ntop++;
        snprintf(tops + strlen(tops), sizeof(tops) - strlen(tops), "%s%d", tops[0] ? "," : "", c);
    }
    long boost = read_long("/sys/devices/system/cpu/cpufreq/boost", 0);
    const char *top_state = nrank < n ? "?" : ntop == 1 ? "unique" : "tied";
    snprintf(pre_summary, sizeof(pre_summary), "top_rank=%s(cpu%d:%ld) smt_pairs_in_set=%d governor=%s minmax=%s boost=%ld",
             top_state, top_cpu, top, smt_pairs, gov0, pinned ? "pinned" : "range", boost);
    fprintf(stderr, "preflight: %s\n", pre_summary);
    if (ntop > 1) {
        fprintf(stderr, "preflight: note: CPUs %s (different cores) share the top rank %ld of the allowed set. "
                "On one machine such sets did not reproduce, on another they did; see README 'What a run needs'.\n",
                tops, top);
    }
    if (nrank < n) {
        fprintf(stderr, "preflight: WARNING: no amd_pstate_prefcore_ranking for some allowed CPUs; check the ranks "
                "yourself (root: /sys/kernel/debug/x86/sched_core_priority).\n");
    }
    if (smt_pairs) {
        fprintf(stderr, "preflight: WARNING: the set contains %d SMT sibling pair(s); the effect is much weaker "
                "with siblings allowed. Use one hardware thread per core.\n", smt_pairs);
    }
    if (waker_cpu >= 0 && CPU_ISSET(waker_cpu, allowed)) {
        fprintf(stderr, "preflight: WARNING: waker_cpu %d is inside the allowed set; keep it outside.\n", waker_cpu);
    }
    if (waker_sib_in_set) {
        fprintf(stderr, "preflight: WARNING: the SMT sibling of waker_cpu %d is in the allowed set.\n", waker_cpu);
    }
    if (!pinned || boost != 0) {
        fprintf(stderr, "preflight: WARNING: clocks are not pinned (min != max or boost on). On one box the effect "
                "was not measurable until clocks were pinned; see README.\n");
    }
}

static uint64_t burst(uint64_t x, long n) {
    for (long i = 0; i < n; i++) {
        x = x * 6364136223846793005ull + 1442695040888963407ull;
    }
    return x;
}

static void pin(int cpu) {
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpu, &set);
    if (sched_setaffinity(0, sizeof(set), &set) != 0) {
        perror("sched_setaffinity");
        exit(1);
    }
}

static uint32_t clamp32(uint64_t v) {
    return v > UINT32_MAX ? UINT32_MAX : (uint32_t) v;
}

static void *run(void *arg) {
    struct worker *w = arg;
    struct timespec nap = { 0, (long) gap_us * 1000 };
    uint64_t r0, w0, r1, w1, sink = (uint64_t) (uintptr_t) w, v;
    struct rusage ru;
    pthread_setname_np(pthread_self(), "asym-worker");
    fprintf(stderr, "worker tid %d\n", gettid());
    prctl(PR_SET_TIMERSLACK, 1UL);
    getrusage(RUSAGE_THREAD, &ru);
    long nvcsw0 = ru.ru_nvcsw;
    schedstat(&r0, &w0);
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        int c = sched_getcpu();
        atomic_store_explicit(&w->cpu, c, memory_order_relaxed);
        for (int i = 0; c >= 0 && i < nworkers; i++) {
            if (&all[i] != w && atomic_load_explicit(&all[i].cpu, memory_order_relaxed) == c) {
                w->overlap++;
                break;
            }
        }
        if (c >= 0 && c < MAX_CPUS) {
            w->bursts_on[c]++;
        }
        uint64_t t0 = now_ns();
        sink = burst(sink, iters_per_burst);
        uint64_t t1 = now_ns();
        if (w->bursts < MAX_SAMPLES) {
            w->burst_ns[w->bursts++] = clamp32(t1 - t0);
        }
        atomic_store_explicit(&w->cpu, -1, memory_order_relaxed);
        if (waker_cpu < 0) {
            nanosleep(&nap, NULL);
            continue;
        }
        atomic_store_explicit(&w->ready_at, t1, memory_order_release);
        if (read(w->efd, &v, sizeof(v)) != sizeof(v)) {
            perror("read eventfd");
            exit(1);
        }
        uint64_t s = atomic_load_explicit(&w->signaled_at, memory_order_acquire);
        if (s) {
            uint64_t d = now_ns() - s;
            w->stacked += d >= stacked_ns;
            if (w->wakes < MAX_SAMPLES) {
                w->wake_ns[w->wakes++] = clamp32(d);
            }
        }
    }
    getrusage(RUSAGE_THREAD, &ru);
    w->nvcsw = ru.ru_nvcsw - nvcsw0;
    schedstat(&r1, &w1);
    w->run_ns = r1 - r0;
    w->wait_ns = w1 - w0;
    return (void *) (uintptr_t) (sink == 42);   // keeps the burst from being optimized away
}

// Polls the workers and signals each one gap_us after its burst ended.
static void *waker(void *arg) {
    struct worker *ws = arg;
    uint64_t one = 1, r0, w0, r1, w1;
    pthread_setname_np(pthread_self(), "asym-waker");
    pin(waker_cpu);
    schedstat(&r0, &w0);
    while (!atomic_load_explicit(&stop, memory_order_relaxed)) {
        for (int i = 0; i < nworkers; i++) {
            uint64_t r = atomic_load_explicit(&ws[i].ready_at, memory_order_acquire);
            if (!r) {
                continue;
            }
            uint64_t t = now_ns();
            if (t >= r && t - r >= (uint64_t) gap_us * 1000) {
                atomic_store_explicit(&ws[i].ready_at, 0, memory_order_relaxed);
                atomic_store_explicit(&ws[i].signaled_at, now_ns(), memory_order_release);
                if (write(ws[i].efd, &one, sizeof(one)) != sizeof(one)) {
                    perror("write eventfd");
                    exit(1);
                }
            }
        }
    }
    for (int i = 0; i < nworkers; i++) {   // release workers blocked at stop
        atomic_store_explicit(&ws[i].signaled_at, 0, memory_order_release);
        if (write(ws[i].efd, &one, sizeof(one)) != sizeof(one)) {
            perror("write eventfd");
        }
    }
    schedstat(&r1, &w1);
    waker_run_ns = r1 - r0;
    waker_wait_ns = w1 - w0;
    return NULL;
}

static int cmp_u32(const void *a, const void *b) {
    uint32_t x = *(const uint32_t *) a, y = *(const uint32_t *) b;
    return x < y ? -1 : x > y;
}

static void print_pcts(const char *name, uint32_t *v, long n) {
    if (n == 0) {
        return;
    }
    qsort(v, n, sizeof(uint32_t), cmp_u32);
    printf(" %s p50 %.3f p99 %.3f p99.9 %.3f max %.3f ms", name, v[n / 2] * 1e-6, v[n * 99 / 100] * 1e-6,
           v[n * 999 / 1000] * 1e-6, v[n - 1] * 1e-6);
}

int main(int argc, char **argv) {
    if (argc < 5 || argc > 6) {
        fprintf(stderr, "usage: %s <threads> <burst_us> <gap_us> <seconds> [waker_cpu|-1]\n",
                argv[0]);
        return 2;
    }
    nworkers = atoi(argv[1]);
    int burst_us = atoi(argv[2]);
    gap_us = atoi(argv[3]);
    seconds = atoi(argv[4]);
    if (argc > 5) {
        waker_cpu = atoi(argv[5]);
    }

    // calibrate the burst size alone, before any thread starts
    long probe = 1000000;
    uint64_t best = UINT64_MAX, x = 1;
    for (int i = 0; i < 20; i++) {
        uint64_t t0 = now_ns();
        x = burst(x, probe);
        uint64_t dt = now_ns() - t0;
        if (dt < best) {
            best = dt;
        }
    }
    iters_per_burst = (long) ((double) probe * burst_us * 1000.0 / best) + (x == 42);
    stacked_ns = (uint64_t) burst_us * 500;

    cpu_set_t allowed;
    if (sched_getaffinity(0, sizeof(allowed), &allowed) != 0) {
        perror("sched_getaffinity");
        return 1;
    }
    preflight(&allowed);
    pthread_t wk;
    struct worker *ws = calloc(nworkers, sizeof(*ws));
    all = ws;
    for (int i = 0; i < nworkers; i++) {
        atomic_store(&ws[i].cpu, -1);
    }
    for (int i = 0; i < nworkers; i++) {
        ws[i].efd = eventfd(0, 0);
        ws[i].burst_ns = malloc(sizeof(uint32_t) * MAX_SAMPLES);
        ws[i].wake_ns = malloc(sizeof(uint32_t) * MAX_SAMPLES);
        pthread_create(&ws[i].th, NULL, run, &ws[i]);
    }
    if (waker_cpu >= 0) {
        pthread_create(&wk, NULL, waker, ws);
    }
    struct timespec total = { seconds, 0 };
    nanosleep(&total, NULL);
    atomic_store(&stop, 1);
    if (waker_cpu >= 0) {
        pthread_join(wk, NULL);
    }
    for (int i = 0; i < nworkers; i++) {
        pthread_join(ws[i].th, NULL);
    }
    printf("threads=%d burst_us=%d gap_us=%d seconds=%d waker_cpu=%d\n", nworkers, burst_us, gap_us, seconds,
           waker_cpu);
    for (int i = 0; i < nworkers; i++) {
        struct worker *w = &ws[i];
        printf("worker %d: wait %.2f%% (run_ns %lu wait_ns %lu) bursts %ld vcsw %ld", i,
               100.0 * w->wait_ns / (w->run_ns + w->wait_ns), w->run_ns, w->wait_ns, w->bursts,
               w->nvcsw);
        print_pcts("burst", w->burst_ns, w->bursts);
        print_pcts("handoff", w->wake_ns, w->wakes);
        if (w->wakes) {
            printf(" stacked(>=%.1fms) %ld of %ld", stacked_ns * 1e-6, w->stacked, w->wakes);
        }
        printf("\n  published-start-CPU overlap %ld of %ld bursts (%.2f%%); burst starts per CPU:", w->overlap,
               w->bursts, 100.0 * w->overlap / w->bursts);
        for (int c = 0; c < MAX_CPUS; c++) {
            if (w->bursts_on[c]) {
                printf(" %d:%ld", c, w->bursts_on[c]);
            }
        }
        printf("\n");
    }

    // one line per run, for collecting repetitions
    char buf[1024];
    const char *features = read_line("/sys/kernel/debug/sched/features", buf, sizeof(buf));
    const char *dd = strstr(features, "NO_DELAY_DEQUEUE") ? "N" : strstr(features, "DELAY_DEQUEUE") ? "Y" : "?";
    char ibuf[8];
    const char *itmt = read_line("/sys/kernel/debug/x86/sched_itmt_enabled", ibuf, sizeof(ibuf));
    printf("SUMMARY itmt=%s delay_dequeue=%s allowed_cpus=", itmt, dd);
    for (int c = 0, first = 1; c < CPU_SETSIZE; c++) {
        if (CPU_ISSET(c, &allowed)) {
            printf("%s%d", first ? "" : ",", c);
            first = 0;
        }
    }
    printf(" waker_cpu=%d seconds=%d %s", waker_cpu, seconds, pre_summary);
    printf(" wait%%=");
    for (int i = 0; i < nworkers; i++) {
        printf("%s%.2f", i ? "," : "", 100.0 * ws[i].wait_ns / (ws[i].run_ns + ws[i].wait_ns));
    }
    printf(" burst_max_ms=");
    for (int i = 0; i < nworkers; i++) {   // burst_ns is sorted by print_pcts above
        printf("%s%.3f", i ? "," : "", ws[i].bursts ? ws[i].burst_ns[ws[i].bursts - 1] * 1e-6 : 0.0);
    }
    if (waker_cpu >= 0) {
        printf(" stacked=");
        for (int i = 0; i < nworkers; i++) {
            printf("%s%ld", i ? "," : "", ws[i].stacked);
        }
        printf(" wakes=");
        for (int i = 0; i < nworkers; i++) {
            printf("%s%ld", i ? "," : "", ws[i].wakes);
        }
        printf(" handoff_max_ms=");
        for (int i = 0; i < nworkers; i++) {   // wake_ns is sorted by print_pcts above
            printf("%s%.3f", i ? "," : "", ws[i].wakes ? ws[i].wake_ns[ws[i].wakes - 1] * 1e-6 : 0.0);
        }
        printf(" waker_wait%%=%.3f", 100.0 * waker_wait_ns / (waker_run_ns + waker_wait_ns));
    }
    printf("\n");
    return 0;
}
