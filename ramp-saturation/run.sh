#!/usr/bin/env bash
# Start a ramp against all four databases at once.
#   run.sh [delay-seconds]   start that many seconds from now (default 60)
# The defaults are the run of 2026-10-24 (results/2026-10-24-pipelined):
#   REPLICAS=8                 client pods per database (4 on each load node)
#   START=40 STEP=40 MAX=1600  clients per database, in all its pods
#   STAGE=30                   seconds between steps (40 steps: ~20 minutes)
#   DELAY_MS=10                sleep between batches: ~2,000 req/s offered per client
#   PIPELINE=10                SET+GET pairs per round trip (1: no pipelining)
#   KEYSPACE=10000000 TTL=0    random keys of user:0..N-1, no expiry: a fixed dataset
#   TIMEOUT_MS=1000            a request not answered in this long is an error
# stop.sh deletes the clients.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
ACR=$(cat "$here/.state/acr")
IMAGE="$ACR.azurecr.io/ramp-client:${TAG:-latest}"
REPLICAS=${REPLICAS:-8}
START=${START:-40}; STEP=${STEP:-40}; MAX=${MAX:-1600}; STAGE=${STAGE:-30}
DELAY_MS=${DELAY_MS:-10}; TTL=${TTL:-0}
PIPELINE=${PIPELINE:-10}; KEYSPACE=${KEYSPACE:-10000000}
per() { echo $(( ($1 + REPLICAS - 1) / REPLICAS )); }
START_AT=$(( $(date +%s) + ${1:-60} ))
kubectl get ns bench >/dev/null 2>&1 || kubectl create ns bench
for db in kividb redis dragonfly redis-cluster; do
  case $db in
    kividb) addrs=10.60.1.10:6379; cl=0 ;;
    redis) addrs=10.60.1.11:6379; cl=0 ;;
    dragonfly) addrs=10.60.1.12:6379; cl=0 ;;
    redis-cluster) addrs=10.60.1.20:6379,10.60.1.21:6379,10.60.1.22:6379,10.60.1.23:6379; cl=1 ;;
  esac
  cat <<EOF
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: client-$db
  namespace: bench
  labels: {app: ramp-client, db: $db}
spec:
  replicas: $REPLICAS
  selector:
    matchLabels: {app: ramp-client, db: $db}
  template:
    metadata:
      labels: {app: ramp-client, db: $db}
    spec:
      nodeSelector: {bench-db: $db}
      # Evenly over the database's load nodes.
      topologySpreadConstraints:
        - maxSkew: 1
          topologyKey: kubernetes.io/hostname
          whenUnsatisfiable: DoNotSchedule
          labelSelector:
            matchLabels: {app: ramp-client, db: $db}
      tolerations:
        - {key: bench, operator: Equal, value: load, effect: NoSchedule}
      initContainers:
        - name: flush
          image: $IMAGE
          command: ["/client"]
          env:
            - {name: DB_ADDRS, value: "$addrs"}
            - {name: CLUSTER, value: "$cl"}
            - {name: FLUSH_ONLY, value: "1"}
      containers:
        - name: client
          image: $IMAGE
          ports:
            - {name: metrics, containerPort: 8081}
          env:
            - {name: DB_NAME, value: "$db"}
            - {name: DB_ADDRS, value: "$addrs"}
            - {name: CLUSTER, value: "$cl"}
            - {name: TIMEOUT_MS, value: "${TIMEOUT_MS:-1000}"}
            - {name: START_CLIENTS, value: "$(per "$START")"}
            - {name: STEP_CLIENTS, value: "$(per "$STEP")"}
            - {name: MAX_CLIENTS, value: "$(per "$MAX")"}
            - {name: STAGE_SECONDS, value: "$STAGE"}
            - {name: REQUEST_DELAY_MS, value: "$DELAY_MS"}
            - {name: TTL_SECONDS, value: "$TTL"}
            - {name: PIPELINE, value: "${PIPELINE:-1}"}
            - {name: KEYSPACE, value: "${KEYSPACE:-0}"}
            - {name: START_AT, value: "$START_AT"}
EOF
done > "$here/.state/clients.yaml"
cat >> "$here/.state/clients.yaml" <<'EOF'
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: ramp-client
  namespace: bench
spec:
  selector:
    matchLabels: {app: ramp-client}
  podMetricsEndpoints:
    - port: metrics
      interval: 5s
EOF
kubectl -n bench delete deploy -l app=ramp-client --ignore-not-found --wait=true
kubectl apply -f "$here/.state/clients.yaml"
# GNU date (Linux) or BSD date (macOS).
at() { date -d "@$1" '+%H:%M:%S' 2>/dev/null || date -r "$1" '+%H:%M:%S'; }
echo "$START_AT" > "$here/.state/start-at"
echo "ramp starts at $(at "$START_AT") ($REPLICAS pods per database; $START -> $MAX clients, +$STEP every ${STAGE}s)"
echo "START_AT=$START_AT (also in .state/start-at); render with: python3 video/render.py --start $START_AT --end $((START_AT + STAGE * ((MAX - START) / STEP + 1) + 15))"
