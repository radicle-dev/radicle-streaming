// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Caller} from "src/Caller.sol";
import {AddressDriver} from "src/AddressDriver.sol";
import {
    AccountMetadata,
    Drips,
    StreamConfigImpl,
    StreamsHistory,
    StreamReceiver,
    SplitsReceiver
} from "src/Drips.sol";
import {ManagedProxy} from "src/Managed.sol";
import {Test} from "forge-std/Test.sol";
import {
    IERC20,
    ERC20PresetFixedSupply
} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract AddressDriverTest is Test {
    Drips internal drips;
    Caller internal caller;
    AddressDriver internal driver;
    IERC20 internal erc20;

    address internal admin = address(1);
    uint256 internal thisId;
    address internal user = address(2);
    uint256 internal accountId;

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this), "")));

        caller = new Caller();

        // Make AddressDriver's driver ID non-0 to test if it's respected by AddressDriver
        drips.registerDriver(address(1));
        drips.registerDriver(address(1));
        uint32 driverId = drips.registerDriver(address(this));
        AddressDriver driverLogic = new AddressDriver(drips, address(caller), driverId);
        driver = AddressDriver(address(new ManagedProxy(driverLogic, admin, "")));
        drips.updateDriverAddress(driverId, address(driver));

        thisId = driver.calcAccountId(address(this));
        accountId = driver.calcAccountId(user);

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
        erc20.transfer(user, erc20.totalSupply() / 100);
        vm.prank(user);
        erc20.approve(address(driver), type(uint256).max);
    }

    function testCollect() public {
        uint128 amt = 5;
        vm.prank(user);
        driver.give(thisId, erc20, amt);
        drips.split(thisId, erc20, new SplitsReceiver[](0));
        uint256 balance = erc20.balanceOf(address(this));

        uint128 collected = driver.collect(erc20, address(this));

        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(address(this)), balance + amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testCollectTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        vm.prank(user);
        driver.give(thisId, erc20, amt);
        drips.split(thisId, erc20, new SplitsReceiver[](0));
        address transferTo = address(1234);

        uint128 collected = driver.collect(erc20, transferTo);

        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testGive() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));

        driver.give(accountId, erc20, amt);

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        assertEq(drips.splittable(accountId, erc20), amt, "Invalid received amount");
    }

    function testSetStreams() public {
        uint128 amt = 5;

        // Top-up

        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] =
            StreamReceiver(accountId, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));
        uint256 balance = erc20.balanceOf(address(this));

        int128 realBalanceDelta = driver.setStreams(
            erc20, new StreamReceiver[](0), int128(amt), receivers, 0, 0, address(this)
        );

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance after top-up");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance after top-up");
        (,,, uint128 streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance after top-up");
        assertEq(realBalanceDelta, int128(amt), "Invalid streams balance delta after top-up");
        (bytes32 streamsHash,,,,) = drips.streamsState(thisId, erc20);
        assertEq(streamsHash, drips.hashStreams(receivers), "Invalid streams hash after top-up");

        // Withdraw
        balance = erc20.balanceOf(address(user));

        realBalanceDelta =
            driver.setStreams(erc20, receivers, -int128(amt), receivers, 0, 0, address(user));

        assertEq(erc20.balanceOf(address(user)), balance + amt, "Invalid balance after withdrawal");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance after withdrawal");
        (,,, streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance after withdrawal");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta after withdrawal");
    }

    function testSetStreamsDecreasingBalanceTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        StreamReceiver[] memory receivers = new StreamReceiver[](0);
        driver.setStreams(erc20, receivers, int128(amt), receivers, 0, 0, address(this));
        address transferTo = address(1234);

        int128 realBalanceDelta =
            driver.setStreams(erc20, receivers, -int128(amt), receivers, 0, 0, transferTo);

        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(thisId, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta");
    }

    function testSetSplits() public {
        SplitsReceiver[] memory receivers = new SplitsReceiver[](1);
        receivers[0] = SplitsReceiver(accountId, 1);

        driver.setSplits(receivers);

        bytes32 actual = drips.splitsHash(thisId);
        bytes32 expected = drips.hashSplits(receivers);
        assertEq(actual, expected, "Invalid splits hash");
    }

    function testEmitAccountMetadata() public {
        AccountMetadata[] memory accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
        driver.emitAccountMetadata(accountMetadata);
    }

    function testForwarderIsTrusted() public {
        vm.prank(user);
        caller.authorize(address(this));
        assertEq(drips.splittable(accountId, erc20), 0, "Invalid splittable before give");
        uint128 amt = 10;

        bytes memory giveData = abi.encodeCall(driver.give, (accountId, erc20, amt));
        caller.callAs(user, address(driver), giveData);

        assertEq(drips.splittable(accountId, erc20), amt, "Invalid splittable after give");
    }

    modifier canBePausedTest() {
        vm.prank(admin);
        driver.pause();
        vm.expectRevert("Contract paused");
        _;
    }

    function testCollectCanBePaused() public canBePausedTest {
        driver.collect(erc20, user);
    }

    function testGiveCanBePaused() public canBePausedTest {
        driver.give(accountId, erc20, 0);
    }

    function testSetStreamsCanBePaused() public canBePausedTest {
        driver.setStreams(erc20, new StreamReceiver[](0), 0, new StreamReceiver[](0), 0, 0, user);
    }

    function testSetSplitsCanBePaused() public canBePausedTest {
        driver.setSplits(new SplitsReceiver[](0));
    }

    function testEmitAccountMetadataCanBePaused() public canBePausedTest {
        driver.emitAccountMetadata(new AccountMetadata[](0));
    }
}
