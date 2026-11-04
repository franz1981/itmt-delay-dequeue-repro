#!/bin/bash
# Run as root, under BENCH.lock, with clocks as found (expects pinned clocks: checked and printed, not changed).
# tbench (dbench 4.0, loopback) with client and server confined to CPUS (default 4-7, no SMT siblings),
# ITMT on/off x DELAY_DEQUEUE on/off, REPS interleaved rounds, SECS s per run, for each client count.
# Restores ITMT and DELAY_DEQUEUE on exit.
# Usage: ./tbench-pinned.sh [reps] [seconds] [client counts, comma separated] [cpus]
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-3}; SECS=${2:-30}; CLIENTS=${3:-1,2,4}; CPUS=${4:-4-7}
CPUF=/sys/devices/system/cpu; ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features
ITMT0=$(cat $ITMT); DD0=$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)
trap 'pkill -x tbench_srv; echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; echo $DD0 > $F; echo "# restored itmt=$(cat $ITMT) $(tr " " "\n" < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)"' EXIT
echo "# tbench-pinned.sh reps=$REPS secs=$SECS clients=$CLIENTS cpus=$CPUS start=$(date -Is) $(uname -r) itmt=$ITMT0 $DD0" \
     "boost=$(cat $CPUF/cpufreq/boost) governor=$(cat $CPUF/cpu*/cpufreq/scaling_governor | sort -u | tr '\n' ' ')" \
     "min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')" \
     "loadavg=$(cut -d' ' -f1-3 /proc/loadavg)"
taskset -c $CPUS tbench_srv > /dev/null 2>&1 &
sleep 1
for r in $(seq $REPS); do
  for cfg in 1:DELAY_DEQUEUE 0:DELAY_DEQUEUE 1:NO_DELAY_DEQUEUE 0:NO_DELAY_DEQUEUE; do
    echo ${cfg%%:*} > $ITMT; echo ${cfg#*:} > $F; sleep 1
    for n in ${CLIENTS//,/ }; do
      echo "## round $r tbench clients=$n cpus=$CPUS itmt=$(cat $ITMT) ${cfg#*:} $(date +%T)"
      taskset -c $CPUS tbench -t $SECS -c /usr/share/dbench/client.txt $n 127.0.0.1 2>&1 | grep -E '^Throughput'
    done
  done
done
echo "# end=$(date -Is)"
