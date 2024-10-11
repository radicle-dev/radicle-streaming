// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {create3ManagedProxy} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {Drips, dripsModule, DripsModule} from "script/modules/Drips.sol";
import {ImmutableSplitsDriver} from "src/ImmutableSplitsDriver.sol";

bytes32 constant IMMUTABLE_SPLITS_DRIVER_MODULE_SALT = "ImmutableSplitsDriverModule";

function isImmutableSplitsDriverModuleDeployed(ModulesDeployer modulesDeployer)
    view
    returns (bool yes)
{
    return isModuleDeployed(modulesDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT);
}

function immutableSplitsDriverModule(ModulesDeployer modulesDeployer)
    view
    returns (ImmutableSplitsDriverModule)
{
    return
        ImmutableSplitsDriverModule(getModule(modulesDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT));
}

function immutableSplitsDriverModuleData(ModulesDeployer modulesDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(modulesDeployer, admin);
    return ModuleData({
        salt: IMMUTABLE_SPLITS_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(ImmutableSplitsDriverModule).creationCode, args),
        value: 0
    });
}

contract ImmutableSplitsDriverModule is Module {
    ImmutableSplitsDriver public immutable immutableSplitsDriver;

    constructor(ModulesDeployer modulesDeployer, address admin)
        Module(modulesDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(modulesDeployer);
        Drips drips = dripsModule_.drips();
        uint32 driverId = 2;
        ImmutableSplitsDriver logic = new ImmutableSplitsDriver(drips, driverId);
        address proxy =
            create3ManagedProxy(modulesDeployer, "ImmutableSplitsDriver", logic, admin, "");
        immutableSplitsDriver = ImmutableSplitsDriver(proxy);
        dripsModule_.claimDriverId(IMMUTABLE_SPLITS_DRIVER_MODULE_SALT, driverId, proxy);
    }
}
