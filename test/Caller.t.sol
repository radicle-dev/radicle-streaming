// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Call, Caller} from "src/Caller.sol";

contract CallerTest is Test {
    bytes internal constant ERROR_ZERO_INPUT = "Input is zero";
    bytes internal constant ERROR_DEADLINE = "Execution deadline expired";
    bytes internal constant ERROR_SIGNATURE = "Invalid signature";
    bytes internal constant ERROR_NONCE_NOT_INCREASED = "Nonce not increased";
    bytes internal constant ERROR_UNAUTHORIZED = "Not authorized";

    string internal constant DOMAIN_TYPE_NAME =
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
    bytes32 internal immutable domainTypeHash = keccak256(bytes(DOMAIN_TYPE_NAME));
    string internal constant CALL_SIGNED_TYPE_NAME = "CallSigned("
        "address sender,address target,bytes data,uint256 value,uint256 nonce,uint256 deadline)";
    bytes32 internal immutable callSignedTypeHash = keccak256(bytes(CALL_SIGNED_TYPE_NAME));

    Caller internal caller;
    Target internal target;
    Target internal targetOtherForwarder;
    bytes32 internal callerDomainSeparator;
    uint256 internal senderKey;
    address internal sender;

    function setUp() public {
        caller = new Caller();
        bytes32 nameHash = keccak256("Caller");
        bytes32 versionHash = keccak256("1");
        callerDomainSeparator = keccak256(
            abi.encode(domainTypeHash, nameHash, versionHash, block.chainid, address(caller))
        );
        target = new Target(address(caller));
        targetOtherForwarder = new Target(address(0));
        senderKey = uint256(keccak256("I'm the sender"));
        sender = vm.addr(senderKey);
    }

    function testCallSigned() public {
        uint256 input = 1234567890;
        bytes memory data = abi.encodeCall(target.run, (input));
        uint256 value = 4321;
        uint256 deadline = vm.getBlockTimestamp();
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, value, 0, deadline);

        bytes memory returned =
            caller.callSigned{value: value}(sender, address(target), data, deadline, r, sv);

        assertEq(abi.decode(returned, (uint256)), input + 1, "Invalid returned value");
        target.verify(sender, input, value);
    }

    function testCallSignedRejectsExpiredDeadline() public {
        bytes memory data = abi.encodeCall(target.run, (1));
        uint256 deadline = vm.getBlockTimestamp();
        skip(1);
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);

        vm.expectRevert(ERROR_DEADLINE);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
    }

    function testCallSignedRejectsInvalidNonce() public {
        bytes memory data = abi.encodeCall(target.run, (1));
        uint256 deadline = vm.getBlockTimestamp();
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
        assertNonce(sender, 1);

        vm.expectRevert(ERROR_SIGNATURE);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
    }

    function testCallSignedRejectsInvalidSigner() public {
        bytes memory data = abi.encodeCall(target.run, (1));
        uint256 deadline = vm.getBlockTimestamp();
        (bytes32 r, bytes32 sv) = signCall(senderKey + 1, target, data, 0, 0, deadline);

        vm.expectRevert(ERROR_SIGNATURE);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
    }

    function testCallSignedBubblesErrors() public {
        // Zero input triggers a revert in Target
        bytes memory data = abi.encodeCall(target.run, (0));
        uint256 deadline = vm.getBlockTimestamp();
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);

        vm.expectRevert(ERROR_ZERO_INPUT);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
    }

    function testSetNonceCanIncreaseNonce() public {
        caller.setNonce(1);
        assertNonce(address(this), 1);
    }

    function testSetNonceCanIncreaseNonceByMaxNonceIncrease() public {
        caller.setNonce(1);
        uint256 newNonce = caller.MAX_NONCE_INCREASE() + 1;
        caller.setNonce(newNonce);
        assertNonce(address(this), newNonce);
    }

    function testSetNonceCanNotLeaveNonceUnchanged() public {
        caller.setNonce(1);
        vm.expectRevert(ERROR_NONCE_NOT_INCREASED);
        caller.setNonce(1);
    }

    function testSetNonceCanNotDecreaseNonce() public {
        caller.setNonce(1);
        vm.expectRevert(ERROR_NONCE_NOT_INCREASED);
        caller.setNonce(0);
    }

    function testSetNonceCanNotIncreaseNonceByMoreThanMaxNonceIncrease() public {
        caller.setNonce(1);
        uint256 newNonce = caller.MAX_NONCE_INCREASE() + 2;
        vm.expectRevert("Nonce increased by too much");
        caller.setNonce(newNonce);
    }

    function testCallAs() public {
        uint256 input = 1234567890;
        bytes memory data = abi.encodeCall(target.run, (input));
        uint256 value = 4321;
        authorize(sender, address(this));
        address[] memory allAuthorized = new address[](1);
        allAuthorized[0] = address(this);
        assertEq(caller.allAuthorized(sender), allAuthorized, "Invalid all authorized");

        bytes memory returned = caller.callAs{value: value}(sender, address(target), data);

        assertEq(abi.decode(returned, (uint256)), input + 1, "Invalid returned value");
        target.verify(sender, input, value);
    }

    function testCallAsRejectsWhenNotAuthorized() public {
        bytes memory data = abi.encodeCall(target.run, (1));

        vm.expectRevert(ERROR_UNAUTHORIZED);
        caller.callAs(sender, address(target), data);
    }

    function testCallAsRejectsWhenUnauthorized() public {
        bytes memory data = abi.encodeCall(target.run, (1));
        authorize(sender, address(this));
        unauthorize(sender, address(this));
        assertEq(caller.allAuthorized(sender), new address[](0), "Invalid all authorized");

        vm.expectRevert(ERROR_UNAUTHORIZED);
        caller.callAs(sender, address(target), data);
    }

    function testAuthorizingAuthorizedReverts() public {
        authorize(sender, address(this));
        vm.prank(sender);
        vm.expectRevert("Address already is authorized");
        caller.authorize(address(this));
    }

    function testUnauthorizingUnauthorizedReverts() public {
        vm.prank(sender);
        vm.expectRevert("Address is not authorized");
        caller.unauthorize(address(this));
    }

    function testUnauthorizeAllUnauthorizesAll() public {
        authorize(sender, address(1));
        authorize(sender, address(2));

        vm.prank(sender);
        caller.unauthorizeAll();

        assertFalse(caller.isAuthorized(sender, address(1)), "UnauthorizeAll failed for address 1");
        assertFalse(caller.isAuthorized(sender, address(2)), "UnauthorizeAll failed for address 2");
        assertEq(caller.allAuthorized(sender), new address[](0), "All authorized not empty");
        // Authorization still works
        authorize(sender, address(1));
        address[] memory allAuthorized = new address[](1);
        allAuthorized[0] = address(1);
        assertEq(caller.allAuthorized(sender), allAuthorized, "Invalid all authorized");
        // Unauthorization still works
        unauthorize(sender, address(1));
    }

    function testCallAsBubblesErrors() public {
        // Zero input triggers a revert in Target
        bytes memory data = abi.encodeCall(target.run, (0));
        authorize(sender, address(this));

        vm.expectRevert(ERROR_ZERO_INPUT);
        caller.callAs(sender, address(target), data);
    }

    function testCallBatched() public {
        uint256 input1 = 1234567890;
        uint256 input2 = 2468024680;
        uint256 value1 = 4321;
        uint256 value2 = 8642;
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(target),
            data: abi.encodeCall(target.run, (input1)),
            value: value1
        });
        calls[1] = Call({
            target: address(targetOtherForwarder),
            data: abi.encodeCall(target.run, (input2)),
            value: value2
        });

        bytes[] memory returned = caller.callBatched{value: value1 + value2}(calls);

        assertEq(abi.decode(returned[0], (uint256)), input1 + 1, "Invalid returned value 1");
        assertEq(abi.decode(returned[1], (uint256)), input2 + 1, "Invalid returned value 2");
        target.verify(address(this), input1, value1);
        targetOtherForwarder.verify(address(caller), input2, value2);
    }

    function testCallBatchedBubblesErrors() public {
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            target: address(target),
            data: abi.encodeCall(target.run, (1234567890)),
            value: 0
        });
        // Zero input triggers a revert in Target
        calls[1] = Call({
            target: address(targetOtherForwarder),
            data: abi.encodeCall(target.run, (0)),
            value: 0
        });

        vm.expectRevert(ERROR_ZERO_INPUT);
        caller.callBatched(calls);

        // The effects of the first call are reverted
        target.verify(address(0), 0, 0);
    }

    function testCallerCanCallOnItselfCallAs() public {
        Call[] memory calls = new Call[](1);
        bytes memory data = abi.encodeCall(target.run, (1));
        calls[0] = Call({
            target: address(caller),
            data: abi.encodeCall(caller.callAs, (sender, address(target), data)),
            value: 0
        });
        authorize(sender, address(this));

        caller.callBatched(calls);

        target.verify(sender, 1, 0);
    }

    function testCallerCanCallOnItselfAuthorize() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(caller),
            data: abi.encodeCall(caller.authorize, (sender)),
            value: 0
        });

        caller.callBatched(calls);

        assertTrue(caller.isAuthorized(address(this), sender), "Not authorized");
    }

    function testCallerCanCallOnItselfUnuthorize() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(caller),
            data: abi.encodeCall(caller.unauthorize, (sender)),
            value: 0
        });
        caller.authorize(sender);

        caller.callBatched(calls);

        assertFalse(caller.isAuthorized(address(this), sender), "Not unauthorized");
    }

    function testCallerCanCallOnItselfUnuthorizeAll() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(caller),
            data: abi.encodeCall(caller.unauthorizeAll, ()),
            value: 0
        });
        caller.authorize(sender);

        caller.callBatched(calls);

        assertFalse(caller.isAuthorized(address(this), sender), "Not unauthorized");
    }

    function testCallerCanCallOnItselfSetNonce() public {
        Call[] memory calls = new Call[](1);
        calls[0] =
            Call({target: address(caller), data: abi.encodeCall(caller.setNonce, (1)), value: 0});
        caller.authorize(sender);

        caller.callBatched(calls);

        assertNonce(address(this), 1);
    }

    function testCallerCanCallOnItselfCallBatched() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(target), data: abi.encodeCall(target.run, (1)), value: 0});
        authorize(sender, address(this));
        bytes memory data = abi.encodeCall(caller.callBatched, (calls));

        caller.callAs(sender, address(caller), data);

        target.verify(sender, 1, 0);
    }

    function authorize(address authorizing, address authorized) internal {
        vm.prank(authorizing);
        caller.authorize(authorized);
        assertTrue(caller.isAuthorized(authorizing, authorized), "Authorization failed");
    }

    function unauthorize(address authorizing, address unauthorized) internal {
        vm.prank(authorizing);
        caller.unauthorize(unauthorized);
        assertFalse(caller.isAuthorized(authorizing, unauthorized), "Unauthorization failed");
    }

    function signCall(
        uint256 privKey,
        Target callTarget,
        bytes memory data,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 r, bytes32 sv) {
        bytes memory payload = abi.encode(
            callSignedTypeHash,
            vm.addr(privKey),
            address(callTarget),
            keccak256(data),
            value,
            nonce,
            deadline
        );
        bytes32 digest = ECDSA.toTypedDataHash(callerDomainSeparator, keccak256(payload));
        uint8 v;
        bytes32 s;
        (v, r, s) = vm.sign(privKey, digest);
        sv = (s << 1 >> 1) | (bytes32(uint256(v) - 27) << 255);
    }

    function assertNonce(address user, uint256 expectedNonce) internal {
        assertEq(caller.nonce(user), expectedNonce, "Invalid nonce");
    }
}

contract Target is ERC2771Context, Test {
    address public sender;
    uint256 public input;
    uint256 public value;

    constructor(address forwarder) ERC2771Context(forwarder) {
        return;
    }

    function run(uint256 input_) public payable returns (uint256) {
        require(input_ > 0, "Input is zero");
        sender = _msgSender();
        input = input_;
        value = msg.value;
        return input + 1;
    }

    function verify(address expectedSender, uint256 expectedInput, uint256 expectedValue) public {
        assertEq(sender, expectedSender, "Invalid sender");
        assertEq(input, expectedInput, "Invalid input");
        assertEq(value, expectedValue, "Invalid value");
    }
}
