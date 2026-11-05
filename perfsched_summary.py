#!/usr/bin/python3 -I
# Summarise `perf sched timehist -w -M --state` output of an asym_min run (CPUs 4-7, waker on CPU 2), recorded with
# perf sched record -a (all CPUs: every switch on a CPU is needed to rebuild switch-in times).
#   perf sched timehist -i perfsched/run1.data -w -M --state 2>/dev/null | python3 -I perfsched_summary.py
# All times come from event timestamps, not from perf's rounded duration columns:
#   switch-in of a task on CPU c = timestamp of the previous switch row on CPU c;
#   <idle> interval on CPU c = [previous switch row on c, the <idle> row];
#   wakeup wait = [the worker's last "awakened" event since its previous switch-out (state S), its switch-in];
#   preempted wait = [its switch-out in state R, its next switch-in].
# For every asym-worker wait >= 0.5 ms: the CPU it started running on ("run CPU"), whether it was migrated during
# the wait (then it waited on the migration's source CPU), the share of the wait each of CPUs 4-7 ran <idle>, and
# the share of the wait the other worker ran on the run CPU.
import re, sys, collections, statistics

SW = re.compile(r"^\s*(\d+\.\d+)\s+\[(\d+)\]\s+(.+?)\s+(\d+\.\d+)\s+(\d+\.\d+)\s+(\d+\.\d+)\s+(\S+)\s*$")
EV = re.compile(r"^\s*(\d+\.\d+)\s+\[(\d+)\]\s+(.+?)\s+(awakened|migrated): (\S+)(?: cpu (\d+) => (\d+))?\s*$")
WORKER = re.compile(r"^asym-worker\[(\d+)/")
CPUS = (4, 5, 6, 7)
LONG = 0.5e-3

last_sw = {}                              # cpu -> timestamp of the previous switch row on it
idle = collections.defaultdict(list)      # cpu -> [(start, end)]
runs = collections.defaultdict(list)      # tid -> [(switch_in, switch_out, cpu, state at switch-out)]
migr = collections.defaultdict(list)      # tid -> [(t, by, logged_cpu, src, dst)]
wakes = collections.defaultdict(list)     # tid -> [t]
unparsed = 0
for line in sys.stdin:
    m = SW.match(line)
    if m:
        t, cpu, task = float(m[1]), int(m[2]), m[3]
        start = last_sw.get(cpu)
        last_sw[cpu] = t
        if start is None:
            continue
        if task == "<idle>":
            idle[cpu].append((start, t))
        w = WORKER.match(task)
        if w:
            runs[int(w[1])].append((start, t, cpu, m[7]))
        continue
    m = EV.match(line)
    if m:
        w = WORKER.match(m[5])
        if w and m[4] == "migrated":
            migr[int(w[1])].append((float(m[1]), re.sub(r"\[.*", "", m[3]), int(m[2]), int(m[6]), int(m[7])))
        elif w:
            wakes[int(w[1])].append(float(m[1]))
        continue
    if re.match(r"^\s*\d+\.\d+\s", line):
        unparsed += 1

def overlap(iv, a, b):
    return sum(max(0.0, min(e, b) - max(s, a)) for s, e in iv)

tids = sorted(runs)
print(f"workers {tids}  unparsed event lines {unparsed} (lines of other tasks whose names contain spaces)")
rows = []
for tid in tids:
    other = [o for o in tids if o != tid][0]
    oruns = collections.defaultdict(list)
    for s, e, c, _ in runs[other]:
        oruns[c].append((s, e))
    r, wk = runs[tid], wakes[tid]
    j = 0
    for i in range(1, len(r)):
        prev_out, (sin, _, cpu, _) = r[i - 1][1], r[i]
        if r[i - 1][3] == "S":
            while j < len(wk) and wk[j] <= prev_out:
                j += 1
            k = j
            while k + 1 < len(wk) and wk[k + 1] <= sin:
                k += 1
            if j >= len(wk) or not prev_out < wk[k] <= sin:
                continue                  # no wakeup event between switch-out and switch-in
            a, kind = wk[k], "wakeup"
        elif r[i - 1][3] == "R":
            a, kind = prev_out, "preempted"
        else:
            continue
        if sin - a < LONG:
            continue
        mv = [x for x in migr[tid] if a <= x[0] <= sin]
        rows.append(dict(tid=tid, kind=kind, run_cpu=cpu, wait_cpu=mv[0][3] if mv else cpu, mv=mv, start=a,
                         wait=sin - a, sh={c: overlap(idle[c], a, sin) / (sin - a) for c in CPUS},
                         other=overlap(oruns[cpu], a, sin) / (sin - a)))

def report(title, r):
    print(f"\n{title}: {len(r)}  per tid {dict(collections.Counter(x['tid'] for x in r))}"
          f"  waited on cpu {dict(sorted(collections.Counter(x['wait_cpu'] for x in r).items()))}"
          f"  run cpu {dict(sorted(collections.Counter(x['run_cpu'] for x in r).items()))}")
    if not r:
        return
    w = [x["wait"] * 1e3 for x in r]
    print(f"  wait ms: min {min(w):.3f} median {statistics.median(w):.3f} max {max(w):.3f}")
    print(f"  run CPU <idle> share of the wait: max {max(x['sh'][x['run_cpu']] for x in r):.4f}")
    print(f"  other worker ran on the run CPU, share of the wait: min {min(x['other'] for x in r):.4f}")
    oth = [min(x["sh"][c] for c in CPUS if c != x["run_cpu"]) for x in r]
    print(f"  lowest <idle> share among the 3 other CPUs: min {min(oth):.4f} median {statistics.median(oth):.4f}")
    for lim in (0.99, 0.98, 0.95, 0.90):
        print(f"    all 3 other CPUs <idle> >= {lim:.0%} of the wait: {sum(o >= lim for o in oth)}/{len(r)}")

for kind in ("wakeup", "preempted"):
    k = [x for x in rows if x["kind"] == kind]
    report(f"{kind} waits >= 0.5 ms, not migrated during the wait", [x for x in k if not x["mv"]])
    m = [x for x in k if x["mv"]]
    print(f"\n{kind} waits >= 0.5 ms, migrated during the wait: {len(m)}")
    for x in m:
        print(f"  waited on cpu {x['wait_cpu']} ran on cpu {x['run_cpu']} wait {x['wait']*1e3:.3f} ms; moves: " +
              "; ".join(f"{b} on cpu {lc} {s}->{d} at {(t - x['start'])*1e3:.3f} ms into the wait"
                        for t, b, lc, s, d in x["mv"]))
