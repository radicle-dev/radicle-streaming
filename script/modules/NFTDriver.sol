// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {callerModule} from "script/modules/Caller.sol";
import {Drips, dripsModule, DripsModule} from "script/modules/Drips.sol";
import {create3ManagedProxy} from "script/utils/Create3Helpers.sol";
import {
    isModuleDeployed,
    ModulesDeployer,
    getModule,
    Module,
    ModuleData
} from "script/utils/ModulesDeployer.sol";
import {NFTDriver} from "src/NFTDriver.sol";

bytes32 constant NFT_DRIVER_MODULE_SALT = "NFTDriverModule";

function isNFTDriverModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, NFT_DRIVER_MODULE_SALT);
}

function nftDriverModule(ModulesDeployer modulesDeployer) view returns (NFTDriverModule) {
    return NFTDriverModule(getModule(modulesDeployer, NFT_DRIVER_MODULE_SALT));
}

function nftDriverModuleData(ModulesDeployer modulesDeployer, address admin)
    pure
    returns (ModuleData memory)
{
    bytes memory args = abi.encode(modulesDeployer, admin);
    return ModuleData({
        salt: NFT_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(NFTDriverModule).creationCode, args),
        value: 0
    });
}

contract NFTDriverModule is Module {
    NFTDriver public immutable nftDriver;

    constructor(ModulesDeployer modulesDeployer, address admin)
        Module(modulesDeployer, NFT_DRIVER_MODULE_SALT)
    {
        DripsModule dripsModule_ = dripsModule(modulesDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(modulesDeployer).caller());
        uint32 driverId = 1;
        NFTDriver logic = new NFTDriver(drips, forwarder, driverId);
        address proxy = create3ManagedProxy(modulesDeployer, "NFTDriver", logic, admin, "");
        nftDriver = NFTDriver(proxy);
        dripsModule_.claimDriverId(NFT_DRIVER_MODULE_SALT, driverId, proxy);
    }
}
