// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Script.sol";
import {
    addressDriverModule, isAddressDriverModuleDeployed
} from "script/modules/AddressDriver.sol";
import {
    axelarBridgedGovernorModule,
    isAxelarBridgedGovernorModuleDeployed
} from "script/modules/AxelarBridgedGovernor.sol";
import {callerModule, isCallerModuleDeployed} from "script/modules/Caller.sol";
import {Drips, dripsModule, isDripsModuleDeployed} from "script/modules/Drips.sol";
import {
    giversRegistryModule, isGiversRegistryModuleDeployed
} from "script/modules/GiversRegistry.sol";
import {
    immutableSplitsDriverModule,
    isImmutableSplitsDriverModuleDeployed
} from "script/modules/ImmutableSplitsDriver.sol";
import {
    isLZBridgedGovernorModuleDeployed,
    lzBridgedGovernorModule
} from "script/modules/LZBridgedGovernor.sol";
import {
    isNativeTokenUnwrapperModuleDeployed,
    nativeTokenUnwrapperModule
} from "script/modules/NativeTokenUnwrapper.sol";
import {isNFTDriverModuleDeployed, nftDriverModule} from "script/modules/NFTDriver.sol";
import {
    isRepoDriverModuleDeployed, RepoDriver, repoDriverModule
} from "script/modules/RepoDriver.sol";
import {isModuleDeployed, ModulesDeployer} from "script/utils/ModulesDeployer.sol";

function writeDeploymentJson(VmSafe vm, ModulesDeployer modulesDeployer, string memory salt) {
    string memory objectKey = "deployment JSON";

    if (isAxelarBridgedGovernorModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "AxelarBridgedGovernor",
            address(axelarBridgedGovernorModule(modulesDeployer).axelarBridgedGovernor())
        );
    }

    if (isLZBridgedGovernorModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "LZBridgedGovernor",
            address(lzBridgedGovernorModule(modulesDeployer).lzBridgedGovernor())
        );
    }

    if (isCallerModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(objectKey, "Caller", address(callerModule(modulesDeployer).caller()));
    }

    if (isDripsModuleDeployed(modulesDeployer)) {
        Drips drips = dripsModule(modulesDeployer).drips();
        vm.serializeAddress(objectKey, "Drips", address(drips));
        vm.serializeUint(objectKey, "Drips cycle seconds", drips.cycleSecs());
    }

    if (isAddressDriverModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "AddressDriver",
            address(addressDriverModule(modulesDeployer).addressDriver())
        );
    }

    if (isNFTDriverModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey, "NFTDriver", address(nftDriverModule(modulesDeployer).nftDriver())
        );
    }

    if (isImmutableSplitsDriverModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "ImmutableSplitsDriver",
            address(immutableSplitsDriverModule(modulesDeployer).immutableSplitsDriver())
        );
    }

    if (isRepoDriverModuleDeployed(modulesDeployer)) {
        RepoDriver repoDriver = repoDriverModule(modulesDeployer).repoDriver();
        vm.serializeAddress(objectKey, "RepoDriver", address(repoDriver));
        vm.serializeAddress(
            objectKey, "RepoDriver tasks owner", address(repoDriver.gelatoTasksOwner())
        );
    }

    if (isGiversRegistryModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "GiversRegistry",
            address(giversRegistryModule(modulesDeployer).giversRegistry())
        );
    }

    if (isNativeTokenUnwrapperModuleDeployed(modulesDeployer)) {
        vm.serializeAddress(
            objectKey,
            "NativeTokenUnwrapper",
            address(nativeTokenUnwrapperModule(modulesDeployer).nativeTokenUnwrapper())
        );
    }

    vm.serializeAddress(objectKey, "ModulesDeployer", address(modulesDeployer));
    vm.serializeString(objectKey, "Salt", salt);
    vm.serializeAddress(objectKey, "Deployer", msg.sender);
    string memory json = vm.serializeUint(objectKey, "Chain ID", block.chainid);

    vm.writeJson(json, "deployment.json");
}
