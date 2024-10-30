// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IGovernor} from "openzeppelin-contracts/governance/IGovernor.sol";

address constant RADWORKS = 0x8dA8f82d2BbDd896822de723F55D6EdF416130ba;

struct RadworksProposal {
    address[] targets;
    uint256[] values;
    bytes[] calldatas;
    string description;
}

function createProposal(string memory description)
    pure
    returns (RadworksProposal memory proposal)
{
    proposal.description = description;
}

function addProposalStep(
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

function propose(RadworksProposal memory proposal) returns (uint256 proposalId) {
    return IGovernor(RADWORKS).propose(
        proposal.targets, proposal.values, proposal.calldatas, proposal.description
    );
}
