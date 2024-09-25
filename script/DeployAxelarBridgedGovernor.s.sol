// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Script} from "forge-std/Script.sol";
import {AxelarBridgedGovernor, GovernorProxy, Call} from "src/BridgedGovernor.sol";
import {UUPSUpgradeable} from "src/Managed.sol";
import {IAxelarGasService} from "axelar/interfaces/IAxelarGasService.sol";
import {IAxelarGMPGateway} from "axelar/interfaces/IAxelarGMPGateway.sol";
import {AddressToString} from "axelar/libs/AddressString.sol";

string constant SEPOLIA_CHAIN_NAME = "ethereum-sepolia";
string constant BSC_TESTNET_CHAIN_NAME = "binance";

IAxelarGMPGateway constant SEPOLIA_GATEWAY =
    IAxelarGMPGateway(0xe432150cce91c13a887f7D836923d5597adD8E31);
IAxelarGasService constant BSC_TESTNET_GAS_SERVICE =
    IAxelarGasService(0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6);
IAxelarGMPGateway constant BSC_TESTNET_GATEWAY =
    IAxelarGMPGateway(0x4D147dCb984e6affEEC47e44293DA442580A3Ec0);

// forge script scripts/DeployAxelarBridgedGovernor.s.sol:DeployToBscTestnet $WALLET_ARGS -f "$ETH_RPC_URL"

// contract DeployToBscTestnet is Script {
//     function run() public {
//         address owner = vm.envOr("OWNER", msg.sender);

//         require(block.chainid == 97, "Must be run on BSC testnet");
//         vm.startBroadcast();
//         AxelarBridgedGovernor logic =
//             new AxelarBridgedGovernor(BSC_TESTNET_GATEWAY, SEPOLIA_CHAIN_NAME, owner);
//         GovernorProxy governor = new GovernorProxy(address(logic), new Call[](0));
//         vm.stopBroadcast();
//         console.log("Deployed AxelarBridgedGovernor:", address(governor));
//     }
// }

// Gateway and ddresses taken from https://docs.axelar.dev/resources/contract-addresses/testnet

// Run on BSC testnet
// forge create $WALLET_ARGS scripts/DeployAxelarBridgedGovernor.s.sol:ContractCaller \
// --constructor-args 0x4D147dCb984e6affEEC47e44293DA442580A3Ec0 0xbE406F0189A0B4cf3A05C286473D23791Dd44Cc6

// Run on Sepolia
// OWNER=0xdACfE6Bf5A06953EccC3755758C5aDFfed94e147 \
// GATEWAY=0xe432150cce91c13a887f7D836923d5597adD8E31 \
// SOURCE_CHAIN=binance \
// forge script scripts/DeployAxelarBridgedGovernor.s.sol:DeployGovernor $WALLET_ARGS -f "$ETH_RPC_URL"

// Run on BSC testnet
// cast send $WALLET_ARGS 0xdACfE6Bf5A06953EccC3755758C5aDFfed94e147 \
// 'setRecipient(string,address)' ethereum-sepolia 0x78EeC20c86e5f40Ceb1b651c38072DF528AE6407

// Run on BSC testnet
// CALLER=0xdACfE6Bf5A06953EccC3755758C5aDFfed94e147 \
// FEE=$(cast to-wei 0.00 eth) \
// NONCE=2 \
// forge script scripts/DeployAxelarBridgedGovernor.s.sol:ContractCall $WALLET_ARGS -f "$ETH_RPC_URL"

contract DeployGovernor is Script {
    function run() public {
        address owner = vm.envOr("OWNER", msg.sender);
        IAxelarGMPGateway gateway = IAxelarGMPGateway(vm.envAddress("GATEWAY"));
        string memory sourceChain = vm.envString("SOURCE_CHAIN");

        vm.startBroadcast();
        AxelarBridgedGovernor logic = new AxelarBridgedGovernor(gateway, sourceChain, owner);
        GovernorProxy governor = new GovernorProxy(logic, new Call[](0));
        vm.stopBroadcast();
        console.log("Deployed AxelarBridgedGovernor:", address(governor));
    }
}

contract ContractCaller {
    address public immutable owner;
    IAxelarGMPGateway public immutable gateway;
    IAxelarGasService public immutable gasService;

    string public destinationChain;
    address public recipient;

    constructor(IAxelarGMPGateway gateway_, IAxelarGasService gasService_) {
        owner = msg.sender;
        gateway = gateway_;
        gasService = gasService_;
    }

    function setRecipient(string calldata destinationChain_, address recipient_) public {
        require(msg.sender == owner, "Only owner");
        destinationChain = destinationChain_;
        recipient = recipient_;
    }

    function callContract(bytes calldata payload) public payable {
        require(msg.sender == owner, "Only owner");
        string memory recipient_ = AddressToString.toString(recipient);
        if (msg.value > 0) {
            gasService.payNativeGasForContractCall{value: msg.value}(
                address(this), destinationChain, recipient_, payload, owner
            );
        }
        gateway.callContract(destinationChain, recipient_, payload);
    }
}

contract ContractCall is Script {
    function run() public {
        ContractCaller caller = ContractCaller(vm.envAddress("CALLER"));
        uint256 fee = vm.envOr("FEE", uint256(0));
        uint256 nonce = vm.envUint("NONCE");

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
            data: abi.encodeWithSignature("approve(address,uint256)", address(0x1234), 100 + nonce),
            value: 0
        });
        // calls[0] = Call({
        //     target: 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14,
        //     data: abi.encodeWithSignature("transferFrom(address,address,uint256)",
        //        msg.sender, address(0xdead), 1234),
        //     value: 0
        // });

        vm.broadcast();
        caller.callContract{value: fee}(abi.encode(AxelarBridgedGovernor.Message(nonce, calls)));
    }
}

contract CallUpgrade is Script {
    function run() public {
        require(block.chainid == 1, "Must be run on Ethereum");
        require(msg.sender == 0xEF4B994f97092fD22B8a880c47F053910788471b, "Invalid sender");
        uint256 nonce = 0;
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: 0x186a0C0e2208df6073285cdCf20d8787fba8e302,
            data: abi.encodeCall(
                UUPSUpgradeable.upgradeTo, (0x6bEF578F8B86061f155761f700751Af3013751f6)
            ),
            value: 0
        });
        bytes memory payload = abi.encode(AxelarBridgedGovernor.Message(nonce, calls));
        vm.broadcast();
        IAxelarGMPGateway(0x4F4495243837681061C4743b74B3eEdf548D56A5).callContract(
            "filecoin", "0x3263D62B54D62F3d051736285DB4889D9E32C02b", payload
        );
    }
}
