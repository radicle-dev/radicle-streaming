// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IAxelarGMPExecutable} from "axelar/interfaces/IAxelarGMPExecutable.sol";
import {IAxelarGMPGateway} from "axelar/interfaces/IAxelarGMPGateway.sol";
import {StringToAddress} from "axelar/libs/AddressString.sol";
import {
    ILayerZeroReceiver,
    Origin
} from "layer-zero-v2/protocol/contracts/interfaces/ILayerZeroReceiver.sol";
import {ERC1967Proxy} from "openzeppelin-contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "openzeppelin-contracts/proxy/utils/UUPSUpgradeable.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {ShortString, ShortStrings} from "openzeppelin-contracts/utils/ShortStrings.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

/// @notice Description of a call.
struct Call {
    /// @notice The called address.
    address target;
    /// @notice The calldata to be used for the call.
    bytes data;
    /// @notice The value of the call.
    uint256 value;
}

/// @notice Execute the list of calls.
/// If any of the calls reverts, reverts bubbling the error.
/// @param calls The list of calls to execute.
function executeCalls(Call[] memory calls) {
    for (uint256 i = 0; i < calls.length; i++) {
        Call memory call = calls[i];
        if (call.data.length > 0 || Address.isContract(call.target)) {
            Address.functionCallWithValue(call.target, call.data, call.value);
        } else {
            Address.sendValue(payable(call.target), call.value);
        }
    }
}

/// @notice The governor executing ordered messages.
abstract contract Governor is UUPSUpgradeable {
    /// @notice The required nonce in the next executed message.
    uint256 public nextMessageNonce;

    /// @notice Emitted when a message is executed.
    /// @param nonce The nonce of the message.
    event MessageExecuted(uint256 nonce);

    receive() external payable {}

    /// @notice Returns the current implementation address.
    /// @return implementation_ The implementation address.
    function implementation() public view returns (address implementation_) {
        return _getImplementation();
    }

    /// @notice Executes the message.
    /// @param nonce The message nonce, must be equal to `nextMessageNonce`.
    /// @param calls The list of calls to execute.
    function _executeMessage(uint256 nonce, Call[] memory calls) internal {
        require(nonce == nextMessageNonce, "Invalid message nonce");
        executeCalls(calls);
        require(nonce == nextMessageNonce, "Message execution reentrancy");
        nextMessageNonce++;
        emit MessageExecuted(nonce);
    }

    function _authorizeUpgrade(address /* newImplementation */ ) internal view override {
        require(msg.sender == address(this), "Only upgradeable by self");
    }
}

/// @notice The governor executing messages from its owner on another chain using LayerZero v2.
contract LZBridgedGovernor is Governor, ILayerZeroReceiver {
    /// @notice The LayerZero v2 endpoint that is allowed to execute received messages.
    address public immutable endpoint;
    /// @notice The EID of the chain from which the owner is allowed to send messages.
    uint32 public immutable ownerEid;
    /// @notice The owner address which is allowed to send messages.
    bytes32 public immutable owner;

    /// @notice The message passed over the bridge to the governor to execute.
    struct Message {
        /// @notice The message nonce, must be equal to `nextMessageNonce` when executed.
        /// This is independent from the LayerZero v2 `nextNonce`.
        uint256 nonce;
        /// @notice The minimum accepted `msg.value` passed with the message.
        uint256 value;
        /// @notice The list of calls to execute.
        Call[] calls;
    }

    /// @param endpoint_ The LayerZero v2 endpoint that is allowed to execute received messages.
    /// @param ownerEid_ The EID of the chain from which the owner is allowed to send messages.
    /// @param owner_ The owner address which is allowed to send messages.
    constructor(address endpoint_, uint32 ownerEid_, bytes32 owner_) {
        // slither-disable-next-line missing-zero-check
        endpoint = endpoint_;
        ownerEid = ownerEid_;
        owner = owner_;
    }

    /// @notice Checks if the LayerZero v2 message origin is allowed.
    /// The only allowed origin is the `owner` on the `ownerEid` chain.
    /// This function is required by LayerZero v2 for contracts able to receive messages.
    /// @param origin The message origin.
    /// @return isAllowed True if the message origin is allowed.
    function allowInitializePath(Origin calldata origin)
        public
        view
        override
        onlyProxy
        returns (bool isAllowed)
    {
        return origin.srcEid == ownerEid && origin.sender == owner;
    }

    /// @notice The next LayerZero v2 message nonce.
    /// This is a different nonce from `nextMessageNonce` and it isn't encoded inside messages.
    /// This function is required by LayerZero v2 for contracts able to receive messages.
    /// @return nonce The next LayerZero v2 nonce.
    /// It's always `0` indicating that messages can be delivered in any order.
    function nextNonce(uint32, /* srcEid */ bytes32 /* sender */ )
        public
        view
        override
        onlyProxy
        returns (uint64 nonce)
    {
        return 0;
    }

    /// @notice Receive a LayerZero v2 message. Callable only by `endpoint`.
    /// @param origin The message origin.
    /// The only allowed origin is the `owner` on the `ownerEid` chain.
    /// @param messageEncoded The received message.
    /// It must be an abi-encoded `Message`, see its documentation for more details.
    function lzReceive(
        Origin calldata origin,
        bytes32, /* guid */
        bytes calldata messageEncoded,
        address, /* executor */
        bytes calldata /* extraData */
    ) public payable override onlyProxy {
        require(msg.sender == endpoint, "Must be called by the endpoint");
        require(origin.srcEid == ownerEid, "Invalid message source chain");
        require(origin.sender == owner, "Invalid message sender");

        Message memory message = abi.decode(messageEncoded, (Message));
        require(msg.value >= message.value, "Called with too low value");
        _executeMessage(message.nonce, message.calls);
    }
}

/// @notice The governor executing messages from its owner on another chain using Axelar.
contract AxelarBridgedGovernor is Governor, IAxelarGMPExecutable {
    /// @notice The Axelar gateway used by this contract.
    IAxelarGMPGateway public immutable override gateway;
    /// @notice The name of the chain from which the owner is allowed to send messages.
    ShortString internal immutable _ownerChain;
    /// @notice The owner address which is allowed to send messages.
    address public immutable owner;

    /// @notice The message passed over the bridge to the governor to execute.
    struct Message {
        /// @notice The message nonce, must be equal to `nextMessageNonce` when executed.
        uint256 nonce;
        /// @notice The list of calls to execute.
        Call[] calls;
    }

    /// @notice The name of the chain from which the owner is allowed to send messages.
    /// @return ownerChain_ The name of the chain.
    function ownerChain() public view onlyProxy returns (string memory ownerChain_) {
        return ShortStrings.toString(_ownerChain);
    }

    /// @param gateway_ The Axelar gateway used by this contract.
    /// @param ownerChain_ The name of the chain from which the owner is allowed to send messages.
    /// @param owner_ The owner address which is allowed to send messages.
    constructor(IAxelarGMPGateway gateway_, string memory ownerChain_, address owner_) {
        // slither-disable-next-line missing-zero-check
        gateway = gateway_;
        _ownerChain = ShortStrings.toShortString(ownerChain_);
        owner = owner_;
    }

    /// @notice Execute the specified command sent from another chain.
    /// @param commandId The identifier of the command to execute.
    /// @param sourceChain The name of the source chain from where the command originated.
    /// @param sender The address on the source chain that sent the command.
    /// @param payload The payload of the command to be executed.
    /// It must be an abi-encoded `Message`, see its documentation for more details.
    function execute(
        bytes32 commandId,
        string calldata sourceChain,
        string calldata sender,
        bytes calldata payload
    ) public onlyProxy {
        require(Strings.equal(sourceChain, ownerChain()), "Invalid message source chain");
        require(StringToAddress.toAddress(sender) == owner, "Invalid message sender");
        if (!gateway.validateContractCall(commandId, sourceChain, sender, keccak256(payload))) {
            revert NotApprovedByGateway();
        }

        Message memory message = abi.decode(payload, (Message));
        _executeMessage(message.nonce, message.calls);
    }
}

/// @notice The specialized proxy for `BridgedGovernor`.
contract GovernorProxy is ERC1967Proxy {
    /// @param logic The initial address of the logic for the proxy.
    /// @param calls The list of `Call`s to execute while running the constructor.
    /// It should at least set up the initial LayerZero v2 configuration.
    constructor(address logic, Call[] memory calls) payable ERC1967Proxy(logic, "") {
        executeCalls(calls);
    }
}
