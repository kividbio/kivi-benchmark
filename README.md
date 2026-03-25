# Kivi / Dragonfly / Redis benchmark runbook (AWS)

This runbook aligns **instance types and topology** with the public **Dragonfly c7gn** numbers: Dragonfly on **c7gn.12xlarge** (48 vCPU) and **memtier_benchmark** on a separate **c7gn.16xlarge** in the **same Availability Zone**. Infrastructure is provisioned with Terraform under `terraform/`.

## Dragonfly-published reference (c7gn, memtier defaults unless noted)

| Test | Ops/sec (approx.) | Avg. latency (µs) | P99.9 (µs) |
|------|-------------------|-------------------|------------|
| Write-only (`ratio 1:0`, `-t 60 -c 20 -n 200000`) | ~5.2M | ~250 | ~631 |
| Read-only (`ratio 0:1`, same) | ~6M | ~271 | ~623 |
| Pipelined read (`-c 5`, `--pipeline=10`) | ~8.9M | ~323 | ~839 |

Commands from their write-up:

```bash
# Writes
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000

# Reads
memtier_benchmark -s $SERVER_PRIVATE_IP --distinct-client-seed --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000

# Pipelined reads
memtier_benchmark -s $SERVER_PRIVATE_IP --ratio 0:1 -t 60 -c 5 -n 200000 --distinct-client-seed --hide-histogram --pipeline=10
```

Other README snippets (different instance classes) use larger payloads (`-d 256`) and different `-t` / `-c`; use those only when comparing to those specific README rows.

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
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars: key_name, ssh_cidr (recommended: your /32), region.

terraform init
terraform plan
terraform apply
```

Put `key_name` (and other variables) in **`terraform.tfvars`** so `terraform apply` does not prompt interactively.

**If the server never appears in the EC2 console**

1. **Canceled apply** — If you press Ctrl+C while Terraform says `aws_instance.server: Creating...`, AWS may never finish creating the instance (Terraform error: `RunInstances, request canceled, context canceled`). Run `terraform apply` again and **leave it running**. Large **c7gn** instances can stay in `pending` for **several minutes**; “Still creating… 1m0s” is normal.

2. **Stale plan** — If you only see the **client**, you likely applied the client successfully earlier and the **server** apply never completed. `terraform state list` should show `aws_instance.server` only after a successful apply. If it is missing, run `terraform apply` again.

3. **Insufficient capacity in one Availability Zone (common for c7gn.12xlarge)** — **Smaller or different instance types can launch in an AZ where a larger type cannot.** The console error *“We currently do not have sufficient c7gn.12xlarge capacity in the Availability Zone you requested”* is the definitive explanation; **Terraform does not get a clearer message** until EC2 returns—it may show only `Still creating...` for a long time. **Fix:** set `availability_zone` in `terraform.tfvars` to an AZ AWS lists (e.g. in **us-east-1**: `us-east-1a`, `us-east-1b`, `us-east-1d`, `us-east-1f` when **us-east-1c** fails), or set `subnet_id` to a subnet in a good AZ. After changing AZ, run `terraform apply` so **both** instances use the same subnet/AZ. Check `terraform output availability_zone` and `subnet_id` after apply.

4. **Placement group** — If apply **fails** or hangs unusually long, try `use_placement_group = false` in `terraform.tfvars` (cluster groups can make capacity slightly tighter), then `terraform apply` again.

**Where to see the real EC2 error**

- **EC2 → Launch Instance** flow: the red banner / error when launch fails (what you saw).
- **Terraform**: often only `Still creating...` until success or timeout; for API failures, the provider prints the AWS error message.
- **CloudTrail** (optional): `RunInstances` events if you need an audit trail.

Note outputs:

- `server_private_ip` → use as `SERVER` / `$SERVER_PRIVATE_IP` for memtier from the **client**.
- `server_public_ip` / `client_public_ip` → SSH to install nothing extra if user-data completed (see logs below).
- `availability_zone` / `subnet_id` → confirm you are in an AZ with **c7gn** capacity.

**Placement group:** Terraform enables a **cluster** placement group by default (low latency within the AZ). On AWS, a cluster placement group is **locked to the AZ of its first use**. The Terraform name includes that AZ (e.g. `kivi-benchmark-cluster-useast1f`) so changing `availability_zone` creates a **new** group instead of reusing an old one locked to another AZ (which causes `InvalidParameterValue: ... must be launched in the us-east-1c Availability Zone`). If apply fails for other reasons, set `use_placement_group = false` in `terraform.tfvars` and re-apply.

**Bootstrap logs (no servers or benchmarks start automatically):**

- Server: `/var/log/user-data-server.log` (also `cloud-init` logs).
- Client: `/var/log/user-data-client.log`.

Wait until cloud-init finishes (Rust build on the server can take many minutes).

---

## 3. On the server instance (c7gn.12xlarge)

SSH (see `terraform output ssh_server`).

Optional manual steps if you prefer not to rely on user-data:

```bash
sudo apt update
sudo apt install -y git curl build-essential redis-server
sudo systemctl stop redis-server
sudo systemctl disable redis-server

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
source ~/.cargo/env

git clone https://github.com/kivistore/kivi
cd kivi && cargo build --release

wget https://github.com/dragonflydb/dragonfly/releases/latest/download/dragonfly-aarch64.tar.gz
tar -xzf dragonfly-aarch64.tar.gz
chmod +x dragonfly-aarch64

ulimit -n 65535
```

Run **one server at a time** (example ports: Kivi **6380**, Redis and Dragonfly **6379**).

```bash
# Kivi (listens on 0.0.0.0:6380 by default)
cd ~/kivi
KIVI_THREADS=48 ./target/release/kivi
# Tune KIVI_THREADS to your policy; c7gn.12xlarge has 48 vCPUs.

# Dragonfly (stop Kivi first)
cd ~
./dragonfly-aarch64 --port 6379 --logtostderr

# Redis (stop Dragonfly first)
redis-server --bind 0.0.0.0 --port 6379 --protected-mode no \
  --io-threads 4 --io-threads-do-reads yes --daemonize no
```

---

## 4. On the client instance (c7gn.16xlarge)

```bash
sudo apt update
sudo apt install -y build-essential autoconf automake libpcre3-dev \
  libevent-dev pkg-config zlib1g-dev libssl-dev git

git clone https://github.com/RedisLabs/memtier_benchmark
cd memtier_benchmark
autoreconf -ivf
./configure
make -j$(nproc)
sudo make install
```

**Latency check** (same AZ; replace with server private IP from Terraform):

```bash
ping <server-private-ip>
# Aim for sub-millisecond RTT before benchmarking.
```

---

## 5. Nine memtier runs (from client)

Set `SERVER` to the **server private IP** (`terraform output -raw server_private_ip`).

```bash
SERVER=$(terraform -chdir=/path/to/repo/terraform output -raw server_private_ip)
```

### Kivi (port 6380)

```bash
memtier_benchmark -s $SERVER -p 6380 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > kivi_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6380 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > kivi_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6380 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > kivi_pipelined.txt 2>&1
```

### Dragonfly (port 6379)

```bash
memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > dragonfly_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > dragonfly_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > dragonfly_pipelined.txt 2>&1
```

### Redis (port 6379; run only while Redis is bound to 6379, not Dragonfly)

```bash
memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 1:0 -t 60 -c 20 -n 200000 \
  > redis_writeonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --distinct-client-seed \
  --hide-histogram --ratio 0:1 -t 60 -c 20 -n 200000 \
  > redis_readonly.txt 2>&1

memtier_benchmark -s $SERVER -p 6379 --ratio 0:1 -t 60 -c 5 \
  -n 200000 --distinct-client-seed --hide-histogram --pipeline=10 \
  > redis_pipelined.txt 2>&1
```

### Summarize

```bash
grep -A5 "ALL STATS" kivi_writeonly.txt kivi_readonly.txt kivi_pipelined.txt
grep -A5 "ALL STATS" dragonfly_writeonly.txt dragonfly_readonly.txt dragonfly_pipelined.txt
grep -A5 "ALL STATS" redis_writeonly.txt redis_readonly.txt redis_pipelined.txt
```

---

## 6. Teardown

```bash
cd terraform && terraform destroy
```

---

## 7. Comparing to Dragonfly README (other scenarios)

The upstream README also documents **m5.large** vs **m5.xlarge** Redis comparisons and **c6gn.16xlarge** peak throughput with **`-d 256`** and tunable **`-t`** / **`--pipeline`**. Those require **different instance types and memtier flags** than this c7gn runbook; reproduce them by changing `server_instance_type` / `client_instance_type` and the memtier command lines to match the README row you care about.
