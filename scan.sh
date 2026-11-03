#!/bin/bash
# Unprivileged. Runs asym_stack2 on several CPU sets, for machines where the documented set does not reproduce.
# Candidate sets: K consecutive physical cores of one NUMA node, one hardware thread each (the lowest-numbered
# sibling), waker on the next physical core of the same node outside the set. Or give sets explicitly:
#   SETS="4-7:2 1,3,5,7:2" ./scan.sh       (cpus:waker_cpu)
# Usage: ./scan.sh [runs] [seconds] [k]
cd "$(dirname "$0")" || exit 1
RUNS=${1:-3}; SECS=${2:-30}; K=${3:-4}
[ -x ./asym_stack2 ] || gcc -O2 -pthread -o asym_stack2 asym_stack2.c || exit 1

expand() {   # "0-3,8" -> "0 1 2 3 8"
  tr ',' '\n' <<< "$1" | while IFS=- read a b; do seq $a ${b:-$a}; done
}
if [ -z "${SETS:-}" ]; then
  for n in /sys/devices/system/node/node[0-9]*; do
    P=()
    for c in $(expand "$(cat $n/cpulist)"); do
      first=$(expand "$(cat /sys/devices/system/cpu/cpu$c/topology/thread_siblings_list)" | head -1)
      [ "$first" = "$c" ] && P+=($c)
    done
    for ((i = 0; i + K <= ${#P[@]}; i++)); do
      w=$(( i + K < ${#P[@]} ? P[i + K] : P[i - 1] ))
      [ $i -eq 0 ] && [ $K -ge ${#P[@]} ] && continue   # no core left for the waker
      SETS+="$(IFS=,; echo "${P[*]:i:K}"):$w "
    done
  done
fi

echo "# scan.sh runs=$RUNS secs=$SECS $(date -Is) $(uname -r)"
for r in $(seq $RUNS); do
  for s in $SETS; do
    taskset -c ${s%%:*} ./asym_stack2 2 1000 10 $SECS ${s##*:} 2>/dev/null | grep SUMMARY
  done
done | tee /dev/stderr | awk '
  { for (i = 1; i <= NF; i++) { split($i, kv, "="); f[kv[1]] = kv[2] }
    k = f["allowed_cpus"] " waker=" f["waker_cpu"] " " f["top_rank"]
    split(f["stacked"], st, ","); runs[k] = runs[k] " " st[1] + st[2]; order[k] = order[k] ? order[k] : ++n }
  END { print "\n# stacked handoffs per run (both workers), per set:"
        for (k in order) o[order[k]] = k
        for (i = 1; i <= n; i++) printf "%-60s%s\n", o[i], runs[o[i]] }'
