// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";

import {addressDriverModuleData} from "script/modules/AddressDriver.sol";
import {
    axelarBridgedGovernorModule,
    axelarBridgedGovernorModuleData,
    IAxelarGMPGateway
} from "script/modules/AxelarBridgedGovernor.sol";
import {callerModuleData} from "script/modules/Caller.sol";
import {dripsModuleData} from "script/modules/Drips.sol";
import {giversRegistryModuleData, IWrappedNativeToken} from "script/modules/GiversRegistry.sol";
import {immutableSplitsDriverModuleData} from "script/modules/ImmutableSplitsDriver.sol";
import {nativeTokenUnwrapperModuleData} from "script/modules/NativeTokenUnwrapper.sol";
import {nftDriverModuleData} from "script/modules/NFTDriver.sol";
import {IAutomate, repoDriverModuleData} from "script/modules/RepoDriver.sol";
import {deployCreate3Factory, ICreate3Factory} from "script/utils/Create3Factory.sol";
import {writeDeploymentJson} from "script/utils/DeploymentJson.sol";
import {
    deployModulesDeployer, ModulesDeployer, ModuleData
} from "script/utils/ModulesDeployer.sol";
import {RADWORKS} from "script/utils/Radworks.sol";

/// @dev As of 09.10.2024 Foundry doesn't work well with the Filecoin RPCs.
/// To avoid errors, pass `--gas-estimate-multiplier 80000 --slow` to `forge script`.
contract Deploy is Script {
    function run() public {
        require(block.chainid == 314, "Must be run on Filecoin");
        string memory salt = vm.envString("SALT");
        address radworks = vm.envOr("RADWORKS", RADWORKS);

        vm.startBroadcast();
        ICreate3Factory create3Factory = deployCreate3Factory();
        ModulesDeployer modulesDeployer =
            deployModulesDeployer(create3Factory, bytes32(bytes(salt)), msg.sender);

        ModuleData[] memory modules = new ModuleData[](1);
        modules[0] = axelarBridgedGovernorModuleData({
            modulesDeployer: modulesDeployer,
            // Taken from https://docs.axelar.dev/dev/reference/mainnet-contract-addresses/
            gateway: IAxelarGMPGateway(0xe432150cce91c13a887f7D836923d5597adD8E31),
            ownerChain: "Ethereum",
            owner: radworks
        });
        modulesDeployer.deployModules(modules);

        address governor =
            address(axelarBridgedGovernorModule(modulesDeployer).axelarBridgedGovernor());

        modules = new ModuleData[](2);
        modules[0] = callerModuleData(modulesDeployer);
        modules[1] = dripsModuleData(modulesDeployer, governor, 1 days);
        modulesDeployer.deployModules(modules);

        modules = new ModuleData[](2);
        modules[0] = addressDriverModuleData(modulesDeployer, governor);
        modules[1] = nftDriverModuleData(modulesDeployer, governor);
        modulesDeployer.deployModules(modules);

        modules = new ModuleData[](2);
        modules[0] = immutableSplitsDriverModuleData(modulesDeployer, governor);
        modules[1] = repoDriverModuleData({
            modulesDeployer: modulesDeployer,
            admin: governor,
            // Taken from https://docs.gelato.network/web3-services/web3-functions/contract-addresses
            gelatoAutomate: IAutomate(0x2A6C106ae13B558BB9E2Ec64Bd2f1f7BEFF3A5E0),
            // Deployed from https://github.com/drips-network/contracts-gelato-web3-function
            ipfsCid: "QmeP5ETCt7bZLMtQeFRmJNm5mhYaGgM3GNvExQ4PP12whD",
            // Calculated to saturate the Gelato free tier giving 200K GU.
            // Assumes that each requests costs up to 11 GU (5 seconds of CPU + 1 transaction).
            // The penalty-free throughput is 1 request per 3 minutes.
            maxRequestsPerBlock: 80,
            maxRequestsPer31Days: 18000
        });
        modulesDeployer.deployModules(modules);

        // Take from https://docs.filecoin.io/smart-contracts/advanced/wrapped-fil
        IWrappedNativeToken wfil = IWrappedNativeToken(0x60E1773636CF5E4A227d9AC24F20fEca034ee25A);
        modules = new ModuleData[](2);
        modules[0] = giversRegistryModuleData(modulesDeployer, governor, wfil);
        modules[1] = nativeTokenUnwrapperModuleData(modulesDeployer, wfil);
        modulesDeployer.deployModules(modules);

        vm.stopBroadcast();

        writeDeploymentJson(vm, modulesDeployer, salt);
    }
}
