// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Caller} from "src/Caller.sol";
import {DriverTransferUtils} from "src/DriverTransferUtils.sol";
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

contract DummyDriver is DriverTransferUtils {
    Drips public immutable drips;

    constructor(Drips drips_, address forwarder) DriverTransferUtils(forwarder) {
        drips = drips_;
        drips.registerDriver(address(this));
    }

    function _drips() internal view override returns (Drips) {
        return drips;
    }

    function collect(uint256 accountId, IERC20 erc20, address transferTo)
        public
        returns (uint128 amt)
    {
        return _collectAndTransfer(accountId, erc20, transferTo);
    }

    function give(uint256 accountId, uint256 receiver, IERC20 erc20, uint128 amt) public {
        _giveAndTransfer(accountId, receiver, erc20, amt);
    }

    function setStreams(
        uint256 accountId,
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        int128 balanceDelta,
        StreamReceiver[] calldata newReceivers,
        // slither-disable-next-line similar-names
        uint32 maxEndHint1,
        uint32 maxEndHint2,
        address transferTo
    ) public returns (int128 realBalanceDelta) {
        return _setStreamsAndTransfer(
            accountId,
            erc20,
            currReceivers,
            balanceDelta,
            newReceivers,
            maxEndHint1,
            maxEndHint2,
            transferTo
        );
    }
}

contract DriverTransferUtilsTest is Test {
    Drips internal drips;
    Caller internal caller;
    DummyDriver internal driver;
    IERC20 internal erc20;

    uint256 accountId = 1;
    address userAddr = address(1234);

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this), "")));

        caller = new Caller();

        driver = new DummyDriver(drips, address(caller));

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
    }

    function noStreamReceivers() public pure returns (StreamReceiver[] memory) {
        return new StreamReceiver[](0);
    }

    function noSplitsReceivers() public pure returns (SplitsReceiver[] memory) {
        return new SplitsReceiver[](0);
    }

    function testCollectTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        driver.give(accountId, accountId, erc20, amt);
        drips.split(accountId, erc20, noSplitsReceivers());

        uint128 collected = driver.collect(accountId, erc20, userAddr);

        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(userAddr), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        assertEq(drips.collectable(accountId, erc20), 0, "Invalid collectable amount");
    }

    function testGiveTransfersFundsFromTheSender() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));

        driver.give(accountId, accountId, erc20, amt);

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        assertEq(drips.splittable(accountId, erc20), amt, "Invalid received amount");
    }

    function testGiveTransfersFundsFromTheForwarderProvidedSender() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));
        caller.authorize(userAddr);
        bytes memory giveData = abi.encodeCall(driver.give, (accountId, accountId, erc20, amt));

        vm.prank(userAddr);
        caller.callAs(address(this), address(driver), giveData);

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        assertEq(drips.splittable(accountId, erc20), amt, "Invalid received amount");
    }

    function testSetStreamsIncreasingBalanceTransfersFundsFromTheSender() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));

        int128 realBalanceDelta = driver.setStreams(
            accountId, erc20, noStreamReceivers(), int128(amt), noStreamReceivers(), 0, 0, userAddr
        );

        assertEq(realBalanceDelta, int128(amt), "Invalid streams balance delta");
        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(accountId, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance");
    }

    function testSetStreamsDecreasingBalanceTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));
        driver.setStreams(
            accountId, erc20, noStreamReceivers(), int128(amt), noStreamReceivers(), 0, 0, userAddr
        );

        int128 realBalanceDelta = driver.setStreams(
            accountId, erc20, noStreamReceivers(), -int128(amt), noStreamReceivers(), 0, 0, userAddr
        );

        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta");
        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(userAddr), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(accountId, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance");
    }

    function testSetStreamsIncreasingBalanceTransfersFundsFromTheForwarderProvidedSender() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));
        caller.authorize(userAddr);
        bytes memory setStreamsData = abi.encodeCall(
            driver.setStreams,
            (
                accountId,
                erc20,
                noStreamReceivers(),
                int128(amt),
                noStreamReceivers(),
                0,
                0,
                userAddr
            )
        );

        vm.prank(userAddr);
        bytes memory returnData = caller.callAs(address(this), address(driver), setStreamsData);

        assertEq(abi.decode(returnData, (int128)), int128(amt), "Invalid streams balance delta");
        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(accountId, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance");
    }
}
