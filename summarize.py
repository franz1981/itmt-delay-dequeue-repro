#!/usr/bin/env python3
"""Summarize final.sh output: per config, per run, both workers. Usage: python3 -I summarize.py results-final*.txt
asym_stack2 output: cross-checks the per-worker lines against each run's SUMMARY line, exits non-zero on mismatch.
asym_min output: reads the SUMMARY line, exits non-zero if a field does not hold both workers' values.
wait % is only printed by asym_stack2 (nan for asym_min)."""
import re
import sys

W = re.compile(r'^worker (\d+): wait ([\d.]+)% .*? handoff p50 ([\d.]+) p99 ([\d.]+) p99\.9 ([\d.]+) max ([\d.]+) ms '
               r'stacked\(>=[\d.]+ms\) (\d+) of (\d+)')
runs, cur = [], None
for line in open(sys.argv[1]):
    if line.startswith('## round'):
        m = re.match(r'## round (\d+) config (\S+) cpus (\S+)', line)
        cur = {'round': int(m[1]), 'cfg': m[2], 'cpus': m[3], 'w': []}
        runs.append(cur)
    elif cur is not None and (m := W.match(line)):
        cur['w'].append(dict(wait=float(m[2]), p50=float(m[3]), p99=float(m[4]), p999=float(m[5]), mx=float(m[6]),
                             stacked=int(m[7]), wakes=int(m[8])))
    elif cur is not None and line.startswith('SUMMARY'):
        f = dict(kv.split('=', 1) for kv in line.split()[1:] if '=' in kv)
        cur['summary'] = f

MIN = ('stacked', 'wakes', 'handoff_p50_ms', 'handoff_p99_ms', 'handoff_p999_ms', 'handoff_max_ms')
for r in runs:   # asym_min output: the SUMMARY line is the only source; every field must hold both workers
    s = r.get('summary')
    if s and not r['w'] and 'handoff_p999_ms' in s:
        v = {k: s[k].split(',') for k in MIN}
        if any(len(x) != 2 for x in v.values()):
            sys.exit(f"bad SUMMARY in round {r['round']} {r['cfg']}: {s}")
        r['w'] = [dict(wait=float('nan'), p50=float(v['handoff_p50_ms'][i]), p99=float(v['handoff_p99_ms'][i]),
                       p999=float(v['handoff_p999_ms'][i]), mx=float(v['handoff_max_ms'][i]),
                       stacked=int(v['stacked'][i]), wakes=int(v['wakes'][i])) for i in (0, 1)]
        r['min'] = True

bad = 0
for r in runs:
    if r.get('min'):
        continue
    s = r.get('summary')
    if s is None or len(r['w']) != 2:
        print(f"MISSING data in round {r['round']} {r['cfg']}", file=sys.stderr)
        bad += 1
        continue
    if [w['stacked'] for w in r['w']] != [int(x) for x in s['stacked'].split(',')] or \
       [w['wakes'] for w in r['w']] != [int(x) for x in s['wakes'].split(',')] or \
       [f"{w['mx']:.3f}" for w in r['w']] != s['handoff_max_ms'].split(','):
        print(f"MISMATCH round {r['round']} {r['cfg']}: {r['w']} vs {s}", file=sys.stderr)
        bad += 1
if bad:
    sys.exit(f"{bad} runs failed the cross-check")

print(f"{len(runs)} runs parsed" + (", from SUMMARY lines (asym_min)" if all(r.get('min') for r in runs) else ", all cross-checked against SUMMARY"))
cfgs = list(dict.fromkeys(r['cfg'] for r in runs))
print(f"{'config':18} {'stacked per 30 s run (w0+w1)':34} {'handoff p99.9 ms (all workers)':32} {'handoff max ms':16} wait %")
for c in cfgs:
    rs = [r for r in runs if r['cfg'] == c]
    ws = [w for r in rs for w in r['w']]
    st = ', '.join(str(sum(w['stacked'] for w in r['w'])) for r in rs)
    p = sorted(w['p999'] for w in ws)
    m = sorted(w['mx'] for w in ws)
    wt = sorted(w['wait'] for w in ws)
    print(f"{c:18} {st:34} {p[0]:.3f}-{p[-1]:.3f}{'':20} {m[0]:.3f}-{m[-1]:.3f}    {wt[0]:.2f}-{wt[-1]:.2f}")
    tot = sum(w['stacked'] for w in ws)
    wk = sum(w['wakes'] for w in ws)
    print(f"{'':18} total stacked {tot} of {wk} wakeups ({100.0 * tot / wk:.3f} %), p50 {min(w['p50'] for w in ws):.3f}-"
          f"{max(w['p50'] for w in ws):.3f} ms, p99 {min(w['p99'] for w in ws):.3f}-{max(w['p99'] for w in ws):.3f} ms")
