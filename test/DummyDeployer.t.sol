// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Test} from "forge-std/Test.sol";

IContractDeployer constant CONTRACT_DEPLOYER = IContractDeployer(address(0x8006));

interface IContractDeployer {
        function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);
}

contract DummyDeployerTest is Test {
    function testDummyDeployer() public {
        Dummy dummy = new DummyDeployer().deploy("salt");
        console.log("Message:", dummy.MESSAGE());
    }
}

contract Dummy {
    string public constant MESSAGE = "Hello";
}

contract DummyDeployer {
    bytes32 immutable internal codeHash = address(new Dummy()).codehash;

    function deploy(bytes32 salt) public returns (Dummy) {
        return Dummy(CONTRACT_DEPLOYER.create2(salt, codeHash, ""));
    }
}