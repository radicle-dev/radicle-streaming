// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {ModulesDeployer} from "script/utils/ModulesDeployer.sol";
import {Call, Governor, GovernorProxy} from "src/BridgedGovernor.sol";
import {Managed, ManagedProxy} from "src/Managed.sol";

function create3ManagedProxy(
    ModulesDeployer modulesDeployer,
    bytes32 salt,
    Managed logic,
    address admin,
    bytes memory data
) returns (address proxy) {
    bytes memory args = abi.encode(logic, admin, data);
    // slither-disable-next-line too-many-digits
    return create3(modulesDeployer, salt, type(ManagedProxy).creationCode, args);
}

function create3GovernorProxy(
    ModulesDeployer modulesDeployer,
    bytes32 salt,
    Governor logic,
    Call[] memory calls
) returns (address proxy) {
    bytes memory args = abi.encode(logic, calls);
    // slither-disable-next-line too-many-digits
    return create3(modulesDeployer, salt, type(GovernorProxy).creationCode, args);
}

function create3(
    ModulesDeployer modulesDeployer,
    bytes32 salt,
    bytes memory creationCode,
    bytes memory args
) returns (address deployment) {
    return modulesDeployer.create3Factory().deploy(salt, abi.encodePacked(creationCode, args));
}
