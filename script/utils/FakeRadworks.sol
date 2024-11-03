// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Governor} from "openzeppelin-contracts/governance/Governor.sol";
import {GovernorCountingSimple} from
    "openzeppelin-contracts/governance/extensions/GovernorCountingSimple.sol";

contract FakeRadworks is Governor("Test governor"), GovernorCountingSimple {
    address public immutable owner = msg.sender;

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function clock() public view virtual override returns (uint48) {
        return uint48(block.timestamp);
    }

    function _getVotes(address account, uint256, bytes memory)
        internal
        view
        override
        returns (uint256 votes)
    {
        if (account == owner) votes = 1;
    }

    function quorum(uint256) public pure override returns (uint256) {
        return 1;
    }

    function votingDelay() public pure override returns (uint256) {
        return 1 minutes;
    }

    function votingPeriod() public pure override returns (uint256) {
        return 10 minutes;
    }
}
