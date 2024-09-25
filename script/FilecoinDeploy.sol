// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";
import {CREATE3_FACTORY} from "script/DeployCreate3Factory.sol";
import "script/DripsDeployer.sol";

contract FilecoinDeploy is Script {
    function run() public {
        require(block.chainid == 314, "Must be run on Filecoin");
        string memory salt = vm.envString("SALT");
        DripsDeployer dripsDeployer = _deployDripsDeployer(salt);
        address governor = _deployBridgedGovernor(dripsDeployer);
        _deployDrips(dripsDeployer, governor);
        _writeDeploymentJson(dripsDeployer, salt, governor);
    }

    function _deployDripsDeployer(string memory salt)
        internal
        returns (DripsDeployer dripsDeploeyr)
    {
        bytes32 saltBytes = bytes32(bytes(salt));
        bytes memory creationCode = dripsDeployerCreationCode(CREATE3_FACTORY, msg.sender);
        vm.broadcast();
        return DripsDeployer(payable(CREATE3_FACTORY.deploy(saltBytes, creationCode)));
    }

    function _deployBridgedGovernor(DripsDeployer dripsDeployer)
        internal
        returns (address governor)
    {
        // Taken from https://docs.axelar.dev/dev/reference/mainnet-contract-addresses/
        IAxelarGMPGateway gateway = IAxelarGMPGateway(0xe432150cce91c13a887f7D836923d5597adD8E31);
        string memory ownerChain = "Ethereum";
        // Radworks governance controls the bridge from Ethereum.
        address owner = 0x8dA8f82d2BbDd896822de723F55D6EdF416130ba;

        ModuleData[] memory modules = new ModuleData[](1);
        modules[0] = axelarBridgedGovernorModuleData(dripsDeployer, gateway, ownerChain, owner);
        vm.broadcast();
        dripsDeployer.deployModules(modules);

        axelarBridgedGovernorModule(dripsDeployer);

        return address(axelarBridgedGovernorModule(dripsDeployer).axelarBridgedGovernor());
    }

    function _deployDrips(DripsDeployer dripsDeployer, address governor) internal {
        uint32 cycleSecs = 1 days;
        // Taken from https://docs.gelato.network/web3-services/web3-functions/contract-addresses
        IAutomate gelatoAutomate = IAutomate(0x2A6C106ae13B558BB9E2Ec64Bd2f1f7BEFF3A5E0);
        // Deployed from https://github.com/drips-network/contracts-gelato-web3-function
        string memory ipfsCid = "QmeP5ETCt7bZLMtQeFRmJNm5mhYaGgM3GNvExQ4PP12whD";
        // Calculated to saturate the Gelato free tier giving 200K GU.
        // Calculated with assumption that each requests costs up to 11 GU (5 seconds CPU + 1 TX).
        // The penalty-free throughput is 1 request per 3 minutes.
        uint32 maxRequestsPerBlock = 80;
        uint32 maxRequestsPer31Days = 18000;
        // Take from https://docs.filecoin.io/smart-contracts/advanced/wrapped-fil
        IWrappedNativeToken wfil = IWrappedNativeToken(0x60E1773636CF5E4A227d9AC24F20fEca034ee25A);

        ModuleData[] memory modules1 = new ModuleData[](2);
        modules1[0] = callerModuleData(dripsDeployer);
        modules1[1] = dripsModuleData(dripsDeployer, cycleSecs, governor);

        ModuleData[] memory modules2 = new ModuleData[](2);
        modules2[0] = addressDriverModuleData(dripsDeployer, governor);
        modules2[1] = nftDriverModuleData(dripsDeployer, governor);

        ModuleData[] memory modules3 = new ModuleData[](2);
        modules3[0] = immutableSplitsDriverModuleData(dripsDeployer, governor);
        modules3[1] = repoDriverModuleData(
            dripsDeployer,
            governor,
            gelatoAutomate,
            ipfsCid,
            maxRequestsPerBlock,
            maxRequestsPer31Days
        );

        ModuleData[] memory modules4 = new ModuleData[](2);
        modules4[0] = giversRegistryModuleData(dripsDeployer, wfil, governor);
        modules4[1] = nativeTokenUnwrapperModuleData(dripsDeployer, wfil);

        vm.startBroadcast();
        dripsDeployer.deployModules(modules1);
        dripsDeployer.deployModules(modules2);
        dripsDeployer.deployModules(modules3);
        dripsDeployer.deployModules(modules4);
        vm.stopBroadcast();
    }

    function _writeDeploymentJson(DripsDeployer dripsDeployer, string memory salt, address governor)
        internal
    {
        string memory objectKey = "deployment JSON";

        vm.serializeAddress(objectKey, "Deployer", msg.sender);
        vm.serializeString(objectKey, "Salt", salt);
        vm.serializeAddress(objectKey, "DripsDeployer", address(dripsDeployer));

        vm.serializeAddress(objectKey, "LZBridgedGovernor", governor);

        Caller caller = callerModule(dripsDeployer).caller();
        vm.serializeAddress(objectKey, "Caller", address(caller));

        Drips drips = dripsModule(dripsDeployer).drips();
        vm.serializeAddress(objectKey, "Drips", address(drips));
        vm.serializeUint(objectKey, "Drips cycle seconds", drips.cycleSecs());

        AddressDriver addressDriver = addressDriverModule(dripsDeployer).addressDriver();
        vm.serializeAddress(objectKey, "AddressDriver", address(addressDriver));

        NFTDriver nftDriver = nftDriverModule(dripsDeployer).nftDriver();
        vm.serializeAddress(objectKey, "NFTDriver", address(nftDriver));

        ImmutableSplitsDriver immutableSplitsDriver =
            immutableSplitsDriverModule(dripsDeployer).immutableSplitsDriver();
        vm.serializeAddress(objectKey, "ImmutableSplitsDriver", address(immutableSplitsDriver));

        RepoDriver repoDriver = repoDriverModule(dripsDeployer).repoDriver();
        vm.serializeAddress(objectKey, "RepoDriver", address(repoDriver));
        vm.serializeAddress(
            objectKey, "RepoDriver tasks owner", address(repoDriver.gelatoTasksOwner())
        );

        GiversRegistry giversRegistry = giversRegistryModule(dripsDeployer).giversRegistry();
        vm.serializeAddress(objectKey, "GiversRegistry", address(giversRegistry));

        NativeTokenUnwrapper nativeTokenUnwrapper =
            nativeTokenUnwrapperModule(dripsDeployer).nativeTokenUnwrapper();
        string memory json =
            vm.serializeAddress(objectKey, "NativeTokenUnwrapper", address(nativeTokenUnwrapper));

        vm.writeJson(json, "deployment.json");
    }
}
