# Latency, throughput and saturation: KiviDB vs Dragonfly vs Redis vs Redis Cluster (Azure)

A load test in the manner of Anton Putra's
[lesson 228](https://github.com/antonputra/tutorials/tree/main/lessons/228)
("Redis vs Dragonfly Performance (Latency - Throughput - Saturation)").
Instead of one figure from a fixed load, it adds clients step by step and
graphs throughput, latency, errors, CPU and memory as the load rises, until
each database can take no more.

Everything here builds, runs and tears down the bench on Azure. Prometheus
and Grafana show the run live, and `video/render.py` turns a run into a
video.

## Results: 2026-10-24, KiviDB 1.1.2

| | Peak throughput | Breaking point (clients) | p50 / p99 at 1,600 clients | Errors |
|---|---:|---:|---:|---:|
| **KiviDB 1.1.2** | **2.08M req/s** | ~1,300 | **4.3 / 13.9 ms** | 0 |
| Dragonfly 2.0.2 | 1.56M req/s | ~1,100 | 10.1 / 33.9 ms | 0 |
| Redis 8.10.2 Cluster (4 primaries × 2 vCPU, no replicas) | 0.97M req/s | ~650 | 26.8 / 44.9 ms | 0 |
| Redis 8.10.2 | 0.49M req/s | ~280 | 55.2 / 72.1 ms | 0 |

Latency is per pipelined batch of 10 SET+GET pairs.

- Grafana snapshot of the run (frozen, public):
  https://snapshots.raintank.io/dashboard/snapshot/AheJ35tyvNmMmRx3ExXOe2bbsebZIvWg
- Video, final frame and peak card, rendered from the run's data:
  [results/2026-10-24-pipelined/](results/2026-10-24-pipelined/)
- The run's raw series (5 s resolution, every panel):
  [results/2026-10-24-pipelined/prometheus-export.json](results/2026-10-24-pipelined/prometheus-export.json)

All four databases follow the offered load until their breaking point. There
their throughput flattens while the load keeps rising, and their latency
climbs. No database timed out a request (1 s timeout).

## What the test does

**Workload.** Each client loops forever:

1. One round trip with 10 pairs of `SET user:<n> <value>` then `GET user:<n>`,
   where `n` is random in 0..10M−1 and the value is one of 1,024 pre-built
   ~110-byte JSON users, shaped like the lesson's.
2. Sleep 10 ms.

So a client offers about 2,000 requests/s. That's Anton's pacing: a client
does a request and sleeps, so the load offered rises in a straight line with
the number of clients, which is what makes the graphs comparable. With no
TTL and a fixed key range, the dataset reaches 10M keys in the first minutes
and then stays the same size.

**Ramp.**
- Clients go from 40 to 1,600 per database, 40 more every 30 s: 40 steps, about 20 minutes.
- At the top, ~3.2M requests/s are offered, more than any of the four can serve.
- All four databases get their load at the same moment: every client pod waits for one shared start time.

**Measured** (Prometheus, 5 s scrapes):
- **Throughput and errors:** each client's counters.
- **p50 and p99 latency:** a client-side histogram of each batch's round trip.
- **Database CPU and memory:** `node_exporter` on each database VM (summed over the cluster's four VMs for memory, averaged for CPU).
- **Load-generator CPU:** cAdvisor, so you can check the clients were not the limit.

## Setup

All in one Azure resource group, in one proximity placement group (one datacenter), region `centralindia`.

| Role | Machine | Software |
|---|---|---|
| KiviDB | D8ps_v5 (8 vCPU arm64, 32 GB) | KiviDB 1.1.2 `.deb`, default threads (cores − 2), persistence off |
| Dragonfly | D8ps_v5 | Dragonfly 2.0.2 `.deb`, default `proactor_threads` (all cores), snapshots off |
| Redis | D8ps_v5 | Redis 8.10.2 from packages.redis.io, default `io-threads 1`, persistence off |
| Redis Cluster | 4 × D2ps_v5 (2 vCPU each, 8 in all) | Redis 8.10.2, `cluster-enabled yes`, 4 primaries, `--cluster-replicas 0`, as in the lesson |
| Load generators | per database, 2 × D8as_v5 (8 vCPU x86) on AKS, tainted so nothing else runs there | Go 1.23, go-redis v9 (cluster client for the cluster), 8 pods per database |
| Monitoring | AKS system node, D4s_v5 | kube-prometheus-stack (Prometheus, Grafana) |

Each database serves on `0.0.0.0:6379` with its file descriptor limit raised, and with saving and AOF off. It's a cache test, as the lesson's was.

**Caveats:**
- **Pipelining.** The run uses a pipeline depth of 10. Without pipelining (`PIPELINE=1`), KiviDB 1.1.2 measured about 20% below Dragonfly on this hardware. Say which one you show.
- **Dragonfly's CPU.** Dragonfly's threads busy-poll the network, so its CPU graph reads ~100% from the first minute at any load. It shows reserved cores, not work done.
- **The lesson's machine sizes aren't published.** The Redis Cluster here has the same total vCPUs as each single-server database.
- **Client headroom.** At 2M requests/s the load generators used ~11 of their 16 cores (the "Load generator CPU" panel). Check that panel if you change the machines.
- **Memory.** The memory graph is the VM's used memory, which includes the operating system; four VMs' worth for the cluster. Reboot the database VMs before a run so every one starts from the same baseline (~0.7 GB on the 8-vCPU VMs).

## Reproduce

You need the Azure CLI (logged in), `kubectl`, `helm`, Python 3 with
`matplotlib` and `imageio-ffmpeg` (for the video), and `~/.ssh/id_rsa.pub`.
The bench needs about 100 vCPUs in the region: 32 DPSv5 (arm64), 64 DASv5,
and 4 DSv5. It costs roughly $4–5 an hour while everything runs.

```bash
cd ramp-saturation

# 1. Machines: resource group, VMs, AKS, registry, client image (~25 min)
bash infra/create.sh
export KUBECONFIG=$PWD/.state/kubeconfig

# 2. Databases on the VMs, then the Redis Cluster
KIVIDB_VERSION=v1.1.2 bash infra/setup-all.sh

# 3. Prometheus and Grafana; prints Grafana's address (reachable from your IP only)
bash monitoring/install.sh
#    user admin, password in .state/grafana-password

# 4. Before a run: reboot the database VMs, so all start from the same memory
#    baseline. A restart of Prometheus starts its data empty (it has no disk).
for vm in db-kividb db-redis db-dragonfly db-rcluster-0 db-rcluster-1 db-rcluster-2 db-rcluster-3; do
  az vm restart -g kividb-video -n $vm --no-wait; done
kubectl -n monitoring delete pod prometheus-kps-kube-prometheus-stack-prometheus-0

# 5. The run: the defaults are the 2026-10-24 run. Starts 60 s from now.
bash run.sh 60
#    Grafana at http://<address>/d/ramp; add &kiosk to hide the menus.
#    python3 peek.py prints the same numbers in the terminal, if you
#    port-forward Prometheus to 127.0.0.1:19090.

# 6. After it: stop the clients, then render the video from Prometheus
bash stop.sh
python3 video/render.py --start <START_AT> --end <END> --kividb-label "KiviDB 1.1.2"
#    (run.sh prints this command with the numbers filled in)

# 7. Tear everything down
bash infra/destroy.sh
```

To re-render the published run without Azure:

```bash
python3 video/render.py --export results/2026-10-24-pipelined/prometheus-export.json --kividb-label "KiviDB 1.1.2"
```

`run.sh` takes its settings from the environment: `PIPELINE`, `KEYSPACE`, `TTL`,
`DELAY_MS`, `START`/`STEP`/`MAX`/`STAGE`, `REPLICAS` and `TIMEOUT_MS`. With
`PIPELINE=1 DELAY_MS=0 KEYSPACE=0 TTL=20`, for example, you get the lesson's
workload without pacing: a new UUID per pair, a 20 s TTL and no pipelining.

## Files

| Path | What it is |
|---|---|
| `client/` | The load generator (Go), its Dockerfile |
| `infra/create.sh`, `create-aks.sh` | Resource group, VMs, AKS, registry, client image |
| `infra/setup-db.sh`, `setup-all.sh` | Installs and configures each database; creates the cluster |
| `infra/profile-db.sh` | Per-thread CPU, per-core time, perf profile of a server under load |
| `infra/destroy.sh` | Deletes the resource group |
| `monitoring/` | Prometheus/Grafana values, the dashboard (`gen_dashboard.py` writes `ramp.json`) |
| `run.sh`, `stop.sh` | Start and stop a run |
| `peek.py` | The dashboard's numbers, in a terminal |
| `video/render.py` | A run, from Prometheus or an export, as an MP4 and PNGs |
| `results/` | Published runs |
