#!/bin/bash

printf "\n💧 Drips contracts are deployed at: \n"

cat ./deployment_unknown.json
printf "\n\n"

printf "🪙 Test ERC 20 is deployed at:\n"

printf "0x700b6A60ce7EaaEA56F065753d8dcB9653dbAD35 \n\n"

printf "🪙 Address 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 has 1000 TEST.\n\n"

printf "Starting testnet...\n\n"

exec anvil --load-state ./anvil-state.json --host 0.0.0.0
