#!/bin/bash
# Run as root. Tests which conditions the effect needs, interleaved, REPS rounds of SECS-second runs:
#   1. CPU set: unique-top vs tied-top preferred-core rank (clocks pinned, ITMT + DELAY_DEQUEUE on)
#   2. clocks: pinned vs unpinned (performance + boost, powersave + boost), CPUs 4-7
#   3. features on a tied-top set: ITMT off, NO_DELAY_DEQUEUE
# The CPU sets and waker CPUs are for the 7950X in system.txt; other machines need their own (see README).
# Restores ITMT, DELAY_DEQUEUE, boost and per-CPU governor/min/max on exit.
# Usage: ./preconditions.sh [reps] [seconds] [freq_mhz]
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-3}; SECS=${2:-30}; MHZ=${3:-4300}
ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features; B=/sys/devices/system/cpu/cpufreq/boost
CPUS=$(ls -d /sys/devices/system/cpu/cpu[0-9]* | sed 's/.*cpu//' | sort -n)

ITMT0=$(cat $ITMT); DD0=$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE); BOOST0=$(cat $B)
declare -A GOV0 MIN0 MAX0
for c in $CPUS; do
  d=/sys/devices/system/cpu/cpu$c/cpufreq
  GOV0[$c]=$(cat $d/scaling_governor); MIN0[$c]=$(cat $d/scaling_min_freq); MAX0[$c]=$(cat $d/scaling_max_freq)
done
restore() {
  echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; echo $DD0 > $F; echo $BOOST0 > $B
  for c in $CPUS; do
    d=/sys/devices/system/cpu/cpu$c/cpufreq
    echo ${GOV0[$c]} > $d/scaling_governor
    # order matters: widen first, then narrow
    echo ${MAX0[$c]} > $d/scaling_max_freq; echo ${MIN0[$c]} > $d/scaling_min_freq; echo ${MAX0[$c]} > $d/scaling_max_freq
  done
  echo "# restored itmt=$(cat $ITMT) $(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE) boost=$(cat $B)" \
       "cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor):$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_min_freq)-$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq)"
}
trap restore EXIT

clocks() {   # pinned | perf | powersave
  for c in $CPUS; do
    d=/sys/devices/system/cpu/cpu$c/cpufreq; lo=$(cat $d/cpuinfo_min_freq); hi=$(cat $d/cpuinfo_max_freq)
    case $1 in
      pinned) echo performance > $d/scaling_governor
              echo $hi > $d/scaling_max_freq; echo $((MHZ * 1000)) > $d/scaling_min_freq; echo $((MHZ * 1000)) > $d/scaling_max_freq ;;
      perf|powersave) echo $([ $1 = perf ] && echo performance || echo powersave) > $d/scaling_governor
              echo $hi > $d/scaling_max_freq; echo $lo > $d/scaling_min_freq
              [ $1 = powersave ] && echo balance_performance > $d/energy_performance_preference ;;
    esac
  done
  [ $1 = pinned ] && echo 0 > $B || echo 1 > $B
}
feat() { echo $1 > $ITMT; echo $2 > $F; }
run() {   # label cpus waker
  echo "## $1 | epp=$(cat /sys/devices/system/cpu/cpu4/cpufreq/energy_performance_preference)"
  sleep 1
  taskset -c $2 ./asym_stack2 2 1000 10 $SECS $3 2>&1 | grep -e SUMMARY -e 'burst starts per CPU' | sed 's/^ *//'
}

echo "# preconditions.sh reps=$REPS secs=$SECS mhz=$MHZ $(date -Is) $(uname -r)"
echo "# initial: itmt=$ITMT0 $DD0 boost=$BOOST0 cpu0=${GOV0[0]}:${MIN0[0]}-${MAX0[0]}"
for r in $(seq $REPS); do
  echo "# ===== round $r"
  clocks pinned; feat 1 DELAY_DEQUEUE
  run "set unique-top 4-7 (top 6)"        4-7     2
  run "set tied-top 1,3,5,7 (top 1,3)"    1,3,5,7 2
  run "set tied-top 0-3 (top 1,3)"        0-3     6
  run "set unique-top 0,2,5,7 (top 2)"    0,2,5,7 4
  run "set unique-top 8-11 (top 11)"      8-11    12
  clocks perf;      run "clocks performance+boost, range, 4-7" 4-7 2
  clocks powersave; run "clocks powersave+boost+EPP balance_performance, range, 4-7"   4-7 2
  clocks pinned
  feat 0 DELAY_DEQUEUE;    run "tied-top 1,3,5,7, ITMT off"         1,3,5,7 2
  feat 1 NO_DELAY_DEQUEUE; run "tied-top 1,3,5,7, NO_DELAY_DEQUEUE" 1,3,5,7 2
  feat 1 DELAY_DEQUEUE
done
