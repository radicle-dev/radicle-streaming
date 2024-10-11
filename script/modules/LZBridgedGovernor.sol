// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {create3GovernorProxy} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {LZBridgedGovernor} from "src/BridgedGovernor.sol";

bytes32 constant LZ_BRIDGED_GOVERNOR_MODULE_SALT = "LZBridgedGovernorModule";

function isLZBridgedGovernorModuleDeployed(ModulesDeployer modulesDeployer)
    view
    returns (bool yes)
{
    return isModuleDeployed(modulesDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT);
}

function lzBridgedGovernorModule(ModulesDeployer modulesDeployer)
    view
    returns (LZBridgedGovernorModule)
{
    return LZBridgedGovernorModule(getModule(modulesDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT));
}

function lzBridgedGovernorModuleData(
    ModulesDeployer modulesDeployer,
    address endpoint,
    uint32 ownerEid,
    bytes32 owner
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(modulesDeployer, endpoint, ownerEid, owner);
    return ModuleData({
        salt: LZ_BRIDGED_GOVERNOR_MODULE_SALT,
        initCode: abi.encodePacked(type(LZBridgedGovernorModule).creationCode, args),
        value: 0
    });
}

contract LZBridgedGovernorModule is Module {
    LZBridgedGovernor public immutable lzBridgedGovernor;

    constructor(ModulesDeployer modulesDeployer, address endpoint, uint32 ownerEid, bytes32 owner)
        Module(modulesDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT)
    {
        LZBridgedGovernor logic = new LZBridgedGovernor(endpoint, ownerEid, owner);
        address proxy = create3GovernorProxy(modulesDeployer, "LZBridgedGovernor", logic);
        lzBridgedGovernor = LZBridgedGovernor(payable(proxy));
    }
}
