#!/usr/bin/env bash
# Delete everything the bench created, and confirm it is gone.
set -euo pipefail
RG=${RG:-kividb-video}
az group delete -n "$RG" --yes
echo "$RG exists: $(az group exists -n "$RG")"
here=$(cd "$(dirname "$0")/.." && pwd)
rm -f "$here/.state/kubeconfig"
