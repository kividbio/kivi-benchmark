#!/usr/bin/env bash
# Stop every engine on this host and make sure it is gone.
#
# One engine runs at a time. A process left behind from the previous run
# would share the machine with the next engine, and with SO_REUSEPORT it can
# even share its port, so "stopped" is checked, not assumed.
set -uo pipefail

NAMES=(kividb redis-server dragonfly valkey-server)

running() {
  local name
  for name in "${NAMES[@]}"; do
    pgrep -x "$name" >/dev/null && return 0
  done
  return 1
}

for name in "${NAMES[@]}"; do pkill -TERM -x "$name" 2>/dev/null; done
for _ in $(seq 20); do
  running || break
  sleep 0.5
done
if running; then
  for name in "${NAMES[@]}"; do pkill -KILL -x "$name" 2>/dev/null; done
  sleep 1
fi
if running; then
  echo "stop-server: an engine is still running:" >&2
  for name in "${NAMES[@]}"; do pgrep -xa "$name" >&2; done
  exit 1
fi
# Nothing may be listening on the ports the engines use (a killed io_uring
# server can hold its sockets for a moment after the process is gone).
for _ in $(seq 20); do
  ss -ltn 2>/dev/null | grep -Eq ':(6379|6380|70[0-9][0-9]) ' || break
  sleep 0.5
done
if ss -ltn 2>/dev/null | grep -Eq ':(6379|6380|70[0-9][0-9]) '; then
  echo "stop-server: something is still listening:" >&2
  ss -ltnp 2>/dev/null | grep -E ':(6379|6380|70[0-9][0-9]) ' >&2
  exit 1
fi
echo "stop-server: no engine running"
