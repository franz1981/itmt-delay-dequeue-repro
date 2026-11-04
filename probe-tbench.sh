#!/bin/bash
# Run as root, under BENCH.lock, normally via INNER=probe-tbench.sh ./freeclock-tbench.sh (free clocks).
# tbench confined to CPUS, DELAY_DEQUEUE as found, ITMT on vs off with the order alternated every round
# (odd rounds on->off, even rounds off->on), REPS rounds of SECS s, one client count.
# Each run is wrapped in perf stat counting mode, all CPUs (-a -A): msr/aperf/, msr/mperf/, msr/tsc/ per CPU, plus
# power/energy-pkg/ (package) and power_core/energy-core/ (per core); energy is reported as J, W and mJ per MB of tbench
# throughput (W / MB/s; duration from CPU's tsc). Per-CPU busy/clock reported as
#   busy = mperf/tsc (share of the run the CPU was not idle) and clock = aperf/mperf * TSC_MHZ (effective clock while busy).
# Restores ITMT on exit.
# Usage: ./probe-tbench.sh <reps> <seconds> <clients> <cpus>
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
cd "$(dirname "$0")" || exit 1
REPS=${1:-8}; SECS=${2:-30}; N=${3:-1}; CPUS=${4:-4-7}; TSC_MHZ=4500
ITMT=/sys/kernel/debug/x86/sched_itmt_enabled; F=/sys/kernel/debug/sched/features; CPUF=/sys/devices/system/cpu
ITMT0=$(cat $ITMT); P=$(mktemp)
trap 'pkill -x tbench_srv; echo $([ "$ITMT0" = Y ] && echo 1 || echo 0) > $ITMT; rm -f $P; echo "# restored itmt=$(cat $ITMT)"' EXIT
echo "# probe-tbench.sh reps=$REPS secs=$SECS clients=$N cpus=$CPUS start=$(date -Is) $(uname -r) itmt=$ITMT0" \
     "$(tr ' ' '\n' < $F | grep -x -e DELAY_DEQUEUE -e NO_DELAY_DEQUEUE) boost=$(cat $CPUF/cpufreq/boost)" \
     "min=$(cat $CPUF/cpu*/cpufreq/scaling_min_freq | sort -u | tr '\n' ' ')max=$(cat $CPUF/cpu*/cpufreq/scaling_max_freq | sort -u | tr '\n' ' ')tsc_mhz=$TSC_MHZ"
taskset -c $CPUS tbench_srv > /dev/null 2>&1 &
sleep 1
for r in $(seq $REPS); do
  [ $((r % 2)) = 1 ] && ORDER="1 0" || ORDER="0 1"
  for i in $ORDER; do
    echo $i > $ITMT; sleep 1
    echo "## round $r tbench clients=$N cpus=$CPUS itmt=$(cat $ITMT) $(date +%T)"
    T=$(mktemp)
    perf stat -x, -a -A -e msr/aperf/,msr/mperf/,msr/tsc/,power/energy-pkg/,power_core/energy-core/ -o $P -- \
      taskset -c $CPUS tbench -t $SECS -c /usr/share/dbench/client.txt $N 127.0.0.1 2>&1 | grep -E '^Throughput' | tee $T
    python3 -I - $P $TSC_MHZ "$CPUS" $T <<'PY'
import sys, collections, re
v = collections.defaultdict(dict)
for l in open(sys.argv[1]):
    f = l.strip().split(",")
    if len(f) > 3 and f[0].startswith("CPU"):
        try: v[int(f[0][3:])][f[3].split("/")[1]] = float(f[1])
        except ValueError: pass
want = [c for p in sys.argv[3].split(",") for c in range(int(p.split("-")[0]), int(p.split("-")[-1]) + 1)]
mhz = float(sys.argv[2])
print("perf " + " ".join(f"cpu{c}: busy {100*v[c]['mperf']/v[c]['tsc']:.1f}% clock {v[c]['aperf']/v[c]['mperf']*mhz:.0f}MHz" for c in want))
secs = v[want[0]]["tsc"] / (mhz * 1e6)
pkg = sum(d.get("energy-pkg", 0) for d in v.values())
core = sum(v[c].get("energy-core", 0) for c in want)
allcore = sum(d.get("energy-core", 0) for d in v.values())
tp = float(re.search(r"Throughput ([\d.]+)", open(sys.argv[4]).read())[1])
print(f"energy secs {secs:.2f} pkg {pkg:.1f} J ({pkg/secs:.2f} W) cores {sys.argv[3]} {core:.2f} J ({core/secs:.2f} W) "
      f"all cores {allcore:.1f} J ({allcore/secs:.2f} W) pkg_J_per_MB {pkg/secs/tp*1000:.3f} mJ/MB cores_J_per_MB {core/secs/tp*1000:.3f} mJ/MB")
PY
    rm -f $T
  done
done
echo "# end=$(date -Is)"
