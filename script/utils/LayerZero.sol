// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ExecutorOptions} from "layer-zero-v2/protocol/contracts/messagelib/libs/ExecutorOptions.sol";
import {
    ILayerZeroEndpointV2,
    IMessageLibManager,
    MessagingParams
} from "layer-zero-v2/protocol/contracts/interfaces/ILayerZeroEndpointV2.sol";
import {SetConfigParam} from "layer-zero-v2/protocol/contracts/interfaces/IMessageLibManager.sol";
import {Constant} from "layer-zero-v2/messagelib/test/util/Constant.sol";
import {addProposalStep, RADWORKS, RadworksProposal} from "script/utils/Radworks.sol";
import {LZBridgedGovernor, Call} from "src/BridgedGovernor.sol";

// Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
bytes32 constant RADWORKS_ID = bytes32(uint256(uint160(RADWORKS)));
uint32 constant ETHEREUM_EID = 30101;
address constant ETHEREUM_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
address constant ETHEREUM_SEND_ULN = 0xbB2Ea70C9E858123480642Cf96acbcCE1372dCe1;

// Taken from layer-zero-v2/messagelib/contracts/uln/UlnBase.sol
struct UlnConfig {
    uint64 confirmations;
    uint8 requiredDVNCount;
    uint8 optionalDVNCount;
    uint8 optionalDVNThreshold;
    address[] requiredDVNs;
    address[] optionalDVNs;
}

function createSetConfigParams(uint32 otherChainEid, address[] memory dvns, uint8 threshold)
    pure
    returns (SetConfigParam[] memory params)
{
    require(dvns.length > 0, "Empty list of DVNs");
    sortDVNs(dvns);
    params = new SetConfigParam[](1);
    params[0] = SetConfigParam({
        eid: otherChainEid,
        configType: Constant.CONFIG_TYPE_ULN,
        config: abi.encode(
            UlnConfig({
                // 96 blocks are 3 epochs on Ethereum which guarantees that the block is finalized.
                confirmations: 96,
                requiredDVNCount: Constant.NIL_DVN_COUNT,
                requiredDVNs: new address[](0),
                optionalDVNCount: uint8(dvns.length),
                optionalDVNs: dvns,
                optionalDVNThreshold: threshold
            })
        )
    });
}

function sortDVNs(address[] memory dvns) pure {
    for (uint256 i = 0; i < dvns.length - 1; i++) {
        for (uint256 j = i + 1; j < dvns.length; j++) {
            if (uint160(dvns[i]) > uint160(dvns[j])) {
                (dvns[i], dvns[j]) = (dvns[j], dvns[i]);
            }
        }
    }
}

function governorConfigInitCalls(
    address endpoint,
    address governor,
    address receiveUln,
    SetConfigParam[] memory params
) pure returns (Call[] memory calls) {
    calls = new Call[](2);
    bytes memory data = abi.encodeCall(
        IMessageLibManager.setReceiveLibrary, (governor, params[0].eid, receiveUln, 0)
    );
    calls[0] = Call({target: endpoint, data: data, value: 0});
    calls[1] = governorConfigUpdateCall(endpoint, governor, receiveUln, params);
}

function governorConfigUpdateCall(
    address endpoint,
    address governor,
    address receiveUln,
    SetConfigParam[] memory params
) pure returns (Call memory call) {
    bytes memory data = abi.encodeCall(IMessageLibManager.setConfig, (governor, receiveUln, params));
    return Call({target: endpoint, data: data, value: 0});
}

function addRadworksConfigInit(RadworksProposal memory proposal, SetConfigParam[] memory params)
    pure
{
    bytes memory data = abi.encodeCall(
        IMessageLibManager.setSendLibrary, (RADWORKS, params[0].eid, ETHEREUM_SEND_ULN)
    );
    addProposalStep(proposal, ETHEREUM_ENDPOINT, 0, data);
    addRadworksConfigUpdate(proposal, params);
}

function addRadworksConfigUpdate(RadworksProposal memory proposal, SetConfigParam[] memory params)
    pure
{
    bytes memory data =
        abi.encodeCall(IMessageLibManager.setConfig, (RADWORKS, ETHEREUM_SEND_ULN, params));
    addProposalStep(proposal, ETHEREUM_ENDPOINT, 0, data);
}

function addGovernorMessage(
    RadworksProposal memory proposal,
    uint256 fee,
    uint32 governorEid,
    address governor,
    uint128 gas,
    LZBridgedGovernor.Message memory message
) pure {
    bytes memory receiveOption = ExecutorOptions.encodeLzReceiveOption(gas, uint128(message.value));
    // Taken from lib/LayerZero-v2/oapp/contracts/oapp/libs/OptionsBuilder.sol
    bytes memory messageOptions = abi.encodePacked(
        uint16(3), // options type
        ExecutorOptions.WORKER_ID,
        uint16(1 + receiveOption.length),
        ExecutorOptions.OPTION_TYPE_LZRECEIVE,
        receiveOption
    );
    MessagingParams memory params = MessagingParams({
        dstEid: governorEid,
        receiver: bytes32(uint256(uint160(governor))),
        message: abi.encode(message),
        options: messageOptions,
        payInLzToken: false
    });
    bytes memory data = abi.encodeCall(ILayerZeroEndpointV2.send, (params, RADWORKS));
    addProposalStep(proposal, ETHEREUM_ENDPOINT, fee, data);
}
