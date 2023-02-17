#!/bin/bash

set -eEuo pipefail

( docker compose version 2>&1 || docker-compose version 2>&1 ) | grep -q v2 || { echo "docker compose v2 is required to run this script"; exit 1; }
compose_cmd="$(docker compose version 2>&1 | grep -q v2 && echo 'docker compose' || echo 'docker-compose')"

function scnode_start_check() {
  local container_name="${1}"
  local port="${2}"
  i=0
  while [ "$(docker inspect "${container_name}" 2>&1 | jq -rc '.[].State.Status' 2>&1)" != "running" ]; do
    sleep 5
    i="$((i+1))"
    if [ "$i" -gt 48 ]; then
      echo "Error: ${container_name} container did not start within 4 minutes."
      exit 1
    fi
  done

  i=0
  while [ "$(curl -Isk -o /dev/null -w '%{http_code}' -m 10 -X POST "http://127.0.0.1:$port/block/best" -H 'accept: application/json' -H 'Content-Type: application/json')" -ne 200 ]; do
    echo "Waiting for ${container_name} container and/or application to be ready."
    sleep 5
    i="$((i+1))"
    if [ "$i" -gt 48 ]; then
      fn_die "Error: ${container_name} container and/or application did not start within 4 minutes."
    fi
  done
}

echo "Starting evm nodes..."
$compose_cmd up -d

scnode_start_check evmapp-forger1 9585
scnode_start_check evmapp-dev1 9545


######
# The END
######
echo "" && echo "=== EVMAPP nodes were successfully started ===" && echo ""
exit 0
