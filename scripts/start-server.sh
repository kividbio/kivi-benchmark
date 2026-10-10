#!/usr/bin/env bash
# Start exactly one engine on this host, with persistence off, and record the
# command it was started with.
#
#   scripts/start-server.sh <kividb|dragonfly|redis|redis-cluster>
#
# Environment:
#   PORT        client port (default 6379; redis-cluster uses 7000 upwards)
#   THREADS     worker threads for KiviDB and Dragonfly (default: vCPUs - 2,
#               which is also KiviDB's own default)
#   IO_THREADS  Redis I/O threads (default 8). Redis still executes commands
#               on one thread; redis-cluster is the multi-core comparison.
#   SHARDS      Redis Cluster primaries (default: vCPUs - 2), no replicas
#   BIN         where the KiviDB and Dragonfly binaries are (default ~/bin)
#
# Every engine is started the same way: an empty working directory, no
# snapshot or append-only file, no memory limit, listening on all addresses.
# The command line and the version are appended to ~/logs/launch.log, so a
# result can always be traced to how the engine was configured.
set -euo pipefail

ENGINE=${1:?usage: start-server.sh <kividb|dragonfly|redis|redis-cluster>}
HERE=$(cd "$(dirname "$0")" && pwd)
PORT=${PORT:-6379}
VCPUS=$(nproc)
THREADS=${THREADS:-$((VCPUS - 2))}
IO_THREADS=${IO_THREADS:-8}
SHARDS=${SHARDS:-$((VCPUS - 2))}
BIN=${BIN:-$HOME/bin}
RUN=$HOME/run
LOGS=$HOME/logs

"$HERE/stop-server.sh"
rm -rf "$RUN"
mkdir -p "$RUN" "$LOGS"
cd "$RUN"
ulimit -n 1000000 2>/dev/null || ulimit -n 65535

record() { # version, command...
  local version=$1
  shift
  printf '%s  %s  [%s]\n    %s\n' "$(date -u +%FT%TZ)" "$ENGINE" "$version" "$*" | tee -a "$LOGS/launch.log"
}

wait_for() { # port
  for _ in $(seq 120); do
    redis-cli -p "$1" ping 2>/dev/null | grep -q PONG && return 0
    sleep 0.5
  done
  echo "start-server: $ENGINE did not answer on port $1" >&2
  tail -20 "$LOGS/$ENGINE.log" >&2
  exit 1
}

case $ENGINE in
  kividb)
    cmd=("$BIN/kividb" --port "$PORT" --bind 0.0.0.0 --threads "$THREADS")
    record "$("$BIN/kividb" --version 2>&1 | head -1)" "${cmd[@]}"
    nohup "${cmd[@]}" > "$LOGS/$ENGINE.log" 2>&1 &
    wait_for "$PORT"
    # A fallback from io_uring would be a different engine from the one meant.
    grep -i "I/O model" "$LOGS/$ENGINE.log" | tail -1
    ;;
  dragonfly)
    cmd=("$BIN/dragonfly" --port "$PORT" --bind 0.0.0.0 --proactor_threads "$THREADS"
      --dbfilename "" --logtostderr)
    record "$("$BIN/dragonfly" --version 2>&1 | head -1)" "${cmd[@]}"
    nohup "${cmd[@]}" > "$LOGS/$ENGINE.log" 2>&1 &
    wait_for "$PORT"
    ;;
  redis)
    cmd=(redis-server --port "$PORT" --bind 0.0.0.0 --protected-mode no
      --save "" --appendonly no --io-threads "$IO_THREADS")
    record "$(redis-server --version)" "${cmd[@]}"
    nohup "${cmd[@]}" > "$LOGS/$ENGINE.log" 2>&1 &
    wait_for "$PORT"
    ;;
  redis-cluster)
    # One single-threaded primary per core, no replicas: Redis using the
    # whole machine, which is the like-for-like for a multi-threaded engine.
    ip=$(hostname -I | awk '{print $1}')
    nodes=()
    for i in $(seq 0 $((SHARDS - 1))); do
      port=$((7000 + i))
      mkdir -p "$RUN/$port"
      cmd=(redis-server --port "$port" --bind 0.0.0.0 --protected-mode no
        --save "" --appendonly no --cluster-enabled yes
        --cluster-config-file "nodes-$port.conf" --cluster-node-timeout 15000
        --dir "$RUN/$port")
      [ "$i" = 0 ] && record "$(redis-server --version) x $SHARDS primaries, ports 7000-$((7000 + SHARDS - 1))" "${cmd[@]}"
      nohup "${cmd[@]}" > "$LOGS/$ENGINE-$port.log" 2>&1 &
      nodes+=("$ip:$port")
    done
    for i in $(seq 0 $((SHARDS - 1))); do wait_for $((7000 + i)); done
    redis-cli --cluster create "${nodes[@]}" --cluster-replicas 0 --cluster-yes > "$LOGS/$ENGINE-create.log" 2>&1
    for _ in $(seq 120); do
      redis-cli -p 7000 cluster info 2>/dev/null | grep -q "cluster_state:ok" && break
      sleep 0.5
    done
    redis-cli -p 7000 cluster info | grep -E "cluster_state|cluster_slots_ok|cluster_known_nodes"
    ;;
  *)
    echo "unknown engine: $ENGINE" >&2
    exit 2
    ;;
esac
echo "start-server: $ENGINE is up"
