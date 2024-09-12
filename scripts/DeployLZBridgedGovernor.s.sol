// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";
import {ExecutorOptions} from "layer-zero-v2/protocol/contracts/messagelib/libs/ExecutorOptions.sol";
import {
    ILayerZeroEndpointV2,
    IMessageLibManager,
    MessagingParams,
    MessagingReceipt
} from "layer-zero-v2/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layer-zero-v2/protocol/contracts/interfaces/IMessageLibManager.sol";
import {Constant} from "layer-zero-v2/messagelib/test/util/Constant.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";
import {LZBridgedGovernor, GovernorProxy, Call} from "src/BridgedGovernor.sol";

// Taken from layer-zero-v2/messagelib/contracts/uln/UlnBase.sol
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

uint256 constant SEPOLIA_CHAIN_ID = 11155111;
uint256 constant BSC_TESTNET_CHAIN_ID = 97;

uint256 constant NO_GRACE_PERIOD = 0;

// Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
address constant SEPOLIA_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
uint32 constant SEPOLIA_EID = 40161;
address constant SEPOLIA_SEND_ULN_302 = 0xcc1ae8Cf5D3904Cef3360A9532B477529b177cCE;
address constant BSC_TESTNET_ENDPOINT = 0x6EDCE65403992e310A62460808c4b910D972f10f;
uint32 constant BSC_TESTNET_EID = 40102;
address constant BSC_TESTNET_RECEIVE_ULN_302 = 0x188d4bbCeD671A7aA2b5055937F79510A32e9683;

// Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/dvn-addresses
address constant SEPOLIA_LAYER_ZERO_LABS_DVN = 0x8eebf8b423B73bFCa51a1Db4B7354AA0bFCA9193;
address constant BSC_TESTNET_LAYER_ZERO_LABS_DVN = 0x0eE552262f7B562eFcED6DD4A7e2878AB897d405;
address constant SEPOLIA_BWARE_LABS_DVN = 0xCA7a736be0Fe968A33Af62033B8b36D491f7999B;
address constant BSC_TESTNET_BWARE_LABS_DVN = 0x35fa068eC18631719A7f6253710Ba29aB5C5F3b7;

function requireSorted(address[] memory addresses) pure {
    for (uint256 i = 1; i < addresses.length; i++) {
        require(uint160(addresses[i - 1]) < uint160(addresses[i]), "Addresses not sorted");
    }
}

function messageOptions(uint128 gas, uint128 value) pure returns (bytes memory) {
    bytes memory lzReceiveOption = ExecutorOptions.encodeLzReceiveOption(gas, value);
    return abi.encodePacked(
        uint16(3), // options type
        ExecutorOptions.WORKER_ID,
        uint16(1 + lzReceiveOption.length),
        ExecutorOptions.OPTION_TYPE_LZRECEIVE,
        lzReceiveOption
    );
}

function addressToBytes32(address addr) pure returns (bytes32) {
    return bytes32(uint256(uint160(addr)));
}

// forge script scripts/DeployLZBridgedGovernor.s.sol:ConfigureOnSepolia $WALLET_ARGS -f "$ETH_RPC_URL"

contract ConfigureOnSepolia is Script {
    function run() public {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Must be run on Sepolia");

        address[] memory optionalDVNs = new address[](2);
        optionalDVNs[0] = SEPOLIA_LAYER_ZERO_LABS_DVN;
        optionalDVNs[1] = SEPOLIA_BWARE_LABS_DVN;
        requireSorted(optionalDVNs);

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: BSC_TESTNET_EID,
            configType: Constant.CONFIG_TYPE_ULN,
            config: abi.encode(
                UlnConfig({
                    confirmations: 2,
                    requiredDVNCount: Constant.NIL_DVN_COUNT,
                    optionalDVNCount: uint8(optionalDVNs.length),
                    optionalDVNThreshold: 1,
                    requiredDVNs: new address[](0),
                    optionalDVNs: optionalDVNs
                })
            )
        });

        vm.startBroadcast();
        ILayerZeroEndpointV2 endpoint = ILayerZeroEndpointV2(SEPOLIA_ENDPOINT);
        endpoint.setSendLibrary(msg.sender, BSC_TESTNET_EID, SEPOLIA_SEND_ULN_302);
        endpoint.setConfig(msg.sender, SEPOLIA_SEND_ULN_302, params);
        vm.stopBroadcast();
    }
}

// forge script scripts/DeployLZBridgedGovernor.s.sol:DeployToBscTestnet $WALLET_ARGS -f "$ETH_RPC_URL"

contract DeployToBscTestnet is Script {
    function run() public {
        require(block.chainid == BSC_TESTNET_CHAIN_ID, "Must be run on BSC testnet");

        address[] memory optionalDVNs = new address[](2);
        optionalDVNs[0] = BSC_TESTNET_LAYER_ZERO_LABS_DVN;
        optionalDVNs[1] = BSC_TESTNET_BWARE_LABS_DVN;
        requireSorted(optionalDVNs);

        SetConfigParam[] memory params = new SetConfigParam[](1);
        params[0] = SetConfigParam({
            eid: SEPOLIA_EID,
            configType: Constant.CONFIG_TYPE_ULN,
            config: abi.encode(
                UlnConfig({
                    confirmations: 2,
                    requiredDVNCount: Constant.NIL_DVN_COUNT,
                    optionalDVNCount: uint8(optionalDVNs.length),
                    optionalDVNThreshold: 1,
                    requiredDVNs: new address[](0),
                    optionalDVNs: optionalDVNs
                })
            )
        });

        address governor = vm.computeCreateAddress(msg.sender, vm.getNonce(msg.sender) + 1);
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: BSC_TESTNET_ENDPOINT,
            data: abi.encodeWithSelector(
                IMessageLibManager.setReceiveLibrary.selector,
                governor,
                SEPOLIA_EID,
                BSC_TESTNET_RECEIVE_ULN_302,
                NO_GRACE_PERIOD
            ),
            value: 0
        });
        calls[1] = Call({
            target: BSC_TESTNET_ENDPOINT,
            data: abi.encodeWithSelector(
                IMessageLibManager.setConfig.selector, governor, BSC_TESTNET_RECEIVE_ULN_302, params
            ),
            value: 0
        });

        bytes32 owner = addressToBytes32(msg.sender);

        vm.startBroadcast();
        address governorLogic =
            address(new LZBridgedGovernor(BSC_TESTNET_ENDPOINT, SEPOLIA_EID, owner));
        address governorProxy = address(new GovernorProxy(governorLogic, calls));
        vm.stopBroadcast();

        require(governorProxy == governor, "Invalid deployment address");
        console.log("Deployed LZBridgedGovernor:", governor);
    }
}

// forge script scripts/DeployLZBridgedGovernor.s.sol:SendToBscTestnet $WALLET_ARGS -f "$ETH_RPC_URL"

contract SendToBscTestnet is Script {
    function run() public {
        require(block.chainid == SEPOLIA_CHAIN_ID, "Must be run on Sepolia");

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: 0xeD24FC36d5Ee211Ea25A80239Fb8C4Cfd80f12Ee,
            data: abi.encodeWithSignature("approve(address,uint256)", address(0x1234), 5678),
            value: 0
        });

        MessagingParams memory params = MessagingParams({
            dstEid: BSC_TESTNET_EID,
            receiver: addressToBytes32(0xc9241Cf4cD7d9569cA044d8202EF1080405Bc6C9),
            message: abi.encode(LZBridgedGovernor.Message({nonce: 0, value: 0, calls: calls})),
            options: messageOptions(50_000, 0),
            payInLzToken: false
        });

        vm.startBroadcast();
        MessagingReceipt memory receipt =
            ILayerZeroEndpointV2(SEPOLIA_ENDPOINT).send{value: 0.001 ether}(params, msg.sender);
        vm.stopBroadcast();
        console.log("GUID:", Strings.toHexString(uint256(receipt.guid), 32));
        console.log("Nonce:", receipt.nonce);
        console.log("Cost wei:", receipt.fee.nativeFee);
    }
}

// - C O N F I R M A T I O N S -
//96, // 3 epochs
