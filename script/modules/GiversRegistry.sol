// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {AddressDriver, addressDriverModule} from "script/modules/AddressDriver.sol";
import {create3ManagedProxy} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {GiversRegistry} from "src/Giver.sol";
import {IWrappedNativeToken} from "src/IWrappedNativeToken.sol";

bytes32 constant GIVERS_REGISTRY_MODULE_SALT = "GiversRegistryModule";

function isGiversRegistryModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, GIVERS_REGISTRY_MODULE_SALT);
}

function giversRegistryModule(ModulesDeployer modulesDeployer)
    view
    returns (GiversRegistryModule)
{
    return GiversRegistryModule(getModule(modulesDeployer, GIVERS_REGISTRY_MODULE_SALT));
}

function giversRegistryModuleData(
    ModulesDeployer modulesDeployer,
    address admin,
    IWrappedNativeToken wrappedNativeToken
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(modulesDeployer, admin, wrappedNativeToken);
    return ModuleData({
        salt: GIVERS_REGISTRY_MODULE_SALT,
        initCode: abi.encodePacked(type(GiversRegistryModule).creationCode, args),
        value: 0
    });
}

contract GiversRegistryModule is Module {
    GiversRegistry public immutable giversRegistry;

    constructor(
        ModulesDeployer modulesDeployer,
        address admin,
        IWrappedNativeToken wrappedNativeToken
    ) Module(modulesDeployer, GIVERS_REGISTRY_MODULE_SALT) {
        AddressDriver addressDriver = addressDriverModule(modulesDeployer).addressDriver();
        GiversRegistry logic = new GiversRegistry(addressDriver, wrappedNativeToken);
        address proxy = create3ManagedProxy(modulesDeployer, "GiversRegistry", logic, admin, "");
        giversRegistry = GiversRegistry(proxy);
    }
}
