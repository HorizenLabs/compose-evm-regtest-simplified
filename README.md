# Compose evm regtest
This project uses docker compose to spin up an evmapp sidechain on regtest.  One forging node and one normal node will be spun up.

## Requirements
- docker >= v23.0.0
- docker compose v2
- jq
- bc
- pwgen

## Setup
1. Populate the .env file starting from the .env.template:
    ```shell
    cp .env.template .env
    ```
2. Run the following command to create the stack for the first time:
    ```shell
    ./scripts/init.sh
    ```

## Usage
The evmapp node RPC interfaces will be available over HTTP at:
- Dev: http://localhost:9545/
- Forger: http://localhost:9585/

The Ethereum RPC interface is available at /ethv1:
- Dev: http://localhost:9545/ethv1
- Forger: http://localhost:9585/ethv1
