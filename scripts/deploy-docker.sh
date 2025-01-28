#!/bin/bash

echo Deploying contracts to anvil...

while ! grep -q "Listening on 0.0.0.0:8545" <(anvil --dump-state ./anvil-state.json --host 0.0.0.0); do
  sleep 1
done

source ./scripts/local-env.sh
export ETH_RPC_URL=http://localhost:8545

yes | ./scripts/deploy.sh

yes | forge create --private-key 0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6 lib/openzeppelin-contracts/contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol:ERC20PresetFixedSupply --broadcast --constructor-args "Test token" "TEST" 1000 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266

anvil_pid=$(ps aux | grep anvil | grep -v grep | awk '{print $2}')
kill -2 $anvil_pid
wait
