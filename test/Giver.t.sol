// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {console, Test} from "forge-std/Test.sol";
import {AddressDriver, Drips, IERC20, StreamReceiver} from "src/AddressDriver.sol";
import {Address, Giver, GiversRegistry} from "src/Giver.sol";
import {IWrappedNativeToken} from "src/IWrappedNativeToken.sol";
import {ManagedProxy} from "src/Managed.sol";
import {CONTRACT_DEPLOYER} from "src/ZkSyncUtils.sol";
import {
    ERC20,
    ERC20PresetFixedSupply
} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract WrappedNativeToken is ERC20("", ""), IWrappedNativeToken {
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 amount) external {
        _burn(msg.sender, amount);
        Address.sendValue(payable(msg.sender), amount);
    }
}

contract Logic {
    function fun(uint256 arg) external payable returns (address, uint256, uint256) {
        return (address(this), arg, msg.value);
    }
}

contract GiverTest is Test {
    Giver internal giver = new Giver();
    address internal logic = address(new Logic());

    function testDelegate() public {
        uint256 arg = 1234;
        uint256 value = 5678;

        bytes memory returned = giver.delegate{value: value}(logic, abi.encodeCall(Logic.fun, arg));

        (address thisAddr, uint256 receivedArg, uint256 receivedValue) =
            abi.decode(returned, (address, uint256, uint256));
        assertEq(thisAddr, address(giver), "Invalid delegation context");
        assertEq(receivedArg, arg, "Invalid argument");
        assertEq(receivedValue, value, "Invalid value");
    }

    function testDelegateRevertsForNonOwner() public {
        vm.prank(address(1234));
        vm.expectRevert("Caller is not the owner");
        giver.delegate(logic, "");
    }

    function testTransferToGiver() public {
        uint256 amt = 123;
        Address.sendValue(payable(address(giver)), amt);
        assertEq(address(giver).balance, amt, "Invalid balance");
    }
}

contract GiversRegistryTest is Test {
    Drips internal drips;
    AddressDriver internal addressDriver;
    IERC20 internal erc20;
    IWrappedNativeToken internal wrappedNativeToken;
    GiversRegistry internal giversRegistry;
    address internal admin = address(1);
    uint256 internal accountId;
    address payable internal giver;

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, admin, "")));
        drips.registerDriver(address(1));
        AddressDriver addressDriverLogic =
            new AddressDriver(drips, address(0), drips.nextDriverId());
        addressDriver = AddressDriver(address(new ManagedProxy(addressDriverLogic, admin, "")));
        drips.registerDriver(address(addressDriver));

        wrappedNativeToken = new WrappedNativeToken();
        GiversRegistry giversRegistryLogic = new GiversRegistry(addressDriver, wrappedNativeToken);
        giversRegistry = GiversRegistry(address(new ManagedProxy(giversRegistryLogic, admin, "")));
        accountId = 1234;
        giver = payable(giversRegistry.giver(accountId));
        emit log_named_address("GIVER", giver);

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(addressDriver), type(uint256).max);
    }

    function give(uint256 amt) internal {
        give(amt, amt);
    }

    function give(uint256 amt, uint256 expectedGiven) internal {
        erc20.transfer(giver, amt);
        uint256 balanceBefore = erc20.balanceOf(giver);
        uint256 amtBefore = drips.splittable(accountId, erc20);

        giversRegistry.give(accountId, erc20);

        uint256 balanceAfter = erc20.balanceOf(giver);
        uint256 amtAfter = drips.splittable(accountId, erc20);
        assertEq(balanceAfter, balanceBefore - expectedGiven, "Invalid giver balance");
        assertEq(amtAfter, amtBefore + expectedGiven, "Invalid given amount");
    }

    function giveNative(uint256 amtNative, uint256 amtWrapped) internal {
        Address.sendValue(giver, amtNative);
        wrappedNativeToken.deposit{value: amtWrapped}();
        wrappedNativeToken.transfer(giver, amtWrapped);

        uint256 balanceBefore = giver.balance + wrappedNativeToken.balanceOf(giver);
        uint256 amtBefore = drips.splittable(accountId, wrappedNativeToken);

        giversRegistry.give(accountId, IERC20(address(0)));

        uint256 balanceAfter = wrappedNativeToken.balanceOf(giver);
        uint256 amtAfter = drips.splittable(accountId, wrappedNativeToken);
        assertEq(giver.balance, 0, "Invalid giver native token balance");
        uint256 expectedGiven = amtNative + amtWrapped;
        assertEq(balanceAfter, balanceBefore - expectedGiven, "Invalid giver balance");
        assertEq(amtAfter, amtBefore + expectedGiven, "Invalid given amount");
    }

    function testGive() public {
        give(5);
    }

    function testGiveZero() public {
        give(0);
    }

    function testGiveUsingDeployedGiver() public {
        give(1);
        give(5);
    }

    function testGiveMaxBalance() public {
        give(drips.MAX_TOTAL_BALANCE());
        give(1, 0);
    }

    function testGiveOverMaxBalance() public {
        erc20.approve(address(addressDriver), 15);
        addressDriver.setStreams(
            erc20, new StreamReceiver[](0), 10, new StreamReceiver[](0), 0, 0, address(this)
        );
        addressDriver.give(0, erc20, 5);
        give(drips.MAX_TOTAL_BALANCE(), drips.MAX_TOTAL_BALANCE() - 15);
    }

    function testGiveNative() public {
        giveNative(10, 0);
    }

    function testGiveWrapped() public {
        giveNative(0, 5);
    }

    function testGiveNativeAndWrapped() public {
        giveNative(10, 5);
    }

    function testGiveZeroWrapped() public {
        // console.log("Giver type bytecode");
        // console.logBytes(type(Giver).creationCode);

        // console.log("Giver type bytecode hash");
        // bytes32 creationCodeHash = keccak256(type(Giver).creationCode);
        // console.logBytes32(creationCodeHash);

        // console.log("Giver contract bytecode");
        bytes32 codeHash = address(new Giver()).codehash;
        // console.logBytes32(codeHash);

        Giver givr2 = Giver(payable(CONTRACT_DEPLOYER.create2("salty?", codeHash, "")));
        console.log("Giver 2", address(givr2));
        console.log("Giver 2 owner", givr2.owner());

        console.log("Will a()");
        Giver givr3 = new Lol().a();
        console.log("Giver 3", address(givr3));
        console.log("Giver 3 owner", givr3.owner());


        giveNative(0, 0);
    }

    function testGiveCanBePaused() public {
        vm.prank(admin);
        giversRegistry.pause();
        vm.expectRevert("Contract paused");
        giversRegistry.give(accountId, erc20);
    }

    function testGiveImplReverts() public {
        vm.expectRevert("Caller is not GiversRegistry");
        giversRegistry.giveImpl(accountId, erc20);
    }
}


contract Lol {
    function a() public returns (Giver) {
        bytes32 codeHash = address(new Giver()).codehash;
        console.log("Giver out");
        return Giver(payable(CONTRACT_DEPLOYER.create2("salty?", codeHash, "")));
    }
}