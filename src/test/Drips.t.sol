// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.13;

import {DSTest} from "ds-test/test.sol";
import {Hevm} from "./Hevm.t.sol";
import {Drips, DripsReceiver} from "../Drips.sol";

contract DripsTest is DSTest {
    struct Config {
        uint64 lastUpdate;
        uint128 lastBalance;
        DripsReceiver[] currReceivers;
    }

    string internal constant ERROR_NOT_SORTED = "Receivers not sorted";
    string internal constant ERROR_INVALID_CONFIG = "Invalid current drips configuration";

    Drips.Storage internal s;
    uint64 internal cycleSecs = 10;
    // Keys are assetId and userId
    mapping(uint256 => mapping(uint256 => Config)) internal configs;
    uint256 internal defaultAsset = 1;
    uint256 internal otherAsset = 2;
    uint256 internal sender = 1;
    uint256 internal sender1 = 2;
    uint256 internal sender2 = 3;
    uint256 internal receiver = 4;
    uint256 internal receiver1 = 5;
    uint256 internal receiver2 = 6;

    function warpToCycleEnd() internal {
        warpBy(cycleSecs - (block.timestamp % cycleSecs));
    }

    function warpBy(uint256 secs) internal {
        Hevm(HEVM_ADDRESS).warp(block.timestamp + secs);
    }

    function loadConfig(uint256 assetId, uint256 userId)
        internal
        returns (
            uint64 lastUpdate,
            uint128 lastBalance,
            DripsReceiver[] memory currReceivers
        )
    {
        Config storage config = configs[assetId][userId];
        lastUpdate = config.lastUpdate;
        lastBalance = config.lastBalance;
        currReceivers = config.currReceivers;
        assertDrips(assetId, userId, lastUpdate, lastBalance, currReceivers);
    }

    function storeConfig(
        uint256 assetId,
        uint256 userId,
        uint128 newBalance,
        DripsReceiver[] memory newReceivers
    ) internal {
        uint64 currTimestamp = uint64(block.timestamp);
        assertDrips(assetId, userId, currTimestamp, newBalance, newReceivers);
        Config storage config = configs[assetId][userId];
        config.lastUpdate = currTimestamp;
        config.lastBalance = newBalance;
        delete config.currReceivers;
        for (uint256 i = 0; i < newReceivers.length; i++) {
            config.currReceivers.push(newReceivers[i]);
        }
    }

    function recv() internal pure returns (DripsReceiver[] memory list) {
        list = new DripsReceiver[](0);
    }

    function recv(uint256 userId, uint256 amtPerSec)
        internal
        pure
        returns (DripsReceiver[] memory receivers)
    {
        return recv(userId, amtPerSec, 0, 0);
    }

    function recv(
        uint256 userId,
        uint256 amtPerSec,
        uint256 start,
        uint256 duration
    ) internal pure returns (DripsReceiver[] memory receivers) {
        receivers = new DripsReceiver[](1);
        receivers[0] = DripsReceiver(userId, uint128(amtPerSec), uint64(start), uint64(duration));
    }

    function recv(DripsReceiver[] memory recv1, DripsReceiver[] memory recv2)
        internal
        pure
        returns (DripsReceiver[] memory receivers)
    {
        receivers = new DripsReceiver[](recv1.length + recv2.length);
        for (uint256 i = 0; i < recv1.length; i++) receivers[i] = recv1[i];
        for (uint256 i = 0; i < recv2.length; i++) receivers[recv1.length + i] = recv2[i];
    }

    function recv(
        DripsReceiver[] memory recv1,
        DripsReceiver[] memory recv2,
        DripsReceiver[] memory recv3
    ) internal pure returns (DripsReceiver[] memory) {
        return recv(recv(recv1, recv2), recv3);
    }

    function recv(
        DripsReceiver[] memory recv1,
        DripsReceiver[] memory recv2,
        DripsReceiver[] memory recv3,
        DripsReceiver[] memory recv4
    ) internal pure returns (DripsReceiver[] memory) {
        return recv(recv(recv1, recv2, recv3), recv4);
    }

    function setDrips(
        uint256 user,
        uint128 balanceFrom,
        uint128 balanceTo,
        DripsReceiver[] memory newReceivers
    ) internal {
        setDrips(defaultAsset, user, balanceFrom, balanceTo, newReceivers);
    }

    function setDrips(
        uint256 assetId,
        uint256 userId,
        uint128 balanceFrom,
        uint128 balanceTo,
        DripsReceiver[] memory newReceivers
    ) internal {
        int128 balanceDelta = int128(balanceTo) - int128(balanceFrom);
        (uint64 lastUpdate, uint128 lastBalance, DripsReceiver[] memory currReceivers) = loadConfig(
            assetId,
            userId
        );

        (uint128 newBalance, int128 realBalanceDelta) = Drips.setDrips(
            s,
            cycleSecs,
            userId,
            assetId,
            lastUpdate,
            lastBalance,
            currReceivers,
            balanceDelta,
            newReceivers
        );

        storeConfig(assetId, userId, newBalance, newReceivers);
        assertEq(newBalance, balanceTo, "Invalid drips balance");
        assertEq(realBalanceDelta, balanceDelta, "Invalid real balance delta");
    }

    function assertDrips(
        uint256 assetId,
        uint256 userId,
        uint64 lastUpdate,
        uint128 lastBalance,
        DripsReceiver[] memory currReceivers
    ) internal {
        bytes32 actual = Drips.dripsHash(s, userId, assetId);
        bytes32 expected = Drips.hashDrips(lastUpdate, lastBalance, currReceivers);
        assertEq(actual, expected, "Invalid drips configuration");
    }

    function assertDripsBalance(uint256 userId, uint128 expected) internal {
        changeBalance(userId, expected, expected);
    }

    function changeBalance(
        uint256 userId,
        uint128 balanceFrom,
        uint128 balanceTo
    ) internal {
        (, , DripsReceiver[] memory currReceivers) = loadConfig(defaultAsset, userId);
        setDrips(userId, balanceFrom, balanceTo, currReceivers);
    }

    function assertSetDripsReverts(
        uint256 userId,
        DripsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        (uint64 lastUpdate, uint128 lastBalance, DripsReceiver[] memory currReceivers) = loadConfig(
            defaultAsset,
            userId
        );
        assertSetDripsReverts(
            userId,
            lastUpdate,
            lastBalance,
            currReceivers,
            0,
            newReceivers,
            expectedReason
        );
    }

    function assertSetDripsReverts(
        uint256 userId,
        uint64 lastUpdate,
        uint128 lastBalance,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        try
            this.setDripsExternal(
                defaultAsset,
                userId,
                lastUpdate,
                lastBalance,
                currReceivers,
                balanceDelta,
                newReceivers
            )
        {
            assertTrue(false, "Set drips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid set drips revert reason");
        }
    }

    function setDripsExternal(
        uint256 assetId,
        uint256 userId,
        uint64 lastUpdate,
        uint128 lastBalance,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers
    ) external {
        Drips.setDrips(
            s,
            cycleSecs,
            userId,
            assetId,
            lastUpdate,
            lastBalance,
            currReceivers,
            balanceDelta,
            newReceivers
        );
    }

    function receiveDrips(uint256 userId, uint128 expectedAmt) internal {
        receiveDrips(defaultAsset, userId, expectedAmt);
    }

    function receiveDrips(
        uint256 assetId,
        uint256 userId,
        uint128 expectedAmt
    ) internal {
        (uint128 actualAmt, ) = Drips.receiveDrips(s, cycleSecs, userId, assetId, type(uint64).max);
        assertEq(actualAmt, expectedAmt, "Invalid amount received from drips");
    }

    function receiveDrips(
        uint256 userId,
        uint64 maxCycles,
        uint128 expectedReceivedAmt,
        uint64 expectedReceivedCycles,
        uint128 expectedAmtAfter,
        uint64 expectedCyclesAfter
    ) internal {
        uint128 expectedTotalAmt = expectedReceivedAmt + expectedAmtAfter;
        uint64 expectedTotalCycles = expectedReceivedCycles + expectedCyclesAfter;
        assertReceivableDripsCycles(userId, expectedTotalCycles);
        assertReceivableDrips(userId, type(uint64).max, expectedTotalAmt, 0);
        assertReceivableDrips(userId, maxCycles, expectedReceivedAmt, expectedCyclesAfter);

        (uint128 receivedAmt, uint64 receivableCycles) = Drips.receiveDrips(
            s,
            cycleSecs,
            userId,
            defaultAsset,
            maxCycles
        );

        assertEq(receivedAmt, expectedReceivedAmt, "Invalid amount received from drips");
        assertEq(receivableCycles, expectedCyclesAfter, "Invalid receivable drips cycles left");
        assertReceivableDripsCycles(userId, expectedCyclesAfter);
        assertReceivableDrips(userId, type(uint64).max, expectedAmtAfter, 0);
    }

    function assertReceivableDripsCycles(uint256 userId, uint64 expectedCycles) internal {
        uint64 actualCycles = Drips.receivableDripsCycles(s, cycleSecs, userId, defaultAsset);
        assertEq(actualCycles, expectedCycles, "Invalid total receivable drips cycles");
    }

    function assertReceivableDrips(uint256 userId, uint128 expectedAmt) internal {
        (uint128 actualAmt, ) = Drips.receivableDrips(
            s,
            cycleSecs,
            userId,
            defaultAsset,
            type(uint64).max
        );
        assertEq(actualAmt, expectedAmt, "Invalid receivable amount");
    }

    function assertReceivableDrips(
        uint256 userId,
        uint64 maxCycles,
        uint128 expectedAmt,
        uint64 expectedCycles
    ) internal {
        (uint128 actualAmt, uint64 actualCycles) = Drips.receivableDrips(
            s,
            cycleSecs,
            userId,
            defaultAsset,
            maxCycles
        );
        assertEq(actualAmt, expectedAmt, "Invalid receivable amount");
        assertEq(actualCycles, expectedCycles, "Invalid receivable drips cycles");
    }

    function testAllowsDrippingToASingleReceiver() public {
        setDrips(sender, 0, 100, recv(receiver, 1));
        warpBy(15);
        // Sender had 15 seconds paying 1 per second
        changeBalance(sender, 85, 0);
        warpToCycleEnd();
        // Receiver 1 had 15 seconds paying 1 per second
        receiveDrips(receiver, 15);
    }

    function testDripsToTwoReceivers() public {
        setDrips(sender, 0, 100, recv(recv(receiver1, 1), recv(receiver2, 1)));
        warpBy(14);
        // Sender had 14 seconds paying 2 per second
        changeBalance(sender, 72, 0);
        warpToCycleEnd();
        // Receiver 1 had 14 seconds paying 1 per second
        receiveDrips(receiver1, 14);
        // Receiver 2 had 14 seconds paying 1 per second
        receiveDrips(receiver2, 14);
    }

    function testDripsFromTwoSendersToASingleReceiver() public {
        setDrips(sender1, 0, 100, recv(receiver, 1));
        warpBy(2);
        setDrips(sender2, 0, 100, recv(receiver, 2));
        warpBy(15);
        // Sender1 had 17 seconds paying 1 per second
        changeBalance(sender1, 83, 0);
        // Sender2 had 15 seconds paying 2 per second
        changeBalance(sender2, 70, 0);
        warpToCycleEnd();
        // Receiver had 2 seconds paying 1 per second and 15 seconds paying 3 per second
        receiveDrips(receiver, 47);
    }

    function testDoesNotRequireReceiverToBeInitialized() public {
        receiveDrips(receiver, 0);
    }

    function testAllowsReceivingWhileBeingDrippedTo() public {
        setDrips(sender, 0, cycleSecs + 10, recv(receiver, 1));
        warpToCycleEnd();
        // Receiver had cycleSecs seconds paying 1 per second
        receiveDrips(receiver, cycleSecs);
        warpBy(7);
        // Sender had cycleSecs + 7 seconds paying 1 per second
        changeBalance(sender, 3, 0);
        warpToCycleEnd();
        // Receiver had 7 seconds paying 1 per second
        receiveDrips(receiver, 7);
    }

    function testDripsFundsUntilTheyRunOut() public {
        setDrips(sender, 0, 100, recv(receiver, 9));
        warpBy(10);
        // Sender had 10 seconds paying 9 per second, drips balance is about to run out
        assertDripsBalance(sender, 10);
        warpBy(1);
        // Sender had 11 seconds paying 9 per second, drips balance has run out
        assertDripsBalance(sender, 1);
        // Nothing more will be dripped
        warpToCycleEnd();
        changeBalance(sender, 1, 0);
        receiveDrips(receiver, 99);
    }

    function testAllowsToppingUpWhileDripping() public {
        setDrips(sender, 0, 100, recv(receiver, 10));
        warpBy(6);
        // Sender had 6 seconds paying 10 per second
        changeBalance(sender, 40, 60);
        warpBy(5);
        // Sender had 5 seconds paying 10 per second
        changeBalance(sender, 10, 0);
        warpToCycleEnd();
        // Receiver had 11 seconds paying 10 per second
        receiveDrips(receiver, 110);
    }

    function testAllowsToppingUpAfterFundsRunOut() public {
        setDrips(sender, 0, 100, recv(receiver, 10));
        warpBy(10);
        // Sender had 10 seconds paying 10 per second
        assertDripsBalance(sender, 0);
        warpToCycleEnd();
        // Receiver had 10 seconds paying 10 per second
        assertReceivableDrips(receiver, 100);
        changeBalance(sender, 0, 60);
        warpBy(5);
        // Sender had 5 seconds paying 10 per second
        changeBalance(sender, 10, 0);
        warpToCycleEnd();
        // Receiver had 15 seconds paying 10 per second
        receiveDrips(receiver, 150);
    }

    function testAllowsDrippingWhichShouldEndAfterMaxTimestamp() public {
        uint128 balance = type(uint64).max + uint128(6);
        setDrips(sender, 0, balance, recv(receiver, 1));
        warpBy(10);
        // Sender had 10 seconds paying 1 per second
        changeBalance(sender, balance - 10, 0);
        warpToCycleEnd();
        // Receiver had 10 seconds paying 1 per second
        receiveDrips(receiver, 10);
    }

    function testAllowsChangingReceiversWhileDripping() public {
        setDrips(sender, 0, 100, recv(recv(receiver1, 6), recv(receiver2, 6)));
        warpBy(3);
        setDrips(sender, 64, 64, recv(recv(receiver1, 4), recv(receiver2, 8)));
        warpBy(4);
        // Sender had 7 seconds paying 12 per second
        changeBalance(sender, 16, 0);
        warpToCycleEnd();
        // Receiver1 had 3 seconds paying 6 per second and 4 seconds paying 4 per second
        receiveDrips(receiver1, 34);
        // Receiver2 had 3 seconds paying 6 per second and 4 seconds paying 8 per second
        receiveDrips(receiver2, 50);
    }

    function testAllowsRemovingReceiversWhileDripping() public {
        setDrips(sender, 0, 100, recv(recv(receiver1, 5), recv(receiver2, 5)));
        warpBy(3);
        setDrips(sender, 70, 70, recv(receiver2, 10));
        warpBy(4);
        setDrips(sender, 30, 30, recv());
        warpBy(10);
        // Sender had 7 seconds paying 10 per second
        changeBalance(sender, 30, 0);
        warpToCycleEnd();
        // Receiver1 had 3 seconds paying 5 per second
        receiveDrips(receiver1, 15);
        // Receiver2 had 3 seconds paying 5 per second and 4 seconds paying 10 per second
        receiveDrips(receiver2, 55);
    }

    function testLimitsTheTotalReceiversCount() public {
        uint160 countMax = Drips.MAX_DRIPS_RECEIVERS;
        DripsReceiver[] memory receivers = new DripsReceiver[](countMax);
        for (uint160 i = 0; i < countMax; i++) {
            receivers[i] = recv(i, 1, 0, 0)[0];
        }
        setDrips(sender, 0, 0, receivers);
        receivers = recv(receivers, recv(countMax, 1, 0, 0));
        assertSetDripsReverts(sender, receivers, "Too many drips receivers");
    }

    function testRejectsZeroAmtPerSecReceivers() public {
        assertSetDripsReverts(sender, recv(receiver, 0), "Drips receiver amtPerSec is zero");
    }

    function testRejectsUnsortedReceivers() public {
        assertSetDripsReverts(
            sender,
            recv(recv(receiver2, 1), recv(receiver1, 1)),
            ERROR_NOT_SORTED
        );
    }

    function testRejectsDuplicateReceivers() public {
        assertSetDripsReverts(sender, recv(recv(receiver, 1), recv(receiver, 1)), ERROR_NOT_SORTED);
    }

    function testSetDripsRevertsIfInvalidLastUpdate() public {
        setDrips(sender, 0, 0, recv(receiver, 1));
        assertSetDripsReverts(
            sender,
            uint64(block.timestamp) + 1,
            0,
            recv(receiver, 1),
            0,
            recv(),
            ERROR_INVALID_CONFIG
        );
    }

    function testSetDripsRevertsIfInvalidLastBalance() public {
        setDrips(sender, 0, 1, recv(receiver, 1));
        assertSetDripsReverts(
            sender,
            uint64(block.timestamp),
            2,
            recv(receiver, 1),
            0,
            recv(),
            ERROR_INVALID_CONFIG
        );
    }

    function testSetDripsRevertsIfInvalidCurrReceivers() public {
        setDrips(sender, 0, 0, recv(receiver, 1));
        assertSetDripsReverts(
            sender,
            uint64(block.timestamp),
            0,
            recv(receiver, 2),
            0,
            recv(),
            ERROR_INVALID_CONFIG
        );
    }

    function testAllowsAnAddressToDripAndReceiveIndependently() public {
        setDrips(sender, 0, 10, recv(sender, 10));
        warpBy(1);
        // Sender had 1 second paying 10 per second
        assertDripsBalance(sender, 0);
        warpToCycleEnd();
        // Sender had 1 second paying 10 per second
        receiveDrips(sender, 10);
    }

    function testCapsWithdrawalOfMoreThanDripsBalance() public {
        DripsReceiver[] memory receivers = recv(receiver, 1);
        setDrips(sender, 0, 10, receivers);
        uint64 lastUpdate = uint64(block.timestamp);
        warpBy(4);
        // Sender had 4 second paying 1 per second
        (uint128 newBalance, int128 realBalanceDelta) = Drips.setDrips(
            s,
            cycleSecs,
            sender,
            defaultAsset,
            lastUpdate,
            10,
            receivers,
            type(int128).min,
            receivers
        );
        storeConfig(defaultAsset, sender, newBalance, receivers);
        assertEq(newBalance, 0, "Invalid balance");
        assertEq(realBalanceDelta, -6, "Invalid real balance delta");
        assertDripsBalance(sender, 0);
        warpToCycleEnd();
        // Receiver had 4 seconds paying 1 per second
        receiveDrips(receiver, 4);
    }

    function testReceiveNotAllDripsCycles() public {
        // Enough for 3 cycles
        uint128 amt = cycleSecs * 3;
        warpToCycleEnd();
        setDrips(sender, 0, amt, recv(receiver, 1));
        warpToCycleEnd();
        warpToCycleEnd();
        warpToCycleEnd();
        receiveDrips({
            userId: receiver,
            maxCycles: 2,
            expectedReceivedAmt: cycleSecs * 2,
            expectedReceivedCycles: 2,
            expectedAmtAfter: cycleSecs,
            expectedCyclesAfter: 1
        });
        receiveDrips(receiver, cycleSecs);
    }

    function testSenderCanDripToThemselves() public {
        uint128 amt = cycleSecs * 3;
        warpToCycleEnd();
        setDrips(sender, 0, amt, recv(recv(sender, 1), recv(receiver, 2)));
        warpToCycleEnd();
        receiveDrips(sender, cycleSecs);
        receiveDrips(receiver, cycleSecs * 2);
    }

    function testDripsOfDifferentAssetsAreIndependent() public {
        // Covers 1.5 cycles of dripping
        setDrips(
            defaultAsset,
            sender,
            0,
            9 * cycleSecs,
            recv(recv(receiver1, 4), recv(receiver2, 2))
        );

        warpToCycleEnd();
        // Covers 2 cycles of dripping
        setDrips(otherAsset, sender, 0, 6 * cycleSecs, recv(receiver1, 3));

        warpToCycleEnd();
        // receiver1 had 1.5 cycles of 4 per second
        receiveDrips(defaultAsset, receiver1, 6 * cycleSecs);
        // receiver1 had 1.5 cycles of 2 per second
        receiveDrips(defaultAsset, receiver2, 3 * cycleSecs);
        // receiver1 had 1 cycle of 3 per second
        receiveDrips(otherAsset, receiver1, 3 * cycleSecs);
        // receiver2 received nothing
        receiveDrips(otherAsset, receiver2, 0);

        warpToCycleEnd();
        // receiver1 received nothing
        receiveDrips(defaultAsset, receiver1, 0);
        // receiver2 received nothing
        receiveDrips(defaultAsset, receiver2, 0);
        // receiver1 had 1 cycle of 3 per second
        receiveDrips(otherAsset, receiver1, 3 * cycleSecs);
        // receiver2 received nothing
        receiveDrips(otherAsset, receiver2, 0);
    }
}
