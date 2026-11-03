#!/bin/bash
# Run as root. The run the report cites: REPS interleaved rounds of SECS-second runs on CPUS (waker WAKER), configs
#   default (ITMT on, DELAY_DEQUEUE) | ITMT off | NO_DELAY_DEQUEUE | default with the SMT siblings also allowed
# Full program output (per-worker handoff percentiles) plus the machine state at start. Restores ITMT and
# DELAY_DEQUEUE on exit. Does not touch clocks: it records them.
# Usage: ./final.sh [reps] [seconds] [cpus] [sibling_cpus] [waker]   (runs ./asym_min; gcc -O2 -pthread -o asym_min asym_min.c)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-5}; SECS=${2:-30}; CPUS=${3:-4-7}; SIBS=${4:-20-23}; WAKER=${5:-2}; PROG=asym_min
ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features
ITMT0=$(cat $ITMT); DD0=$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)
trap 'echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; echo $DD0 > $F; echo "# restored itmt=$(cat $ITMT) $(tr " " "\n" < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)"' EXIT

echo "# final.sh prog=$PROG reps=$REPS secs=$SECS cpus=$CPUS siblings=$SIBS waker=$WAKER start=$(date -Is)"
echo "# uname: $(uname -r)  tainted: $(cat /proc/sys/kernel/tainted)  cmdline: $(cat /proc/cmdline)"
echo "# $(grep -m1 'model name' /proc/cpuinfo)"
echo "# itmt=$ITMT0 features: $(cat $F)"
echo "# boost=$(cat /sys/devices/system/cpu/cpufreq/boost) amd_pstate=$(cat /sys/devices/system/cpu/amd_pstate/status 2>/dev/null)"
for c in $(seq 0 31); do d=/sys/devices/system/cpu/cpu$c/cpufreq
  printf '%s:%s:%s-%s:%s ' $c $(cat $d/scaling_governor $d/scaling_min_freq $d/scaling_max_freq $d/amd_pstate_prefcore_ranking 2>/dev/null)
done | sed 's/^/# cpu:governor:min-max:rank  /'; echo
echo "# base_slice_ns=$(cat /sys/kernel/debug/sched/base_slice_ns 2>/dev/null) HZ=$(grep -m1 '^CONFIG_HZ=' /boot/config-$(uname -r) | cut -d= -f2) preempt=$(cat /sys/kernel/debug/sched/preempt 2>/dev/null)"
echo "# loadavg: $(cat /proc/loadavg)"
echo "# busiest processes at start:"; ps -eo pcpu,comm --sort=-pcpu | sed -n 2,8p | sed 's/^/#   /'

for r in $(seq $REPS); do
  for cfg in "default 1 DELAY_DEQUEUE $CPUS" "itmt-off 0 DELAY_DEQUEUE $CPUS" "no-delay-dequeue 1 NO_DELAY_DEQUEUE $CPUS" \
             "default+siblings 1 DELAY_DEQUEUE $CPUS,$SIBS"; do
    set -- $cfg; echo $2 > $ITMT; echo $3 > $F; sleep 1
    echo "## round $r config $1 cpus $4 $(date +%T) loadavg $(cut -d' ' -f1 /proc/loadavg)"
    taskset -c $4 ./$PROG 1000 10 $SECS $WAKER 2>&1
  done
done
echo "# end=$(date -Is)"
