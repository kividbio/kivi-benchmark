#!/usr/bin/env bash
# Install and configure every database VM (infra/setup-db.sh on each, in
# parallel), then make the Redis Cluster: 4 primaries, no replicas, as in
# Anton Putra's lesson 228. Run after infra/create.sh. (Plain bash 3.2, as
# macOS ships, is enough.)
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG=${RG:-kividb-video}
here=$(cd "$(dirname "$0")/.." && pwd)
pub() { az vm show -d -g "$RG" -n "$1" --query publicIps -o tsv; }

mkdir -p "$here/.state"
: > "$here/.state/db-ips"
# "vm kind" pairs.
for pair in "db-kividb kividb" "db-redis redis" "db-dragonfly dragonfly" \
            "db-rcluster-0 redis-cluster" "db-rcluster-1 redis-cluster" \
            "db-rcluster-2 redis-cluster" "db-rcluster-3 redis-cluster"; do
  set -- $pair
  vm=$1 kind=$2
  (
    ip=$(pub "$vm")
    echo "$vm $ip" >> "$here/.state/db-ips"
    scp -q -o StrictHostKeyChecking=accept-new "$here/infra/setup-db.sh" "azureuser@$ip:~/"
    if ssh -n "azureuser@$ip" "sed -i 's/\r$//' setup-db.sh && sudo KIVIDB_VERSION=${KIVIDB_VERSION:-v1.1.2} bash setup-db.sh $kind" \
      > "$here/.state/setup-$vm.log" 2>&1; then
      echo "$vm ($kind): ok"
    else
      echo "$vm ($kind): FAILED, see .state/setup-$vm.log"
    fi
  ) &
done
wait

ip0=$(pub db-rcluster-0)
ssh -n "azureuser@$ip0" 'yes yes | redis-cli --cluster create \
  10.60.1.20:6379 10.60.1.21:6379 10.60.1.22:6379 10.60.1.23:6379 --cluster-replicas 0 > /dev/null; \
  sleep 5; redis-cli CLUSTER INFO | grep -E "cluster_state|cluster_size"'
