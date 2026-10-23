#!/usr/bin/env bash
# Run on a database VM as root:
#   KIVIDB_VERSION=v1.1.2 setup-db.sh kividb|redis|redis-cluster|dragonfly
# Each server listens on 0.0.0.0:6379 with persistence off (a cache, as in the
# lesson) and its default threading; node_exporter on :9100 gives CPU/memory.
# Redis comes from packages.redis.io (8.10.2 when this was written), Dragonfly
# is pinned to v2.0.2, KiviDB to KIVIDB_VERSION.
set -euxo pipefail
kind="$1"
KIVIDB_VERSION=${KIVIDB_VERSION:-v1.1.2}
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq prometheus-node-exporter curl gnupg ca-certificates > /dev/null
systemctl enable --now prometheus-node-exporter

cat > /etc/sysctl.d/90-bench.conf <<'EOF'
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65000
vm.overcommit_memory = 1
EOF
sysctl --system > /dev/null

nofile() { # unit
  mkdir -p "/etc/systemd/system/$1.service.d"
  printf '[Service]\nLimitNOFILE=1048576\n' > "/etc/systemd/system/$1.service.d/90-bench.conf"
}

case "$kind" in
kividb)
  curl -fsSL -o /tmp/kividb.deb \
    "https://github.com/kividbio/kividb/releases/download/$KIVIDB_VERSION/kividb_arm64.deb"
  apt-get install -y -qq /tmp/kividb.deb > /dev/null
  cat > /etc/kividb/kividb.conf <<'EOF'
bind 0.0.0.0
port 6379
protected-mode no
dir /var/lib/kividb
save ""
appendonly no
update-check no
EOF
  chown kividb:kividb /etc/kividb/kividb.conf
  nofile kividb
  systemctl daemon-reload
  systemctl enable kividb
  systemctl restart kividb
  ;;
redis)
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/redis.list
  apt-get update -qq
  apt-get install -y -qq redis > /dev/null
  conf=/etc/redis/redis.conf
  sed -i -E 's/^bind .*/bind 0.0.0.0/; s/^protected-mode .*/protected-mode no/; s/^appendonly .*/appendonly no/' "$conf"
  sed -i -E '/^save /d' "$conf"
  echo 'save ""' >> "$conf"
  nofile redis-server
  systemctl daemon-reload
  systemctl enable redis-server
  systemctl restart redis-server
  ;;
redis-cluster)
  # A Redis Cluster node: the same package and settings as `redis`, in
  # cluster mode (the cluster is made by create-cluster.sh once all are up).
  curl -fsSL https://packages.redis.io/gpg | gpg --dearmor --yes -o /usr/share/keyrings/redis-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main"     > /etc/apt/sources.list.d/redis.list
  apt-get update -qq
  apt-get install -y -qq redis > /dev/null
  conf=/etc/redis/redis.conf
  sed -i -E 's/^bind .*/bind 0.0.0.0/; s/^protected-mode .*/protected-mode no/; s/^appendonly .*/appendonly no/' "$conf"
  sed -i -E '/^save /d; /^cluster-enabled /d; /^cluster-config-file /d; /^cluster-node-timeout /d' "$conf"
  printf 'save ""
cluster-enabled yes
cluster-config-file /var/lib/redis/nodes.conf
cluster-node-timeout 5000
' >> "$conf"
  nofile redis-server
  systemctl daemon-reload
  systemctl enable redis-server
  systemctl restart redis-server
  ;;
dragonfly)
  curl -fsSL -o /tmp/dragonfly.deb \
    https://github.com/dragonflydb/dragonfly/releases/download/v2.0.2/dragonfly_arm64.deb
  apt-get install -y -qq /tmp/dragonfly.deb > /dev/null
  # The package's unit reads flags from this file.
  flagfile=$(systemctl cat dragonfly 2>/dev/null | grep -oE -- '--flagfile=[^ ]+' | head -1 | cut -d= -f2 || true)
  flagfile=${flagfile:-/etc/dragonfly/dragonfly.conf}
  mkdir -p "$(dirname "$flagfile")"
  cat > "$flagfile" <<'EOF'
--bind=0.0.0.0
--port=6379
--dbfilename=
--dir=/var/lib/dragonfly
EOF
  nofile dragonfly
  systemctl daemon-reload
  systemctl enable dragonfly
  systemctl restart dragonfly
  ;;
*) echo "unknown $kind"; exit 2 ;;
esac
sleep 2
apt-get install -y -qq redis-tools > /dev/null 2>&1 || true
redis-cli -p 6379 INFO server | grep -E '^(redis_version|kividb_version|dragonfly_version|executable)' || true
redis-cli -p 6379 PING
