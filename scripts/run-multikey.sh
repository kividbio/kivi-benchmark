#!/usr/bin/env bash
# Multi-key commands against one engine, from the client instance: MSET and
# MGET of 10 keys a command.
#
#   scripts/run-multikey.sh <label> <server-ip> <port>
#
# The server is emptied and every key written once (100-byte values), then
# each command runs for a fixed time at pipeline depth 1. Results go to
# ~/results/<label>/ as mset10_d100.{txt,json} and mget10_d100.{txt,json},
# and are appended to its summary.csv.
#
# Not for a cluster: ten random keys do not share a hash slot.
#
# Environment: DURATION (60), KEYS (10 million), MEMTIER_THREADS (60), SIZE (100), OUT.
set -euo pipefail

LABEL=${1:?usage: run-multikey.sh <label> <server-ip> <port>}
SERVER=${2:?server ip}
PORT=${3:?port}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=${OUT:-$HOME/results/$LABEL}
DURATION=${DURATION:-60}
KEYS=${KEYS:-10000000}
THREADS=${MEMTIER_THREADS:-60}
SIZE=${SIZE:-100}
N=10
mkdir -p "$OUT"

common=(-s "$SERVER" -p "$PORT" --distinct-client-seed --hide-histogram
  --key-minimum=1 "--key-maximum=$KEYS" -d "$SIZE")

redis-cli -h "$SERVER" -p "$PORT" flushall > /dev/null
echo "== load: $KEYS keys of $SIZE bytes"
memtier_benchmark "${common[@]}" --ratio 1:0 --key-pattern P:P -n allkeys \
  -t "$THREADS" -c 5 --pipeline 16 > "$OUT/load-multikey.txt" 2>&1

mset="MSET"
mget="MGET"
for _ in $(seq "$N"); do
  mset+=" __key__ __data__"
  mget+=" __key__"
done

for name in mset mget; do
  command=$mset
  [ "$name" = mget ] && command=$mget
  file="${name}${N}_d${SIZE}"
  echo "== $file ($DURATION s)"
  memtier_benchmark "${common[@]}" "--command=$command" --command-key-pattern=R \
    "--test-time=$DURATION" -t "$THREADS" -c 20 --pipeline 1 \
    --json-out-file "$OUT/$file.json" > "$OUT/$file.txt" 2>&1
  grep -a "^Totals" "$OUT/$file.txt" | tail -1
done
python3 "$HERE/summarize.py" "$OUT" > "$OUT/summary.csv"
cat "$OUT/summary.csv"
