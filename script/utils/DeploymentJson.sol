// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {VmSafe} from "forge-std/Script.sol";
import "script/utils/DripsDeployer.sol";

function writeDeploymentJson(VmSafe vm, DripsDeployer dripsDeployer, string memory salt) {
    string memory objectKey = "deployment JSON";

    if (isModuleDeployed(dripsDeployer, AXELAR_BRIDGED_GOVERNOR_MODULE_SALT)) {
        AxelarBridgedGovernor axelarBridgedGovernor =
            axelarBridgedGovernorModule(dripsDeployer).axelarBridgedGovernor();
        vm.serializeAddress(objectKey, "AxelarBridgedGovernor", address(axelarBridgedGovernor));
    }

    if (isModuleDeployed(dripsDeployer, LZ_BRIDGED_GOVERNOR_MODULE_SALT)) {
        LZBridgedGovernor lzBridgedGovernor =
            lzBridgedGovernorModule(dripsDeployer).lzBridgedGovernor();
        vm.serializeAddress(objectKey, "AxelarBridgedGovernor", address(lzBridgedGovernor));
    }

    if (isModuleDeployed(dripsDeployer, CALLER_MODULE_SALT)) {
        Caller caller = callerModule(dripsDeployer).caller();
        vm.serializeAddress(objectKey, "Caller", address(caller));
    }

    if (isModuleDeployed(dripsDeployer, DRIPS_MODULE_SALT)) {
        Drips drips = dripsModule(dripsDeployer).drips();
        vm.serializeAddress(objectKey, "Drips", address(drips));
        vm.serializeUint(objectKey, "Drips cycle seconds", drips.cycleSecs());
    }

    if (isModuleDeployed(dripsDeployer, ADDRESS_DRIVER_MODULE_SALT)) {
        AddressDriver addressDriver = addressDriverModule(dripsDeployer).addressDriver();
        vm.serializeAddress(objectKey, "AddressDriver", address(addressDriver));
    }

    if (isModuleDeployed(dripsDeployer, NFT_DRIVER_MODULE_SALT)) {
        NFTDriver nftDriver = nftDriverModule(dripsDeployer).nftDriver();
        vm.serializeAddress(objectKey, "NFTDriver", address(nftDriver));
    }

    if (isModuleDeployed(dripsDeployer, IMMUTABLE_SPLITS_DRIVER_MODULE_SALT)) {
        ImmutableSplitsDriver immutableSplitsDriver =
            immutableSplitsDriverModule(dripsDeployer).immutableSplitsDriver();
        vm.serializeAddress(objectKey, "ImmutableSplitsDriver", address(immutableSplitsDriver));
    }

    if (isModuleDeployed(dripsDeployer, REPO_DRIVER_MODULE_SALT)) {
        RepoDriver repoDriver = repoDriverModule(dripsDeployer).repoDriver();
        vm.serializeAddress(objectKey, "RepoDriver", address(repoDriver));
        vm.serializeAddress(
            objectKey, "RepoDriver tasks owner", address(repoDriver.gelatoTasksOwner())
        );
    }

    if (isModuleDeployed(dripsDeployer, GIVERS_REGISTRY_MODULE_SALT)) {
        GiversRegistry giversRegistry = giversRegistryModule(dripsDeployer).giversRegistry();
        vm.serializeAddress(objectKey, "GiversRegistry", address(giversRegistry));
    }

    if (isModuleDeployed(dripsDeployer, NATIVE_TOKEN_UNWRAPPER_MODULE_SALT)) {
        NativeTokenUnwrapper nativeTokenUnwrapper =
            nativeTokenUnwrapperModule(dripsDeployer).nativeTokenUnwrapper();
        vm.serializeAddress(objectKey, "NativeTokenUnwrapper", address(nativeTokenUnwrapper));
    }

    vm.serializeString(objectKey, "Salt", salt);
    vm.serializeAddress(objectKey, "DripsDeployer", address(dripsDeployer));
    string memory json = vm.serializeAddress(objectKey, "Deployer", msg.sender);

    vm.writeJson(json, "deployment.json");
}
