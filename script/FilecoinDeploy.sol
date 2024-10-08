// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";
import {deployCreate3Factory} from "script/utils/Create3Factory.sol";
import {writeDeploymentJson} from "script/utils/DeploymentJson.sol";
import "script/utils/DripsDeployer.sol";

contract FilecoinDeploy is Script {
    function run() public {
        require(block.chainid == 314, "Must be run on Filecoin");
        string memory salt = vm.envString("SALT");

        vm.startBroadcast();
        ICreate3Factory create3Factory = deployCreate3Factory();
        DripsDeployer dripsDeployer =
            deployDripsDeployer(create3Factory, bytes32(bytes(salt)), msg.sender);

        ModuleData[] memory modules = new ModuleData[](1);
        modules[0] = axelarBridgedGovernorModuleData({
            dripsDeployer: dripsDeployer,
            // Taken from https://docs.axelar.dev/dev/reference/mainnet-contract-addresses/
            gateway: IAxelarGMPGateway(0xe432150cce91c13a887f7D836923d5597adD8E31),
            ownerChain: "Ethereum",
            // Radworks governance on Ethereum controlling the bridge.
            owner: 0x8dA8f82d2BbDd896822de723F55D6EdF416130ba
        });
        dripsDeployer.deployModules(modules);

        address admin = address(axelarBridgedGovernorModule(dripsDeployer).axelarBridgedGovernor());

        modules = new ModuleData[](2);
        modules[0] = callerModuleData(dripsDeployer);
        modules[1] =
            dripsModuleData({dripsDeployer: dripsDeployer, admin: admin, cycleSecs: 1 days});
        dripsDeployer.deployModules(modules);

        modules = new ModuleData[](2);
        modules[0] = addressDriverModuleData(dripsDeployer, admin);
        modules[1] = nftDriverModuleData(dripsDeployer, admin);
        dripsDeployer.deployModules(modules);

        modules = new ModuleData[](2);
        modules[0] = immutableSplitsDriverModuleData(dripsDeployer, admin);
        modules[1] = repoDriverModuleData({
            dripsDeployer: dripsDeployer,
            admin: admin,
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
        dripsDeployer.deployModules(modules);

        // Take from https://docs.filecoin.io/smart-contracts/advanced/wrapped-fil
        IWrappedNativeToken wfil = IWrappedNativeToken(0x60E1773636CF5E4A227d9AC24F20fEca034ee25A);
        modules = new ModuleData[](2);
        modules[0] = giversRegistryModuleData(dripsDeployer, admin, wfil);
        modules[1] = nativeTokenUnwrapperModuleData(dripsDeployer, wfil);
        dripsDeployer.deployModules(modules);

        vm.stopBroadcast();

        writeDeploymentJson(vm, dripsDeployer, salt);
    }
}
