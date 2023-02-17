#!/bin/bash
set -eEuo pipefail

command -v jq &> /dev/null || { echo "jq is required to run this script"; exit 1; }
command -v bc &> /dev/null || { echo "bc is required to run this script"; exit 1; }
command -v docker &> /dev/null || { echo "docker is required to run this script"; exit 1; }
command -v pwgen &> /dev/null || { echo "pwgen is required to run this script"; exit 1; }
( docker compose version 2>&1 || docker-compose version 2>&1 ) | grep -q v2 || { echo "docker compose v2 is required to run this script"; exit 1; }
compose_cmd="$(docker compose version 2>&1 | grep -q v2 && echo 'docker compose' || echo 'docker-compose')"
workdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." &> /dev/null && pwd )"
magic_numbers_count=4

# Creating .env from .env.template file
cp -a "${workdir}/.env.template" "${workdir}/.env"

# Checking if .env file exist
if ! [ -f "${workdir}/.env" ]; then
  echo ".env file is missing. EVMAPP will not be able to start.  Exiting..."
  exit 1
fi

compose_project_name="$(grep COMPOSE_PROJECT_NAME "${workdir}"/.env | cut -d '=' -f2)" || { echo "COMPOSE_PROJECT_NAME value is wrong. Check .env file"; exit 1; }

cd "${workdir}"

# Functions
fn_die() {
  echo -e "$1" >&2
  exit "${2:-1}"
}

source_pattern_from_env () {
  local usage="Source variables from .env matching regexp patterns - usage: ${FUNCNAME[0]} {pattern} {pattern...}"
  [ "${1:-}" = "usage" ] && echo "${usage}" && return
  [ "$#" -lt 1 ] && { echo -e "${FUNCNAME[0]} error: function requires at least one argument.\n\n${usage}"; exit 1;}
  set -a
  for pattern in "$@"; do
    # shellcheck disable=SC1090
    source <(grep -e "${pattern}" "${workdir}"/.env)
  done
  set +a
}

bootstrap_cmd_dev_evm () {
  local cmd="$1"
  local args="$2"
  # shellcheck disable=SC2086
  $compose_cmd run --rm sctool-dev-evm "$cmd" $args | tail -n1
}

zen-cli_cmd () {
  local cmd="$1"
  local args="${*:2}"
  # shellcheck disable=SC2086
  $compose_cmd exec zend gosu user zen-cli "$cmd" $args
}

scnode_cmd () {
  local node="$1"
  local route="$2"
  local postdata="${3:-}"
  if [ -n "${postdata}" ]; then
    postdata="-d ${postdata}"
  fi
  $compose_cmd exec "$node" gosu user curl -sX POST -H 'accept: application/json' -H 'Content-Type: application/json' ${postdata} http://127.0.0.1:9585/"${route}"
}

docker_internal_network () {
  mapfile -t compose_project_networks < <(docker network ls --filter "name=${compose_project_name}" --format json | jq -r '.Name')
  networks=()
  for network in "${compose_project_networks[@]}"; do
    if [ "$(docker inspect "${network}" | jq -r '.[].Internal')" == 'true' ]; then
      networks+=("${network}")
      if [ "${#networks[@]}" -gt 1 ]; then
        echo "There are more than one docker internal networks. Exiting ..."
        exit 1
      else
        echo "${network[0]}"
      fi
    fi
  done
}

check_mc_node () {
  local i=0
  local node="${1}"
  # shellcheck disable=SC2155
  local internal_network=$(docker_internal_network)
  local usage="Check ${node} is up and running correctly - usage: ${FUNCNAME[0]}"
  [ "${1:-}" = "usage" ] && echo "${usage}" && return

  # check all nodes are running
  source_pattern_from_env "^ZEN_RPC_PORT=" "^ZEN_RPC_USER=" "^ZEN_RPC_PASSWORD="

  $compose_cmd up -d "${node}"
  while [ "$(docker inspect "${node}" 2>&1 | jq -rc '.[].State.Status' 2>&1)" != "running" ]; do
    sleep 5
    i="$((i+1))"
    if [ "$i" -gt 48 ]; then
      echo "Error: ${node} container did not start within 4 minutes."
      exit 1
    fi
  done

  # check node is fully up
  node_ip="$(docker inspect "${node}" | jq -rc ".[].NetworkSettings.Networks | with_entries(select(.key | test(\"${internal_network}\"))) [].IPAddress")"
  while [ -n "$( (curl -s --data-binary '{"jsonrpc": "1.0", "id":"curltest", "method": "getblockcount", "params": [] }' -H 'content-type: text/plain;' -u "${ZEN_RPC_USER}:${ZEN_RPC_PASSWORD}" "http://${node_ip}:${ZEN_RPC_PORT}/" || echo '{"error":"connection error"}') | jq 'select(has("code") or has("error") and ."error" != null)')" ]; do
    echo "${FUNCNAME[0]} info: Waiting for ${node} container to be ready."
    sleep 1
  done
}

######
# Building SCTOOL image to make sure new COMMITTISH is being used
######
if docker volume ls | grep evmapp-regtest ; then
  read -rp "This action will erase all the data and all the volumes. If you proceed you will also delete your local wallet. Continue (y/n)? " REPLY
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    fn_die "Exiting ..."
  fi
fi

echo "" && echo "=== Building sidechain bootstrap image ===" && echo ""
$compose_cmd build sctool-dev-evm


######
# Preparing docker environment for a fresh start
######
echo "" && echo "=== Preparing docker environment for EVMAPP launch ===" && echo ""

$compose_cmd down
docker volume rm evmapp-regtest_evmapp-dev1-data evmapp-regtest_evmapp-forger1-data evmapp-regtest_evmapp-snark-keys evmapp-regtest_zen-data || true
$compose_cmd up -d zend

# Making sure Mainchain node(zend) has started correctly
check_mc_node zend

######
# Generating SEED phrases
######
echo "" && echo "=== Generating SEED phrases for Sidechain nodes ===" && echo ""
scnode_wallet_seed_forger1="$(pwgen 64 1)"
scnode_wallet_seed_dev1="$(pwgen 64 1)"
scnode_master_seed1="$(pwgen 64 1)"

# create secrets
withdrawalEpochLen=0
virtualWithdrawalEpochLen=100
ftAmount=100
keyPairForger1="$(bootstrap_cmd_dev_evm generatekey '{"seed":"'"${scnode_wallet_seed_forger1}"'"}')"
vrfKeyPairForger1="$(bootstrap_cmd_dev_evm generateVrfKey '{"seed":"'"${scnode_wallet_seed_forger1}"'"}')"
accountKeyPairForger1="$(bootstrap_cmd_dev_evm generateAccountKey '{"seed":"'"${scnode_wallet_seed_forger1}"'"}')"
accountKeyPairDev1="$(bootstrap_cmd_dev_evm generateAccountKey '{"seed":"'"${scnode_wallet_seed_dev1}"'"}')"
certForger1="$(bootstrap_cmd_dev_evm generateCertificateSignerKey '{"seed":"'"${scnode_wallet_seed_forger1}"'"}')"
certMaster1="$(bootstrap_cmd_dev_evm generateCertificateSignerKey '{"seed":"'"${scnode_master_seed1}"'"}')"

CertProofInfo="$(bootstrap_cmd_dev_evm generateCertWithKeyRotationProofInfo '{"signersPublicKeys":["'"$(jq -rc ".signerPublicKey" <<< "${certForger1}")"'"],"mastersPublicKeys":["'"$(jq -rc ".signerPublicKey" <<< "${certMaster1}")"'"],"threshold":1,"verificationKeyPath":"/tools/output/marlin_snark_vk","provingKeyPath":"/tools/output/marlin_snark_pk","isCSWEnabled":false}')"


######
# Registering a Sidechain
######
echo "" && echo "=== Registering a Sidechain ===" && echo ""

# register sidechain
zen-cli_cmd generate 480 &> /dev/null
sleep 5

arg="{\"version\":2,"
arg+="\"withdrawalEpochLength\":${withdrawalEpochLen},"
arg+="\"toaddress\":\"$(jq -rc ".accountProposition" <<< "${accountKeyPairForger1}")\","
arg+="\"amount\":${ftAmount},"
arg+="\"wCertVk\":\"$(jq -rc ".verificationKey" <<< "${CertProofInfo}")\","
arg+="\"customData\":\"$(jq -rc ".vrfPublicKey" <<< "${vrfKeyPairForger1}")$(jq -rc ".publicKey" <<< "${keyPairForger1}")\","
arg+="\"constant\":\"$(jq -rc ".genSysConstant" <<< "${CertProofInfo}")\","
arg+="\"vFieldElementCertificateFieldConfig\":[255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255,255]}"

scCreate="$(zen-cli_cmd sc_create "${arg}")"

zen-cli_cmd generate 1 &> /dev/null

echo "" && echo "=== Sidechain was successfully registered. Getting genesisinfo ===" && echo ""

scgenesisinfo="$(zen-cli_cmd getscgenesisinfo "$(jq -rc '.scid' <<< "${scCreate}")")"
genesisinfo="$(bootstrap_cmd_dev_evm genesisinfo '{"model":"account","info":"'"${scgenesisinfo}"'","secret":"'"$(jq -rc ".secret" <<< "${keyPairForger1}")"'","vrfSecret":"'"$(jq -rc ".vrfSecret" <<< "${vrfKeyPairForger1}")"'","virtualWithdrawalEpochLength":'"${virtualWithdrawalEpochLen}"'}')"


######
# Populating settings for sidechain nodes
######
echo "" && echo "=== Populating settings for sidechain nodes ===" && echo ""

# populate .env
sed -i "s/SCNODE_CERT_SIGNERS_PUBKEYS=.*/SCNODE_CERT_SIGNERS_PUBKEYS='\"$(jq -rc '.signerPublicKey' <<< "${certForger1}")\"'/g" .env
sed -i "s/SCNODE_CERT_MASTERS_PUBKEYS=.*/SCNODE_CERT_MASTERS_PUBKEYS='\"$(jq -rc '.signerPublicKey' <<< "${certMaster1}")\"'/g" .env
sed -i "s/SCNODE_CERT_SIGNERS_SECRETS_FORGER1=.*/SCNODE_CERT_SIGNERS_SECRETS_FORGER1='\"$(jq -rc '.signerSecret' <<< "${certForger1}")\"'/g" .env
sed -i "s/SCNODE_FORGER_ALLOWED_FORGERS=.*/SCNODE_FORGER_ALLOWED_FORGERS={ blockSignProposition: \"$(jq -rc '.publicKey' <<< "${keyPairForger1}")\"\\\n vrfPublicKey: \"$(jq -rc '.vrfPublicKey' <<< "${vrfKeyPairForger1}")\"}/g" .env
sed -i "s/SCNODE_GENESIS_BLOCKHEX=.*/SCNODE_GENESIS_BLOCKHEX=$(jq -rc '.scGenesisBlockHex' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_SCID=.*/SCNODE_GENESIS_SCID=$(jq -rc '.scId' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_POWDATA=.*/SCNODE_GENESIS_POWDATA=$(jq -rc '.powData' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_MCBLOCKHEIGHT=.*/SCNODE_GENESIS_MCBLOCKHEIGHT=$(jq -rc '.mcBlockHeight' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_MCNETWORK=.*/SCNODE_GENESIS_MCNETWORK=$(jq -rc '.mcNetwork' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_WITHDRAWALEPOCHLENGTH=.*/SCNODE_GENESIS_WITHDRAWALEPOCHLENGTH=$(jq -rc '.withdrawalEpochLength' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_COMMTREEHASH=.*/SCNODE_GENESIS_COMMTREEHASH=$(jq -rc '.initialCumulativeCommTreeHash' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_GENESIS_ISNONCEASING=.*/SCNODE_GENESIS_ISNONCEASING=$(jq -rc '.isNonCeasing' <<< "${genesisinfo}")/g" .env
sed -i "s/SCNODE_WALLET_ACCOUNT_ADDRESS_FORGER1=.*/SCNODE_WALLET_ACCOUNT_ADDRESS_FORGER1='\"$(jq -rc ".accountProposition" <<< "${accountKeyPairForger1}")\"'/g" .env
sed -i "s/SCNODE_WALLET_ACCOUNT_ADDRESS_DEV1=.*/SCNODE_WALLET_ACCOUNT_ADDRESS_DEV1='\"$(jq -rc ".accountProposition" <<< "${accountKeyPairDev1}")\"'/g" .env
sed -i "s/SCNODE_WALLET_GENESIS_SECRETS_FORGER1=.*/SCNODE_WALLET_GENESIS_SECRETS_FORGER1='\"$(jq -rc ".secret" <<< "${keyPairForger1}")\",\"$(jq -rc ".vrfSecret" <<< "${vrfKeyPairForger1}")\",\"$(jq -rc ".accountSecret" <<< "${accountKeyPairForger1}")\"'/g" .env
sed -i "s/SCNODE_WALLET_GENESIS_SECRETS_DEV1=.*/SCNODE_WALLET_GENESIS_SECRETS_DEV1='\"$(jq -rc '.accountSecret' <<< "${accountKeyPairDev1}")\"'/g" .env
sed -i "s/SCNODE_WALLET_SEED_DEV1=.*/SCNODE_WALLET_SEED_DEV1=${scnode_wallet_seed_dev1}/g" .env
sed -i "s/SCNODE_WALLET_SEED_FORGER1=.*/SCNODE_WALLET_SEED_FORGER1=${scnode_wallet_seed_forger1}/g" .env
sed -i "s/SCNODE_MASTER_SEED1=.*/SCNODE_MASTER_SEED1=${scnode_master_seed1}/g" .env

# Generating nginx basic AUTH credentials
nginx_htpasswd="$(pwgen 20 1)"
sed -i "s/NGINX_HTPASSWD=.*/NGINX_HTPASSWD=evmapp:${nginx_htpasswd}/g" .env

nginx_htpasswd_admin="$(pwgen 20 1)"
sed -i "s/NGINX_HTPASSWD_ADMIN=.*/NGINX_HTPASSWD_ADMIN=admin:${nginx_htpasswd_admin}/g" .env

# Randomly populating SCNODE_NET_MAGICBYTES variable under .env file
magic_numbers_str=''
for ((i=1; i<="${magic_numbers_count}"; i++)); do
  magic_numbers_str+="$(shuf -i 1-99 -n 1)"
  if [ "${i}" -ne "${magic_numbers_count}" ]; then
    magic_numbers_str+=','
  fi
done
sed -i "s/SCNODE_NET_MAGICBYTES=.*/SCNODE_NET_MAGICBYTES=${magic_numbers_str}/g" .env


######
# Starting Sidechain nodes
######
echo "" && echo "=== Starting sidechain nodes ===" && echo ""

# start containers
$compose_cmd up -d

# forward transfer to devnode 1
echo "" && echo "=== Running forward transfer=${ftAmount} ZEN to devnode 1 ===" && echo ""
mcReturnAddress="$(zen-cli_cmd listaddresses | jq -rc '.[0]')"
zen-cli_cmd sc_send '[{"scid":"'"$(jq -rc ".scid" <<< "${scCreate}")"'","toaddress":"'"$(jq -rc ".accountProposition" <<< "${accountKeyPairDev1}")"'","amount":'"${ftAmount}"',"mcReturnAddress":"'"${mcReturnAddress}"'"}]' &> /dev/null

zen-cli_cmd generate 1 &> /dev/null

# wait for forward transfer to arrive
spin='-\|/'
i=0
while ! [ "$(scnode_cmd evmapp-forger1 'wallet/getBalance' '{"address":"'"$(jq -rc ".accountProposition" <<< "${accountKeyPairDev1}")"'"}' | jq -rc '.result.balance' | xargs printf '%.f')" = "$(echo "${ftAmount}*1000000000000000000" | bc)" ]; do
  sleep 0.1
  i=$(( (i+1) % 4 ))
  echo -n "Waiting for forward transfer to arrive on sidechain."
  printf "\r${spin:$i:1}"
done

######
# The END
######
echo "" && echo "=== Done ===" && echo ""
exit 0
