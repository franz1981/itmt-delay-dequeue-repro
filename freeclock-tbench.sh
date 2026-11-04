#!/bin/bash
# Run as root, under BENCH.lock. Frees the clocks (performance governor, boost on, full min..max range), runs
# ./tbench-pinned.sh with the given arguments (tbench confined to a CPU set, ITMT x DELAY_DEQUEUE), and samples
# scaling_cur_freq of CPUS once per second meanwhile only with FREQ_SAMPLE=1 (one line per sample: time, then kHz per CPU, with the
# ITMT/DELAY_DEQUEUE state). Saves and restores every CPU's governor, EPP, scaling_min/max_freq and boost (trap),
# then verifies the read-back per CPU.
# Usage: [INNER=script.sh] ./freeclock-tbench.sh <reps> <seconds> <clients> <cpus>   e.g. 3 30 1,2,4 4-7
# INNER (default tbench-pinned.sh) is the script run with the clocks freed, given the same arguments.
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
CPUS=${4:-4-7}; CPUF=/sys/devices/system/cpu
SAVE=$(mktemp); FREQLOG=results-freeclock-tbench-freq.txt
for c in $CPUF/cpu[0-9]*/cpufreq; do
  echo "$c $(cat $c/scaling_governor) $(cat $c/energy_performance_preference 2>/dev/null || echo -) $(cat $c/scaling_min_freq) $(cat $c/scaling_max_freq)"
done > $SAVE
BOOST0=$(cat $CPUF/cpufreq/boost); SAMPLER=
restore() {
  [ -n "$SAMPLER" ] && kill $SAMPLER 2>/dev/null
  echo $BOOST0 > $CPUF/cpufreq/boost
  while read c gov epp mn mx; do
    echo $gov > $c/scaling_governor
    [ "$epp" != - ] && echo $epp > $c/energy_performance_preference 2>/dev/null
    echo $(cat $c/cpuinfo_min_freq) > $c/scaling_min_freq; echo $mx > $c/scaling_max_freq; echo $mn > $c/scaling_min_freq
  done < $SAVE
  local bad=0
  while read c gov epp mn mx; do
    [ "$(cat $c/scaling_governor) $(cat $c/scaling_min_freq) $(cat $c/scaling_max_freq)" = "$gov $mn $mx" ] || { echo "# RESTORE MISMATCH $c"; bad=1; }
  done < $SAVE
  echo "# restored clocks: boost=$(cat $CPUF/cpufreq/boost) min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')$([ $bad = 0 ] && echo '- verified for every CPU')"
  rm -f $SAVE
}
trap restore EXIT
echo 1 > $CPUF/cpufreq/boost
for c in $CPUF/cpu[0-9]*/cpufreq; do
  echo performance > $c/scaling_governor
  echo $(cat $c/cpuinfo_max_freq) > $c/scaling_max_freq; echo $(cat $c/cpuinfo_min_freq) > $c/scaling_min_freq
done
echo "# free clocks: boost=$(cat $CPUF/cpufreq/boost) min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')"
LIST=$(python3 -I -c "import sys; print(' '.join(str(c) for p in sys.argv[1].split(',') for c in (range(int(p.split('-')[0]), int(p.split('-')[-1]) + 1))))" "$CPUS")
sample() {
  echo "# time itmt dd $(for c in $LIST; do printf 'cpu%s ' $c; done)(scaling_cur_freq kHz, 1/s)"
  while true; do
    printf '%s %s %s ' "$(date +%T)" "$(cat /sys/kernel/debug/x86/sched_itmt_enabled)" "$(tr ' ' '\n' < /sys/kernel/debug/sched/features | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE)"
    for c in $LIST; do printf '%s ' "$(cat $CPUF/cpu$c/cpufreq/scaling_cur_freq)"; done; echo
    sleep 1
  done
}
if [ "${FREQ_SAMPLE:-0}" = 1 ]; then
  sample > $FREQLOG &
  SAMPLER=$!
fi
echo "# clock sampler: $([ "${FREQ_SAMPLE:-0}" = 1 ] && echo "on, $FREQLOG" || echo 'off (set FREQ_SAMPLE=1 for a probed run)')"
./${INNER:-tbench-pinned.sh} "$@"
