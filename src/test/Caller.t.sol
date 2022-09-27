// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";
import {ECDSA} from "openzeppelin-contracts/utils/cryptography/ECDSA.sol";
import {Call, Caller} from "../Caller.sol";

contract CallerTest is Test {
    string internal constant DOMAIN_TYPE_NAME =
        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)";
    bytes32 internal immutable domainTypeHash = keccak256(bytes(DOMAIN_TYPE_NAME));
    string internal constant CALL_SIGNED_TYPE_NAME = "CallSigned("
        "address sender,address to,bytes data,uint256 value,uint256 nonce,uint256 deadline)";
    bytes32 internal immutable callSignedTypeHash = keccak256(bytes(CALL_SIGNED_TYPE_NAME));

    Caller internal caller;
    Target internal target;
    Target internal targetOtherForwarder;
    bytes32 internal callerDomainSeparator;
    uint256 internal senderKey;
    address internal sender;

    constructor() {
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
        bytes memory data = abi.encodeWithSelector(target.run.selector, input);
        uint256 value = 4321;
        uint256 deadline = block.timestamp;
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, value, 0, deadline);

        bytes memory returned =
            caller.callSigned{value: value}(sender, address(target), data, deadline, r, sv);

        assertEq(abi.decode(returned, (uint256)), input + 1, "Invalid returned value");
        target.verify(sender, input, value);
    }

    function testCallSignedRejectsExpiredDeadline() public {
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);
        uint256 deadline = block.timestamp;
        skip(1);
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);

        try caller.callSigned(sender, address(target), data, deadline, r, sv) {
            assertTrue(false, "CallSigned hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Execution deadline expired", "Invalid callSigned revert reason");
        }
    }

    function testCallSignedRejectsInvalidNonce() public {
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);
        uint256 deadline = block.timestamp;
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);
        caller.callSigned(sender, address(target), data, deadline, r, sv);
        assertEq(caller.nonce(sender), 1, "Invalid nonce after a signed call");

        try caller.callSigned(sender, address(target), data, deadline, r, sv) {
            assertTrue(false, "CallSigned hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid signature", "Invalid callSigned revert reason");
        }
    }

    function testCallSignedRejectsInvalidSigner() public {
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);
        uint256 deadline = block.timestamp;
        (bytes32 r, bytes32 sv) = signCall(senderKey + 1, target, data, 0, 0, deadline);

        try caller.callSigned(sender, address(target), data, deadline, r, sv) {
            assertTrue(false, "CallSigned hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid signature", "Invalid callSigned revert reason");
        }
    }

    function testCallSignedBubblesErrors() public {
        // Zero input triggers a revert in Target
        bytes memory data = abi.encodeWithSelector(target.run.selector, 0);
        uint256 deadline = block.timestamp;
        (bytes32 r, bytes32 sv) = signCall(senderKey, target, data, 0, 0, deadline);

        try caller.callSigned(sender, address(target), data, deadline, r, sv) {
            assertTrue(false, "CallSigned hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Input is zero", "Invalid callSigned revert reason");
        }
    }

    function testCallAs() public {
        uint256 input = 1234567890;
        bytes memory data = abi.encodeWithSelector(target.run.selector, input);
        uint256 value = 4321;
        authorize(sender, address(this));

        bytes memory returned = caller.callAs{value: value}(sender, address(target), data);

        assertEq(abi.decode(returned, (uint256)), input + 1, "Invalid returned value");
        target.verify(sender, input, value);
    }

    function testCallAsRejectsWhenNotAuthorized() public {
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);

        try caller.callAs(sender, address(target), data) {
            assertTrue(false, "CallAs hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Not authorized", "Invalid callAs revert reason");
        }
    }

    function testCallAsRejectsWhenUnauthorized() public {
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);
        authorize(sender, address(this));
        unauthorize(sender, address(this));

        try caller.callAs(sender, address(target), data) {
            assertTrue(false, "CallAs hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Not authorized", "Invalid callAs revert reason");
        }
    }

    function testCallAsBubblesErrors() public {
        // Zero input triggers a revert in Target
        bytes memory data = abi.encodeWithSelector(target.run.selector, 0);
        authorize(sender, address(this));

        try caller.callAs(sender, address(target), data) {
            assertTrue(false, "CallAs hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Input is zero", "Invalid callAs revert reason");
        }
    }

    function testCallBatched() public {
        uint256 input1 = 1234567890;
        uint256 input2 = 2468024680;
        uint256 value1 = 4321;
        uint256 value2 = 8642;
        Call[] memory calls = new Call[](2);
        calls[0] = Call({
            to: address(target),
            data: abi.encodeWithSelector(target.run.selector, input1),
            value: value1
        });
        calls[1] = Call({
            to: address(targetOtherForwarder),
            data: abi.encodeWithSelector(target.run.selector, input2),
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
            to: address(target),
            data: abi.encodeWithSelector(target.run.selector, 1234567890),
            value: 0
        });
        // Zero input triggers a revert in Target
        calls[1] = Call({
            to: address(targetOtherForwarder),
            data: abi.encodeWithSelector(target.run.selector, 0),
            value: 0
        });

        try caller.callBatched(calls) {
            assertTrue(false, "CallBatched hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Input is zero", "Invalid callBatched revert reason");
        }

        // The effects of the first call are reverted
        target.verify(address(0), 0, 0);
    }

    function testCallerCanCallOnItselfCallAs() public {
        Call[] memory calls = new Call[](1);
        bytes memory data = abi.encodeWithSelector(target.run.selector, 1);
        calls[0] = Call({
            to: address(caller),
            data: abi.encodeWithSelector(caller.callAs.selector, sender, address(target), data),
            value: 0
        });
        authorize(sender, address(this));

        caller.callBatched(calls);

        target.verify(sender, 1, 0);
    }

    function testCallerCanCallOnItselfAuthorize() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(caller),
            data: abi.encodeWithSelector(caller.authorize.selector, sender),
            value: 0
        });

        caller.callBatched(calls);

        assertTrue(caller.isAuthorized(address(this), sender), "Not authorized");
    }

    function testCallerCanCallOnItselfUnuthorize() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(caller),
            data: abi.encodeWithSelector(caller.unauthorize.selector, sender),
            value: 0
        });
        caller.authorize(sender);

        caller.callBatched(calls);

        assertFalse(caller.isAuthorized(address(this), sender), "Not unauthorized");
    }

    function testCallerCanCallOnItselfCallBatched() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            to: address(target),
            data: abi.encodeWithSelector(target.run.selector, 1),
            value: 0
        });
        authorize(sender, address(this));
        bytes memory data = abi.encodeWithSelector(caller.callBatched.selector, calls);
        authorize(sender, address(this));

        caller.callAs(sender, address(caller), data);

        target.verify(sender, 1, 0);
    }

    function authorize(address authorizing, address authorized) internal {
        vm.prank(authorizing);
        caller.authorize(authorized);
    }

    function unauthorize(address authorizing, address unauthorized) internal {
        vm.prank(authorizing);
        caller.unauthorize(unauthorized);
    }

    function signCall(
        uint256 privKey,
        Target to,
        bytes memory data,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal returns (bytes32 r, bytes32 sv) {
        bytes memory payload = abi.encode(
            callSignedTypeHash,
            vm.addr(privKey),
            address(to),
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