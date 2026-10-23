#!/usr/bin/env bash
# Install Prometheus + Grafana (kube-prometheus-stack) on the system pool,
# with the ramp dashboard; Grafana on a public IP only the operator's IP reaches.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
MYIP=$(cat "$here/.state/myip")
PW_FILE="$here/.state/grafana-password"
[ -s "$PW_FILE" ] || (umask 077; openssl rand -base64 18 | tr -d '/+=' > "$PW_FILE")
PW=$(cat "$PW_FILE")
PY=$(command -v python3 || command -v python)
"$PY" "$here/monitoring/gen_dashboard.py" > /dev/null
sed -e "s#__MYIP__#$MYIP#" -e "s#__GRAFANA_PASSWORD__#$PW#" "$here/monitoring/values.yaml" > "$here/.state/values.yaml"
kubectl get ns monitoring >/dev/null 2>&1 || kubectl create ns monitoring
kubectl -n monitoring create configmap ramp-dashboard --from-file=ramp.json="$here/monitoring/ramp.json" \
  --dry-run=client -o yaml | kubectl label --local -f - grafana_dashboard=1 -o yaml | kubectl apply -f -
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update prometheus-community >/dev/null
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n monitoring \
  -f "$here/.state/values.yaml" --wait --timeout 15m
for _ in $(seq 60); do
  ip=$(kubectl -n monitoring get svc kps-grafana -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  [ -n "$ip" ] && break
  sleep 5
done
echo "Grafana: http://$ip/d/ramp  (user admin, password in .state/grafana-password)"
