#!/bin/bash
set -eEuo pipefail

( docker compose version 2>&1 || docker-compose version 2>&1 ) | grep -q v2 || { echo "docker compose v2 is required to run this script"; exit 1; }
compose_cmd="$(docker compose version 2>&1 | grep -q v2 && echo 'docker compose' || echo 'docker-compose')"

read -rp "This action will erase all the data and all the volumes. If you proceed you will also delete your local wallet. Continue (y/n)? " REPLY
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Exiting..."
    exit 1
else
    echo "Erasing data and volumes ..."
    $compose_cmd down
    if [ "$(docker volume ls | grep "evmapp-regtest-*")" ]; then
      docker volume rm evmapp-regtest_evmapp-dev1-data evmapp-regtest_evmapp-forger1-data evmapp-regtest_evmapp-snark-keys evmapp-regtest_zcash-params evmapp-regtest_zen-data || true
    fi
fi

exit 0
