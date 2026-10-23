#!/usr/bin/env bash
# Create the whole bench in one Azure resource group:
#   database VMs, arm64, 8 vCPU per database:
#     KiviDB     db-kividb      D8ps_v5    10.60.1.10
#     Redis      db-redis       D8ps_v5    10.60.1.11
#     Dragonfly  db-dragonfly   D8ps_v5    10.60.1.12
#     Redis Cluster, 4 primaries, no replicas:
#                db-rcluster-0..3  D2ps_v5 10.60.1.20-23
#   AKS: a system pool (1 x D4s_v5) for Prometheus and Grafana, and per
#        database a tainted pool of LOAD_NODES x LOAD_SIZE for its load
#        generator (see create-aks.sh)
#   ACR for the client image, built in Azure
# Then run infra/setup-all.sh, then monitoring/install.sh.
#
# Usage: infra/create.sh   (from ramp-saturation/; needs az, logged in, and
#        ~/.ssh/id_rsa.pub). About 100 vCPUs in the region, of which 32 are
#        DPSv5 (arm64) and 64 + 4 are the load and system pools.
set -euo pipefail
export MSYS_NO_PATHCONV=1  # Git Bash would rewrite /subscriptions/... IDs
RG=${RG:-kividb-video}
LOC=${LOC:-centralindia}
ACR=${ACR:-kividbvideo$RANDOM}
DB_SIZE=${DB_SIZE:-Standard_D8ps_v5}
CLUSTER_NODE_SIZE=${CLUSTER_NODE_SIZE:-Standard_D2ps_v5}
SYS_SIZE=${SYS_SIZE:-Standard_D4s_v5}
LOAD_SIZE=${LOAD_SIZE:-Standard_D8as_v5}
IMAGE_ARM=Canonical:ubuntu-24_04-lts:server-arm64:latest
MYIP=$(curl -s https://api.ipify.org)
here=$(cd "$(dirname "$0")/.." && pwd)
state="$here/.state"; mkdir -p "$state"
echo "$MYIP" > "$state/myip"; echo "$ACR" > "$state/acr"
key=~/.ssh/id_rsa.pub; command -v cygpath >/dev/null && key=$(cygpath -w "$key")

az group create -n "$RG" -l "$LOC" -o none
az network vnet create -g "$RG" -n vnet --address-prefixes 10.60.0.0/16 \
  --subnet-name db --subnet-prefixes 10.60.1.0/24 -o none
az network vnet subnet create -g "$RG" --vnet-name vnet -n aks --address-prefixes 10.60.16.0/20 -o none
az network nsg create -g "$RG" -n db-nsg -o none
az network nsg rule create -g "$RG" --nsg-name db-nsg -n ssh-from-operator --priority 100 \
  --source-address-prefixes "$MYIP/32" --destination-port-ranges 22 --protocol Tcp --access Allow -o none
az network vnet subnet update -g "$RG" --vnet-name vnet -n db --network-security-group db-nsg -o none
# One datacenter for everything, so the network is the same for every database.
az ppg create -g "$RG" -n ppg -l "$LOC" -t Standard \
  --intent-vm-sizes "$DB_SIZE" "$CLUSTER_NODE_SIZE" "$SYS_SIZE" "$LOAD_SIZE" -o none

vm() { # name size ip
  az vm create -g "$RG" -n "$1" --image "$IMAGE_ARM" --size "$2" \
    --vnet-name vnet --subnet db --private-ip-address "$3" --nsg "" \
    --public-ip-sku Standard --ppg ppg --accelerated-networking true \
    --admin-username azureuser --ssh-key-values "$key" \
    --os-disk-size-gb 64 --no-wait -o none
}
vm db-kividb "$DB_SIZE" 10.60.1.10
vm db-redis "$DB_SIZE" 10.60.1.11
vm db-dragonfly "$DB_SIZE" 10.60.1.12
for i in 0 1 2 3; do vm "db-rcluster-$i" "$CLUSTER_NODE_SIZE" "10.60.1.2$i"; done

az acr create -g "$RG" -n "$ACR" --sku Basic -o none
ACR="$ACR" LOAD_SIZE="$LOAD_SIZE" bash "$here/infra/create-aks.sh"

for v in db-kividb db-redis db-dragonfly db-rcluster-0 db-rcluster-1 db-rcluster-2 db-rcluster-3; do
  az vm wait -g "$RG" -n "$v" --created
done
az vm list-ip-addresses -g "$RG" -o table
echo "created: $RG (ACR $ACR). Next: infra/setup-all.sh, then monitoring/install.sh"
