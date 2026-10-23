#!/usr/bin/env bash
# Run on a database VM while load is on: where the server's time goes.
#   profile-db.sh <process-name> [seconds]     e.g. profile-db.sh kividb 20
# Writes ~/profile-<name>/: threads.txt (CPU per thread), mpstat.txt (per
# core: usr/sys/soft/idle), cs.txt (context switches), syscalls.txt (time by
# syscall), perf.txt (on-CPU call graph, top entries).
set -u
name="$1"; secs="${2:-20}"
out=~/profile-$name; rm -rf "$out"; mkdir -p "$out"
if ! command -v perf >/dev/null || ! perf --version >/dev/null 2>&1; then
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat "linux-tools-$(uname -r)" linux-tools-common > /dev/null
fi
command -v mpstat >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sysstat > /dev/null
sudo sysctl -q kernel.perf_event_paranoid=-1 kernel.kptr_restrict=0
pid=$(pgrep -xo "$name")
echo "pid $pid ($(cat /proc/$pid/comm)), $(ls /proc/$pid/task | wc -l) threads" | tee "$out/summary.txt"

# CPU per thread over the window: utime+stime ticks before and after.
ticks() { for t in /proc/$pid/task/*; do echo "$(basename $t) $(cat $t/comm | tr ' ' _) $(awk '{print $14+$15}' $t/stat)"; done; }
ticks > "$out/t0"
mpstat -P ALL "$secs" 1 > "$out/mpstat.txt" &
mp=$!
sudo perf stat -e context-switches,cpu-migrations -p "$pid" -- sleep "$secs" > "$out/cs.txt" 2>&1 &
ps_=$!
sudo perf record -F 199 -g -p "$pid" -o "$out/perf.data" -- sleep "$secs" > /dev/null 2>&1 &
pr=$!
wait $mp $ps_ $pr
ticks > "$out/t1"
hz=$(getconf CLK_TCK)
join "$out/t0" "$out/t1" 2>/dev/null | awk -v s="$secs" -v hz="$hz" \
  '{printf "%-8s %-24s %6.1f%%\n", $1, $2, 100*($5-$3)/hz/s}' | sort -k3 -nr > "$out/threads.txt"
sudo perf trace -s -p "$pid" -- sleep 5 > "$out/syscalls.txt" 2>&1 || true
sudo perf report -i "$out/perf.data" --no-children --stdio --sort sym 2>/dev/null \
  | grep -v '^#' | grep -v '^$' | head -60 > "$out/perf.txt"
sudo perf report -i "$out/perf.data" --no-children --stdio --sort dso 2>/dev/null \
  | grep -v '^#' | grep -v '^$' | head -15 > "$out/dso.txt"
echo "done: $out"
