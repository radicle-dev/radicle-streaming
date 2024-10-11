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
import {Drips} from "src/Drips.sol";

bytes32 constant DRIPS_MODULE_SALT = "DripsModule";

function isDripsModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, DRIPS_MODULE_SALT);
}

function dripsModule(ModulesDeployer modulesDeployer) view returns (DripsModule) {
    return DripsModule(getModule(modulesDeployer, DRIPS_MODULE_SALT));
}

function dripsModuleData(ModulesDeployer modulesDeployer, address admin, uint32 cycleSecs)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(modulesDeployer, admin, cycleSecs);
    return ModuleData({
        salt: DRIPS_MODULE_SALT,
        initCode: abi.encodePacked(type(DripsModule).creationCode, args),
        value: 0
    });
}

contract DripsModule is Module {
    Drips public immutable drips;

    constructor(ModulesDeployer modulesDeployer, address admin, uint32 cycleSecs)
        Module(modulesDeployer, DRIPS_MODULE_SALT)
    {
        Drips logic = new Drips(cycleSecs);
        address proxy = create3ManagedProxy(modulesDeployer, "Drips", logic, admin, "");
        drips = Drips(proxy);
        for (uint256 i = 0; i < 100; i++) {
            // slither-disable-next-line calls-loop,unused-return
            drips.registerDriver(address(this));
        }
    }

    function claimDriverId(bytes32 senderSalt, uint32 driverId, address driver)
        public
        onlyModule(senderSalt)
    {
        drips.updateDriverAddress(driverId, driver);
    }
}
