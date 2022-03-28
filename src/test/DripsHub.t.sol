// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.7;

import {DSTest} from "ds-test/test.sol";
import {DripsHubUserUtils} from "./DripsHubUserUtils.t.sol";
import {AddressIdUser} from "./AddressIdUser.t.sol";
import {ManagedUser} from "./ManagedUser.t.sol";
import {AddressId} from "../AddressId.sol";
import {SplitsReceiver, DripsHub, DripsReceiver} from "../DripsHub.sol";
import {Reserve} from "../Reserve.sol";
import {Proxy} from "../Managed.sol";
import {IERC20, ERC20PresetFixedSupply} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract DripsHubTest is DripsHubUserUtils {
    AddressId private addressId;

    IERC20 private otherErc20;

    AddressIdUser private user;
    AddressIdUser private receiver;
    AddressIdUser private user1;
    AddressIdUser private receiver1;
    AddressIdUser private user2;
    AddressIdUser private receiver2;
    AddressIdUser private receiver3;
    ManagedUser internal admin;
    ManagedUser internal nonAdmin;

    string internal constant ERROR_NOT_OWNER = "Callable only by the owner of the user account";
    string private constant ERROR_NOT_ADMIN = "Caller is not the admin";
    string private constant ERROR_PAUSED = "Contract paused";

    function setUp() public {
        defaultErc20 = new ERC20PresetFixedSupply("test", "test", 10**6 * 1 ether, address(this));
        otherErc20 = new ERC20PresetFixedSupply("other", "other", 10**6 * 1 ether, address(this));
        Reserve reserve = new Reserve(address(this));
        DripsHub hubLogic = new DripsHub(10, reserve);
        dripsHub = DripsHub(address(new Proxy(hubLogic, address(this))));
        reserve.addUser(address(dripsHub));
        addressId = new AddressId(dripsHub);
        user = createUser();
        receiver1 = createUser();
        receiver2 = createUser();
        admin = new ManagedUser(dripsHub);
        nonAdmin = new ManagedUser(dripsHub);
        dripsHub.changeAdmin(address(admin));
        user = createUser();
        user1 = createUser();
        user2 = createUser();
        receiver = createUser();
        receiver1 = createUser();
        receiver2 = createUser();
        receiver3 = createUser();
        // Sort receivers by address
        if (receiver1 > receiver2) (receiver1, receiver2) = (receiver2, receiver1);
        if (receiver2 > receiver3) (receiver2, receiver3) = (receiver3, receiver2);
        if (receiver1 > receiver2) (receiver1, receiver2) = (receiver2, receiver1);
    }

    function createUser() internal returns (AddressIdUser newUser) {
        newUser = new AddressIdUser(addressId);
        defaultErc20.transfer(address(newUser), 100 ether);
        otherErc20.transfer(address(newUser), 100 ether);
    }

    function testAllowsDrippingToASingleReceiver() public {
        setDrips(user, 0, 100, dripsReceivers(receiver, 1));
        warpBy(15);
        // User had 15 seconds paying 1 per second
        changeBalance(user, 85, 0);
        warpToCycleEnd();
        // Receiver 1 had 15 seconds paying 1 per second
        collectAll(receiver, 15);
    }

    function testAllowsDrippingToASingleReceiverForFuzzyTime(uint8 cycles, uint8 timeInCycle)
        public
    {
        uint128 time = (cycles / 10) * dripsHub.cycleSecs() + (timeInCycle % dripsHub.cycleSecs());
        uint128 balance = 25 * dripsHub.cycleSecs() + 256;
        setDrips(user, 0, balance, dripsReceivers(receiver, 1));
        warpBy(time);
        // User had `time` seconds paying 1 per second
        changeBalance(user, balance - time, 0);
        warpToCycleEnd();
        // User had `time` seconds paying 1 per second
        collectAll(receiver, time);
    }

    function testAllowsDrippingToMultipleReceivers() public {
        setDrips(user, 0, 6, dripsReceivers(receiver1, 1, receiver2, 2));
        warpToCycleEnd();
        // User had 2 seconds paying 1 per second
        collectAll(receiver1, 2);
        // User had 2 seconds paying 2 per second
        collectAll(receiver2, 4);
    }

    function testDripsSomeFundsToTwoReceivers() public {
        setDrips(user, 0, 100, dripsReceivers(receiver1, 1, receiver2, 1));
        warpBy(14);
        // User had 14 seconds paying 2 per second
        changeBalance(user, 72, 0);
        warpToCycleEnd();
        // Receiver 1 had 14 seconds paying 1 per second
        collectAll(receiver1, 14);
        // Receiver 2 had 14 seconds paying 1 per second
        collectAll(receiver2, 14);
    }

    function testDripsSomeFundsFromTwoUsersToASingleReceiver() public {
        setDrips(user1, 0, 100, dripsReceivers(receiver, 1));
        warpBy(2);
        setDrips(user2, 0, 100, dripsReceivers(receiver, 2));
        warpBy(15);
        // User1 had 17 seconds paying 1 per second
        changeBalance(user1, 83, 0);
        // User2 had 15 seconds paying 2 per second
        changeBalance(user2, 70, 0);
        warpToCycleEnd();
        // Receiver had 2 seconds paying 1 per second and 15 seconds paying 3 per second
        collectAll(receiver, 47);
    }

    function testDoesNotRequireReceiverToBeInitialized() public {
        collectAll(receiver, 0);
    }

    function testAllowsCollectingFundsWhileTheyAreBeingDripped() public {
        setDrips(user, 0, dripsHub.cycleSecs() + 10, dripsReceivers(receiver, 1));
        warpToCycleEnd();
        // Receiver had cycleSecs seconds paying 1 per second
        collectAll(receiver, dripsHub.cycleSecs());
        warpBy(7);
        // User had cycleSecs + 7 seconds paying 1 per second
        changeBalance(user, 3, 0);
        warpToCycleEnd();
        // Receiver had 7 seconds paying 1 per second
        collectAll(receiver, 7);
    }

    function testCollectAllRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try user.collectAll(address(user), defaultErc20, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid current splits receivers", "Invalid collect revert reason");
        }
    }

    function testDripsFundsUntilTheyRunOut() public {
        setDrips(user, 0, 100, dripsReceivers(receiver, 9));
        warpBy(10);
        // User had 10 seconds paying 9 per second, drips balance is about to run out
        assertDripsBalance(user, 10);
        warpBy(1);
        // User had 11 seconds paying 9 per second, drips balance has run out
        assertDripsBalance(user, 1);
        // Nothing more will be dripped
        warpToCycleEnd();
        changeBalance(user, 1, 0);
        collectAll(receiver, 99);
    }

    function testCollectableAllRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try dripsHub.collectableAll(user.userId(), defaultErc20, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Collectable hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(
                reason,
                "Invalid current splits receivers",
                "Invalid collectable revert reason"
            );
        }
    }

    function testAllowsToppingUpWhileDripping() public {
        setDrips(user, 0, 100, dripsReceivers(receiver, 10));
        warpBy(6);
        // User had 6 seconds paying 10 per second
        changeBalance(user, 40, 60);
        warpBy(5);
        // User had 5 seconds paying 10 per second
        changeBalance(user, 10, 0);
        warpToCycleEnd();
        // Receiver had 11 seconds paying 10 per second
        collectAll(receiver, 110);
    }

    function testAllowsToppingUpAfterFundsRunOut() public {
        setDrips(user, 0, 100, dripsReceivers(receiver, 10));
        warpBy(10);
        // User had 10 seconds paying 10 per second
        assertDripsBalance(user, 0);
        warpToCycleEnd();
        // Receiver had 10 seconds paying 10 per second
        assertCollectableAll(receiver, 100);
        changeBalance(user, 0, 60);
        warpBy(5);
        // User had 5 seconds paying 10 per second
        changeBalance(user, 10, 0);
        warpToCycleEnd();
        // Receiver had 15 seconds paying 10 per second
        collectAll(receiver, 150);
    }

    function testAllowsDrippingWhichShouldEndAfterMaxTimestamp() public {
        uint128 balance = type(uint64).max + uint128(6);
        setDrips(user, 0, balance, dripsReceivers(receiver, 1));
        warpBy(10);
        // User had 10 seconds paying 1 per second
        changeBalance(user, balance - 10, 0);
        warpToCycleEnd();
        // Receiver had 10 seconds paying 1 per second
        collectAll(receiver, 10);
    }

    function testAllowsNoDripsReceiversUpdate() public {
        setDrips(user, 0, 6, dripsReceivers(receiver, 3));
        warpBy(1);
        // User had 1 second paying 3 per second
        setDrips(user, 3, 3, dripsReceivers(receiver, 3));
        warpToCycleEnd();
        collectAll(receiver, 6);
    }

    function testAllowsChangingReceiversWhileDripping() public {
        setDrips(user, 0, 100, dripsReceivers(receiver1, 6, receiver2, 6));
        warpBy(3);
        setDrips(user, 64, 64, dripsReceivers(receiver1, 4, receiver2, 8));
        warpBy(4);
        // User had 7 seconds paying 12 per second
        changeBalance(user, 16, 0);
        warpToCycleEnd();
        // Receiver1 had 3 seconds paying 6 per second and 4 seconds paying 4 per second
        collectAll(receiver1, 34);
        // Receiver2 had 3 seconds paying 6 per second and 4 seconds paying 8 per second
        collectAll(receiver2, 50);
    }

    function testAllowsRemovingReceiversWhileDripping() public {
        setDrips(user, 0, 100, dripsReceivers(receiver1, 5, receiver2, 5));
        warpBy(3);
        setDrips(user, 70, 70, dripsReceivers(receiver2, 10));
        warpBy(4);
        setDrips(user, 30, 30, dripsReceivers());
        warpBy(10);
        // User had 7 seconds paying 10 per second
        changeBalance(user, 30, 0);
        warpToCycleEnd();
        // Receiver1 had 3 seconds paying 5 per second
        collectAll(receiver1, 15);
        // Receiver2 had 3 seconds paying 5 per second and 4 seconds paying 10 per second
        collectAll(receiver2, 55);
    }

    function testLimitsTheTotalReceiversCount() public {
        uint160 countMax = dripsHub.maxDripsReceivers();
        DripsReceiver[] memory receiversGood = new DripsReceiver[](countMax);
        DripsReceiver[] memory receiversBad = new DripsReceiver[](countMax + 1);
        for (uint160 i = 0; i < countMax; i++) {
            receiversGood[i] = DripsReceiver(i, 1, 0, 0);
            receiversBad[i] = receiversGood[i];
        }
        receiversBad[countMax] = DripsReceiver(countMax, 1, 0, 0);

        setDrips(user, 0, 0, receiversGood);
        assertSetReceiversReverts(user, receiversBad, "Too many drips receivers");
    }

    function testRejectsZeroAmtPerSecReceivers() public {
        assertSetReceiversReverts(
            user,
            dripsReceivers(receiver, 0),
            "Drips receiver amtPerSec is zero"
        );
    }

    function testRejectsUnsortedReceivers() public {
        assertSetReceiversReverts(
            user,
            dripsReceivers(receiver2, 1, receiver1, 1),
            "Receivers not sorted"
        );
    }

    function testRejectsDuplicateReceivers() public {
        assertSetReceiversReverts(
            user,
            dripsReceivers(receiver, 1, receiver, 1),
            "Receivers not sorted"
        );
    }

    function testSetDripsRevertsIfInvalidLastUpdate() public {
        setDrips(user, 0, 0, dripsReceivers(receiver, 1));
        assertSetDripsReverts(
            user,
            uint64(block.timestamp) + 1,
            0,
            dripsReceivers(receiver, 1),
            0,
            dripsReceivers(),
            "Invalid current drips configuration"
        );
    }

    function testSetDripsRevertsIfInvalidLastBalance() public {
        setDrips(user, 0, 1, dripsReceivers(receiver, 1));
        assertSetDripsReverts(
            user,
            uint64(block.timestamp),
            2,
            dripsReceivers(receiver, 1),
            0,
            dripsReceivers(),
            "Invalid current drips configuration"
        );
    }

    function testSetDripsRevertsIfInvalidCurrReceivers() public {
        setDrips(user, 0, 0, dripsReceivers(receiver, 1));
        assertSetDripsReverts(
            user,
            uint64(block.timestamp),
            0,
            dripsReceivers(receiver, 2),
            0,
            dripsReceivers(),
            "Invalid current drips configuration"
        );
    }

    function testAllowsAnAddressToDripAndReceiveIndependently() public {
        setDrips(user, 0, 10, dripsReceivers(user, 10));
        warpBy(1);
        // User had 1 second paying 10 per second
        assertDripsBalance(user, 0);
        warpToCycleEnd();
        // User had 1 second paying 10 per second
        collectAll(user, 10);
    }

    function testAllowsWithdrawalOfMoreThanDripsBalance() public {
        DripsReceiver[] memory receivers = dripsReceivers(receiver, 1);
        setDrips(user, 0, 10, receivers);
        uint64 lastUpdate = uint64(block.timestamp);
        warpBy(4);
        // User had 4 second paying 1 per second
        uint256 expectedBalance = defaultErc20.balanceOf(address(user)) + 6;
        (uint128 newBalance, int128 realBalanceDelta) = user.setDrips(
            defaultErc20,
            lastUpdate,
            10,
            receivers,
            type(int128).min,
            receivers
        );
        storeDrips(user, newBalance, receivers);
        assertEq(newBalance, 0, "Invalid balance");
        assertEq(realBalanceDelta, -6, "Invalid real balance delta");
        assertDripsBalance(user, 0);
        assertBalance(user, expectedBalance);
        warpToCycleEnd();
        // Receiver had 4 seconds paying 1 per second
        collectAll(receiver, 4);
    }

    function testLimitsTheTotalSplitsReceiversCount() public {
        uint160 countMax = dripsHub.maxSplitsReceivers();
        SplitsReceiver[] memory receiversGood = new SplitsReceiver[](countMax);
        SplitsReceiver[] memory receiversBad = new SplitsReceiver[](countMax + 1);
        for (uint160 i = 0; i < countMax; i++) {
            receiversGood[i] = SplitsReceiver(i, 1);
            receiversBad[i] = receiversGood[i];
        }
        receiversBad[countMax] = SplitsReceiver(countMax, 1);

        setSplits(user, receiversGood);
        assertSetSplitsReverts(user, receiversBad, "Too many splits receivers");
    }

    function testRejectsTooHighTotalWeightSplitsReceivers() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setSplits(user, splitsReceivers(receiver, totalWeight));
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, totalWeight + 1),
            "Splits weights sum too high"
        );
    }

    function testRejectsZeroWeightSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, 0),
            "Splits receiver weight is zero"
        );
    }

    function testRejectsUnsortedSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver2, 1, receiver1, 1),
            "Splits receivers not sorted by user ID"
        );
    }

    function testRejectsDuplicateSplitsReceivers() public {
        assertSetSplitsReverts(
            user,
            splitsReceivers(receiver, 1, receiver, 2),
            "Duplicate splits receivers"
        );
    }

    function testCollectAllSplits() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        // Receiver1 had 1 second paying 10 per second of which 10 is split
        collectAll(receiver1, 0, 10);
        // Receiver2 got 10 split from receiver1
        collectAll(receiver2, 10);
    }

    function testUncollectedFundsAreSplitUsingCurrentConfig() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setSplits(user1, splitsReceivers(receiver1, totalWeight));
        setDrips(user2, 0, 5, dripsReceivers(user1, 5));
        warpToCycleEnd();
        give(user2, user1, 5);
        setSplits(user1, splitsReceivers(receiver2, totalWeight));
        // Receiver1 had 1 second paying 5 per second and was given 5 of which 10 is split
        collectAll(user1, 0, 10);
        // Receiver1 wasn't a splits receiver when user1 was collecting
        assertCollectableAll(receiver1, 0);
        // Receiver2 was a splits receiver when user1 was collecting
        collectAll(receiver2, 10);
    }

    function testCollectAllSplitsFundsFromSplits() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        setSplits(receiver2, splitsReceivers(receiver3, totalWeight));
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        assertCollectableAll(receiver3, 0);
        // Receiver1 had 1 second paying 10 per second of which 10 is split
        collectAll(receiver1, 0, 10);
        // Receiver2 got 10 split from receiver1 of which 10 is split
        collectAll(receiver2, 0, 10);
        // Receiver3 got 10 split from receiver2
        collectAll(receiver3, 10);
    }

    function testCollectAllMixesDripsAndSplits() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 5, receiver2, 5));
        setSplits(receiver1, splitsReceivers(receiver2, totalWeight));
        warpToCycleEnd();
        // Receiver2 had 1 second paying 5 per second
        assertCollectableAll(receiver2, 5);
        // Receiver1 had 1 second paying 5 per second
        collectAll(receiver1, 0, 5);
        // Receiver2 had 1 second paying 5 per second and got 5 split from receiver1
        collectAll(receiver2, 10);
    }

    function testCollectAllSplitsFundsBetweenReceiverAndSplits() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setDrips(user, 0, 10, dripsReceivers(receiver1, 10));
        setSplits(
            receiver1,
            splitsReceivers(receiver2, totalWeight / 4, receiver3, totalWeight / 2)
        );
        warpToCycleEnd();
        assertCollectableAll(receiver2, 0);
        assertCollectableAll(receiver3, 0);
        // Receiver1 had 1 second paying 10 per second, of which 3/4 is split, which is 7
        collectAll(receiver1, 3, 7);
        // Receiver2 got 1/3 of 7 split from receiver1, which is 2
        collectAll(receiver2, 2);
        // Receiver3 got 2/3 of 7 split from receiver1, which is 5
        collectAll(receiver3, 5);
    }

    function testCanSplitAllWhenCollectedDoesntSplitEvenly() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setDrips(user, 0, 3, dripsReceivers(receiver1, 3));
        setSplits(
            receiver1,
            splitsReceivers(receiver2, totalWeight / 2, receiver3, totalWeight / 2)
        );
        warpToCycleEnd();
        // Receiver1 had 1 second paying 3 per second of which 3 is split
        collectAll(receiver1, 0, 3);
        // Receiver2 got 1 split from receiver
        collectAll(receiver2, 1);
        // Receiver3 got 2 split from receiver
        collectAll(receiver3, 2);
    }

    function testReceiveSomeDripsCycles() public {
        // Enough for 3 cycles
        uint128 amt = dripsHub.cycleSecs() * 3;
        warpToCycleEnd();
        setDrips(user, 0, amt, dripsReceivers(receiver, 1));
        warpToCycleEnd();
        warpToCycleEnd();
        warpToCycleEnd();
        receiveDrips({
            user: receiver,
            maxCycles: 2,
            expectedReceivedAmt: dripsHub.cycleSecs() * 2,
            expectedReceivedCycles: 2,
            expectedAmtAfter: dripsHub.cycleSecs(),
            expectedCyclesAfter: 1
        });
        collectAll(receiver, amt);
    }

    function testReceiveAllDripsCycles() public {
        // Enough for 3 cycles
        uint128 amt = dripsHub.cycleSecs() * 3;
        warpToCycleEnd();
        setDrips(user, 0, amt, dripsReceivers(receiver, 1));
        warpToCycleEnd();
        warpToCycleEnd();
        warpToCycleEnd();

        receiveDrips(receiver, dripsHub.cycleSecs() * 3, 3);

        collectAll(receiver, amt);
    }

    function testFundsGivenFromUserCanBeCollected() public {
        give(user, receiver, 10);
        collectAll(receiver, 10);
    }

    function testSplitSplitsFundsReceivedFromAllSources() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();

        // Gives
        give(user2, user1, 1);

        // Drips
        setDrips(user2, 0, 2, dripsReceivers(user1, 2));
        warpToCycleEnd();
        receiveDrips(user1, 2, 1);

        // Splits
        setSplits(receiver2, splitsReceivers(user1, totalWeight));
        give(receiver2, receiver2, 5);
        split(receiver2, 0, 5);

        // Split the received 1 + 2 + 5 = 8
        setSplits(user1, splitsReceivers(receiver1, totalWeight / 4));
        split(user1, 6, 2);
        collect(user1, 6);
    }

    function testSplitRevertsIfInvalidCurrSplitsReceivers() public {
        setSplits(user, splitsReceivers(receiver, 1));
        try dripsHub.split(user.userId(), defaultErc20, splitsReceivers(receiver, 2)) {
            assertTrue(false, "Split hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Invalid current splits receivers", "Invalid split revert reason");
        }
    }

    function testSplittingSplitsAllFundsEvenWhenTheyDontDivideEvenly() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setSplits(
            user,
            splitsReceivers(receiver1, (totalWeight / 5) * 2, receiver2, totalWeight / 5)
        );
        give(user, user, 9);
        // user gets 40% of 9, receiver1 40 % and receiver2 20%
        split(user, 4, 5);
        collectAll(receiver1, 3);
        collectAll(receiver2, 2);
    }

    function testUserCanSplitToThemselves() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        // receiver1 receives 30%, gets 50% split to themselves and receiver2 gets split 20%
        setSplits(
            receiver1,
            splitsReceivers(receiver1, totalWeight / 2, receiver2, totalWeight / 5)
        );
        give(receiver1, receiver1, 20);

        // Splitting 20
        (uint128 collectableAmt, uint128 splitAmt) = dripsHub.split(
            receiver1.userId(),
            defaultErc20,
            getCurrSplitsReceivers(receiver1)
        );
        assertEq(collectableAmt, 6, "Invalid collectable amount");
        assertEq(splitAmt, 14, "Invalid split amount");
        assertSplittable(receiver1, 10);
        collect(receiver1, 6);
        collectAll(receiver2, 4);

        // Splitting 10 which has been split to receiver1 themselves in the previous step
        (collectableAmt, splitAmt) = dripsHub.split(
            receiver1.userId(),
            defaultErc20,
            getCurrSplitsReceivers(receiver1)
        );
        assertEq(collectableAmt, 3, "Invalid collectable amount");
        assertEq(splitAmt, 7, "Invalid split amount");
        assertSplittable(receiver1, 5);
        collect(receiver1, 3);
        collectAll(receiver2, 2);
    }

    function testUserCanDripToThemselves() public {
        uint128 amt = dripsHub.cycleSecs() * 3;
        warpToCycleEnd();
        setDrips(receiver1, 0, amt, dripsReceivers(receiver1, 1, receiver2, 2));
        warpToCycleEnd();
        receiveDrips(receiver1, dripsHub.cycleSecs(), 1);
        receiveDrips(receiver2, dripsHub.cycleSecs() * 2, 1);
    }

    function testCreateAccount() public {
        address owner = address(0x1234);
        uint32 accountId = dripsHub.nextAccountId();
        assertEq(address(0), dripsHub.accountOwner(accountId), "Invalid nonexistent account owner");
        assertEq(accountId, dripsHub.createAccount(owner), "Invalid assigned account ID");
        assertEq(owner, dripsHub.accountOwner(accountId), "Invalid account owner");
        assertEq(accountId + 1, dripsHub.nextAccountId(), "Invalid next account ID");
    }

    function testTransferAccount() public {
        uint32 accountId = dripsHub.createAccount(address(this));
        assertEq(address(this), dripsHub.accountOwner(accountId), "Invalid account owner before");
        address newOwner = address(0x1234);
        dripsHub.transferAccount(accountId, newOwner);
        assertEq(newOwner, dripsHub.accountOwner(accountId), "Invalid account owner after");
    }

    function testTransferAccountRevertsWhenNotAccountOwner() public {
        uint32 accountId = dripsHub.createAccount(address(0x1234));
        try dripsHub.transferAccount(accountId, address(0x5678)) {
            assertTrue(false, "TransferAccount hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid collect revert reason");
        }
    }

    function testCollectRevertsWhenNotAccountOwner() public {
        try dripsHub.collect(calcUserId(dripsHub.nextAccountId(), 0), defaultErc20) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid collect revert reason");
        }
    }

    function testCollectAllRevertsWhenNotAccountOwner() public {
        try
            dripsHub.collectAll(
                calcUserId(dripsHub.nextAccountId(), 0),
                defaultErc20,
                new SplitsReceiver[](0)
            )
        {
            assertTrue(false, "CollectAll hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid collectAll revert reason");
        }
    }

    function testDripsInDifferentTokensAreIndependent() public {
        uint64 cycleLength = dripsHub.cycleSecs();
        // Covers 1.5 cycles of dripping
        setDrips(
            defaultErc20,
            user,
            0,
            9 * cycleLength,
            dripsReceivers(receiver1, 4, receiver2, 2)
        );

        warpToCycleEnd();
        // Covers 2 cycles of dripping
        setDrips(otherErc20, user, 0, 6 * cycleLength, dripsReceivers(receiver1, 3));

        warpToCycleEnd();
        // receiver1 had 1.5 cycles of 4 per second
        collectAll(defaultErc20, receiver1, 6 * cycleLength);
        // receiver1 had 1.5 cycles of 2 per second
        collectAll(defaultErc20, receiver2, 3 * cycleLength);
        // receiver1 had 1 cycle of 3 per second
        collectAll(otherErc20, receiver1, 3 * cycleLength);
        // receiver2 received nothing
        collectAll(otherErc20, receiver2, 0);

        warpToCycleEnd();
        // receiver1 received nothing
        collectAll(defaultErc20, receiver1, 0);
        // receiver2 received nothing
        collectAll(defaultErc20, receiver2, 0);
        // receiver1 had 1 cycle of 3 per second
        collectAll(otherErc20, receiver1, 3 * cycleLength);
        // receiver2 received nothing
        collectAll(otherErc20, receiver2, 0);
    }

    function testSplitsConfigurationIsCommonBetweenTokens() public {
        uint32 totalWeight = dripsHub.totalSplitsWeight();
        setSplits(user, splitsReceivers(receiver1, totalWeight / 10));
        give(defaultErc20, receiver2, user, 30);
        give(otherErc20, receiver2, user, 100);
        collectAll(defaultErc20, user, 27, 3);
        collectAll(otherErc20, user, 90, 10);
        collectAll(defaultErc20, receiver1, 3);
        collectAll(otherErc20, receiver1, 10);
    }

    function testSetDripsRevertsWhenNotAccountOwner() public {
        try
            dripsHub.setDrips(
                calcUserId(dripsHub.nextAccountId(), 0),
                defaultErc20,
                0,
                0,
                dripsReceivers(),
                0,
                dripsReceivers()
            )
        {
            assertTrue(false, "SetDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid setDrips revert reason");
        }
    }

    function testGiveRevertsWhenNotAccountOwner() public {
        try dripsHub.give(calcUserId(dripsHub.nextAccountId(), 0), 0, defaultErc20, 1) {
            assertTrue(false, "Give hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid give revert reason");
        }
    }

    function testSetSplitsRevertsWhenNotAccountOwner() public {
        try dripsHub.setSplits(calcUserId(dripsHub.nextAccountId(), 0), splitsReceivers()) {
            assertTrue(false, "SetSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_OWNER, "Invalid setSplits revert reason");
        }
    }

    function testAnyoneCanCollectForAnyoneUsingAddressId() public {
        give(user, receiver1, 5);
        split(receiver1, 5, 0);
        assertCollectable(receiver1, 5);
        uint256 balanceBefore = defaultErc20.balanceOf(address(receiver1));

        uint128 collected = addressId.collect(address(receiver1), defaultErc20);

        assertEq(collected, 5, "Invalid collected amount");
        assertCollectable(receiver1, 0);
        assertBalance(receiver1, balanceBefore + 5);
    }

    function testAnyoneCanCollectAllForAnyoneUsingAddressId() public {
        give(user, receiver1, 5);
        assertCollectableAll(receiver1, 5);
        uint256 balanceBefore = defaultErc20.balanceOf(address(receiver1));

        (uint128 collected, uint128 split) = addressId.collectAll(
            address(receiver1),
            defaultErc20,
            splitsReceivers()
        );

        assertEq(collected, 5, "Invalid collected amount");
        assertEq(split, 0, "Invalid split amount");
        assertCollectableAll(receiver1, 0);
        assertBalance(receiver1, balanceBefore + 5);
    }

    function testAdminCanBeChanged() public {
        assertEq(dripsHub.admin(), address(admin));
        admin.changeAdmin(address(nonAdmin));
        assertEq(dripsHub.admin(), address(nonAdmin));
    }

    function testOnlyAdminCanChangeAdmin() public {
        try nonAdmin.changeAdmin(address(0x1234)) {
            assertTrue(false, "ChangeAdmin hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid changeAdmin revert reason");
        }
    }

    function testContractCanBeUpgraded() public {
        uint64 newCycleLength = dripsHub.cycleSecs() + 1;
        DripsHub newLogic = new DripsHub(newCycleLength, dripsHub.reserve());
        admin.upgradeTo(address(newLogic));
        assertEq(dripsHub.cycleSecs(), newCycleLength, "Invalid new cycle length");
    }

    function testOnlyAdminCanUpgradeContract() public {
        try nonAdmin.upgradeTo(address(0)) {
            assertTrue(false, "ChangeAdmin hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid changeAdmin revert reason");
        }
    }

    function testContractCanBePausedAndUnpaused() public {
        assertTrue(!dripsHub.paused(), "Initially paused");
        admin.pause();
        assertTrue(dripsHub.paused(), "Pausing failed");
        admin.unpause();
        assertTrue(!dripsHub.paused(), "Unpausing failed");
    }

    function testOnlyUnpausedContractCanBePaused() public {
        admin.pause();
        try admin.pause() {
            assertTrue(false, "Pause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid pause revert reason");
        }
    }

    function testOnlyPausedContractCanBeUnpaused() public {
        try admin.unpause() {
            assertTrue(false, "Unpause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, "Contract not paused", "Invalid unpause revert reason");
        }
    }

    function testOnlyAdminCanPause() public {
        try nonAdmin.pause() {
            assertTrue(false, "Pause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid pause revert reason");
        }
    }

    function testOnlyAdminCanUnpause() public {
        admin.pause();
        try nonAdmin.unpause() {
            assertTrue(false, "Unpause hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_NOT_ADMIN, "Invalid unpause revert reason");
        }
    }

    function testCollectAllCanBePaused() public {
        admin.pause();
        try user.collectAll(address(user), defaultErc20, splitsReceivers()) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid collect revert reason");
        }
    }

    function testReceiveDripsCanBePaused() public {
        admin.pause();
        try dripsHub.receiveDrips(user.userId(), defaultErc20, 1) {
            assertTrue(false, "ReceiveDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid receiveDrips revert reason");
        }
    }

    function testSplitCanBePaused() public {
        admin.pause();
        try dripsHub.split(user.userId(), defaultErc20, splitsReceivers()) {
            assertTrue(false, "Split hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid split revert reason");
        }
    }

    function testCollectCanBePaused() public {
        admin.pause();
        try user.collect(address(user), defaultErc20) {
            assertTrue(false, "Collect hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid collect revert reason");
        }
    }

    function testSetDripsCanBePaused() public {
        admin.pause();
        try user.setDrips(defaultErc20, 0, 0, dripsReceivers(), 1, dripsReceivers()) {
            assertTrue(false, "SetDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid setDrips revert reason");
        }
    }

    function testSetDripsFromAccountCanBePaused() public {
        admin.pause();
        try user.setDrips(defaultErc20, 0, 0, dripsReceivers(), 1, dripsReceivers()) {
            assertTrue(false, "SetDrips hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid setDrips revert reason");
        }
    }

    function testGiveCanBePaused() public {
        admin.pause();
        try user.give(0, defaultErc20, 1) {
            assertTrue(false, "Give hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid give revert reason");
        }
    }

    function testSetSplitsCanBePaused() public {
        admin.pause();
        try user.setSplits(splitsReceivers()) {
            assertTrue(false, "SetSplits hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid setSplits revert reason");
        }
    }

    function testCreateAccountCanBePaused() public {
        admin.pause();
        try dripsHub.createAccount(address(0x1234)) {
            assertTrue(false, "CreateAccount hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, ERROR_PAUSED, "Invalid createAccount revert reason");
        }
    }
}
