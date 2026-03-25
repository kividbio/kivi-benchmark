#!/bin/bash
# Benchmark client (c7gn.16xlarge class): memtier_benchmark from source — no benchmark runs.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-client.log) 2>&1

apt-get update -y
apt-get install -y build-essential autoconf automake libpcre3-dev \
  libevent-dev pkg-config zlib1g-dev libssl-dev git

sudo -u ubuntu -H bash << 'EOSU'
set -euo pipefail
cd /home/ubuntu
if [[ ! -d /home/ubuntu/memtier_benchmark ]]; then
  git clone https://github.com/RedisLabs/memtier_benchmark
fi
cd /home/ubuntu/memtier_benchmark
git pull --ff-only || true
autoreconf -ivf
./configure
make -j"$(nproc)"
EOSU

cd /home/ubuntu/memtier_benchmark && make install

echo "Client user-data finished. memtier_benchmark: $(command -v memtier_benchmark)"
