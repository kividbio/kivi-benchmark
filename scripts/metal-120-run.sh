#!/usr/bin/env bash
# The 1.2.0 bare-metal rerun of the October 2026 capture, driven from a workstation.
# Same method as the published 1.1.0 numbers: server confined to 32 cores,
# 10 million keys of 100 bytes, 30 s a scenario, pipeline 1 and 16, write-only
# and read-only, two rounds. Garnet added.
#
#   scripts/metal-120-run.sh <ssh-key> <server-public> <server-private> <client-public> <out-dir>
set -euo pipefail
KEY=$1 SERVER_PUB=$2 SERVER_PRIV=$3 CLIENT_PUB=$4 OUT=$5
mkdir -p "$OUT"
SSH=(ssh -i "$KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -o LogLevel=ERROR)
srv() { "${SSH[@]}" "ubuntu@$SERVER_PUB" "$@"; }
cli() { "${SSH[@]}" "ubuntu@$CLIENT_PUB" "$@"; }
log() { echo "[$(date -u +%T)] $*"; }

for h in srv cli; do
  until $h true 2>/dev/null; do sleep 10; done
  $h "cloud-init status --wait > /dev/null; tail -4 /var/log/user-data-*.log"
done
srv "chmod +x ~/kivi-benchmark/scripts/*.sh"; cli "chmod +x ~/kivi-benchmark/scripts/*.sh"
log "both hosts ready"

srv "[ -x ~/garnet/GarnetServer ] || [ -f ~/garnet/VERSION ] && exit 0; cd ~/kivi-benchmark && sed -i 's/^GARNET_VERSION=.*/GARNET_VERSION=\"v2.2.5\"/' scripts/install-more-engines.sh && scripts/install-more-engines.sh 2>&1 | tail -4"
srv "nproc; ~/bin/kividb --version | head -1; ~/bin/dragonfly --version 2>&1 | head -1; redis-server --version; cat ~/garnet/VERSION"
cli "memtier_benchmark --version | head -1"

run_engine() { # engine port [cluster]
  local engine=$1 port=$2 mode=${3:-}
  log "start $engine"
  srv "CORES=32 PORT=$port ~/kivi-benchmark/scripts/start-server.sh $engine 2>&1 | tail -3"
  for round in 1 2; do
    log "$engine round $round"
    cli "OUT=~/results/$engine-r$round DURATION=30 SIZES=100 PIPELINES='1 16' RATIOS='1:0 0:1' \
      ~/kivi-benchmark/scripts/run-matrix.sh $engine-r$round $SERVER_PRIV $port $mode > ~/results-$engine-r$round.log 2>&1; tail -3 ~/results-$engine-r$round.log"
  done
}

cli "mkdir -p ~/results"
run_engine kividb 6379
run_engine dragonfly 6379
run_engine redis 6379
run_engine garnet 6379
run_engine redis-cluster 7000 cluster
srv "~/kivi-benchmark/scripts/stop-server.sh; cat ~/logs/launch.log" > "$OUT/launch.log"
cli "tar -czf - -C ~ results" > "$OUT/client-results.tgz"
log "done"
