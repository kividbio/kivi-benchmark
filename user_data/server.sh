#!/bin/bash
# Benchmark server: installs the engines, at pinned versions, and starts none.
# Engines are started one at a time with scripts/start-server.sh, which is
# where their launch commands are.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-server.log) 2>&1

# ── Pinned versions: change these, and the README, together ─────────────────
KIVIDB_VERSION="v1.0.5"
DRAGONFLY_VERSION="v1.37.0"
# Redis comes from Redis's own apt repository (Ubuntu's is years older). Set
# REDIS_APT_VERSION to an exact version string from `apt-cache policy redis`
# to pin it; empty installs the newest there. The version actually installed
# is printed below and recorded by start-server.sh in ~/logs/launch.log.
REDIS_APT_VERSION=""
KIVIDB_RELEASES_BASE="https://releases.kividb.io"
BENCHMARK_REPO="https://github.com/kividbio/kivi-benchmark"
# ─────────────────────────────────────────────────────────────────────────────

ARCH=$(uname -m) # aarch64 or x86_64

apt-get update -y
apt-get install -y curl wget gpg lsb-release git iproute2

curl -fsSL https://packages.redis.io/gpg | gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
  > /etc/apt/sources.list.d/redis.list
apt-get update -y
if [[ -n "$REDIS_APT_VERSION" ]]; then
  apt-get install -y "redis=$REDIS_APT_VERSION" "redis-server=$REDIS_APT_VERSION" "redis-tools=$REDIS_APT_VERSION"
else
  apt-get install -y redis
fi
systemctl stop redis-server || true
systemctl disable redis-server || true

cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 1000000
* hard nofile 1000000
LIMITS

sysctl -w net.core.somaxconn=65535 || true
grep -q '^net.core.somaxconn' /etc/sysctl.conf || echo 'net.core.somaxconn = 65535' >> /etc/sysctl.conf

sudo -u ubuntu -H bash << EOSU
set -euo pipefail
cd /home/ubuntu
mkdir -p bin

# ── KiviDB: the released binary, default build ──────────────────────────────
if [[ ! -x bin/kividb ]]; then
  curl -fsSL "${KIVIDB_RELEASES_BASE}/${KIVIDB_VERSION}/kividb-linux-${ARCH}.tar.gz" -o kividb.tar.gz
  tar -xzf kividb.tar.gz
  install -m 0755 kividb/kividb bin/kividb
  rm -rf kividb kividb.tar.gz
fi

# ── Dragonfly: the released binary, pinned ──────────────────────────────────
if [[ ! -x bin/dragonfly ]]; then
  wget -q "https://github.com/dragonflydb/dragonfly/releases/download/${DRAGONFLY_VERSION}/dragonfly-${ARCH}.tar.gz" \
    -O dragonfly.tar.gz
  tar -xzf dragonfly.tar.gz
  install -m 0755 "dragonfly-${ARCH}" bin/dragonfly
  rm -f dragonfly.tar.gz "dragonfly-${ARCH}"
fi

[[ -d kivi-benchmark ]] || git clone "${BENCHMARK_REPO}"

echo "KiviDB:    \$(bin/kividb --version 2>&1 | head -1)"
echo "Dragonfly: \$(bin/dragonfly --version 2>&1 | head -1)"
echo "Redis:     \$(redis-server --version)"
EOSU

echo "Server user-data finished. Start an engine with ~/kivi-benchmark/scripts/start-server.sh."
