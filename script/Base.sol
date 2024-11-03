// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";

import {addressDriverModuleData} from "script/modules/AddressDriver.sol";
import {callerModuleData} from "script/modules/Caller.sol";
import {dripsModuleData} from "script/modules/Drips.sol";
import {giversRegistryModuleData, IWrappedNativeToken} from "script/modules/GiversRegistry.sol";
import {immutableSplitsDriverModuleData} from "script/modules/ImmutableSplitsDriver.sol";
import {
    Call,
    lzBridgedGovernorAddress,
    lzBridgedGovernorModule,
    lzBridgedGovernorModuleData
} from "script/modules/LZBridgedGovernor.sol";
import {nativeTokenUnwrapperModuleData} from "script/modules/NativeTokenUnwrapper.sol";
import {nftDriverModuleData} from "script/modules/NFTDriver.sol";
import {IAutomate, repoDriverModuleData} from "script/modules/RepoDriver.sol";
import {deployCreate3Factory, ICreate3Factory} from "script/utils/Create3Factory.sol";
import {writeDeploymentJson} from "script/utils/DeploymentJson.sol";
import {
    addToProposalConfigInit, addToProposalGovernorMessage,
    createSetConfigParams,
    ETHEREUM_EID,
    governorConfigInitCalls, LZBridgedGovernor,
    SetConfigParam,upgradeToCall
} from "script/utils/LayerZero.sol";
import {
    deployModulesDeployer, ModulesDeployer, ModuleData
} from "script/utils/ModulesDeployer.sol";
import {
    addToProposalWithdrawWeth,
    createProposal,execute,propose,RadworksProposal, RADWORKS,
    requireRunOnEthereum,
    WETH
} from "script/utils/Radworks.sol";

// Take from https://docs.base.org/docs/base-contracts
IWrappedNativeToken constant WRAPPED_NATIVE_TOKEN =
    IWrappedNativeToken(0x4200000000000000000000000000000000000006);

// Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/deployed-contracts
uint32 constant BASE_EID = 30184;
address constant BASE_ENDPOINT = 0x1a44076050125825900e736c501f859c50fE728c;
address constant BASE_RECEIVE_ULN = 0xc70AB6f32772f59fBfc23889Caf4Ba3376C84bAf;

function governorSetConfigParams() pure returns (SetConfigParam[] memory params) {
    // Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/dvn-addresses
    address[] memory dvns = new address[](5);
    dvns[0] = 0xC50a49186aA80427aA3b0d3C2Cec19BA64222A29; // Lagrange
    dvns[1] = 0x9e059a54699a285714207b43B055483E78FAac25; // LayerZero Labs
    dvns[2] = 0x8ddF05F9A5c488b4973897E278B58895bF87Cb24; // Polyhedra
    dvns[3] = 0xcdF31d62140204C08853b547E64707110fBC6680; // Stargate
    dvns[4] = 0x9E930731cb4A6bf7eCc11F695A295c60bDd212eB; // Zenrock
    return createSetConfigParams({otherChainEid: ETHEREUM_EID, dvns: dvns, threshold: 3});
}

function radworksSetConfigParams() pure returns (SetConfigParam[] memory params) {
    // Taken from https://docs.layerzero.network/v2/developers/evm/technical-reference/dvn-addresses
    address[] memory dvns = new address[](5);
    dvns[0] = 0x95729Ea44326f8adD8A9b1d987279DBdC1DD3dFf; // Lagrange
    dvns[1] = 0x589dEDbD617e0CBcB916A9223F4d1300c294236b; // LayerZero Labs
    dvns[2] = 0x8ddF05F9A5c488b4973897E278B58895bF87Cb24; // Polyhedra
    dvns[3] = 0x8FafAE7Dd957044088b3d0F67359C327c6200d18; // Stargate
    dvns[4] = 0xd42306DF1a805d8053Bc652cE0Cd9F62BDe80146; // Zenrock
    return createSetConfigParams({otherChainEid: BASE_EID, dvns: dvns, threshold: 3});
}

contract Deploy is Script {
    function run() public {
        string memory salt;
        address radworks;
        if(vm.envOr("FINAL_RUN", false)) {
            require(block.chainid == 8453, "Not running on Base");
            require(msg.sender == 0x7dCaCF417BA662840DcD2A35b67f55911815dD7e, "Use the deployer wallet");
            salt = "DripsV2Final";
            radworks = RADWORKS;
        } else {
            salt = vm.envString("SALT");
            radworks = vm.envAddress("RADWORKS");
        }

        vm.startBroadcast();
        ICreate3Factory create3Factory = deployCreate3Factory();
        ModulesDeployer modulesDeployer =
            deployModulesDeployer(create3Factory, bytes32(bytes(salt)), msg.sender);

        address governor = lzBridgedGovernorAddress(modulesDeployer);
        ModuleData[] memory modules = new ModuleData[](4);
        modules[0] = lzBridgedGovernorModuleData({
            modulesDeployer: modulesDeployer,
            endpoint: BASE_ENDPOINT,
            ownerEid: ETHEREUM_EID,
            owner: radworks,
            calls: governorConfigInitCalls({
                endpoint: BASE_ENDPOINT,
                governor: governor,
                receiveUln: BASE_RECEIVE_ULN,
                params: governorSetConfigParams()
            })
        });
        modules[1] = callerModuleData(modulesDeployer);
        modules[2] = dripsModuleData(modulesDeployer, governor, 1 days);
        modules[3] = addressDriverModuleData(modulesDeployer, governor);
        modulesDeployer.deployModules(modules);

        modules = new ModuleData[](5);
        modules[0] = nftDriverModuleData(modulesDeployer, governor);
        modules[1] = immutableSplitsDriverModuleData(modulesDeployer, governor);
        modules[2] = repoDriverModuleData({
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
        modules[3] = giversRegistryModuleData(modulesDeployer, governor, WRAPPED_NATIVE_TOKEN);
        modules[4] = nativeTokenUnwrapperModuleData(modulesDeployer, WRAPPED_NATIVE_TOKEN);
        modulesDeployer.deployModules(modules);

        writeDeploymentJson(vm, modulesDeployer, salt);
    }
}

contract ProposeTestUpdate is Script{
    function run() public {
        requireRunOnEthereum();
        address radworks = 0xd7bEbfA4ecF5df8bF92Fca35d0Ce7995db2E2E96;
        address governor = 0xEDcC9Ca2303dC8f67879F1BCF6549CBe7FfdBb17;
        address proxy = 0x245A4AF555216cCeaf18968fbb85206B10EB4AcC;
        address implementation = 0x747D2cb1e9dC2bEF8E4E08778A85Df8d43b93842;
        uint256 nonce = 0;

        RadworksProposal memory proposal =
            createProposal(radworks, "Update a proxy\nThis is just a **test**!");

        addToProposalConfigInit(proposal, radworksSetConfigParams());

        uint256 fee = 0.01 ether;
        addToProposalWithdrawWeth(proposal, fee);

        Call[] memory calls = new Call[](1);
        calls[0] = upgradeToCall(proxy, implementation);
        addToProposalGovernorMessage({
            proposal: proposal,
            fee: fee,
            governorEid: BASE_EID,
            governor: governor,
            gas: 100_000,
            message: LZBridgedGovernor.Message({nonce: nonce, value: 0, calls: calls})
        });

        vm.startBroadcast();
        // propose(proposal);
        execute(proposal);
    }
}
