// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {
    AccountMetadata,
    SplitsReceiver,
    StreamConfigImpl,
    Drips,
    StreamsHistory,
    StreamReceiver
} from "src/Drips.sol";
import {ManagedProxy} from "src/Managed.sol";
import {Test} from "forge-std/Test.sol";
import {
    IERC20,
    ERC20PresetFixedSupply
} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

contract DripsTest is Test {
    Drips internal drips;
    // The ERC-20 token used in all helper functions
    IERC20 internal erc20;
    IERC20 internal defaultErc20;
    IERC20 internal otherErc20;

    mapping(uint256 accountId => mapping(IERC20 => StreamReceiver[])) internal currStreamsReceivers;
    mapping(uint256 accountId => SplitsReceiver[]) internal currSplitsReceivers;

    address internal driver = address(1);
    address internal admin = address(2);

    uint32 internal driverId;

    uint256 internal accountId;
    uint256 internal receiver;
    uint256 internal accountId1;
    uint256 internal receiver1;
    uint256 internal accountId2;
    uint256 internal receiver2;
    uint256 internal receiver3;

    bytes internal constant ERROR_NOT_DRIVER = "Callable only by the driver";
    bytes internal constant ERROR_BALANCE_TOO_HIGH = "Total balance too high";
    bytes internal constant ERROR_ERC_20_BALANCE_TOO_LOW = "Token balance too low";

    function setUp() public {
        defaultErc20 = new ERC20PresetFixedSupply("default", "default", 2 ** 128, address(this));
        otherErc20 = new ERC20PresetFixedSupply("other", "other", 2 ** 128, address(this));
        erc20 = defaultErc20;
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, admin, "")));

        driverId = drips.registerDriver(driver);
        uint256 baseAccountId = driverId << 224;
        accountId = baseAccountId + 1;
        accountId1 = baseAccountId + 2;
        accountId2 = baseAccountId + 3;
        receiver = baseAccountId + 4;
        receiver1 = baseAccountId + 5;
        receiver2 = baseAccountId + 6;
        receiver3 = baseAccountId + 7;
    }

    function skipToCycleEnd() internal {
        skip(drips.cycleSecs() - (block.timestamp % drips.cycleSecs()));
    }

    function loadStreams(uint256 forAccount)
        internal
        returns (StreamReceiver[] memory currReceivers)
    {
        currReceivers = currStreamsReceivers[forAccount][erc20];
        assertStreams(forAccount, currReceivers);
    }

    function storeStreams(uint256 forAccount, StreamReceiver[] memory newReceivers) internal {
        assertStreams(forAccount, newReceivers);
        delete currStreamsReceivers[forAccount][erc20];
        for (uint256 i = 0; i < newReceivers.length; i++) {
            currStreamsReceivers[forAccount][erc20].push(newReceivers[i]);
        }
    }

    function loadSplits(uint256 forAccount) internal returns (SplitsReceiver[] memory currSplits) {
        currSplits = currSplitsReceivers[forAccount];
        assertSplits(forAccount, currSplits);
    }

    function storeSplits(uint256 forAccount, SplitsReceiver[] memory newReceivers) internal {
        assertSplits(forAccount, newReceivers);
        delete currSplitsReceivers[forAccount];
        for (uint256 i = 0; i < newReceivers.length; i++) {
            currSplitsReceivers[forAccount].push(newReceivers[i]);
        }
    }

    function streamsReceivers() internal pure returns (StreamReceiver[] memory list) {
        list = new StreamReceiver[](0);
    }

    function streamsReceivers(uint256 streamReceiver, uint128 amtPerSec)
        internal
        view
        returns (StreamReceiver[] memory list)
    {
        list = new StreamReceiver[](1);
        list[0] = StreamReceiver(
            streamReceiver,
            StreamConfigImpl.create(0, uint160(amtPerSec * drips.AMT_PER_SEC_MULTIPLIER()), 0, 0)
        );
    }

    function streamsReceivers(
        uint256 streamReceiver1,
        uint128 amtPerSec1,
        uint256 streamReceiver2,
        uint128 amtPerSec2
    ) internal view returns (StreamReceiver[] memory list) {
        list = new StreamReceiver[](2);
        list[0] = streamsReceivers(streamReceiver1, amtPerSec1)[0];
        list[1] = streamsReceivers(streamReceiver2, amtPerSec2)[0];
    }

    function setStreams(
        uint256 forAccount,
        uint128 balanceFrom,
        uint128 balanceTo,
        StreamReceiver[] memory newReceivers
    ) internal {
        int128 balanceDelta = int128(balanceTo) - int128(balanceFrom);
        uint256 ownBalanceBefore = ownBalance();
        uint256 dripsBalanceBefore = dripsBalance();
        (uint256 streamsBalanceBefore, uint256 splitsBalanceBefore) = balances();
        StreamReceiver[] memory currReceivers = loadStreams(forAccount);

        if (balanceDelta > 0) transferToDrips(uint128(balanceDelta));
        vm.prank(driver);
        int128 realBalanceDelta =
            drips.setStreams(forAccount, erc20, currReceivers, balanceDelta, newReceivers, 0, 0);
        if (balanceDelta < 0) withdraw(uint128(-balanceDelta));

        storeStreams(forAccount, newReceivers);
        assertEq(realBalanceDelta, balanceDelta, "Invalid real balance delta");
        (,, uint32 updateTime, uint128 actualBalance,) = drips.streamsState(forAccount, erc20);
        assertEq(updateTime, block.timestamp, "Invalid new last update time");
        assertEq(balanceTo, actualBalance, "Invalid streams balance");
        assertOwnBalance(uint256(int256(ownBalanceBefore) - balanceDelta));
        assertDripsBalance(uint256(int256(dripsBalanceBefore) + balanceDelta));
        assertBalances(uint256(int256(streamsBalanceBefore) + balanceDelta), splitsBalanceBefore);
    }

    function assertStreams(uint256 forAccount, StreamReceiver[] memory currReceivers) internal {
        (bytes32 actual,,,,) = drips.streamsState(forAccount, erc20);
        bytes32 expected = drips.hashStreams(currReceivers);
        assertEq(actual, expected, "Invalid streams configuration");
    }

    function give(uint256 fromAccount, uint256 toAccount, uint128 amt) internal {
        uint256 ownBalanceBefore = ownBalance();
        uint256 dripsBalanceBefore = dripsBalance();
        (uint256 streamsBalanceBefore, uint256 splitsBalanceBefore) = balances();
        uint128 expectedSplittable = splittable(toAccount) + amt;

        transferToDrips(amt);
        vm.prank(driver);
        drips.give(fromAccount, toAccount, erc20, amt);

        assertOwnBalance(ownBalanceBefore - amt);
        assertDripsBalance(dripsBalanceBefore + amt);
        assertBalances(streamsBalanceBefore, splitsBalanceBefore + amt);
        assertSplittable(toAccount, expectedSplittable);
    }

    function assertGiveReverts(
        uint256 fromAccount,
        uint256 toAccount,
        uint128 amt,
        bytes memory expectedReason
    ) internal {
        vm.prank(driver);
        vm.expectRevert(expectedReason);
        drips.give(fromAccount, toAccount, erc20, amt);
    }

    function splitsReceivers() internal pure returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](0);
    }

    function splitsReceivers(uint256 splitsReceiver, uint32 weight)
        internal
        pure
        returns (SplitsReceiver[] memory list)
    {
        list = new SplitsReceiver[](1);
        list[0] = SplitsReceiver(splitsReceiver, weight);
    }

    function splitsReceivers(
        uint256 splitsReceiver1,
        uint32 weight1,
        uint256 splitsReceiver2,
        uint32 weight2
    ) internal pure returns (SplitsReceiver[] memory list) {
        list = new SplitsReceiver[](2);
        list[0] = SplitsReceiver(splitsReceiver1, weight1);
        list[1] = SplitsReceiver(splitsReceiver2, weight2);
    }

    function setSplits(uint256 forAccount, SplitsReceiver[] memory newReceivers) internal {
        SplitsReceiver[] memory curr = loadSplits(forAccount);
        assertSplits(forAccount, curr);

        vm.prank(driver);
        drips.setSplits(forAccount, newReceivers);

        storeSplits(forAccount, newReceivers);
        assertSplits(forAccount, newReceivers);
    }

    function assertSplits(uint256 forAccount, SplitsReceiver[] memory expectedReceivers) internal {
        bytes32 actual = drips.splitsHash(forAccount);
        bytes32 expected = drips.hashSplits(expectedReceivers);
        assertEq(actual, expected, "Invalid splits hash");
    }

    function collectAll(uint256 forAccount, uint128 expectedAmt) internal {
        collectAll(forAccount, expectedAmt, 0);
    }

    function collectAll(uint256 forAccount, uint128 expectedCollected, uint128 expectedSplit)
        internal
    {
        uint128 receivable = drips.receiveStreamsResult(forAccount, erc20, type(uint32).max);
        uint32 receivableCycles = drips.receivableStreamsCycles(forAccount, erc20);
        receiveStreams(forAccount, receivable, receivableCycles);

        split(forAccount, expectedCollected - collectable(forAccount), expectedSplit);

        collect(forAccount, expectedCollected);
    }

    function receiveStreams(
        uint256 forAccount,
        uint128 expectedReceivedAmt,
        uint32 expectedReceivedCycles
    ) internal {
        receiveStreams(
            forAccount, type(uint32).max, expectedReceivedAmt, expectedReceivedCycles, 0, 0
        );
    }

    function receiveStreams(
        uint256 forAccount,
        uint32 maxCycles,
        uint128 expectedReceivedAmt,
        uint32 expectedReceivedCycles,
        uint128 expectedAmtAfter,
        uint32 expectedCyclesAfter
    ) internal {
        uint128 expectedTotalAmt = expectedReceivedAmt + expectedAmtAfter;
        uint32 expectedTotalCycles = expectedReceivedCycles + expectedCyclesAfter;
        assertReceivableStreamsCycles(forAccount, expectedTotalCycles);
        assertReceiveStreamsResult(forAccount, type(uint32).max, expectedTotalAmt);
        assertReceiveStreamsResult(forAccount, maxCycles, expectedReceivedAmt);

        uint128 receivedAmt = drips.receiveStreams(forAccount, erc20, maxCycles);

        assertEq(receivedAmt, expectedReceivedAmt, "Invalid amount received from streams");
        assertReceivableStreamsCycles(forAccount, expectedCyclesAfter);
        assertReceiveStreamsResult(forAccount, type(uint32).max, expectedAmtAfter);
    }

    function assertReceivableStreamsCycles(uint256 forAccount, uint32 expectedCycles) internal {
        uint32 actualCycles = drips.receivableStreamsCycles(forAccount, erc20);
        assertEq(actualCycles, expectedCycles, "Invalid total receivable streams cycles");
    }

    function assertReceiveStreamsResult(uint256 forAccount, uint32 maxCycles, uint128 expectedAmt)
        internal
    {
        uint128 actualAmt = drips.receiveStreamsResult(forAccount, erc20, maxCycles);
        assertEq(actualAmt, expectedAmt, "Invalid receivable amount");
    }

    function split(uint256 forAccount, uint128 expectedCollectable, uint128 expectedSplit)
        internal
    {
        assertSplittable(forAccount, expectedCollectable + expectedSplit);
        assertSplitResult(forAccount, expectedCollectable + expectedSplit, expectedCollectable);
        uint128 collectableBefore = collectable(forAccount);

        (uint128 collectableAmt, uint128 splitAmt) =
            drips.split(forAccount, erc20, loadSplits(forAccount));

        assertEq(collectableAmt, expectedCollectable, "Invalid collectable amount");
        assertEq(splitAmt, expectedSplit, "Invalid split amount");
        assertSplittable(forAccount, 0);
        assertCollectable(forAccount, collectableBefore + expectedCollectable);
    }

    function splittable(uint256 forAccount) internal view returns (uint128 amt) {
        return drips.splittable(forAccount, erc20);
    }

    function assertSplittable(uint256 forAccount, uint256 expected) internal {
        uint128 actual = splittable(forAccount);
        assertEq(actual, expected, "Invalid splittable");
    }

    function assertSplitResult(uint256 forAccount, uint256 amt, uint256 expected) internal {
        (uint128 collectableAmt, uint128 splitAmt) =
            drips.splitResult(forAccount, loadSplits(forAccount), uint128(amt));
        assertEq(collectableAmt, expected, "Invalid collectable amount");
        assertEq(splitAmt, amt - expected, "Invalid split amount");
    }

    function collect(uint256 forAccount, uint128 expectedAmt) internal {
        assertCollectable(forAccount, expectedAmt);
        uint256 ownBalanceBefore = ownBalance();
        uint256 dripsBalanceBefore = dripsBalance();
        (uint256 streamsBalanceBefore, uint256 splitsBalanceBefore) = balances();

        vm.prank(driver);
        uint128 actualAmt = drips.collect(forAccount, erc20);
        withdraw(actualAmt);

        assertEq(actualAmt, expectedAmt, "Invalid collected amount");
        assertCollectable(forAccount, 0);
        assertOwnBalance(ownBalanceBefore + expectedAmt);
        assertDripsBalance(dripsBalanceBefore - expectedAmt);
        assertBalances(streamsBalanceBefore, splitsBalanceBefore - expectedAmt);
    }

    function collectable(uint256 forAccount) internal view returns (uint128 amt) {
        return drips.collectable(forAccount, erc20);
    }

    function assertCollectable(uint256 forAccount, uint256 expected) internal {
        assertEq(collectable(forAccount), expected, "Invalid collectable");
    }

    function balances() internal view returns (uint256 streamsBalance, uint256 splitsBalance) {
        return drips.balances(erc20);
    }

    function assertBalances(uint256 expectedStreamsBalance, uint256 expectedSplitsBalance)
        internal
    {
        (uint256 streamsBalance, uint256 splitsBalance) = balances();
        assertEq(streamsBalance, expectedStreamsBalance, "Invalid streams balance");
        assertEq(splitsBalance, expectedSplitsBalance, "Invalid splits balance");
    }

    function transferToDrips(uint256 amt) internal {
        (uint256 streamsBalance, uint256 splitsBalance) = balances();
        assertDripsBalance(streamsBalance + splitsBalance);
        erc20.transfer(address(drips), amt);
    }

    function withdraw(uint256 amt) internal {
        uint256 ownBalanceBefore = ownBalance();
        (uint256 streamsBalance, uint256 splitsBalance) = balances();
        assertDripsBalance(streamsBalance + splitsBalance + amt);

        drips.withdraw(erc20, address(this), amt);

        assertOwnBalance(ownBalanceBefore + amt);
        assertDripsBalance(streamsBalance + splitsBalance);
        assertBalances(streamsBalance, splitsBalance);
    }

    function ownBalance() internal view returns (uint256) {
        return erc20.balanceOf(address(this));
    }

    function assertOwnBalance(uint256 expected) internal {
        assertEq(ownBalance(), expected, "Invalid own balance");
    }

    function dripsBalance() internal view returns (uint256) {
        return erc20.balanceOf(address(drips));
    }

    function assertDripsBalance(uint256 expected) internal {
        assertEq(dripsBalance(), expected, "Invalid Drips balance");
    }

    function testDoesNotRequireReceiverToBeInitialized() public {
        receiveStreams(receiver, 0, 0);
        split(receiver, 0, 0);
        collect(receiver, 0);
    }

    function testSetStreamsLimitsWithdrawalToStreamsBalance() public {
        uint128 streamsBalance = 10;
        StreamReceiver[] memory receivers = streamsReceivers();
        uint256 ownBalanceBefore = ownBalance();
        setStreams(accountId, 0, streamsBalance, receivers);

        vm.prank(driver);
        int128 realBalanceDelta = drips.setStreams(
            accountId, erc20, receivers, -int128(streamsBalance) - 1, receivers, 0, 0
        );
        withdraw(uint128(-realBalanceDelta));

        assertEq(realBalanceDelta, -int128(streamsBalance), "Invalid real balance delta");
        (,,, uint128 actualBalance,) = drips.streamsState(accountId, erc20);
        assertEq(actualBalance, 0, "Invalid streams balance");
        assertOwnBalance(ownBalanceBefore);
        assertDripsBalance(0);
        assertBalances(0, 0);
    }

    function testUncollectedFundsAreSplitUsingCurrentConfig() public {
        uint32 totalWeight = drips.TOTAL_SPLITS_WEIGHT();
        setSplits(accountId1, splitsReceivers(receiver1, totalWeight));
        setStreams(accountId2, 0, 5, streamsReceivers(accountId1, 5));
        skipToCycleEnd();
        give(accountId2, accountId1, 5);
        setSplits(accountId1, splitsReceivers(receiver2, totalWeight));
        // Receiver1 had 1 second paying 5 per second and was given 5 of which 10 is split
        collectAll(accountId1, 0, 10);
        // Receiver1 wasn't a splits receiver when accountId1 was collecting
        collectAll(receiver1, 0);
        // Receiver2 was a splits receiver when accountId1 was collecting
        collectAll(receiver2, 10);
    }

    function testReceiveSomeStreamsCycles() public {
        // Enough for 3 cycles
        uint128 amt = drips.cycleSecs() * 3;
        skipToCycleEnd();
        setStreams(accountId, 0, amt, streamsReceivers(receiver, 1));
        skipToCycleEnd();
        skipToCycleEnd();
        skipToCycleEnd();
        receiveStreams({
            forAccount: receiver,
            maxCycles: 2,
            expectedReceivedAmt: drips.cycleSecs() * 2,
            expectedReceivedCycles: 2,
            expectedAmtAfter: drips.cycleSecs(),
            expectedCyclesAfter: 1
        });
        collectAll(receiver, amt);
    }

    function testReceiveAllStreamsCycles() public {
        // Enough for 3 cycles
        uint128 amt = drips.cycleSecs() * 3;
        skipToCycleEnd();
        setStreams(accountId, 0, amt, streamsReceivers(receiver, 1));
        skipToCycleEnd();
        skipToCycleEnd();
        skipToCycleEnd();

        receiveStreams(receiver, drips.cycleSecs() * 3, 3);

        collectAll(receiver, amt);
    }

    function testSqueezeStreams() public {
        skipToCycleEnd();
        // Start streaming
        StreamReceiver[] memory receivers = streamsReceivers(receiver, 1);
        setStreams(accountId, 0, 2, receivers);

        // Create history
        uint32 lastUpdate = uint32(block.timestamp);
        uint32 maxEnd = lastUpdate + 2;
        StreamsHistory[] memory history = new StreamsHistory[](1);
        history[0] = StreamsHistory(0, receivers, lastUpdate, maxEnd);
        bytes32 actualHistoryHash =
            drips.hashStreamsHistory(bytes32(0), drips.hashStreams(receivers), lastUpdate, maxEnd);
        (, bytes32 expectedHistoryHash,,,) = drips.streamsState(accountId, erc20);
        assertEq(actualHistoryHash, expectedHistoryHash, "Invalid history hash");

        // Check squeezable streams
        skip(1);
        uint128 amt = drips.squeezeStreamsResult(receiver, erc20, accountId, 0, history);
        assertEq(amt, 1, "Invalid squeezable amt before");

        // Squeeze
        vm.prank(driver);
        amt = drips.squeezeStreams(receiver, erc20, accountId, 0, history);
        assertEq(amt, 1, "Invalid squeezed amt");

        // Check squeezable streams
        amt = drips.squeezeStreamsResult(receiver, erc20, accountId, 0, history);
        assertEq(amt, 0, "Invalid squeezable amt after");

        // Collect the squeezed amount
        split(receiver, 1, 0);
        collect(receiver, 1);
        skipToCycleEnd();
        collectAll(receiver, 1);
    }

    function testFundsGivenFromAccountCanBeCollected() public {
        give(accountId, receiver, 10);
        collectAll(receiver, 10);
    }

    function testSplitSplitsFundsReceivedFromAllSources() public {
        uint32 totalWeight = drips.TOTAL_SPLITS_WEIGHT();
        // Gives
        give(accountId2, accountId1, 1);

        // Streams
        setStreams(accountId2, 0, 2, streamsReceivers(accountId1, 2));
        skipToCycleEnd();
        receiveStreams(accountId1, 2, 1);

        // Splits
        setSplits(receiver2, splitsReceivers(accountId1, totalWeight));
        give(receiver2, receiver2, 5);
        split(receiver2, 0, 5);

        // Split the received 1 + 2 + 5 = 8
        setSplits(accountId1, splitsReceivers(receiver1, totalWeight / 4));
        split(accountId1, 6, 2);
        collect(accountId1, 6);
    }

    function testEmitAccountMetadata() public {
        AccountMetadata[] memory accountMetadata = new AccountMetadata[](2);
        accountMetadata[0] = AccountMetadata("key 1", "value 1");
        accountMetadata[1] = AccountMetadata("key 2", "value 2");
        vm.prank(driver);
        drips.emitAccountMetadata(accountId, accountMetadata);
    }

    function testBalanceAt() public {
        StreamReceiver[] memory receivers = streamsReceivers(receiver, 1);
        setStreams(accountId, 0, 2, receivers);
        uint256 balanceAt =
            drips.balanceAt(accountId, erc20, receivers, uint32(block.timestamp + 1));
        assertEq(balanceAt, 1, "Invalid balance");
    }

    function testRegisterDriver() public {
        address driverAddr = address(0x1234);
        uint32 nextDriverId = drips.nextDriverId();
        assertEq(address(0), drips.driverAddress(nextDriverId), "Invalid unused driver address");
        assertEq(nextDriverId, drips.registerDriver(driverAddr), "Invalid assigned driver ID");
        assertEq(driverAddr, drips.driverAddress(nextDriverId), "Invalid driver address");
        assertEq(nextDriverId + 1, drips.nextDriverId(), "Invalid next driver ID");
    }

    function testRegisteringDriverForZeroAddressReverts() public {
        vm.expectRevert("Driver registered for 0 address");
        drips.registerDriver(address(0));
    }

    function testUpdateDriverAddress() public {
        assertEq(driver, drips.driverAddress(driverId), "Invalid driver address before");
        address newDriverAddr = address(0x1234);
        vm.prank(driver);
        drips.updateDriverAddress(driverId, newDriverAddr);
        assertEq(newDriverAddr, drips.driverAddress(driverId), "Invalid driver address after");
    }

    function testUpdateDriverAddressRevertsWhenNotCalledByTheDriver() public {
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.updateDriverAddress(driverId, address(1234));
    }

    function testCollectRevertsWhenNotCalledByTheDriver() public {
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.collect(accountId, erc20);
    }

    function testStreamsInDifferentTokensAreIndependent() public {
        uint32 cycleLength = drips.cycleSecs();
        // Covers 1.5 cycles of streaming
        erc20 = defaultErc20;
        setStreams(accountId, 0, 9 * cycleLength, streamsReceivers(receiver1, 4, receiver2, 2));

        skipToCycleEnd();
        // Covers 2 cycles of streaming
        erc20 = otherErc20;
        setStreams(accountId, 0, 6 * cycleLength, streamsReceivers(receiver1, 3));

        skipToCycleEnd();
        // receiver1 had 1.5 cycles of 4 per second
        erc20 = defaultErc20;
        collectAll(receiver1, 6 * cycleLength);
        // receiver1 had 1.5 cycles of 2 per second
        erc20 = defaultErc20;
        collectAll(receiver2, 3 * cycleLength);
        // receiver1 had 1 cycle of 3 per second
        erc20 = otherErc20;
        collectAll(receiver1, 3 * cycleLength);
        // receiver2 received nothing
        erc20 = otherErc20;
        collectAll(receiver2, 0);

        skipToCycleEnd();
        // receiver1 received nothing
        erc20 = defaultErc20;
        collectAll(receiver1, 0);
        // receiver2 received nothing
        erc20 = defaultErc20;
        collectAll(receiver2, 0);
        // receiver1 had 1 cycle of 3 per second
        erc20 = otherErc20;
        collectAll(receiver1, 3 * cycleLength);
        // receiver2 received nothing
        erc20 = otherErc20;
        collectAll(receiver2, 0);
    }

    function testSetStreamsRevertsWhenNotCalledByTheDriver() public {
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.setStreams(accountId, erc20, streamsReceivers(), 0, streamsReceivers(), 0, 0);
    }

    function testGiveRevertsWhenNotCalledByTheDriver() public {
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.give(accountId, 0, erc20, 1);
    }

    function testSetSplitsRevertsWhenNotCalledByTheDriver() public {
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.setSplits(accountId, splitsReceivers());
    }

    function testEmitAccountMetadataRevertsWhenNotCalledByTheDriver() public {
        AccountMetadata[] memory accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
        vm.expectRevert(ERROR_NOT_DRIVER);
        drips.emitAccountMetadata(accountId, accountMetadata);
    }

    function testSetStreamsLimitsTotalBalance() public {
        uint128 splitsBalance = uint128(drips.MAX_TOTAL_BALANCE()) / 10;
        give(accountId, receiver, splitsBalance);
        uint128 maxBalance = uint128(drips.MAX_TOTAL_BALANCE()) - splitsBalance;
        assertBalances(0, splitsBalance);
        setStreams(accountId1, 0, maxBalance, streamsReceivers());
        assertBalances(maxBalance, splitsBalance);

        transferToDrips(1);
        vm.prank(driver);
        vm.expectRevert(ERROR_BALANCE_TOO_HIGH);
        drips.setStreams(accountId2, erc20, streamsReceivers(), 1, streamsReceivers(), 0, 0);
        withdraw(1);

        setStreams(accountId1, maxBalance, maxBalance - 1, streamsReceivers());
        assertBalances(maxBalance - 1, splitsBalance);
        setStreams(accountId2, 0, 1, streamsReceivers());
        assertBalances(maxBalance, splitsBalance);
    }

    function testSetStreamsRequiresTransferredTokens() public {
        setStreams(accountId, 0, 2, streamsReceivers());

        vm.prank(driver);
        vm.expectRevert(ERROR_ERC_20_BALANCE_TOO_LOW);
        drips.setStreams(accountId, erc20, streamsReceivers(), 1, streamsReceivers(), 0, 0);

        setStreams(accountId, 2, 3, streamsReceivers());
    }

    function testGiveLimitsTotalBalance() public {
        uint128 streamsBalance = uint128(drips.MAX_TOTAL_BALANCE()) / 10;
        setStreams(accountId, 0, streamsBalance, streamsReceivers());
        uint128 maxBalance = uint128(drips.MAX_TOTAL_BALANCE()) - streamsBalance;
        assertBalances(streamsBalance, 0);
        give(accountId, receiver1, maxBalance - 1);
        assertBalances(streamsBalance, maxBalance - 1);
        give(accountId, receiver2, 1);
        assertBalances(streamsBalance, maxBalance);

        transferToDrips(1);
        vm.prank(driver);
        vm.expectRevert(ERROR_BALANCE_TOO_HIGH);
        drips.give(accountId, receiver3, erc20, 1);
        withdraw(1);

        collectAll(receiver2, 1);
        assertBalances(streamsBalance, maxBalance - 1);
        give(accountId, receiver3, 1);
        assertBalances(streamsBalance, maxBalance);
    }

    function testGiveRequiresTransferredTokens() public {
        give(accountId, receiver, 2);

        vm.prank(driver);
        vm.expectRevert(ERROR_ERC_20_BALANCE_TOO_LOW);
        drips.give(accountId, receiver, erc20, 1);

        give(accountId, receiver, 1);
    }

    function testWithdrawalBelowTotalBalanceReverts() public {
        setStreams(accountId, 0, 2, streamsReceivers());
        give(accountId, receiver, 2);
        transferToDrips(1);

        vm.expectRevert("Withdrawal amount too high");
        drips.withdraw(erc20, address(this), 2);

        withdraw(1);
    }

    modifier canBePausedTest() {
        vm.prank(admin);
        drips.pause();
        vm.expectRevert("Contract paused");
        _;
    }

    function testReceiveStreamsCanBePaused() public canBePausedTest {
        drips.receiveStreams(accountId, erc20, 1);
    }

    function testSqueezeStreamsCanBePaused() public canBePausedTest {
        drips.squeezeStreams(accountId, erc20, accountId, 0, new StreamsHistory[](0));
    }

    function testSplitCanBePaused() public canBePausedTest {
        drips.split(accountId, erc20, splitsReceivers());
    }

    function testCollectCanBePaused() public canBePausedTest {
        drips.collect(accountId, erc20);
    }

    function testSetStreamsCanBePaused() public canBePausedTest {
        drips.setStreams(accountId, erc20, streamsReceivers(), 1, streamsReceivers(), 0, 0);
    }

    function testGiveCanBePaused() public canBePausedTest {
        drips.give(accountId, 0, erc20, 1);
    }

    function testSetSplitsCanBePaused() public canBePausedTest {
        drips.setSplits(accountId, splitsReceivers());
    }

    function testEmitAccountMetadataCanBePaused() public canBePausedTest {
        drips.emitAccountMetadata(accountId, new AccountMetadata[](0));
    }

    function testRegisterDriverCanBePaused() public canBePausedTest {
        drips.registerDriver(address(0x1234));
    }

    function testUpdateDriverAddressCanBePaused() public canBePausedTest {
        drips.updateDriverAddress(driverId, address(0x1234));
    }
}
