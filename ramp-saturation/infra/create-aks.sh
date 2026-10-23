#!/usr/bin/env bash
# The AKS part of create.sh, on its own so that it can be run again:
# a cluster with a system pool (Prometheus, Grafana), and per database a
# tainted pool of LOAD_NODES x LOAD_SIZE that only its load generator runs
# on, attached to the ACR; then the client image, built in Azure.
#
# The load nodes are x86 (D8as_v5): the arm64 quota had no room for them,
# and the load side need not match the databases, only be the same for
# each. Two 8-vCPU nodes per database kept the clients below saturation at
# about 2M requests/s (check the "Load generator CPU" panel).
set -euo pipefail
export MSYS_NO_PATHCONV=1
RG=${RG:-kividb-video}
LOC=${LOC:-centralindia}
AKS=${AKS:-kividb-video-aks}
LOAD_SIZE=${LOAD_SIZE:-Standard_D8as_v5}
LOAD_NODES=${LOAD_NODES:-2}
SYS_SIZE=${SYS_SIZE:-Standard_D4s_v5}
here=$(cd "$(dirname "$0")/.." && pwd)
ACR=${ACR:-$(cat "$here/.state/acr")}
AKS_SUBNET=$(az network vnet subnet show -g "$RG" --vnet-name vnet -n aks --query id -o tsv)
PPG_ID=$(az ppg show -g "$RG" -n ppg --query id -o tsv)
az aks create -g "$RG" -n "$AKS" --location "$LOC" \
  --nodepool-name sys --node-count 1 --node-vm-size "$SYS_SIZE" --ppg "$PPG_ID" \
  --network-plugin azure --network-plugin-mode overlay --pod-cidr 192.168.0.0/16 \
  --vnet-subnet-id "$AKS_SUBNET" --attach-acr "$ACR" \
  --generate-ssh-keys --tier free -o none
for db in kividb redis dragonfly redis-cluster; do
  case $db in redis-cluster) pool=arclust ;; *) pool="a${db:0:6}" ;; esac
  az aks nodepool add -g "$RG" --cluster-name "$AKS" -n "$pool" --node-count "$LOAD_NODES" \
    --node-vm-size "$LOAD_SIZE" --ppg "$PPG_ID" \
    --labels "bench-db=$db" --node-taints "bench=load:NoSchedule" -o none
done

ctx="$here/client"; command -v cygpath >/dev/null && ctx=$(cygpath -w "$ctx")
az acr build -r "$ACR" --platform linux/amd64 -t ramp-client:latest "$ctx" -o none

kc="$here/.state/kubeconfig"; command -v cygpath >/dev/null && kc=$(cygpath -w "$kc")
az aks get-credentials -g "$RG" -n "$AKS" -f "$kc" --overwrite-existing -o none
echo "kubeconfig: .state/kubeconfig (export KUBECONFIG=\$PWD/.state/kubeconfig)"
