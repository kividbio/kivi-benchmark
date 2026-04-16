#!/bin/bash
# Benchmark server (c7gn.12xlarge class): installs tooling only — no Redis/Dragonfly/Kivi processes.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

exec > >(tee /var/log/user-data-server.log) 2>&1

# ── Pinned versions — update these when cutting a new benchmark run ──────────
KIVIDB_VERSION="v0.1.12"
KIVIDB_RELEASES_BASE="https://releases.kividb.io"
# ─────────────────────────────────────────────────────────────────────────────

apt-get update -y
apt-get install -y wget redis-server   # curl already present on Ubuntu AMIs; git/build-essential no longer needed

systemctl stop redis-server || true
systemctl disable redis-server || true

cat >> /etc/security/limits.conf << 'LIMITS'
* soft nofile 65535
* hard nofile 65535
LIMITS

sysctl -w net.core.somaxconn=65535 || true
grep -q '^net.core.somaxconn' /etc/sysctl.conf || echo 'net.core.somaxconn = 65535' >> /etc/sysctl.conf

sudo -u ubuntu -H bash << EOSU
set -euo pipefail
cd /home/ubuntu

# ── KiviDB: download pre-built binary ────────────────────────────────────────
if [[ ! -x /home/ubuntu/kividb ]]; then
  echo "Downloading KiviDB ${KIVIDB_VERSION}..."
  curl -fsSL "${KIVIDB_RELEASES_BASE}/${KIVIDB_VERSION}/kividb-linux-aarch64.tar.gz" \
    -o kividb-linux-aarch64.tar.gz
  tar -xzf kividb-linux-aarch64.tar.gz
  chmod +x kividb/kividb
  mv kividb/kividb ./kividb
  rm -rf kividb-linux-aarch64.tar.gz kividb/
fi
echo "KiviDB ready: \$(./kividb --version 2>/dev/null || echo 'binary present')"

# ── Dragonfly: download pre-built binary ─────────────────────────────────────
if [[ ! -x /home/ubuntu/dragonfly-aarch64 ]]; then
  echo "Downloading Dragonfly..."
  wget -q "https://github.com/dragonflydb/dragonfly/releases/latest/download/dragonfly-aarch64.tar.gz" \
    -O dragonfly-aarch64.tar.gz
  tar -xzf dragonfly-aarch64.tar.gz
  chmod +x dragonfly-aarch64
  rm -f dragonfly-aarch64.tar.gz
fi
echo "Dragonfly ready."

EOSU

echo "Server user-data finished. KiviDB ${KIVIDB_VERSION} + Dragonfly binary ready under /home/ubuntu."