// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {DEPLOYER_SYSTEM_CONTRACT} from "zksync/system-contracts/contracts/Constants.sol";
import {SystemContractsCaller} from "zksync/system-contracts/contracts/libraries/SystemContractsCaller.sol";
import {L2ContractHelper} from "zksync/l2-contracts/contracts/L2ContractHelper.sol";

// // TODO switch to importing from "zksync/Constants.sol";`
// // when https://github.com/matter-labs/era-contracts/issues/802 is fixed.
// IContractDeployer constant DEPLOYER_SYSTEM_CONTRACT = IContractDeployer(address(0x8006));

library Create2 {
    function deploy(uint128 amount, bytes32 salt, bytes32 bytecodeHash, bytes memory inputData)
        internal
        returns (address addr)
    {
        bytes memory returnData = SystemContractsCaller.systemCallWithPropagatedRevert(
            uint32(gasleft()),
            address(DEPLOYER_SYSTEM_CONTRACT),
            amount,
            abi.encodeCall(DEPLOYER_SYSTEM_CONTRACT.create2, (salt, bytecodeHash, inputData))
        );
        return abi.decode(returnData, (address));
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy}. Any change in the
     * `bytecodeHash` or `salt` will result in a new destination address.
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash, bytes32 constructorInputHash) internal view returns (address) {
        return computeAddress(salt, bytecodeHash, constructorInputHash, address(this));
    }

    /**
     * @dev Returns the address where a contract will be stored if deployed via {deploy} from a contract located at
     * `deployer`. If `deployer` is this contract's address, returns the same value as {computeAddress}.
     */
    function computeAddress(bytes32 salt, bytes32 bytecodeHash, bytes32 constructorInputHash, address deployer) internal pure returns (address addr) {
        return L2ContractHelper.computeCreate2Address(deployer, salt, bytecodeHash, constructorInputHash);
    }
}