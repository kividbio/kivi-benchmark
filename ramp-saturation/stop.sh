#!/usr/bin/env bash
# Stop the load: delete the client deployments (the databases keep running).
set -euo pipefail
kubectl -n bench delete deploy -l app=ramp-client --ignore-not-found
