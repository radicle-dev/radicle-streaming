// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

IContractDeployer constant CONTRACT_DEPLOYER = IContractDeployer(address(0x8006));

interface IContractDeployer {
        function create2(
        bytes32 _salt,
        bytes32 _bytecodeHash,
        bytes calldata _input
    ) external payable returns (address newAddress);

    function getNewAddressCreate(address _sender, uint256 _senderNonce) external pure returns (address newAddress);

    function getNewAddressCreate2(
        address _sender,
        bytes32 _bytecodeHash,
        bytes32 _salt,
        bytes calldata _input
    ) external view returns (address newAddress);

}
