# 2026-10-24: pipelined ramp, KiviDB 1.1.2 vs Dragonfly 2.0.2 vs Redis 8.10.2 vs Redis 8.10.2 Cluster

The run behind the video, made with `run.sh`'s defaults: pipeline depth 10;
SET+GET of ~110-byte JSON values over 10M keys, no TTL; each client sleeps
10 ms between batches; 40 to 1,600 clients per database, 40 more every 30 s.
It started at 2026-10-23 20:20:57 UTC and ran for about 20 minutes. See
[../../README.md](../../README.md) for the setup.

| | Peak throughput | p50 / p99 at 1,600 clients | DB CPU at the top | VM memory used at the top | Errors |
|---|---:|---:|---:|---:|---:|
| **KiviDB 1.1.2** | **2.08M req/s** | **4.3 / 13.9 ms** | 71% | 2.8 GiB | 0 |
| Dragonfly 2.0.2 | 1.56M req/s | 10.1 / 33.9 ms | 100% (busy-polls) | 2.7 GiB | 0 |
| Redis 8.10.2 Cluster (4 × 2 vCPU) | 0.97M req/s | 26.8 / 44.9 ms | 50% | 3.7 GiB (4 VMs) | 0 |
| Redis 8.10.2 | 0.49M req/s | 55.2 / 72.1 ms | 17% (one core) | 2.6 GiB | 0 |

- `prometheus-export.json`: every panel's series at 5 s resolution, as exported
  from Prometheus before the bench was torn down. `video/render.py --export`
  draws the video from it.
- `kividb-vs-dragonfly-vs-redis.mp4`: the run at 15× speed (1 min 24 s), 1920×1080.
- `peak-throughput.mp4` / `.png`: the summary card. `final-dashboard.png`: the last frame.
- Grafana snapshot of the run:
  https://snapshots.raintank.io/dashboard/snapshot/AheJ35tyvNmMmRx3ExXOe2bbsebZIvWg
