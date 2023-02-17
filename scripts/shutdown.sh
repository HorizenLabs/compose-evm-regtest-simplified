#!/bin/bash

set -eEuo pipefail

( docker compose version 2>&1 || docker-compose version 2>&1 ) | grep -q v2 || { echo "docker compose v2 is required to run this script"; exit 1; }
compose_cmd="$(docker compose version 2>&1 | grep -q v2 && echo 'docker compose' || echo 'docker-compose')"

function scnode_stop_check() {
  local container_name="${1}"
  local spin='-\|/'
  local i=0
  while [ "$(docker inspect "${container_name}" 2>&1 | jq -rc '.[].State.Status' 2>&1)" != "exited" ]; do
    echo "Waiting for EVMAPP application to be stopped."
    sleep 5
    i="$((i+1))"
    if [ "$i" -gt 48 ]; then
      echo "Error: EVMAPP application failed to stop within 4 minutes."
      exit 1
    fi
  done
}

#curl -sX POST "http://localhost:9585/node/stop" -H "accept: application/json"
#curl -sX POST "http://localhost:9545/node/stop" -H "accept: application/json"

echo "Stopping evm nodes docker containers ..."
for container in evmapp-foger1 evmapp-dev1; do
  if [ -n "$(docker ps -a -q -f name="${container}")" ]; then
    $compose_cmd stop "${container}"
    scnode_stop_check "${container}"
  fi
done

exit 0
