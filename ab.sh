#!/bin/bash
# Run as root: interleaves ITMT on / ITMT off / ITMT on + NO_DELAY_DEQUEUE, REPS times, CPUs 4-7, waker on CPU 2.
# Restores both settings on exit. Usage: ./ab.sh [reps] [cpus] [waker_cpu]
[ "$(id -u)" = 0 ] || { echo "run as root (it toggles debugfs settings)" >&2; exit 1; }
REPS=${1:-5}; CPUS=${2:-4-7}; WAKER=${3:-2}
ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features
ITMT0=$(cat $ITMT); DD0=$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)
trap 'echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; echo $DD0 > $F; echo "restored itmt=$(cat $ITMT) $(tr " " "\n" < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)" >&2' EXIT
for r in $(seq $REPS); do
  for cfg in "1 DELAY_DEQUEUE" "0 DELAY_DEQUEUE" "1 NO_DELAY_DEQUEUE"; do
    set -- $cfg; echo $1 > $ITMT; echo $2 > $F; sleep 1
    taskset -c $CPUS ./asym_stack2 2 1000 10 10 $WAKER 2>&1 | grep SUMMARY
  done
done
