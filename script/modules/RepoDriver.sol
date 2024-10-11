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
import {IAutomate, RepoDriver} from "src/RepoDriver.sol";

bytes32 constant REPO_DRIVER_MODULE_SALT = "RepoDriverModule";

function isRepoDriverModuleDeployed(ModulesDeployer modulesDeployer) view returns (bool yes) {
    return isModuleDeployed(modulesDeployer, REPO_DRIVER_MODULE_SALT);
}

function repoDriverModule(ModulesDeployer modulesDeployer) view returns (RepoDriverModule) {
    return RepoDriverModule(getModule(modulesDeployer, REPO_DRIVER_MODULE_SALT));
}

function repoDriverModuleData(
    ModulesDeployer modulesDeployer,
    address admin,
    IAutomate gelatoAutomate,
    string memory ipfsCid,
    uint32 maxRequestsPerBlock,
    uint32 maxRequestsPer31Days
) pure returns (ModuleData memory) {
    bytes memory args = abi.encode(
        modulesDeployer, admin, gelatoAutomate, ipfsCid, maxRequestsPerBlock, maxRequestsPer31Days
    );
    return ModuleData({
        salt: REPO_DRIVER_MODULE_SALT,
        initCode: abi.encodePacked(type(RepoDriverModule).creationCode, args),
        value: 0
    });
}

contract RepoDriverModule is Module {
    RepoDriver public immutable repoDriver;

    constructor(
        ModulesDeployer modulesDeployer,
        address admin,
        IAutomate gelatoAutomate,
        string memory ipfsCid,
        uint32 maxRequestsPerBlock,
        uint32 maxRequestsPer31Days
    ) Module(modulesDeployer, REPO_DRIVER_MODULE_SALT) {
        DripsModule dripsModule_ = dripsModule(modulesDeployer);
        Drips drips = dripsModule_.drips();
        address forwarder = address(callerModule(modulesDeployer).caller());
        uint32 driverId = 3;
        RepoDriver logic = new RepoDriver(drips, forwarder, driverId, gelatoAutomate);
        bytes memory data = abi.encodeCall(
            RepoDriver.updateGelatoTask, (ipfsCid, maxRequestsPerBlock, maxRequestsPer31Days)
        );
        address proxy = create3ManagedProxy(modulesDeployer, "RepoDriver", logic, admin, data);
        repoDriver = RepoDriver(payable(proxy));
        dripsModule_.claimDriverId(REPO_DRIVER_MODULE_SALT, driverId, proxy);
    }
}
