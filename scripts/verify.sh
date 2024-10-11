#! /usr/bin/env bash
set -eo pipefail

print_title() {
    echo
    echo -----------------------------------------------------------------------------
    echo "$@"
    echo -----------------------------------------------------------------------------
    echo
}

# Args: module address, field name, field type
query() {
    cast call "$1" "$2()($3)"
}

verify_drips_deployer() {
    print_title "Verifying DripsDeployer"
    local ARGS="$(query "$DRIPS_DEPLOYER" args bytes)"
    verify "$DRIPS_DEPLOYER" "src/DripsDeployer.sol:DripsDeployer" "$(query "$DRIPS_DEPLOYER" args bytes)"
}

# Args: contract name
verify_contract_deployer_module() {
    verify_module "$1"
    if [ -z "$MODULE_ADDR" ]; then
        return 0
    fi
    verify_module_contract "$1" "$MODULE_ADDR" deployment "src/$1.sol:$1"
}

# Args: contract name
verify_proxy_deployer_module() {
    verify_module "$1"
    if [ -z "$MODULE_ADDR" ]; then
        return 0
    fi
    verify_module_contract "$1" "$MODULE_ADDR" logic "src/$1.sol:$1"
    verify_module_contract "$1" "$MODULE_ADDR" proxy "src/Managed.sol:ManagedProxy"
}

# Args: contract name
# Sets: MODULE_ADDR
verify_module() {
    print_title "Verifying module $1"
    local SALT="$(cast format-bytes32-string "$1")"
    MODULE_ADDR="$(cast call "$DRIPS_DEPLOYER" "moduleAddress(bytes32)(address)" "$SALT")"
    if [ "$(cast code "$MODULE_ADDR")" == "0x" ]; then
        echo "Module not deployed, skipping".
        unset MODULE_ADDR
        return 0
    fi
    verify "$MODULE_ADDR" "src/DripsDeployer.sol:$1Module" "$(query "$MODULE_ADDR" args bytes)"
}

# Args: contract name, module address, field name, contract path
verify_module_contract() {
    print_title "Verifying $1 $3"
    verify "$(query "$2" "$3" address)" "$4" "$(query "$2" "$3Args" bytes)"
}

verify_dummy_gelato_automate() {
    # Must be called right after verifying RepoDriver
    local REPO_DRIVER="$(query "$MODULE_ADDR" "proxy" address)"
    local GELATO_AUTOMATE="$(query "$REPO_DRIVER" gelatoAutomate address)"
    # The real Gelato Automate contract is an ERC-1967 proxy unlike the dummy version.
    if [ $(cast implementation "$GELATO_AUTOMATE") == $(cast address-zero) ]; then
        verify "$GELATO_AUTOMATE" "src/RepoDriver.sol:DummyGelatoAutomate" ""
    fi
}

# Args: contract address, contract path, ABI-encoded constructor args
verify() {
    if [ -n "$ETHERSCAN_API_KEY" ]; then
        verify_single "$1" "$2" "$3" etherscan
    fi
    if [ -n "$VERIFY_SOURCIFY" ]; then
        verify_single "$1" "$2" "$3" sourcify
    fi
    if [ -n "$VERIFY_BLOCKSCOUT" ]; then
        verify_single "$1" "$2" "$3" blockscout
    fi
}

# Args: contract address, contract path, ABI-encoded constructor args, verifier name
verify_single() {
    echo "Verifying on $4"
    forge verify-contract "$1" "$2" --chain "$CHAIN_ID" --watch --constructor-args "$3" --verifier "$4"
}

main() {
    if [ -z "$1" ]; then
        echo "Error: expected 1 argument, the DripsDeployer address, see README.md"
        exit 1
    fi
    DRIPS_DEPLOYER="$1"
    if [ -z "$ETH_RPC_URL" ]; then
        echo "Error: 'ETH_RPC_URL' variable not set, see README.md"
        exit 1
    fi
    if [ "$(cast code "$DRIPS_DEPLOYER")" == "0x" ]; then
        echo "Error: DripsDeployer not deployed".
        exit 1
    fi
    CHAIN_ID="$(cast chain-id)"
    if [ "$CHAIN_ID" == 11155111 ]; then
        CHAIN=sepolia
    elif [ "$CHAIN_ID" == 314 ]; then
        CHAIN=filecoin
    else
        CHAIN="$(cast chain)"
    fi
    if [ -z "$ETHERSCAN_API_KEY" ] && [ -z "$VERIFY_SOURCIFY" ] && [ -z "$VERIFY_BLOCKSCOUT" ]; then
        echo "Error: none of 'ETHERSCAN_API_KEY', 'VERIFY_SOURCIFY' or 'VERIFY_BLOCKSCOUT'" \
            "variables set, see README.md"
        exit 1
    fi

    print_title "Installing dependencies"
    forge install

    verify_drips_deployer
    verify_proxy_deployer_module Drips
    verify_contract_deployer_module Caller
    verify_proxy_deployer_module AddressDriver
    verify_proxy_deployer_module NFTDriver
    verify_proxy_deployer_module ImmutableSplitsDriver
    verify_proxy_deployer_module RepoDriver
    verify_dummy_gelato_automate
}

main "$@"
