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
import {Call, LZBridgedGovernor} from "src/BridgedGovernor.sol";

bytes32 constant LZ_BRIDGED_GOVERNOR_MODULE_SALT = "LZBridgedGovernorModule";
bytes32 constant LZ_BRIDGED_GOVERNOR_SALT = "LZBridgedGovernor";

/// @dev Needed to reduce the number of the `LZBridgedGovernorModule`
/// constructor args and prevent the stack too deep error.
struct BridgeOwner {
    uint32 eid;
    bytes32 id;
}

function lzBridgedGovernorAddress(ModulesDeployer modulesDeployer) view returns (address) {
    address module = modulesDeployer.module(LZ_BRIDGED_GOVERNOR_MODULE_SALT);
    return modulesDeployer.create3Factory().getDeployed(module, LZ_BRIDGED_GOVERNOR_SALT);
}

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
    address owner,
    Call[] memory calls
) pure returns (ModuleData memory) {
    BridgeOwner memory bridgeOwner = BridgeOwner(ownerEid, bytes32(uint256(uint160(owner))));
    bytes memory args = abi.encode(modulesDeployer, endpoint, bridgeOwner, calls);
    return ModuleData({
        salt: LZ_BRIDGED_GOVERNOR_MODULE_SALT,
        initCode: abi.encodePacked(type(LZBridgedGovernorModule).creationCode, args),
        value: 0
    });
}

contract LZBridgedGovernorModule is Module {
    LZBridgedGovernor public immutable lzBridgedGovernor;

    constructor(
        ModulesDeployer modulesDeployer,
        address endpoint,
        BridgeOwner memory owner,
        Call[] memory calls
    ) Module(modulesDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT) {
        LZBridgedGovernor logic = new LZBridgedGovernor(endpoint, owner.eid, owner.id);
        address proxy =
            create3GovernorProxy(modulesDeployer, LZ_BRIDGED_GOVERNOR_SALT, logic, calls);
        lzBridgedGovernor = LZBridgedGovernor(payable(proxy));
    }
}
