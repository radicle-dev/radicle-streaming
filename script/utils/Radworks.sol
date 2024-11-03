// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IGovernor} from "openzeppelin-contracts/governance/IGovernor.sol";
import {IWrappedNativeToken} from "src/IWrappedNativeToken.sol";

address constant RADWORKS = 0x8dA8f82d2BbDd896822de723F55D6EdF416130ba;

// Take from https://etherscan.io/tokenholdings?a=0x8dA8f82d2BbDd896822de723F55D6EdF416130ba
IWrappedNativeToken constant WETH = IWrappedNativeToken(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

struct RadworksProposal {
    address radworks;
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
}

function requireRunOnEthereum() view {
    require(block.chainid == 1, "Must be run on Ethereum");
}

function createProposal(address radworks, string memory description)
    pure
    returns (RadworksProposal memory proposal)
{
    proposal.radworks = radworks;
    proposal.description = description;
}

function addToProposal(
    RadworksProposal memory proposal,
    address target,
    uint256 value,
    bytes memory data
) pure {
    uint256 oldLength = proposal.targets.length;

    address[] memory targets = new address[](oldLength + 1);
    uint256[] memory values = new uint256[](oldLength + 1);
    bytes[] memory calldatas = new bytes[](oldLength + 1);

    for (uint256 i = 0; i < oldLength; i++) {
        targets[i] = proposal.targets[i];
        values[i] = proposal.values[i];
        calldatas[i] = proposal.calldatas[i];
    }

    targets[oldLength] = target;
    values[oldLength] = value;
    calldatas[oldLength] = data;

    proposal.targets = targets;
    proposal.values = values;
    proposal.calldatas = calldatas;
}

function addToProposalWithdrawWeth(RadworksProposal memory proposal, uint256 amount) pure {
    bytes memory data = abi.encodeCall(IWrappedNativeToken.withdraw, (amount));
    addToProposal(proposal, address(WETH), 0, data);
}

function propose(RadworksProposal memory proposal) returns (uint256 proposalId) {
    return IGovernor(proposal.radworks).propose(
        proposal.targets, proposal.values, proposal.calldatas, proposal.description
    );
}

function execute(RadworksProposal memory proposal) {
    bytes32 descriptionHash = keccak256(bytes(proposal.description));
    IGovernor(proposal.radworks).execute(
        proposal.targets, proposal.values, proposal.calldatas, descriptionHash
    );
}
