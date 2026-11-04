#!/bin/bash
# Run as root, under BENCH.lock. Throughput with free clocks (performance governor, boost on, full min..max range),
# ITMT on/off x DELAY_DEQUEUE on/off, REPS interleaved rounds:
#   A. asym_min on CPUs 4-7, fixed work per burst (ASYM_ITERS = the iteration count asym_min calibrates for 1 ms at
#      the clocks found at start, i.e. pinned 4300 MHz), SECS s: bursts completed = throughput.
#   B. tbench (dbench 4.0, loopback), CLIENTS clients each, SECS s, whole box: "Throughput ... MB/sec".
# Saves and restores every CPU's governor, EPP, scaling_min/max_freq, global boost, ITMT and DELAY_DEQUEUE (trap),
# then prints the read-back.
# Usage: ./freeclock-ab.sh [reps] [seconds] [tbench client counts, comma separated]
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-3}; SECS=${2:-30}; CLIENTS=${3:-8,32}
CPUF=/sys/devices/system/cpu; ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features
SAVE=$(mktemp)
for c in $CPUF/cpu[0-9]*/cpufreq; do
  echo "$c $(cat $c/scaling_governor) $(cat $c/energy_performance_preference 2>/dev/null || echo -) $(cat $c/scaling_min_freq) $(cat $c/scaling_max_freq)"
done > $SAVE
BOOST0=$(cat $CPUF/cpufreq/boost); ITMT0=$(cat $ITMT)
DD0=$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)
restore() {
  pkill -x tbench_srv 2>/dev/null
  echo $BOOST0 > $CPUF/cpufreq/boost
  while read c gov epp mn mx; do
    echo $gov > $c/scaling_governor
    [ "$epp" != - ] && echo $epp > $c/energy_performance_preference 2>/dev/null
    # order matters: lower min first, then max, then min again
    echo $(cat $c/cpuinfo_min_freq) > $c/scaling_min_freq; echo $mx > $c/scaling_max_freq; echo $mn > $c/scaling_min_freq
  done < $SAVE
  echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; echo $DD0 > $F
  echo "# restored: boost=$(cat $CPUF/cpufreq/boost) itmt=$(cat $ITMT) $(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)" \
       "governor=$(cat $CPUF/cpu*/cpufreq/scaling_governor | sort -u | tr '\n' ' ')" \
       "min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')" \
       "max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')"
  local bad=0
  while read c gov epp mn mx; do
    [ "$(cat $c/scaling_governor) $(cat $c/scaling_min_freq) $(cat $c/scaling_max_freq)" = "$gov $mn $mx" ] || { echo "# RESTORE MISMATCH $c"; bad=1; }
  done < $SAVE
  [ $bad = 0 ] && echo "# restore verified for every CPU"
  rm -f $SAVE
}
trap restore EXIT
echo "# freeclock-ab.sh reps=$REPS secs=$SECS clients=$CLIENTS start=$(date -Is) $(uname -r) saved: boost=$BOOST0 itmt=$ITMT0 $DD0 governor=$(cut -d' ' -f2 $SAVE | sort -u | tr '\n' ' ')min/max=$(cut -d' ' -f4,5 $SAVE | sort -u | tr '\n' ' ')loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
ITERS=$(taskset -c 4-7 ./asym_min 1000 10 1 2 | grep -o 'burst_iters=[0-9]*' | cut -d= -f2)
[ -n "$ITERS" ] || { echo "no burst_iters"; exit 1; }
echo "# ASYM_ITERS=$ITERS (calibrated for 1 ms at the clocks found at start)"
# free clocks
echo 1 > $CPUF/cpufreq/boost
for c in $CPUF/cpu[0-9]*/cpufreq; do
  echo performance > $c/scaling_governor
  echo $(cat $c/cpuinfo_max_freq) > $c/scaling_max_freq; echo $(cat $c/cpuinfo_min_freq) > $c/scaling_min_freq
done
echo "# free clocks: boost=$(cat $CPUF/cpufreq/boost) governor=$(cat $CPUF/cpu*/cpufreq/scaling_governor | sort -u | tr '\n' ' ')min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')"
tbench_srv > /dev/null 2>&1 &
sleep 1
CFGS="1:DELAY_DEQUEUE 0:DELAY_DEQUEUE 1:NO_DELAY_DEQUEUE 0:NO_DELAY_DEQUEUE"
for r in $(seq $REPS); do
  for cfg in $CFGS; do
    echo ${cfg%%:*} > $ITMT; echo ${cfg#*:} > $F; sleep 1
    echo "## round $r asym_min itmt=$(cat $ITMT) ${cfg#*:} $(date +%T)"
    ASYM_ITERS=$ITERS taskset -c 4-7 ./asym_min 1000 10 $SECS 2
    for n in ${CLIENTS//,/ }; do
      echo "## round $r tbench clients=$n itmt=$(cat $ITMT) ${cfg#*:} $(date +%T)"
      tbench -t $SECS -c /usr/share/dbench/client.txt $n 127.0.0.1 2>&1 | grep -E '^Throughput'
    done
  done
done
echo "# end=$(date -Is)"
