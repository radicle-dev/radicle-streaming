// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Managed, ManagedProxy} from "src/Managed.sol";
import {Test} from "forge-std/Test.sol";

contract Logic is Managed {
    uint256 public immutable instanceId;
    bool public called;

    constructor(uint256 instanceId_) {
        instanceId = instanceId_;
    }

    function erc1967Slot(string memory name) public pure returns (bytes32 slot) {
        return _erc1967Slot(name);
    }

    function onlyAdminOrConstructorFunction() public onlyAdminOrConstructor {
        called = true;
    }
}

contract ManagedTest is Test {
    Logic internal logic;
    Logic internal proxy;

    address internal admin = address(1);
    address internal pauser = address(2);
    address internal user = address(3);

    bytes internal constant ERROR_NOT_ADMIN = "Caller not the admin";
    bytes internal constant ERROR_NOT_ADMIN_OR_PAUSER = "Caller not the admin or a pauser";

    function setUp() public {
        logic = new Logic(0);
        proxy = Logic(address(new ManagedProxy(logic, admin, "")));
        vm.prank(admin);
        proxy.grantPauser(pauser);
    }

    function pause() internal {
        vm.prank(pauser);
        proxy.pause();
    }

    function testLogicContractIsPausedForever() public {
        assertTrue(logic.isPaused(), "Not paused");
        assertEq(logic.admin(), address(0), "Admin not zero");
        assertEq(logic.allPausers(), new address[](0), "Pausers not empty");
    }

    function testArbitraryUserCanNotCallOnlyAdminOrConstructorFunction() public {
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.onlyAdminOrConstructorFunction();
    }

    function testPauserCanNotCallOnlyAdminOrConstructorFunction() public {
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.onlyAdminOrConstructorFunction();
    }

    function testAdminCanCallOnlyAdminOrConstructorFunction() public {
        vm.prank(admin);
        proxy.onlyAdminOrConstructorFunction();
        assertTrue(proxy.called(), "Function wasn't called");
    }

    function testProxyConstructorCanCallOnlyAdminOrConstructorFunction() public {
        bytes memory data = abi.encodeCall(Logic.onlyAdminOrConstructorFunction, ());
        Logic proxy_ = Logic(address(new ManagedProxy(new Logic(0), admin, data)));
        assertEq(proxy_.admin(), admin, "Invalid admin address");
        assertTrue(proxy_.called(), "Function wasn't called");
    }

    function testAdminCanProposeNewAdmin() public {
        assertEq(proxy.proposedAdmin(), address(0));

        vm.prank(admin);
        proxy.proposeNewAdmin(user);
        assertEq(proxy.proposedAdmin(), user);

        vm.prank(admin);
        proxy.proposeNewAdmin(address(0));
        assertEq(proxy.proposedAdmin(), address(0));
    }

    function testPauserCanNotProposeNewAdmin() public {
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.proposeNewAdmin(user);
    }

    function testArbitraryUserCanNotProposeNewAdmin() public {
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.proposeNewAdmin(user);
    }

    function testProposedAddressCanAcceptAdmin() public {
        vm.prank(admin);
        proxy.proposeNewAdmin(user);
        assertEq(proxy.admin(), admin);
        assertEq(proxy.proposedAdmin(), user);
        vm.prank(user);
        proxy.acceptAdmin();
        assertEq(proxy.admin(), user);
        assertEq(proxy.proposedAdmin(), address(0));
    }

    function testArbitraryUserCanNotAcceptAdmin() public {
        vm.prank(admin);
        proxy.proposeNewAdmin(user);
        vm.expectRevert("Caller not the proposed admin");
        proxy.acceptAdmin();
    }

    function testAdminCanRenounceAdmin() public {
        vm.prank(admin);
        proxy.proposeNewAdmin(user);
        assertEq(proxy.admin(), admin);
        assertEq(proxy.proposedAdmin(), user);
        vm.prank(admin);
        proxy.renounceAdmin();
        assertEq(proxy.admin(), address(0));
        assertEq(proxy.proposedAdmin(), address(0));
    }

    function testPauserCanNotRenounceAdmin() public {
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.renounceAdmin();
    }

    function testArbitraryUserCanNotRenounceAdmin() public {
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.renounceAdmin();
    }

    function testAdminCanUpgradeContract() public {
        uint256 newInstanceId = proxy.instanceId() + 1;
        Logic newLogic = new Logic(newInstanceId);
        assertEq(proxy.implementation(), address(logic), "Invalid implementation before update");
        vm.prank(admin);
        proxy.upgradeTo(address(newLogic));
        assertEq(proxy.implementation(), address(newLogic), "Invalid implementation after update");
        assertEq(proxy.instanceId(), newInstanceId, "Invalid new instance ID");
    }

    function testPauserCanNotUpgradeContract() public {
        Logic newLogic = new Logic(0);
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.upgradeTo(address(newLogic));
    }

    function testArbitraryUserCanNotUpgradeContract() public {
        Logic newLogic = new Logic(0);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.upgradeTo(address(newLogic));
    }

    function testAdminCanGrantPauser() public {
        vm.prank(admin);
        proxy.grantPauser(user);
        assertTrue(proxy.isPauser(user), "Pauser not granted");
        address[] memory allPausers = new address[](2);
        allPausers[0] = pauser;
        allPausers[1] = user;
        assertEq(proxy.allPausers(), allPausers, "Invalid pausers");
    }

    function testPauserCanNotGrantPauser() public {
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.grantPauser(user);
    }

    function testArbitraryUserCanNotGrantPauser() public {
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.grantPauser(user);
    }

    function testAdminCanRevokePauser() public {
        vm.prank(admin);
        proxy.revokePauser(pauser);
        assertFalse(proxy.isPauser(pauser), "Pauser not revoked");
        assertEq(proxy.allPausers(), new address[](0), "Invalid pausers");
    }

    function testPauserCanNotRevokePauser() public {
        vm.prank(pauser);
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.revokePauser(pauser);
    }

    function testArbitraryUserCanNotRevokePauser() public {
        vm.expectRevert(ERROR_NOT_ADMIN);
        proxy.revokePauser(pauser);
    }

    function testGrantingPauserToPauserReverts() public {
        vm.prank(admin);
        vm.expectRevert("Address already is a pauser");
        proxy.grantPauser(pauser);
    }

    function testRevokingPauserFromNotPauserReverts() public {
        vm.prank(admin);
        vm.expectRevert("Address is not a pauser");
        proxy.revokePauser(user);
    }

    function testAdminCanPause() public {
        vm.prank(admin);
        proxy.pause();
        assertTrue(proxy.isPaused(), "Pausing failed");
    }

    function testPauserCanPause() public {
        vm.prank(pauser);
        proxy.pause();
        assertTrue(proxy.isPaused(), "Pausing failed");
    }

    function testArbitraryUserCanNotPause() public {
        vm.expectRevert(ERROR_NOT_ADMIN_OR_PAUSER);
        proxy.pause();
    }

    function testAdminCanUnpause() public {
        pause();
        vm.prank(admin);
        proxy.unpause();
        assertFalse(proxy.isPaused(), "Unpausing failed");
    }

    function testPauserCanUnpause() public {
        pause();
        vm.prank(pauser);
        proxy.unpause();
        assertFalse(proxy.isPaused(), "Unpausing failed");
    }

    function testArbitraryUserCanNotUnpause() public {
        pause();
        vm.expectRevert(ERROR_NOT_ADMIN_OR_PAUSER);
        proxy.unpause();
    }

    function testOnlyUnpausedContractCanBePaused() public {
        pause();
        vm.prank(admin);
        vm.expectRevert("Contract paused");
        proxy.pause();
    }

    function testOnlyPausedContractCanBeUnpaused() public {
        vm.prank(admin);
        vm.expectRevert("Contract not paused");
        proxy.unpause();
    }

    function testErc1967Slot() public {
        // Values taken from [EIP-1967](https://eips.ethereum.org/EIPS/eip-1967)
        string memory name = "eip1967.proxy.implementation";
        bytes32 erc1967Proxy = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        // The ERC-1976 standard proposes slots shifted by 1 from the raw hash,
        // but the `erc1967Slot` function returns slots shifted by 1024.
        bytes32 expected = bytes32(uint256(erc1967Proxy) + 1 - 1024);
        assertEq(proxy.erc1967Slot(name), expected, "Invalid EIP-1967 slot");
    }
}
