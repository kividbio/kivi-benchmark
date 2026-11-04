# KiviDB 1.2.0 on AWS Graviton3 bare metal (4 November 2026)

A rerun of the October 2026 KiviDB 1.1.0 capture with the 1.2.0 release, on the
same hardware and with the same scripts, with Garnet added.

## Setup

| | |
|---|---|
| Server | AWS c7gn.metal (64 vCPU, Graviton3), us-east-1f; each engine confined to 32 cores with `taskset` (`CORES=32`) |
| Load generator | A second c7gn.metal in the same cluster placement group |
| Client | memtier_benchmark 2.5.2 through `scripts/run-matrix.sh`, 60 threads |
| Connections | 300 with pipeline 16 (5 a thread); 1,200 without pipelining (20 a thread) |
| Data | 10 million keys of 100 bytes, loaded before measuring, read uniformly at random |
| Duration | 30 seconds a scenario (`DURATION=30 SIZES=100 RATIOS="1:0 0:1"`); two rounds, each with a fresh load |
| Persistence | Off for every engine |
| Order | One engine at a time, in one session, 05:29 to 05:52 UTC |

Engines, as `launch.log` recorded them:

| Engine | Version | Command |
|---|---|---|
| KiviDB | 1.2.0 (GitHub release, `kividb-linux-aarch64.tar.gz`) | `taskset -c 0-31 kividb --port 6379 --bind 0.0.0.0 --threads 32` |
| Garnet | v2.2.5 | `taskset -c 0-31 GarnetServer --port 6379 --bind 0.0.0.0 --index 1g` |
| Dragonfly | v2.0.2 | `taskset -c 0-31 dragonfly --port 6379 --bind 0.0.0.0 --proactor_threads 32` |
| Redis | 8.10.3 | `taskset -c 0-31 redis-server --port 6379 --bind 0.0.0.0 --protected-mode no --save "" --appendonly no --io-threads 8` |

## Results

Operations a second, the mean of the two rounds (both rounds are in `all.csv`).

| | KiviDB 1.2.0 | Garnet 2.2.5 | Dragonfly 2.0.2 | Redis 8.10.3 |
|---|---:|---:|---:|---:|
| GET, pipeline 16 | **21.24M** | 20.82M | 9.31M | 2.36M |
| SET, pipeline 16 | 17.79M | **20.27M** | 8.70M | 1.94M |
| GET, no pipelining | 2.99M | 2.88M | **3.30M** | 1.47M |
| SET, no pipelining | 3.22M | 3.07M | **3.37M** | 1.26M |
| p99 GET, pipeline 16 | **0.36 ms** | 0.67 ms | 0.88 ms | 2.29 ms |
| p99 SET, pipeline 16 | **0.45 ms** | 0.80 ms | 1.02 ms | 2.72 ms |
| Memory per key | 143.5 B | not reported | **133.8 B** | 177.7 B |

- Pipelined, KiviDB served 9.0x Redis's GETs and 9.2x its SETs, and 2.3x and 2.0x Dragonfly's.
- Garnet was within 2% of KiviDB on pipelined GET and 14% ahead of it on pipelined SET. KiviDB's p99 was about half of Garnet's on both.
- Without pipelining Dragonfly was 5 to 10% ahead of KiviDB.
- Against the October capture (KiviDB 1.1.0, same machines): pipelined GET 21.2M then and now; pipelined SET 19.2M then, 17.8M now; memory per key 177 B then, 143.5 B now.

## Not in this run

- **Redis Cluster** (32 shards) was started but its runs produced no results; the error log was on the load
  generator, which was terminated before it was read. It is left out rather than taken from another session.
- 1 KB values, the 1:10 mix and core scaling were not run.
- Vector search was not rerun; the October figures stand for KiviDB 1.1.0.

## Files

- `launch.log`: every engine's command line and version, as `start-server.sh` recorded them.
- `client-results.tgz`, and the same files unpacked under `results/`: memtier's text and JSON output for each scenario, `memory-100.txt` and `summary.csv` per engine and round.
- `all.csv`: every round of every engine in one table.
- `../../scripts/metal-120-run.sh`: the driver that ran the session from a workstation.
