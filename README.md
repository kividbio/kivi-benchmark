# KiviDB / Dragonfly / Redis benchmark runbook (AWS)

This runbook aligns **instance types and topology** with the public **Dragonfly c7gn** numbers: Dragonfly on **c7gn.12xlarge** (48 vCPU) and **memtier_benchmark** on a separate **c7gn.16xlarge** in the **same Availability Zone**. Infrastructure is provisioned with the Terraform in this repository; the engines are started and the runs made with the scripts under `scripts/`.

## Results: KiviDB v1.0.5 vs Dragonfly v1.37.0 vs Redis 8.6

These are the numbers published on [kividb.io](https://kividb.io/#benchmark).

**Setup:**
- Server: **c7gn.12xlarge** (48 vCPU, Graviton3). Load generator: a separate **c7gn.16xlarge** in the **same Availability Zone**.
- One store runs at a time, on the same host and with the same `memtier_benchmark` parameters.
- KiviDB listens on port 6380; Dragonfly and Redis on 6379.
- Each scenario uses `-t 60 -c 5 -n 200000 --pipeline=10` (5 clients per thread, pipeline depth 10).

| Scenario | KiviDB ops/sec | Dragonfly ops/sec | Redis ops/sec | KiviDB vs Dragonfly | KiviDB vs Redis |
|---|---:|---:|---:|---:|---:|
| Pipelined write (SET, `--ratio 1:0`) | **18.5M** | 5.6M | 591K | **~3.3×** | **~31×** |
| Pipelined read (GET, `--ratio 0:1`) | **25.9M** | 8.8M | 1.1M | **~2.9×** | **~24×** |
| Mixed 1:1 (`--ratio 1:1`) | **27.9M** | 9.0M | 914K | **~3.1×** | **~31×** |

| Latency | KiviDB | Dragonfly | Redis |
|---|---:|---:|---:|
| SET avg / p99 | **0.17 ms / 0.35 ms** | 0.52 ms / 3.71 ms | 4.93 ms / 20.22 ms |
| GET avg / p99 | **0.16 ms / 0.32 ms** | 0.36 ms / 0.74 ms | 2.72 ms / 4.70 ms |
| Mixed avg / p99 | **0.17 ms / 0.34 ms** | 0.37 ms / 0.79 ms | 3.27 ms / 5.59 ms |

**Headline claims:**
- **Up to ~31× Redis 8.6 throughput:** pipelined SET (18.5M vs 591K ops/sec) and mixed 1:1 (27.9M vs 914K).
- **~3× Dragonfly v1.37.0 throughput** across GET, SET and mixed: 3.3× SET, 2.9× GET, 3.1× mixed.
- **0.35 ms p99 write latency**, against 20.22 ms on Redis 8.6 (58× lower) and 3.71 ms on Dragonfly (10× lower).

The exact commands these were taken with are in [section 5](#5-runs-from-the-client), under *The published capture*.

## Dragonfly-published reference (c7gn, memtier defaults unless noted)

| Test | Ops/sec (approx.) | Avg. latency (µs) | P99.9 (µs) |
|------|-------------------|-------------------|------------|
| Write-only (`ratio 1:0`, `-t 60 -c 20 -n 200000`) | ~5.2M | ~250 | ~631 |
| Read-only (`ratio 0:1`, same) | ~6M | ~271 | ~623 |
| Pipelined read (`-c 5`, `--pipeline=10`) | ~8.9M | ~323 | ~839 |

> **Note:** For the same pipelined-read command, Dragonfly publishes ~8.9M ops/sec. On
> this runbook's hardware we measured Dragonfly v1.37.0 at 8.8M ops/sec, so our
> Dragonfly runs match its own published figures. We benchmark all three stores in
> the same session on the same instance, so the comparison is fair. Expect 5–15%
> run-to-run variance from AWS capacity and NIC state. Treat every published figure,
> including Dragonfly's own, as **one controlled capture**, not a universal guarantee.

Commands from their write-up:
```bash
# Writes
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000

# Reads
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000

# Pipelined reads
memtier_benchmark -s $SERVER_PRIVATE_IP --ratio 0:1 -t 60 -c 5 -n 200000 --distinct-client-seed --hide-histogram --pipeline=10
```

---

## 1. Prerequisites

- AWS account with **service quotas** allowing **c7gn.12xlarge** and **c7gn.16xlarge** in the chosen region.
- An EC2 **key pair** in that region (for SSH).
- [Terraform](https://www.terraform.io/) `>= 1.3`, [AWS CLI](https://aws.amazon.com/cli/) configured (`aws configure` or environment variables).
```bash
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."
# Optional: AWS_SESSION_TOKEN for assumed roles
export AWS_DEFAULT_REGION="us-east-1"
```

---

## 2. Provision instances
```bash
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: key_name, ssh_cidr (recommended: your /32), region.

terraform init
terraform plan
terraform apply
```

Put `key_name` (and other variables) in **`terraform.tfvars`** so `terraform apply` does not prompt interactively.

**If the server never appears in the EC2 console**

1. **Canceled apply** — If you press Ctrl+C while Terraform says `aws_instance.server: Creating...`, AWS may never finish creating the instance. Run `terraform apply` again and **leave it running**. Large **c7gn** instances can stay in `pending` for **several minutes**; "Still creating… 1m0s" is normal.

2. **Stale plan** — If you only see the **client**, the **server** apply likely never completed. `terraform state list` should show `aws_instance.server` only after a successful apply. If it is missing, run `terraform apply` again.

3. **Insufficient capacity** — The console error *"We currently do not have sufficient c7gn.12xlarge capacity in the Availability Zone you requested"* is the definitive explanation. **Fix:** set `availability_zone` in `terraform.tfvars` to an AZ AWS lists (e.g. in **us-east-1**: `us-east-1a`, `us-east-1b`, `us-east-1d`, `us-east-1f` when **us-east-1c** fails), or set `subnet_id` to a subnet in a good AZ. After changing AZ, run `terraform apply` so **both** instances use the same subnet/AZ.

4. **Placement group** — If apply **fails** or hangs unusually long, try `use_placement_group = false` in `terraform.tfvars`, then `terraform apply` again.

Note outputs:

- `server_private_ip` → use as `SERVER` for memtier from the **client**.
- `server_public_ip` / `client_public_ip` → SSH access.
- `availability_zone` / `subnet_id` → confirm you are in an AZ with **c7gn** capacity.

**Bootstrap logs:**

- Server: `/var/log/user-data-server.log`
- Client: `/var/log/user-data-client.log`

Wait until cloud-init finishes on both (`cloud-init status --wait`). The client builds memtier from source, which takes a few minutes.

---

## 3. The server instance (c7gn.12xlarge)

`user_data/server.sh` installs the three engines at pinned versions and starts
none of them. Its log, `/var/log/user-data-server.log`, ends with the version
of each.

| Engine | Version | Source |
|---|---|---|
| KiviDB | v1.0.5, default build | `releases.kividb.io` |
| Dragonfly | v1.37.0 | its GitHub release |
| Redis | the newest in Redis's apt repository, or the one pinned in `server.sh` | `packages.redis.io` |

Start **one engine at a time** with `scripts/start-server.sh`. It stops
whatever was running and checks that it is gone, starts the engine in an empty
directory, and appends the exact command and the engine's version to
`~/logs/launch.log`.

```bash
~/kivi-benchmark/scripts/start-server.sh kividb
~/kivi-benchmark/scripts/start-server.sh dragonfly
~/kivi-benchmark/scripts/start-server.sh redis
~/kivi-benchmark/scripts/start-server.sh redis-cluster
```

Valkey, KeyDB and Garnet are not installed by `user_data/server.sh`. Install
them once with `scripts/install-more-engines.sh` (Valkey 9.1.2 from its
binary package, KeyDB v6.3.4 built from its release tag, Garnet v2.2.1 on the
.NET 10 runtime), and start them the same way:

```bash
~/kivi-benchmark/scripts/install-more-engines.sh
~/kivi-benchmark/scripts/start-server.sh valkey
~/kivi-benchmark/scripts/start-server.sh keydb
~/kivi-benchmark/scripts/start-server.sh garnet
```

What each is started with, on a 48-vCPU instance (all on port 6379, the
cluster on 7000 upwards):

| Engine | Command |
|---|---|
| KiviDB | `kividb --port 6379 --bind 0.0.0.0 --threads 46` |
| Dragonfly | `dragonfly --port 6379 --bind 0.0.0.0 --proactor_threads 46 --dbfilename "" --logtostderr` |
| Redis | `redis-server --port 6379 --bind 0.0.0.0 --protected-mode no --save "" --appendonly no --io-threads 8` |
| Redis Cluster | 46 x `redis-server --port 70NN --cluster-enabled yes --save "" --appendonly no`, no replicas |
| Valkey | `valkey-server --port 6379 --bind 0.0.0.0 --protected-mode no --save "" --appendonly no --io-threads 8` |
| KeyDB | `keydb-server --port 6379 --bind 0.0.0.0 --protected-mode no --save "" --appendonly no --server-threads 16` |
| Garnet | `GarnetServer --port 6379 --bind 0.0.0.0 --index 1g` |

The same for every engine:

- **Persistence is off.** No snapshot and no append-only file.
- **No memory limit**, and an empty dataset at the start.
- **Threads.** KiviDB and Dragonfly get the same number, vCPUs minus two,
  which is KiviDB's own default. Set `THREADS` to change it for both. KiviDB
  takes its thread count from `--threads` only.
- **Redis executes commands on one thread**, whatever `--io-threads` is. A
  single Redis against a multi-threaded engine on 48 cores is one core against
  many. `redis-cluster` is the comparison that gives Redis the whole machine:
  one primary per core, and memtier in cluster mode. Valkey is the same:
  `--io-threads` moves socket I/O off the main thread, not command execution.
- **KeyDB** gets 16 server threads (`KEYDB_THREADS`), and **Garnet** sizes its
  own thread pool. Garnet's hash index is raised from its 128 MB default to
  1 GB, for the 10 million keys of the matrix.

**Core scaling.** `CORES=<n>` confines the engine to the first `n` CPUs with
`taskset` and sets its thread or shard count to match:

```bash
CORES=4  ~/kivi-benchmark/scripts/start-server.sh kividb
CORES=16 ~/kivi-benchmark/scripts/start-server.sh redis-cluster   # 16 primaries
```

`scripts/stop-server.sh` kills everything and fails if anything is left
running or listening. Engines are killed, not asked to stop: the data is
disposable, and an engine asked nicely may first write it all to disk.

---

## 4. The client instance (c7gn.16xlarge)

`user_data/client.sh` builds `memtier_benchmark` from its newest release tag
and installs `redis-cli`. Its log is `/var/log/user-data-client.log`.

**Latency check** (same AZ; should be well under a millisecond):
```bash
ping <server-private-ip>
```

---

## 5. Runs (from the client)

```bash
SERVER=<server-private-ip>

# With the engine started on the server:
~/kivi-benchmark/scripts/run-matrix.sh kividb    $SERVER 6379
~/kivi-benchmark/scripts/run-matrix.sh dragonfly $SERVER 6379
~/kivi-benchmark/scripts/run-matrix.sh redis     $SERVER 6379
~/kivi-benchmark/scripts/run-matrix.sh redis-cluster $SERVER 7000 cluster
```

For each value size, `run-matrix.sh` empties the server, writes every key
once, and then runs each scenario for a fixed time over the whole keyspace:

| | |
|---|---|
| Value sizes | 100 bytes and 1 KB |
| Pipeline depth | 1 (60 threads x 20 connections) and 16 (60 threads x 5 connections) |
| Workloads | write-only, read-only, and 1 write to 10 reads |
| Keys | 10 million, uniformly random |
| Duration | 60 seconds a scenario, after the load |

Two choices matter more than the rest:

- **Scenarios are timed, not counted** (`--test-time`, not `-n`). With a
  fixed number of requests, a fast engine is finished in seconds and is
  measured while it is still warming up, and a slow one runs for minutes.
- **The value size is always given.** memtier's default is 32 bytes, which is
  the most flattering case for any engine.

Results are written to `~/results/<label>/`: memtier's text and JSON output
for every scenario, the server's memory and key count after each load
(bytes per key), and `summary.csv`. Garnet does not report `used_memory`, so
its bytes-per-key column is empty.

**Multi-key commands.** `run-multikey.sh` loads the same 10 million keys
(100-byte values) and runs `MSET` and `MGET` of 10 keys a command for 60
seconds each, at pipeline depth 1. Its rows are added to the same
`summary.csv`, counted in commands a second, not keys. It is not for a
cluster: ten random keys do not share a hash slot.

```bash
~/kivi-benchmark/scripts/run-multikey.sh kividb $SERVER 6379
```

**Core scaling.** With the engine started under `CORES=<n>`, a shorter matrix
is enough to see the curve:

```bash
OUT=~/results/scale-kividb-8 DURATION=30 SIZES=100 PIPELINES=16 RATIOS="1:0 0:1" \
  ~/kivi-benchmark/scripts/run-matrix.sh scale-kividb-8 $SERVER 6379
```

### The published capture

The numbers at the top of this page were taken before these scripts existed,
with the commands below: 60 threads, 5 connections each, pipeline depth 10.

```bash
# Pipelined write (SET)
memtier_benchmark -s $SERVER -p $PORT --ratio 1:0 -t 60 -c 5 -n 200000 \
  --distinct-client-seed --hide-histogram --pipeline=10

# Pipelined read (GET)
memtier_benchmark -s $SERVER -p $PORT --ratio 0:1 -t 60 -c 5 -n 200000 \
  --distinct-client-seed --hide-histogram --pipeline=10

# Mixed 1:1
memtier_benchmark -s $SERVER -p $PORT --ratio 1:1 -t 60 -c 5 -n 200000 \
  --distinct-client-seed --hide-histogram --pipeline=10
```

Read them with these in mind:

- They fix the number of requests (60 million a run), so the faster the
  engine, the shorter its run.
- No value size is given, so values are memtier's 32-byte default.
- KiviDB was started without `--threads` and so ran on its default, 46
  threads on this instance; Dragonfly with its defaults; Redis as a single
  instance with `--io-threads 4`.

---

## 6. Teardown
```bash
terraform destroy
```

---

## 7. Reproducibility notes

Results are **environment-specific**. Repeat runs on your own hardware and
workload shape. Key factors that affect numbers:

- **NIC state** — c7gn ENA adapters can vary in throughput across runs by 5–15%.
- **NUMA / CPU frequency** — Graviton3 has a single NUMA node; frequency
  scaling is minimal but not zero.
- **Kernel scheduler** — io_uring submission batching varies with load.
- **Run order** — Always benchmark all three stores in the same session on
  the same instance to control for environmental drift.

Treat all published figures as **one controlled capture**, not a universal
guarantee. The scripts and the Terraform are in this repository.

---

## 8. Comparing to Dragonfly README (other scenarios)

The upstream Dragonfly README also documents **m5.large** vs **m5.xlarge**
comparisons and **c6gn.16xlarge** peak throughput with **`-d 256`** and
tunable **`-t`** / **`--pipeline`**. Those require different instance types
and memtier flags than this c7gn runbook; reproduce them by changing
`server_instance_type` / `client_instance_type` and the memtier command
lines to match the specific README row you care about.

---

# Vector search benchmark (KiviDB vs Redis Stack)

Separate from the memtier KV runbook above: this benchmarks KiviDB's
`FT.CREATE`/`FT.SEARCH` HNSW vector index against **Redis Stack Server**
using [**vector-db-benchmark**](https://github.com/redis-performance/vector-db-benchmark)
(the tool the wider industry uses for this comparison, not a KiviDB-only
script) — same dataset, same HNSW parameters, same client, on the same
single instance in the same run.

**Repo pointer:** upstream `redis/vector-db-benchmark` didn't have a `kividb`
engine — we added one and it merged as
[PR #203](https://github.com/redis/vector-db-benchmark/pull/203) on
2026-07-26. The numbers below run straight from that official repo, at the
commit linked in Methodology.

## Methodology

| | |
|---|---|
| Tool | [`vector-db-benchmark`](https://github.com/redis/vector-db-benchmark/tree/31a28b5ae6d35da96de6d218ada209868a628b42), run at this commit |
| Dataset | `glove-25-angular` — 1,183,514 vectors, 25-dim, cosine |
| Index config | HNSW `M=16`, `EF_CONSTRUCTION=256` (`redis-m-16-ef-256`) |
| Upload | 100 threads, batch size 64, unpipelined `HSET` per vector (matches the tool's real client — not a pipelined synthetic script) |
| Search sweep | `ef` ∈ {64, 128, 256, 512}, `parallel` = 100 |
| Instance | **AWS, `us-east-1`, one cluster placement group.** Server (KiviDB / Redis Stack, one at a time): `c7gn.12xlarge` (48 vCPU, Graviton, network-optimized). Client (benchmark driver): a **separate** `c7gn.12xlarge` instance — co-locating the driver with the server under test understates the server's real throughput (confirmed live: numbers on a shared, smaller instance were markedly worse for both engines). |
| KiviDB | built from source at KiviDB HEAD, same CI run |
| Redis Stack | `redis-stack-server` **7.4.0-v8** (bundles Redis engine 7.4.7 + RediSearch 2.10.20) from the official `packages.redis.io` apt repo, version-pinned — not `:latest` |

This is the exact methodology KiviDB's own internal CI regression gate runs
on every push to `main`/`master` and on demand. That workflow is the
automated, reproducible source of truth for these numbers — provisions the
server + client pair above, builds KiviDB and the driver from source on
native arm64 runners, runs both engines, and tears both instances down.

## Results

Real run, 2026-07-27, on the topology above, against the official
`redis/vector-db-benchmark` repo (`gh run view` job timestamps and result
artifacts on file):

| | KiviDB | Redis Stack | |
|---|---:|---:|---|
| Upload throughput (1.18M vectors) | **5,262 rec/s** | 2,605 rec/s | KiviDB 2.02× |
| Total ingest time | **225.1 s** | 454.6 s | KiviDB 2.02× |
| Search QPS, ef=64 | **42,360** | 2,508 | KiviDB 16.9× |
| Search QPS, ef=128 | **36,023** | 2,265 | KiviDB 15.9× |
| Search QPS, ef=256 | **23,409** | 1,563 | KiviDB 15.0× |
| Search QPS, ef=512 | **13,229** | 988 | KiviDB 13.4× |
| Recall, ef=64 | 0.9425 | 0.9115 | KiviDB higher at every tier |
| Recall, ef=512 | 0.9977 | 0.9951 | KiviDB higher at every tier |
| P50 latency, ef=64 | **1.91 ms** | 30.40 ms | KiviDB lower at every tier |
| P95 latency, ef=64 | **4.52 ms** | 59.68 ms | KiviDB lower at every tier |

KiviDB wins ingest, search QPS, recall, and latency simultaneously — not a
tradeoff at any operating point in this sweep. A first run on our own fork of
the benchmark tool, before this one, landed within a few percent of every
number above — confirming it on official upstream ruled out anything
fork-specific. Full per-tier P50/P95/precision breakdown is available on
request from the run's result artifacts.

## A real compatibility gap this surfaced, and its fix

The published `vector-db-benchmark` client waits for indexing to finish by
polling `FT.INFO` for RediSearch's `num_docs`/`percent_indexed` fields.
KiviDB's `FT.INFO` doesn't expose those — it reports HNSW graph state
directly as `hnsw_live_count`/`hnsw_compaction_in_progress` instead, because
KiviDB builds each vector's HNSW entry synchronously inside the `HSET` that
stores it (there is no async backfill to report on). A client that only
understands `num_docs` sees it stuck at 0 and stalls until its own timeout —
looking like a hung indexer when the data was actually already fully
indexed.

Fixed by the `kividb` engine added in
[PR #203](https://github.com/redis/vector-db-benchmark/pull/203) (`src/bin/vector_db_benchmark/engine/kividb.rs`),
merged upstream 2026-07-26, which polls the fields KiviDB actually reports
instead, mirroring the existing `dragonfly`/`valkey` Redis-wire-compatible
engines.

## Reproducing

The numbers above ran via KiviDB's own internal CI (builds from source,
tears down after). To reproduce independently, you need TWO c7gn.12xlarge
instances (server + client, same placement group) — running both roles on
one box measures materially lower numbers for both engines (see
Methodology). On the CLIENT instance:

```bash
git clone https://github.com/redis/vector-db-benchmark /tmp/vdb
cd /tmp/vdb && git checkout 31a28b5ae6d35da96de6d218ada209868a628b42
sudo apt-get install -y libhdf5-dev pkg-config dpkg-dev
HDF5_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/hdf5/serial" \
  cargo build --release --bin vector-db-benchmark
```

Two single-entry engines-files — the tool rejects `--engines` and
`--engines-file` together, and one file with no name filter runs every
entry in it, so a shared file can't select just one engine:

```bash
cat > kividb-engine.json << 'EOF'
[{ "name": "kividb-glove25", "engine": "kividb", "connection_params": {},
   "collection_params": { "hnsw_config": { "M": 16, "EF_CONSTRUCTION": 256 } },
   "search_params": [
     { "parallel": 100, "search_params": { "ef": 64 } },
     { "parallel": 100, "search_params": { "ef": 128 } },
     { "parallel": 100, "search_params": { "ef": 256 } },
     { "parallel": 100, "search_params": { "ef": 512 } }
   ],
   "upload_params": { "parallel": 100, "batch_size": 64 } }]
EOF
# Same shape with "engine": "redis" for redisstack-engine.json.

KIVIDB_PORT=6380 ./target/release/vector-db-benchmark --host <server-private-ip> \
  --engines-file kividb-engine.json --datasets glove-25-angular --parallels 100 --skip-if-exists false
REDIS_PORT=6381 ./target/release/vector-db-benchmark --host <server-private-ip> \
  --engines-file redisstack-engine.json --datasets glove-25-angular --parallels 100 --skip-if-exists false
```

No Python, no venv, no `redis==4.6.0` RESP3 workaround needed anymore — the
Rust tool's `redis` crate defaults to RESP2 like KiviDB, same as the old
Python client needed the pin for.