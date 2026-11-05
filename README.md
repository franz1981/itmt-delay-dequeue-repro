# ITMT + DELAY_DEQUEUE: two busy threads queue behind each other on the preferred CPU

Kernel 7.1.13-100.fc43.x86_64 (Fedora, untainted), AMD Ryzen 9 7950X, ITMT on (AMD preferred cores), DELAY_DEQUEUE
on (both defaults), 4300 MHz fixed, boost off. Box details in `system.txt` (preferred-core ranks: CPU 6 is the
highest of CPUs 4-7; SMT siblings are n and n+16).

Two workers each run a calibrated ~1 ms CPU burst, then block on an eventfd. A waker thread busy-polls on CPU 2
(100 % of that CPU) and signals each worker ~10 us after its burst ends, like event loops woken from network softirq
on other CPUs. Four CPUs are allowed and only two threads are busy, yet with ITMT on a woken worker regularly waits a
full burst (~1 ms) behind the other worker on CPU 6.

    gcc -O2 -pthread -o asym_min asym_min.c        # the reproducer (one SUMMARY line per run)
    taskset -c 4-7 ./asym_min 1000 10 30 2         # burst_us gap_us seconds waker_cpu
    sudo ./final.sh 5 30                           # defaults / ITMT off / NO_DELAY_DEQUEUE / +siblings, interleaved
    python3 -I summarize.py results-final-min.txt
    sudo bpftrace stackcheck.bt -c "taskset -c 4-7 ./asym_min 1000 10 30 2"    # where and how (one run)
    ./scan.sh          # other machines: same test over several CPU sets (no root), uses asym_stack2

Requirements: gcc and taskset for `asym_min` (no root; ITMT/DELAY_DEQUEUE state shows `?` without root). Root for
`final.sh`, `ab.sh` and `preconditions.sh`: they toggle `/sys/kernel/debug/x86/sched_itmt_enabled` and
`/sys/kernel/debug/sched/features` and restore both on exit (`preconditions.sh` also changes cpufreq settings and
restores them). bpftrace for the `.bt` scripts. The CPU set 4-7 and waker CPU 2 are for the 7950X in `system.txt`;
other machines may need other CPUs, see "Other machines". `config-7.1.13-100.fc43.x86_64` is the kernel config used.

`asym_stack2.c` is the earlier, longer version (preflight checks, per-CPU placement counts, per-worker detail); the
sections dated 2026-10-31 and the `results-*.txt` files other than `results-final-min*` were measured with it.
Its field descriptions follow.


`SUMMARY` fields, per worker: `wait%` = run-queue wait share from /proc/thread-self/schedstat, wait/(run+wait)
(`run_delay`; on 7.1.13 it can over-count for sched_delayed tasks migrated while asleep, see `upstream-status.txt`,
so `stacked` and `handoff_max_ms` are the primary numbers);
`stacked` = handoffs of at least half a burst (0.5 ms), where a handoff is the waker's timestamp just before the
eventfd write -> the worker's read returning; `handoff_max_ms`, `burst_max_ms` = longest of each. `waker_wait%` is the
waker's own run-queue wait share (0.007-0.048 % in all runs, so a delayed waker does not explain the long handoffs).
`itmt=`/`delay_dequeue=` are read from debugfs and show `?` unless run as root. The preflight fields (no root):
`top_rank` = highest `amd_pstate_prefcore_ranking` in the allowed set and whether one physical core holds it
(`unique`) or several (`tied`); `smt_pairs_in_set`; `governor`, `minmax` (`pinned` = min == max on every allowed
CPU), `boost`. The preflight also warns on stderr when the waker CPU or its SMT sibling is in the allowed set.

## Run cited in the report (2026-11-03, `asym_min`, `final.sh 5 30`, `results-final-min.txt`)

5 interleaved rounds of 30 s runs, CPUs 4-7, waker CPU 2, clocks pinned. Stalls (handoffs >= 0.5 ms) per run, both
workers summed:

| setting | stalls per 30 s run | total |
|---|---|---|
| defaults | 212, 49, 48, 76, 214 | 599 of 294616 |
| ITMT off | 1, 0, 0, 0, 0 | 1 of 295349 |
| NO_DELAY_DEQUEUE | 21, 9, 11, 26, 14 | 81 of 295201 |
| defaults, siblings 20-23 allowed | 16, 27, 15, 13, 2 | 73 of 295215 |

Traces (`results-final-min-trace.txt`): 310 and 153 long waits (program: 312, 153); 288 and 137 on CPU 6 behind the
other worker; 280 and 139 after a delayed wakeup with no CPU selection (340 and 174 such wakeups of 58592 and 58770);
the other worker moved there by active balance in 30 and 12. `results-final-min-idle.txt`: 3 of 4 allowed CPUs idle
at the waiter's wakeup in all 102 long waits. `asym_min` stalled about 3x less often than `asym_stack2` (next
section); why is not known.

## Same matrix with asym_stack2 (2026-11-03, `results-final.txt`)

5 interleaved rounds of 30 s runs, CPUs 4-7, waker CPU 2, clocks pinned (4300 MHz, boost off). Stalls (`stacked`) per
run, both workers summed:

| setting | stalls per 30 s run | stalled wakeups | handoff p99.9 | longest handoff |
|---|---|---|---|---|
| defaults | 282, 207, 282, 413, 559 | 1743 of 293266 (0.59 %) | 0.997-0.998 ms | 2.807 ms |
| ITMT off | 0, 0, 0, 0, 3 | 3 of 295315 | 0.004-0.007 ms | 0.999 ms |
| NO_DELAY_DEQUEUE | 30, 20, 29, 16, 34 | 129 of 294977 (0.044 %) | 0.005-0.117 ms | 2.813 ms |
| defaults, siblings 20-23 allowed | 7, 11, 23, 1, 13 | 55 of 295307 | 0.005-0.008 ms | 1.364 ms |

Traces with the defaults, two 30 s runs (`results-final-trace.txt`): 477 and 283 long waits (program: 477, 284); 440
and 258 on CPU 6 behind the other worker; 436 and 256 after a delayed wakeup with no CPU selection (519 and 300 such
wakeups out of 58441 and 58670); the other worker had been moved to CPU 6 by active balance in 31 and 23.
`stackcheck-idle.bt` (`results-final-idle.txt`): at the waiter's wakeup, 3 of the 4 allowed CPUs were idle in 360 of
377 long waits (all wakeups: 3 idle in 40601, 4 idle in 17186 of 58383, the expected shape). That is the state at the
wakeup, not for the whole wait. CPUs 4-7 report the same `amd_pstate_highest_perf` (166), only the ranking differs.

## What a run needs

Measured on two machines. The second is a Ryzen 9 9950X3D2 on 7.2.15-300.fc45 (tainted: nvidia), run by someone
else from this README; its numbers are from their report, not re-measured here.

| condition | 7950X, 7.1.13 (this box) | 9950X3D2, 7.2.15 |
|---|---|---|
| ITMT on | needed: ITMT off gave 0 stacked on 4-7 (5 runs) and 1,3,5,7 (3 runs) | needed: ITMT off gave 0 |
| one hardware thread per core | siblings allowed: 0-8 per worker per 10 s, vs 11-75 without | about 6x fewer with siblings allowed |
| clocks pinned | not needed: unpinned runs stacked as much or more (table below) | needed: powersave + boost gave 2 stacked in 24 runs |
| unique top rank in the allowed set | does not predict the rate (table below) | tied-top sets stacked ~12x less than unique-top sets |
| documented set `taskset -c 4-7`, waker 2 | 259-323 stacked per 30 s run | ~0 (CPUs 4 and 5 tie at rank 236) |

What decides the rate on a given machine and CPU set is not known. Two of the second box's conditions (pinned
clocks, unique top rank) do not hold on this box. The rate also varies by more than 50x between runs of the same set
(0-3 below: 3, 11, 169). Their powersave runs used an EPP value that was not recorded; the powersave runs here set
`balance_performance`.

`preconditions.sh` (root, 2026-11-03, `results-preconditions.txt`): 3 interleaved rounds, 30 s runs, 2 workers,
1 ms burst, 10 us gap; clocks pinned at 4300 MHz with boost off unless stated; ITMT and DELAY_DEQUEUE on unless
stated. Stacked = both workers summed, per run, in round order.

| CPU set (waker) | ranks | top | stacked per 30 s run |
|---|---|---|---|
| 4-7 (2) | 211 216 231 221 | unique, 6 | 259, 277, 323 |
| 1,3,5,7 (2) | 236 236 216 221 | tied, 1 and 3 | 28, 4, 4 |
| 0-3 (6) | 206 236 226 236 | tied, 1 and 3 | 3, 11, 169 |
| 0,2,5,7 (4) | 206 226 216 221 | unique, 2 | 0, 0, 12 |
| 8-11 (12) | 171 191 186 196 | unique, 11 | 17, 42, 2 |
| 4-7 (2), performance governor, full range, boost on | | | 276, 197, 197 |
| 4-7 (2), powersave, EPP balance_performance, full range, boost on | | | 403, 434, 507 |
| 1,3,5,7 (2), ITMT off | | | 0, 0, 0 |
| 1,3,5,7 (2), NO_DELAY_DEQUEUE | | | 19, 16, 12 |

The waker CPU differs between sets, so set and waker CPU are not separated here. In the tied sets both workers ran on
the two top CPUs (1 and 3) and moved between them: each worker started 27-72 % of its bursts on each of the two. On
the second box, with the tied set 4-7, each worker stayed on one of the two top CPUs (95-99 % and 85-99 % of
bursts). Why the two boxes differ there is not known. NO_DELAY_DEQUEUE did not lower the count on the tied set
1,3,5,7 (47 vs 36 summed); on 4-7 it did (23 vs 374, below).

Two 30 s traces of the tied set 1,3,5,7 (`results-trace-tied.txt`) show the same pattern as 4-7 (next sections):
20 of 29 and 10 of 13 long waits were behind the other worker on CPU 1 or 3, and 23 of 29 and 10 of 13 long waits
followed a delayed wakeup that selected no CPU (26 and 14 such wakeups out of ~58,900 per run). The remaining long
waits were behind unrelated tasks (kworkers, systemd, desktop processes).

In the 30 s runs the longest handoff on 4-7 was 1.1-2.8 ms, i.e. longer than one burst; the 10 s runs below topped
out at 1.007 ms. Not investigated.

## Other machines

1. Build and run the documented command 3 times, 30 s each. Read the `preflight:` lines: they flag SMT siblings
   in the set, a waker inside the set, unpinned clocks and a tied top rank. They do not decide whether it reproduces.
2. If `stacked` stays near 0, run `./scan.sh` (no root, ~15 min on a 16-core part): it tries 4 consecutive physical
   cores per NUMA node, one thread each, waker on the next core, 3 x 30 s, and prints stacked per run per set.
   `SETS="4-7:2 2,3,6,7:12" ./scan.sh` runs given sets instead.
3. For a set that stacks, run `ab.sh` with that set (`sudo ./ab.sh 5 <cpus> <waker>`) and the trace with it.
4. Ranks: `amd_pstate_prefcore_ranking` (AMD, no root) or `/sys/kernel/debug/x86/sched_core_priority` (root). On
   this box both are equal; they can change at runtime and after firmware updates. Intel ITMT is untested.

## ITMT / DELAY_DEQUEUE A/B on 4-7 (2026-10-31, `ab.sh 5`: 5 interleaved rounds of 10 s runs, `results-ab.txt`)

| setting | wait per worker | stacked per worker per 10 s | longest handoff |
|---|---|---|---|
| ITMT on, DELAY_DEQUEUE on (default) | 0.16-0.85 % | 11-75 | 0.998-1.007 ms |
| ITMT off | 0.00 % | 0 | 5-7 us |
| ITMT on, NO_DELAY_DEQUEUE | 0.01-0.09 % | 1-5 | 0.94-1.01 ms |
| default, SMT siblings also allowed (`taskset -c 4-7,20-23`), 3 runs | 0.00-0.10 % | 0-8 | 0.007-1.008 ms |

ITMT off removes it. NO_DELAY_DEQUEUE leaves 1/16 of the stacked handoffs (23 vs 374 summed over the 5 rounds) and
1/9 of the mean wait share. On CPUs 4-7 with both defaults every run so far had stacked handoffs for both workers, but
the rate varies a lot from run to run (11-75 here, 3 and 1 in one traced run below), so a single round does not always
separate the defaults from NO_DELAY_DEQUEUE; use several. Why the rate varies is not known. With ITMT on the longest
burst is ~2 ms in nearly every run (a burst that shared its CPU), vs 1.02 ms with ITMT off; `wait%` includes that,
`stacked` does not.

## Where and how (`stackcheck.bt`, `results-trace.txt`)

The script follows every worker wakeup from `sched_waking` to the worker's switch-in. Per wakeup it records whether
the worker was still queued as delayed (`se.sched_delayed` at `try_to_wake_up()` entry) and whether
`select_task_rq_fair()` ran. For waits of at least 0.5 ms it records the CPU, what that CPU ran just before, and how
the other worker got there. Its long-wait count equals the program's `stacked` total in all 5 traced runs, and its
wakeup count is within 2 of the program's wakes.

| run | long waits | on CPU 6 behind the other worker | waiter's wakeup: delayed, no CPU selection | other worker got onto CPU 6 by |
|---|---|---|---|---|
| default 1 (10 s) | 80 | 76 | 75 (of 90 delayed wakeups in 19.6k) | delayed wakeup 61, selected wakeup 10, active balance 5 |
| default 2 (10 s) | 4 | 4 | 3 (of 5) | delayed wakeup 1, selected wakeup 2, active balance 1 |
| default 3 (10 s) | 51 | 45 | 44 (of 53) | delayed wakeup 33, selected wakeup 7, active balance 5 |
| NO_DELAY_DEQUEUE 1 (20 s) | 1 | 0 | 0 (feature off) | (the one wait ended on idle CPU 7) |
| NO_DELAY_DEQUEUE 2 (20 s) | 5 | 5 | 0 (feature off; 4 selected a CPU, 1 neither) | active balance 4, newidle balance 1 |

Measured: delayed wakeups are rare (0.03-0.46 % of all wakeups) and never select a CPU, all other wakeups but at most one per run do; but
most of the long waits (75 of 80, 3 of 4, 44 of 51) are such delayed wakeups re-queued on CPU 6 while the other worker
runs there. "Active balance" = the other worker was moved by `active_load_balance_cpu_stop`, "newidle balance" = by
`detach_tasks` from `sched_balance_newidle`.

The code path, 7.1.13 (read in the source, matches the traced flags):

    fair.c:dequeue_entity()     if (sched_feat(DELAY_DEQUEUE) && delay &&
                                    !entity_eligible(cfs_rq, se)) { ... set_delayed(se); return false; }
    core.c:try_to_wake_up()     if (READ_ONCE(p->on_rq) && ttwu_runnable(p, wake_flags))
                                        break;          <- select_task_rq() comes after this, not reached
    core.c:ttwu_runnable()      if (p->se.sched_delayed)
                                        enqueue_task(rq, p, ENQUEUE_NOCLOCK | ENQUEUE_DELAYED);
    fair.c:pick_next_entity()   if (se->sched_delayed) { dequeue_entities(...DEQUEUE_DELAYED); return NULL; }

A task alone on its cfs_rq is always eligible (`vruntime_eligible()`: `avg >= key * load` with `avg = key*w`,
`load = w`), so a worker can only be delayed while another task shares its cfs_rq: DELAY_DEQUEUE keeps two workers
stacked once they are, it cannot stack them. How the first stacking happens is only partly traced (the other worker
reached CPU 6 by active balance in 5 of 76, 1 of 4 and 5 of 45 long waits; most arrivals were its own delayed
wakeup, i.e. it was already there). Documented: a delayed task stays queued until it is picked or woken (features.h,
"Delay dequeueing tasks until they get selected or woken"; commit 152e11f6df29, "sched/fair: Implement delayed
dequeue"). Not documented anywhere found: that the wakeup re-queues it on the same CPU without selecting one; that is
what the code does, and Peter Zijlstra's unmerged "[PATCH v2 11/12] sched: Change ttwu_runnable() vs sched_delayed"
(2025-07-02) proposed changing it. Whether the resulting placement is intended is not known.

With NO_DELAY_DEQUEUE every wakeup selects a CPU, and the remaining long waits are on CPU 6 right after a balancer
moved the other worker there; why the waiter's own wakeup still ended on CPU 6 in those cases is not traced.

Not verified: why the wait is about one burst. The longest handoff in 30 s runs, 2.822 ms, is close to
`base_slice_ns` (2.8 ms, `system.txt`); whether that is related is not known.

## Follow-up, 2026-11-04: boost on, and throughput

Same box and kernel. DELAY_DEQUEUE on unless stated; ITMT on/off alternated per round. Run as root.

| script | what | results |
|---|---|---|
| `tbench-pinned.sh 3 30 1,2,4 4-7` | tbench (dbench 4.0, loopback) on CPUs 4-7, clocks pinned as found (boost off, 4300 MHz), ITMT x DELAY_DEQUEUE | `results-tbench-pinned.txt` |
| `freeclock-tbench.sh 3 30 1,2,4 4-7` | the same with clocks freed (performance governor, boost on, full range), restored on exit | `results-freeclock-tbench.txt` |
| `freeclock-ab.sh 3 30 8,32` | clocks freed: asym_min on CPUs 4-7 with fixed work per burst (`ASYM_ITERS`), tbench 8/32 clients on all CPUs, ITMT x DELAY_DEQUEUE | `results-freeclock.txt` |
| `INNER=probe-tbench.sh freeclock-tbench.sh 8 30 1 4-7` | clocks freed, tbench 1 client on CPUs 4-7 under `perf stat` (msr aperf/mperf/tsc; second run also energy-pkg/energy-core) | `results-probe-tbench.txt`, `results-probe-energy.txt` |

`asym_min.c` now takes `ASYM_ITERS` (fixed iterations per burst, to compare work across clock settings) and prints
`burst_iters` in SUMMARY; nothing else changed. A stall is still a handoff of 0.5 ms or more (`stacked=` in SUMMARY).
The `# summary` blocks at the end of the results files were computed from the lines above them.

## perf sched trace, 2026-11-04

`perfsched.sh` runs `perf sched record -a -- taskset -c 4-7 ./asym_min 1000 10 30 2` three times (clocks pinned, boost
off, ITMT and DELAY_DEQUEUE on); `perfsched_summary.py` reads `perf sched timehist -w -M --state` and counts, per wait
of 0.5 ms or more, where it happened, whether a worker migrated during it and how much of it the other allowed CPUs
spent in `<idle>`. Results: `results-perfsched.txt` (the `# CORRECTED` block at the end supersedes the summary above
it). `perfsched/excerpt-run2.txt`: unedited timehist lines of one episode start. The perf.data files are not
published (`-a` records every task on the machine).
