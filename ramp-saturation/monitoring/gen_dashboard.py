"""Write monitoring/ramp.json: the Grafana dashboard for the ramp test."""
import json
import os

COLORS = {"kividb": "#73BF69", "redis": "#F2495C", "dragonfly": "#B877D9", "redis-cluster": "#FF9830"}
NAMES = {"kividb": "KiviDB", "redis": "Redis", "dragonfly": "Dragonfly",
         "redis-cluster": "Redis Cluster (4 x 2 vCPU)"}
W = "[20s]"


def overrides():
    return [
        {
            "matcher": {"id": "byName", "options": NAMES[db]},
            "properties": [
                {"id": "color", "value": {"mode": "fixed", "fixedColor": c}},
            ],
        }
        for db, c in COLORS.items()
    ]


def panel(pid, title, expr, unit, x, y, w=12, h=8, decimals=None, legend_by="db"):
    targets = []
    for i, db in enumerate(COLORS):
        targets.append(
            {
                "refId": chr(65 + i),
                "expr": expr.replace("$DB", db),
                "legendFormat": NAMES[db],
                "range": True,
            }
        )
    defaults = {
        "unit": unit,
        "custom": {"lineWidth": 2, "fillOpacity": 0, "showPoints": "never", "spanNulls": True},
        "min": 0,
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "id": pid,
        "type": "timeseries",
        "title": title,
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": targets,
        "fieldConfig": {"defaults": defaults, "overrides": overrides()},
        "options": {
            "legend": {"displayMode": "list", "placement": "bottom", "calcs": ["lastNotNull", "max"]},
            "tooltip": {"mode": "multi", "sort": "desc"},
        },
    }


p99 = (
    'histogram_quantile(0.99, sum by (le) (rate(client_request_duration_seconds_bucket'
    '{db="$DB",op="%s"}' + W + ')))'
)
panels = [
    panel(1, "Throughput (requests/s, SET + GET)",
          'sum(rate(client_requests_total{db="$DB",status="ok"}' + W + '))', "reqps", 0, 0),
    panel(2, "Clients (concurrent connections)",
          'sum(client_workers{db="$DB"})', "short", 12, 0, decimals=0),
    panel(3, "p50 latency (per request, or per pipelined batch)",
          p99.replace("0.99", "0.50") % "set", "s", 0, 8),
    panel(4, "p99 latency (per request, or per pipelined batch)", p99 % "set", "s", 12, 8),
    panel(5, "Database CPU usage (8 vCPU each; the cluster averaged over its 4 VMs)",
          '100 * (1 - avg(rate(node_cpu_seconds_total{job="db-nodes",db="$DB",mode="idle"}' + W + ')))',
          "percent", 0, 16),
    panel(6, "Database memory used (VM)",
          'sum(node_memory_MemTotal_bytes{job="db-nodes",db="$DB"} - node_memory_MemAvailable_bytes{job="db-nodes",db="$DB"})',
          "bytes", 12, 16),
    panel(7, "Errors (requests/s)",
          'sum(rate(client_requests_total{db="$DB",status="error"}' + W + ')) or vector(0)', "reqps", 0, 24),
    panel(8, "Load generator CPU (cores, of 16 on its two nodes; 1 min average)",
          'sum(rate(container_cpu_usage_seconds_total{namespace="bench",container="client",pod=~"client-$DB-.*"}[1m]))',
          "short", 12, 24),
]
for p in panels:
    p["fieldConfig"]["defaults"]["max"] = 100 if p["fieldConfig"]["defaults"]["unit"] == "percent" else None
    if p["fieldConfig"]["defaults"]["max"] is None:
        del p["fieldConfig"]["defaults"]["max"]

dash = {
    "uid": "ramp",
    "title": "KiviDB vs Redis vs Dragonfly: latency, throughput, saturation",
    "timezone": "browser",
    "refresh": "5s",
    "time": {"from": "now-15m", "to": "now"},
    "schemaVersion": 39,
    "panels": panels,
    "tags": ["ramp"],
}
out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ramp.json")
with open(out, "w") as f:
    json.dump(dash, f, indent=1)
print(out)
