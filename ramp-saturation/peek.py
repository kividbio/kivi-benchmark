"""Print the dashboard's numbers now, per database (Prometheus on 127.0.0.1:19090)."""
import json
import sys
import urllib.parse
import urllib.request

PROM = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:19090"
W = "[20s]"
Q = {
    "clients": 'sum by (db) (client_workers)',
    "req/s": 'sum by (db) (rate(client_requests_total{status="ok"}' + W + '))',
    "err/s": 'sum by (db) (rate(client_requests_total{status="error"}' + W + '))',
    "p99 set ms": '1000 * histogram_quantile(0.99, sum by (db, le) (rate(client_request_duration_seconds_bucket{op="set"}' + W + ')))',
    "p50 set ms": '1000 * histogram_quantile(0.50, sum by (db, le) (rate(client_request_duration_seconds_bucket{op="set"}' + W + ')))',
    "db cpu %": '100 * (1 - avg by (db) (rate(node_cpu_seconds_total{job="db-nodes",mode="idle"}' + W + ')))',
    "db mem MiB": 'sum by (db) (node_memory_MemTotal_bytes{job="db-nodes"} - node_memory_MemAvailable_bytes{job="db-nodes"}) / 1048576',
    "client cores": 'sum by (db) (label_replace(rate(container_cpu_usage_seconds_total{namespace="bench",container="client"}[1m]), "db", "$1", "pod", "client-([a-z]+)-.*"))',
}
rows = {}
for name, q in Q.items():
    url = PROM + "/api/v1/query?" + urllib.parse.urlencode({"query": q})
    data = json.load(urllib.request.urlopen(url))["data"]["result"]
    for r in data:
        rows.setdefault(r["metric"].get("db", "?"), {})[name] = float(r["value"][1])
print(f"{'db':14}" + "".join(f"{k:>13}" for k in Q))
for db in ("kividb", "redis", "dragonfly", "redis-cluster"):
    v = rows.get(db, {})
    print(f"{db:14}" + "".join(f"{v.get(k, float('nan')):13,.1f}" for k in Q))
