// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {
    AxelarBridgedGovernor,
    Call,
    executeCalls,
    Governor,
    GovernorProxy,
    IAxelarGMPExecutable,
    IAxelarGMPGateway,
    LZBridgedGovernor,
    Origin,
    StringToAddress,
    UUPSUpgradeable
} from "src/BridgedGovernor.sol";
import {Test} from "forge-std/Test.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {Strings} from "openzeppelin-contracts/utils/Strings.sol";

contract CallTarget {
    fallback() external payable {}
}

function buildCalls(address target, uint256 value, bytes memory data)
    pure
    returns (Call[] memory calls)
{
    calls = new Call[](1);
    calls[0] = Call({target: target, data: data, value: value});
}

contract ExecuteCallsTest is Test {
    address internal immutable target = address(new CallTarget());
    address internal immutable eoa = address(0x1234);

    function executeCallsExternal(Call[] memory calls) external {
        executeCalls(calls);
    }

    function testCallsContract() public {
        vm.expectCall(target, 3, "abcde", 1);
        this.executeCallsExternal(buildCalls(target, 3, "abcde"));
    }

    function testSendsValueToContract() public {
        vm.expectCall(target, 3, "", 1);
        this.executeCallsExternal(buildCalls(target, 3, ""));
    }

    function testCallingEOAReverts() public {
        vm.expectRevert("Address: call to non-contract");
        this.executeCallsExternal(buildCalls(eoa, 3, "abcde"));
    }

    function testSendsValueToEOA() public {
        vm.expectCall(eoa, 3, "", 1);
        this.executeCallsExternal(buildCalls(eoa, 3, ""));
    }

    function testExecutesMultipleCalls() public {
        Call[] memory calls = new Call[](2);
        vm.expectCall(target, 3, "abcde", 1);
        calls[0] = buildCalls(target, 3, "abcde")[0];
        vm.expectCall(eoa, 5, "", 1);
        calls[1] = buildCalls(eoa, 5, "")[0];
        this.executeCallsExternal(calls);
    }
}

contract TestGovernor is Governor {
    function executeMessage(uint256 nonce, Call[] memory calls) public payable {
        _executeMessage(nonce, calls);
    }
}

contract GovernorTest is Test {
    address internal immutable target = address(new CallTarget());
    TestGovernor internal governor;

    function setUp() public {
        TestGovernor logic = new TestGovernor();
        governor = TestGovernor(payable(new GovernorProxy(logic, new Call[](0))));
    }

    function testReceivesTransfer() public {
        assertEq(address(governor).balance, 0, "Invalid balance before transfer");
        Address.sendValue(payable(governor), 5);
        assertEq(address(governor).balance, 5, "Invalid balance after transfer");
    }

    function testExecuteMessage() public {
        uint256 nonce = governor.nextMessageNonce();
        vm.expectCall(target, 3, "abcde", 1);
        governor.executeMessage{value: 3}(nonce, buildCalls(target, 3, "abcde"));
        assertEq(governor.nextMessageNonce(), nonce + 1, "Invalid next message nonce");
    }

    function testExecuteMessageRevertsWhenNonceIsInvalid() public {
        uint256 badNonce = governor.nextMessageNonce() + 1;
        vm.expectRevert("Invalid message nonce");
        governor.executeMessage(badNonce, buildCalls(target, 0, ""));
    }

    function testExecuteMessagePreventsReentrancy() public {
        uint256 nonce = governor.nextMessageNonce();
        Call[] memory targetCalls = buildCalls(target, 0, "");
        bytes memory callData = abi.encodeCall(TestGovernor.executeMessage, (nonce, targetCalls));
        Call[] memory governorCalls = buildCalls(address(governor), 0, callData);
        vm.expectRevert("Message execution reentrancy");
        governor.executeMessage(nonce, governorCalls);
    }

    function testProxyConstructorExecutesCalls() public {
        vm.expectCall(target, 3, "abcde", 1);
        new GovernorProxy{value: 3}(new TestGovernor(), buildCalls(target, 3, "abcde"));
    }

    function testUpgrade() public {
        uint256 nonce = governor.nextMessageNonce();
        address logic = address(new TestGovernor());
        bytes memory callData = abi.encodeCall(UUPSUpgradeable.upgradeTo, (logic));
        governor.executeMessage(nonce, buildCalls(address(governor), 0, callData));
        assertEq(governor.implementation(), logic, "Invalid implementation");
    }

    function testUpgradeRevertsWhenNotCalledBySelf() public {
        address logic = address(new TestGovernor());
        vm.expectRevert("Only upgradeable by self");
        governor.upgradeTo(logic);
    }
}

contract LZBridgedGovernorTest is Test {
    address internal immutable endpoint = address(0x1234);
    uint32 internal immutable ownerEid = 1234;
    bytes32 internal immutable owner = "owner";
    address internal immutable target = address(new CallTarget());
    LZBridgedGovernor internal governor;

    function setUp() public {
        LZBridgedGovernor logic = new LZBridgedGovernor(endpoint, ownerEid, owner);
        governor = LZBridgedGovernor(payable(new GovernorProxy(logic, new Call[](0))));
        vm.deal(endpoint, 100);
    }

    function testAllowInitializePath() public {
        assertAllowInitializePath(Origin(ownerEid, owner, 0), true);
        assertAllowInitializePath(Origin(ownerEid + 1, owner, 0), false);
        assertAllowInitializePath(Origin(ownerEid, owner ^ hex"01", 0), false);
        assertAllowInitializePath(Origin(ownerEid, owner, 1), true);
    }

    function assertAllowInitializePath(Origin memory origin, bool expected) internal {
        assertEq(governor.allowInitializePath(origin), expected, "Invalid allowInitializePath");
    }

    function testNextNonce() public {
        assertEq(governor.nextNonce(ownerEid, owner), 0, "Invalid next nonce for the owner");
    }

    function buildMessage(uint256 nonce, uint256 value, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(LZBridgedGovernor.Message(nonce, value, calls));
    }

    function testLzReceive() public {
        uint256 nextNonce = governor.nextMessageNonce() + 1;
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner, 0);
        vm.expectCall(target, value, "abcde", 1);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value, calls);
        vm.prank(endpoint);
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
        assertEq(governor.nextMessageNonce(), nextNonce, "Invalid next message nonce");
    }

    function testLzReceiveWithTooHighValue() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner, 0);
        vm.expectCall(target, value, "abcde", 1);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value, calls);
        vm.prank(endpoint);
        governor.lzReceive{value: value + 1}(origin, 0, message, address(0), "");
    }

    function testLzReceiveRevertsWhenValueIsTooLow() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner, 0);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value + 1, calls);
        vm.prank(endpoint);
        vm.expectRevert("Called with too low value");
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
    }

    function testLzReceiveRevertsWhenNotCalledByEndpoint() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner, 0);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value, calls);
        vm.expectRevert("Must be called by the endpoint");
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
    }

    function testLzReceiveRevertsWhenSrcEidIsInvalid() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid + 1, owner, 0);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value, calls);
        vm.prank(endpoint);
        vm.expectRevert("Invalid message source chain");
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
    }

    function testLzReceiveRevertsWhenSenderIsInvalid() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner ^ hex"01", 0);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), value, calls);
        vm.prank(endpoint);
        vm.expectRevert("Invalid message sender");
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
    }

    function testLzReceiveRevertsWhenNonceIsInvalid() public {
        uint256 value = 5;
        Origin memory origin = Origin(ownerEid, owner, 0);
        Call[] memory calls = buildCalls(target, value, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce() + 1, value, calls);
        vm.prank(endpoint);
        vm.expectRevert("Invalid message nonce");
        governor.lzReceive{value: value}(origin, 0, message, address(0), "");
    }
}

contract AxelarBridgedGovernorTest is Test {
    address internal immutable gateway = address(0x1234);
    string internal ownerChain = "owner chain";
    // string internal immutable OWNER = "0x0123456789abcDEF0123456789abCDef01234567";
    string internal owner;
    address internal immutable target = address(new CallTarget());
    AxelarBridgedGovernor internal governor;

    function setUp() public {
        address owner_ = 0x0123456789abcDEF0123456789abCDef01234567;
        owner = Strings.toHexString(owner_);
        AxelarBridgedGovernor logic =
            new AxelarBridgedGovernor(IAxelarGMPGateway(gateway), ownerChain, owner_);
        governor = AxelarBridgedGovernor(payable(new GovernorProxy(logic, new Call[](0))));
        vm.deal(address(governor), 100);
    }

    function testOwnerChain() public {
        assertEq(governor.ownerChain(), ownerChain, "Invalid owner chain");
    }

    function buildMessage(uint256 nonce, Call[] memory calls)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(AxelarBridgedGovernor.Message(nonce, calls));
    }

    function testExecute() public {
        bytes32 commandId = "command ID";
        uint256 nextNonce = governor.nextMessageNonce() + 1;
        vm.expectCall(target, 5, "abcde", 1);
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        bytes memory expectedGatwayCall = abi.encodeCall(
            IAxelarGMPGateway.validateContractCall,
            (commandId, ownerChain, owner, keccak256(message))
        );
        vm.expectCall(gateway, expectedGatwayCall, 1);
        vm.mockCall(gateway, "", abi.encode(true));
        governor.execute(commandId, ownerChain, owner, message);
        assertEq(governor.nextMessageNonce(), nextNonce, "Invalid next message nonce");
    }

    function testExecuteRevertsWhenNonceIsInvalid() public {
        bytes32 commandId = "command ID";
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce() + 1, calls);
        vm.mockCall(gateway, "", abi.encode(true));
        vm.expectRevert("Invalid message nonce");
        governor.execute(commandId, ownerChain, owner, message);
    }

    function testExecuteRevertsWhenSourceChainIsInvalid() public {
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        vm.expectRevert("Invalid message source chain");
        governor.execute("command ID", string.concat(ownerChain, "!"), owner, message);
    }

    function testExecuteRevertsWhenSourceSenderIsInvalid() public {
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        bytes memory owner_ = bytes(owner);
        owner_[2] = "a";
        assertFalse(Strings.equal(owner, string(owner_)), "Owner not invalid");
        vm.expectRevert("Invalid message sender");
        governor.execute("command ID", ownerChain, string(owner_), message);
    }

    function testExecuteAcceptsArbitrarilyCasedSender() public {
        bytes32 commandId = "command ID";
        bytes memory owner_ = bytes(owner);
        for (uint256 i = 0; i < owner_.length; i++) {
            if (owner_[i] == "a") owner_[i] = "A";
        }
        assertFalse(Strings.equal(owner, string(owner_)), "Owner not differently cased");
        vm.expectCall(target, 5, "abcde", 1);
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        vm.mockCall(gateway, "", abi.encode(true));
        governor.execute(commandId, ownerChain, string(owner_), message);
    }

    function testExecuteRevertsWhenSourceSenderIsMalformed() public {
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        bytes memory owner_ = bytes(owner);
        owner_[2] = "!";
        assertFalse(Strings.equal(owner, string(owner_)), "Owner not invalid");
        vm.expectRevert(abi.encodeWithSelector(StringToAddress.InvalidAddressString.selector));
        governor.execute("command ID", ownerChain, string(owner_), message);
    }

    function testExecuteRevertsWhenGatewayDoesNotValidateMessage() public {
        bytes32 commandId = "command ID";
        Call[] memory calls = buildCalls(target, 5, "abcde");
        bytes memory message = buildMessage(governor.nextMessageNonce(), calls);
        vm.mockCall(gateway, "", abi.encode(false));
        vm.expectRevert(abi.encodeWithSelector(IAxelarGMPExecutable.NotApprovedByGateway.selector));
        governor.execute(commandId, ownerChain, owner, message);
    }
}
