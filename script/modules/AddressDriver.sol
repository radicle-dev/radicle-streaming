// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {create3ManagedProxy} from "script/utils/Create3Helpers.sol";
import {callerModule} from "script/modules/Caller.sol";
import {Drips, dripsModule, DripsModule} from "script/modules/Drips.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {AddressDriver} from "src/AddressDriver.sol";

bytes32 constant ADDRESS_DRIVER_MODULE_SALT = "AddressDriverModule";

function isAddressDriverModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, ADDRESS_DRIVER_MODULE_SALT);
}

function addressDriverModule(ModulesDeployer modulesDeployer) view returns (AddressDriverModule) {
    return AddressDriverModule(getModule(modulesDeployer, ADDRESS_DRIVER_MODULE_SALT));
}

function addressDriverModuleData(ModulesDeployer modulesDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(modulesDeployer, admin);
    return ModuleData({
        salt: ADDRESS_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(AddressDriverModule).creationCode, args),
        value: 0
    });
}

contract AddressDriverModule is Module {
    AddressDriver public immutable addressDriver;

    constructor(ModulesDeployer modulesDeployer, address admin)
        Module(modulesDeployer, ADDRESS_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(modulesDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(modulesDeployer).caller());
        uint32 driverId = 0;
        AddressDriver logic = new AddressDriver(drips, forwarder, driverId);
        address proxy = create3ManagedProxy(modulesDeployer, "AddressDriver", logic, admin, "");
        addressDriver = AddressDriver(proxy);
        dripsModule_.claimDriverId(ADDRESS_DRIVER_MODULE_SALT, driverId, proxy);
    }
}
