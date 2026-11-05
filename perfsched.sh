#!/bin/bash
# Run as root. REPS runs of asym_min under perf sched record (all CPUs), defaults (ITMT and DELAY_DEQUEUE
# as found). Raw perf.data kept in perfsched/. Analyse with: perf sched timehist -i perfsched/runN.data
# Usage: ./perfsched.sh [reps] [seconds]
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-3}; SECS=${2:-30}
echo "# perfsched.sh reps=$REPS secs=$SECS start=$(date -Is) $(uname -r) itmt=$(cat /sys/kernel/debug/x86/sched_itmt_enabled) $(tr ' ' '\n' < /sys/kernel/debug/sched/features | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE) boost=$(cat /sys/devices/system/cpu/cpufreq/boost) loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
for r in $(seq $REPS); do
  echo "## run $r $(date +%T): perf sched record -a -m 64M -o perfsched/run$r.data -- taskset -c 4-7 ./asym_min 1000 10 $SECS 2"
  perf sched record -a -m 64M -o perfsched/run$r.data -- taskset -c 4-7 ./asym_min 1000 10 $SECS 2 2>&1
done
chown -R --reference=. perfsched
echo "# end=$(date -Is)"
