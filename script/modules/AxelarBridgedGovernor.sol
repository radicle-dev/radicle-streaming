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
import {AxelarBridgedGovernor, Call, IAxelarGMPGateway} from "src/BridgedGovernor.sol";

bytes32 constant AXELAR_BRIDGED_GOVERNOR_MODULE_SALT = "AxelarBridgedGovernorModule";

function isAxelarBridgedGovernorModuleDeployed(ModulesDeployer modulesDeployer)
    view
    returns (bool yes)
{
    return isModuleDeployed(modulesDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT);
}

function axelarBridgedGovernorModule(ModulesDeployer modulesDeployer)
    view
    returns (AxelarBridgedGovernorModule)
{
    return
        AxelarBridgedGovernorModule(getModule(modulesDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT));
}

function axelarBridgedGovernorModuleData(
    ModulesDeployer modulesDeployer,
    IAxelarGMPGateway gateway,
    string memory ownerChain,
    address owner
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(modulesDeployer, gateway, ownerChain, owner);
    return ModuleData({
        salt: AXELAR_BRIDGED_GOVERNOR_MODULE_SALT,
        initCode: abi.encodePacked(type(AxelarBridgedGovernorModule).creationCode, args),
        value: 0
    });
}

contract AxelarBridgedGovernorModule is Module {
    AxelarBridgedGovernor public immutable axelarBridgedGovernor;

    constructor(
        ModulesDeployer modulesDeployer,
        IAxelarGMPGateway gateway,
        string memory ownerChain,
        address owner
    ) Module(modulesDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT) {
        AxelarBridgedGovernor logic = new AxelarBridgedGovernor(gateway, ownerChain, owner);
        address proxy =
            create3GovernorProxy(modulesDeployer, "AxelarBridgedGovernor", logic, new Call[](0));
        axelarBridgedGovernor = AxelarBridgedGovernor(payable(proxy));
    }
}
