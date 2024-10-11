// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {create3} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {Caller} from "src/Caller.sol";

bytes32 constant CALLER_MODULE_SALT = "CallerModule";

function isCallerModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, CALLER_MODULE_SALT);
}

function callerModule(ModulesDeployer modulesDeployer) view returns (CallerModule) {
    return CallerModule(getModule(modulesDeployer, CALLER_MODULE_SALT));
}

function callerModuleData(ModulesDeployer modulesDeployer) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(modulesDeployer);
    return ModuleData({
        salt: CALLER_MODULE_SALT,
        initCode: abi.encodePacked(type(CallerModule).creationCode, args),
        value: 0
    });
}

contract CallerModule is Module {
    Caller public immutable caller;

    constructor(ModulesDeployer modulesDeployer) Module(modulesDeployer, CALLER_MODULE_SALT) {
        // slither-disable-next-line too-many-digits
        caller = Caller(create3(modulesDeployer, "Caller", type(Caller).creationCode, ""));
    }
}
