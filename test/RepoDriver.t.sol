// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Caller} from "src/Caller.sol";
import {Forge, GelatoTasksOwner, RepoDriver} from "src/RepoDriver.sol";
import {
    AccountMetadata,
    StreamConfigImpl,
    Drips,
    StreamsHistory,
    StreamReceiver,
    SplitsReceiver
} from "src/Drips.sol";
import {ManagedProxy} from "src/Managed.sol";
import {StdAssertions, Test} from "forge-std/Test.sol";
import {
    IAutomate,
    IGelato,
    IProxyModule,
    Module,
    ModuleData,
    TriggerType
} from "gelato-automate/integrations/Types.sol";
import {IAutomate as IAutomate2} from "gelato-automate/interfaces/IAutomate.sol";
import {
    ERC20,
    IERC20,
    ERC20PresetFixedSupply
} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

address constant GELATO_NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

contract Events {
    event OwnerUpdateRequested(uint256 indexed accountId, Forge forge, bytes name, address payer);
}

contract Automate is StdAssertions, Events {
    /// @dev Used by RepoDriver
    Gelato public immutable gelato = new Gelato();
    ProxyModule public immutable proxyModule = new ProxyModule();
    bytes32[] internal taskIds;
    string internal expectedIpfsCid;
    uint256 internal _feeAmount;
    address internal _feeToken;

    /// @dev Used by RepoDriver
    function taskModuleAddresses(Module module) public returns (address moduleAddress) {
        assertTrue(module == Module.PROXY, "Only proxy module supported");
        return address(proxyModule);
    }

    function assertUserSupported(address user) internal {
        assertEq(user, proxyModule.opsProxyFactory().user(), "Unsupported user");
    }

    /// @dev Used by RepoDriver
    function getTaskIdsByUser(address user) public returns (bytes32[] memory taskIds_) {
        assertUserSupported(user);
        return taskIds;
    }

    function pushTaskId(bytes32 taskId) public {
        taskIds.push(taskId);
    }

    /// @dev Used by RepoDriver
    function cancelTask(bytes32 taskId) public {
        assertUserSupported(msg.sender);
        for (uint256 i = 0; i < taskIds.length; i++) {
            if (taskIds[i] == taskId) {
                taskIds[i] = taskIds[taskIds.length - 1];
                taskIds.pop();
                return;
            }
        }
        assertTrue(false, "Task ID not found");
    }

    function expectIpfsCid(string calldata ipfsCid) public {
        expectedIpfsCid = ipfsCid;
    }

    /// @dev Used by RepoDriver
    function createTask(
        address execAddress,
        bytes calldata execDataOrSelector,
        ModuleData calldata moduleData,
        address feeToken
    ) public returns (bytes32 taskId) {
        assertGe(execDataOrSelector.length, 4, "Exec data too short");

        assertEq(moduleData.modules.length, 3, "Invalid modules length");
        assertEq(moduleData.args.length, 3, "Invalid args length");

        assertTrue(moduleData.modules[0] == Module.PROXY, "Invalid module 0");
        assertEq(moduleData.args[0], "", "Invalid args 0");

        assertTrue(moduleData.modules[1] == Module.WEB3_FUNCTION, "Invalid module 1");
        assertEq(moduleData.args[1], abi.encode(expectedIpfsCid, ""), "Invalid args 1");

        assertTrue(moduleData.modules[2] == Module.TRIGGER, "Invalid module 2");
        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = new bytes32[](1);
        topics[0][0] = OwnerUpdateRequested.selector;
        bytes memory trigger = abi.encode(GelatoTasksOwner(msg.sender).owner(), topics, 1);
        assertEq(moduleData.args[2], abi.encode(TriggerType.EVENT, trigger), "Invalid args 2");

        assertEq(feeToken, GELATO_NATIVE_TOKEN, "Fee token not native");

        assertEq(taskIds.length, 0, "Uncancelled tasks");

        taskId = keccak256(abi.encode(execAddress, execDataOrSelector, moduleData, feeToken));
        taskIds.push(taskId);
    }

    function setFeeDetails(uint256 feeAmount, address feeToken) public {
        _feeAmount = feeAmount;
        _feeToken = feeToken;
    }

    /// @dev Used by RepoDriver
    function getFeeDetails() public view returns (uint256 feeAmount, address feeToken) {
        return (_feeAmount, _feeToken);
    }

    fallback() external {
        assertTrue(false, "Automate function not implemented");
    }
}

contract Gelato is StdAssertions {
    /// @dev Used by RepoDriver
    address public immutable feeCollector = address(bytes20("fee collector"));

    fallback() external {
        assertTrue(false, "Gelato function not implemented");
    }
}

contract ProxyModule is StdAssertions {
    /// @dev Used by RepoDriver
    OpsProxyFactory public immutable opsProxyFactory = new OpsProxyFactory();

    fallback() external {
        assertTrue(false, "ProxyModule function not implemented");
    }
}

contract OpsProxyFactory is StdAssertions {
    address public user;
    address public immutable proxy = address(bytes20("gelato proxy"));
    bool public isDeployed;

    fallback() external {
        assertTrue(false, "OpsProxyFactory function not implemented");
    }

    function assertUserSupported(address user_) public {
        if (user != address(0)) assertEq(user_, user, "Unsupported user");
    }

    /// @dev Used by RepoDriver
    function ownerOf(address proxy_) external returns (address) {
        assertEq(proxy_, proxy, "Invalid proxy address");
        return user;
    }

    /// @dev Used by RepoDriver
    function getProxyOf(address user_) external returns (address, bool) {
        assertUserSupported(user_);
        return (proxy, isDeployed);
    }

    /// @dev Used by RepoDriver
    function deployFor(address user_) external returns (address) {
        assertUserSupported(user_);
        user = user_;
        assertFalse(isDeployed, "Proxy already deployed");
        isDeployed = true;
        return proxy;
    }
}

contract RepoDriverTest is Test, Events {
    Drips internal drips;
    Caller internal caller;
    RepoDriver internal driver;
    IERC20 internal erc20;

    address internal admin = address(1);
    address internal user = address(2);
    uint256 internal accountId;
    uint256 internal accountId1;
    uint256 internal accountId2;
    uint256 internal accountIdUser;
    uint256 internal accountIdUnclaimed;

    bytes internal constant ERROR_NOT_OWNER = "Caller is not the account owner";

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this), "")));

        caller = new Caller();

        address driverAddress =
            vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        Automate automate_ = new Automate();

        // Make RepoDriver's driver ID non-0 to test if it's respected by RepoDriver
        drips.registerDriver(address(1));
        drips.registerDriver(address(1));
        uint32 driverId = drips.registerDriver(driverAddress);

        string memory ipfsCid = "Gelato Function";
        automate_.expectIpfsCid(ipfsCid);
        bytes memory data = abi.encodeCall(RepoDriver.updateGelatoTask, (ipfsCid, 0, 0));

        RepoDriver driverLogic =
            new RepoDriver(drips, address(caller), driverId, IAutomate(address(automate_)));
        driver = RepoDriver(payable(new ManagedProxy(driverLogic, admin, data)));
        require(address(driver) == driverAddress, "Invalid driver address");

        accountId = initialUpdateOwner("this/repo1", address(this));
        accountId1 = initialUpdateOwner("this/repo2", address(this));
        accountId2 = initialUpdateOwner("this/repo3", address(this));
        accountIdUser = initialUpdateOwner("user/repo", user);
        accountIdUnclaimed = driver.calcAccountId(Forge.GitHub, "this/repo");

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
        erc20.transfer(user, erc20.totalSupply() / 100);
        vm.prank(user);
        erc20.approve(address(driver), type(uint256).max);
    }

    function automate() internal view returns (Automate automate_) {
        return Automate(address(driver.gelatoAutomate()));
    }

    function gelatoProxy() internal view returns (address proxy) {
        return automate().proxyModule().opsProxyFactory().proxy();
    }

    function noMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](0);
    }

    function someMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
    }

    function initialUpdateOwner(bytes memory name, address owner)
        internal
        returns (uint256 accountId_)
    {
        accountId_ = driver.calcAccountId(Forge.GitHub, name);
        updateOwnerByGelato(accountId_, owner, address(0));
    }

    function updateOwnerByGelato(uint256 accountId_, address owner, address payer) internal {
        updateOwnerByGelato(accountId_, owner, payer, 0);
    }

    function updateOwnerByGelato(
        uint256 accountId_,
        address owner,
        address payer,
        uint256 feeAmount
    ) internal {
        address feeCollector = automate().gelato().feeCollector();
        automate().setFeeDetails(feeAmount, GELATO_NATIVE_TOKEN);
        uint256 balanceBefore = feeCollector.balance;
        vm.expectCall(address(automate()), bytes.concat(IAutomate.getFeeDetails.selector));
        vm.prank(gelatoProxy());

        driver.updateOwnerByGelato(accountId_, owner, payer);

        assertEq(feeCollector.balance, balanceBefore + feeAmount, "Invalid fee collector balance");
        assertOwner(accountId_, owner);
    }

    function testUpgradeOwnerByGelato() public {
        updateOwnerByGelato(accountIdUnclaimed, user, address(this));
    }

    function testUpgradeOwnerByGelatoPaidByCommonFunds() public {
        Address.sendValue(payable(driver), 3);

        updateOwnerByGelato(accountIdUnclaimed, user, address(this), 2);

        assertCommonFunds(1);
    }

    function testUpgradeOwnerByGelatoPaidByUserFunds() public {
        driver.depositUserFunds{value: 3}(address(this));

        updateOwnerByGelato(accountIdUnclaimed, user, address(this), 2);

        assertUserFunds(address(this), 1);
    }

    function testUpgradeOwnerByGelatoPaidByCommonAndUserFunds() public {
        Address.sendValue(payable(driver), 2);
        driver.depositUserFunds{value: 2}(address(this));

        updateOwnerByGelato(accountIdUnclaimed, user, address(this), 3);

        assertCommonFunds(1);
        assertUserFunds(address(this), 0);
    }

    function testUpgradeOwnerByGelatoRevertsIfNotEnoughFunds() public {
        automate().setFeeDetails(1, GELATO_NATIVE_TOKEN);
        vm.prank(gelatoProxy());
        vm.expectRevert("Not enough funds");
        driver.updateOwnerByGelato(accountIdUnclaimed, user, address(this));
    }

    function testUpgradeOwnerByGelatoRevertsIfFeeNotInNativeTokens() public {
        automate().setFeeDetails(0, address(1));
        vm.prank(gelatoProxy());
        vm.expectRevert("Payment must be in native tokens");
        driver.updateOwnerByGelato(accountIdUnclaimed, user, address(this));
    }

    function testUpgradeOwnerByGelatoRevertsIfNotCalledByProxy() public {
        vm.expectRevert("Callable only by Gelato");
        driver.updateOwnerByGelato(accountIdUnclaimed, user, address(this));
    }

    function testUpgradeOwnerByGelatoRevertsWhenOwnerUnchanged() public {
        updateOwnerByGelato(accountIdUnclaimed, user, address(this));
        vm.prank(gelatoProxy());
        vm.expectRevert("New owner is the same");
        driver.updateOwnerByGelato(accountIdUnclaimed, user, address(this));
    }

    function assertOwner(uint256 accountId_, address expectedOwner) internal {
        assertEq(driver.ownerOf(accountId_), expectedOwner, "Invalid account owner");
    }

    function assertCommonFunds(uint256 expectedAmt) internal {
        assertEq(driver.commonFunds(), expectedAmt, "Invalid common funds amount");
    }

    function assertUserFunds(address user_, uint256 expectedAmt) internal {
        assertEq(driver.userFunds(user_), expectedAmt, "Invalid user funds amount");
    }

    function assertAddressBalance(address user_, uint256 expectedAmt) internal {
        assertEq(user_.balance, expectedAmt, "Invalid address balance");
    }

    function testAccountIdsDoNotCollideBetweenForges() public {
        bytes memory name = "me/repo";
        uint256 accountIdGitHub = driver.calcAccountId(Forge.GitHub, name);
        uint256 accountIdGitLab = driver.calcAccountId(Forge.GitLab, name);
        assertFalse(accountIdGitHub == accountIdGitLab, "Account IDs collide");
    }

    function testCalcAccountId() public {
        bytes memory name3 = "a/b";
        bytes memory name27 = "abcdefghijklm/nopqrstuvwxyz";
        bytes memory name28 = "abcdefghijklm/nopqrstuvwxyz_";

        // The lookup of the hex values for the manual inspection of the test
        assertEq(driver.driverId(), 0x00000002, "Invalid driver ID hex representation");
        assertEq(bytes3(name3), bytes3(0x612f62), "Invalid 3 byte name hex representation");
        assertEq(
            bytes27(name27),
            bytes27(0x6162636465666768696a6b6c6d2f6e6f707172737475767778797a),
            "Invalid 27 byte name hex representation"
        );
        assertEq(
            keccak256(name28),
            0x14ef39e0dc9b20b0f16f6d0e523b42684b6f3881fa3c23115048bc6643c2f866,
            "Invalid 28 byte name hash"
        );

        assertAccountId(
            Forge.GitHub,
            name3,
            0x00000002_00_612f62000000000000000000000000000000000000000000000000
        );
        assertAccountId(
            Forge.GitHub,
            name27,
            0x00000002_00_6162636465666768696a6b6c6d2f6e6f707172737475767778797a
        );
        assertAccountId(
            Forge.GitHub,
            name28,
            0x00000002_01_9b20b0f16f6d0e523b42684b6f3881fa3c23115048bc6643c2f866
        );
        assertAccountId(
            Forge.GitLab,
            name3,
            0x00000002_02_612f62000000000000000000000000000000000000000000000000
        );
        assertAccountId(
            Forge.GitLab,
            name27,
            0x00000002_02_6162636465666768696a6b6c6d2f6e6f707172737475767778797a
        );
        assertAccountId(
            Forge.GitLab,
            name28,
            0x00000002_03_9b20b0f16f6d0e523b42684b6f3881fa3c23115048bc6643c2f866
        );
    }

    function assertAccountId(Forge forge, bytes memory name, uint256 expectedAccountId) internal {
        uint256 actualAccountId = driver.calcAccountId(forge, name);
        assertEq(bytes32(actualAccountId), bytes32(expectedAccountId), "Invalid account ID");
    }

    function testUpdateGelatoTask() public {
        address taskOwner = address(driver.gelatoTasksOwner());
        automate().pushTaskId(hex"1234");
        string memory ipfsCid = "The new Gelato Function";
        automate().expectIpfsCid(ipfsCid);
        vm.expectCall(address(automate()), bytes.concat(Automate.createTask.selector));
        vm.prank(admin);
        driver.updateGelatoTask(ipfsCid, 0, 0);
        assertEq(taskOwner, address(driver.gelatoTasksOwner()), "Task owner changed");
    }

    function testUpdateGelatoTaskRevertsIfNotCalledByAdmin() public {
        string memory ipfsCid = "The new Gelato Function";
        automate().expectIpfsCid(ipfsCid);
        vm.expectRevert("Caller not the admin");
        driver.updateGelatoTask(ipfsCid, 0, 0);
    }

    function testRequestUpdateOwner() public {
        Forge forge = Forge.GitHub;
        bytes memory name = "this/repo";

        vm.expectEmit(address(driver));
        emit OwnerUpdateRequested(driver.calcAccountId(forge, name), forge, name, address(this));
        driver.requestUpdateOwner(forge, name);
    }

    function testRequestUpdateOwnerViaForwarder() public {
        Forge forge = Forge.GitHub;
        bytes memory name = "this/repo";
        vm.prank(user);
        caller.authorize(address(this));
        bytes memory data = abi.encodeCall(driver.requestUpdateOwner, (forge, name));

        vm.expectEmit(address(driver));
        emit OwnerUpdateRequested(driver.calcAccountId(forge, name), forge, name, user);
        caller.callAs(user, address(driver), data);
    }

    function testRequestUpdateOwnerAppliesGasPenalty() public {
        string memory ipfsCid = "The new Gelato Function";
        automate().expectIpfsCid(ipfsCid);
        vm.prank(admin);
        // The penalty increase of 1/6 of the block gas results in maximum 3 requests per block.
        // Decrease of the penalty by 1 increase per day results in 31 requests per 31 days
        // on top of the 6 requests maxing out the penalty.
        uint256 penaltyIncrease = block.gaslimit / 6;
        driver.updateGelatoTask(ipfsCid, 3, 31 + 6);

        // Move away from timestamp 0 by the time it takes to decrease the penalty by 1 increase.
        vm.warp(1 days);
        requestWithGasPenalty(0 * penaltyIncrease);
        requestWithGasPenalty(1 * penaltyIncrease);
        requestWithGasPenalty(2 * penaltyIncrease);
        // Decrease the penalty by 2 increases.
        vm.warp(vm.getBlockTimestamp() + 2 days);
        requestWithGasPenalty(1 * penaltyIncrease);
    }

    function requestWithGasPenalty(uint256 gasPenalty) internal {
        assertApproxEqAbs(gasPenalty, driver.requestUpdateOwnerGasPenalty(), 1, "Invalid penalty");
        uint256 gasUsed = gasleft();
        driver.requestUpdateOwner(Forge.GitHub, "this/repo");
        gasUsed -= gasleft();
        uint256 gasBase = 8_000;
        uint256 gasDelta = 4_000;
        assertApproxEqAbs(gasUsed, gasBase + gasPenalty, gasDelta, "Invalid applied penalty");
    }

    function testReceivedNativeTokensAreAddedToCommonFunds() public {
        assertCommonFunds(0);
        Address.sendValue(payable(driver), 1);
        assertCommonFunds(1);
        Address.sendValue(payable(driver), 2);
        assertCommonFunds(3);
    }

    function testDepositUserFunds() public {
        assertUserFunds(user, 0);

        driver.depositUserFunds{value: 1}(user);
        assertUserFunds(user, 1);

        driver.depositUserFunds{value: 2}(user);
        assertUserFunds(user, 3);
    }

    function testWithdrawFunds() public {
        driver.depositUserFunds{value: 3}(address(this));
        assertUserFunds(address(this), 3);
        assertAddressBalance(admin, 0);

        driver.withdrawUserFunds(2, payable(admin));
        assertUserFunds(address(this), 1);
        assertAddressBalance(admin, 2);
    }

    function testWithdrawFundsViaForwarder() public {
        driver.depositUserFunds{value: 3}(user);
        assertUserFunds(user, 3);
        assertAddressBalance(user, 0);

        vm.prank(user);
        caller.authorize(address(this));
        bytes memory data = abi.encodeCall(driver.withdrawUserFunds, (2, payable(admin)));

        caller.callAs(user, address(driver), data);
        assertUserFunds(user, 1);
        assertAddressBalance(admin, 2);
    }

    function testWithdrawFundsAll() public {
        driver.depositUserFunds{value: 3}(address(this));
        assertUserFunds(address(this), 3);
        assertAddressBalance(admin, 0);

        driver.withdrawUserFunds(0, payable(admin));
        assertUserFunds(address(this), 0);
        assertAddressBalance(admin, 3);
    }

    function testWithdrawFundsAllWhenBalanceIsZero() public {
        assertUserFunds(address(this), 0);
        assertAddressBalance(admin, 0);

        driver.withdrawUserFunds(0, payable(admin));
        assertUserFunds(address(this), 0);
        assertAddressBalance(admin, 0);
    }

    function testWithdrawFundsRevertsWhenAmountTooHigh() public {
        driver.depositUserFunds{value: 3}(address(this));
        assertUserFunds(address(this), 3);

        vm.expectRevert("Not enough user funds");
        driver.withdrawUserFunds(4, payable(admin));
    }

    function testCollect() public {
        uint128 amt = 5;
        driver.give(accountId1, accountId2, erc20, amt);
        drips.split(accountId2, erc20, new SplitsReceiver[](0));
        uint256 balance = erc20.balanceOf(address(this));
        uint128 collected = driver.collect(accountId2, erc20, address(this));
        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(address(this)), balance + amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testCollectTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        driver.give(accountId1, accountId2, erc20, amt);
        drips.split(accountId2, erc20, new SplitsReceiver[](0));
        address transferTo = address(1234);
        uint128 collected = driver.collect(accountId2, erc20, transferTo);
        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testCollectRevertsWhenNotAccountOwner() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.collect(accountIdUser, erc20, address(this));
    }

    function testGive() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));
        driver.give(accountId1, accountId2, erc20, amt);
        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        assertEq(drips.splittable(accountId2, erc20), amt, "Invalid received amount");
    }

    function testGiveRevertsWhenNotAccountOwner() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.give(accountIdUser, accountId, erc20, 5);
    }

    function testSetStreams() public {
        uint128 amt = 5;
        // Top-up
        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] =
            StreamReceiver(accountId2, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));
        uint256 balance = erc20.balanceOf(address(this));
        int128 realBalanceDelta = driver.setStreams(
            accountId1, erc20, new StreamReceiver[](0), int128(amt), receivers, 0, 0, address(this)
        );
        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance after top-up");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance after top-up");
        (,,, uint128 streamsBalance,) = drips.streamsState(accountId1, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance after top-up");
        assertEq(realBalanceDelta, int128(amt), "Invalid streams balance delta after top-up");
        (bytes32 streamsHash,,,,) = drips.streamsState(accountId1, erc20);
        assertEq(streamsHash, drips.hashStreams(receivers), "Invalid streams hash after top-up");
        // Withdraw
        balance = erc20.balanceOf(address(user));
        realBalanceDelta = driver.setStreams(
            accountId1, erc20, receivers, -int128(amt), receivers, 0, 0, address(user)
        );
        assertEq(erc20.balanceOf(address(user)), balance + amt, "Invalid balance after withdrawal");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance after withdrawal");
        (,,, streamsBalance,) = drips.streamsState(accountId1, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance after withdrawal");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta after withdrawal");
    }

    function testSetStreamsDecreasingBalanceTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        StreamReceiver[] memory receivers = new StreamReceiver[](0);
        driver.setStreams(accountId, erc20, receivers, int128(amt), receivers, 0, 0, address(this));
        address transferTo = address(1234);
        int128 realBalanceDelta = driver.setStreams(
            accountId, erc20, receivers, -int128(amt), receivers, 0, 0, transferTo
        );
        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(accountId1, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta");
    }

    function testSetStreamsRevertsWhenNotAccountOwner() public {
        StreamReceiver[] memory noReceivers = new StreamReceiver[](0);
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.setStreams(accountIdUser, erc20, noReceivers, 0, noReceivers, 0, 0, address(this));
    }

    function testSetSplits() public {
        SplitsReceiver[] memory receivers = new SplitsReceiver[](1);
        receivers[0] = SplitsReceiver(accountId2, 1);
        driver.setSplits(accountId, receivers);
        bytes32 actual = drips.splitsHash(accountId);
        bytes32 expected = drips.hashSplits(receivers);
        assertEq(actual, expected, "Invalid splits hash");
    }

    function testSetSplitsRevertsWhenNotAccountOwner() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.setSplits(accountIdUser, new SplitsReceiver[](0));
    }

    function testEmitAccountMetadata() public {
        driver.emitAccountMetadata(accountId, someMetadata());
    }

    function testEmitAccountMetadataRevertsWhenNotAccountOwner() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.emitAccountMetadata(accountIdUser, someMetadata());
    }

    function testForwarderIsTrusted() public {
        vm.prank(user);
        caller.authorize(address(this));
        assertEq(drips.splittable(accountId, erc20), 0, "Invalid splittable before give");
        uint128 amt = 10;
        bytes memory giveData =
            abi.encodeWithSelector(driver.give.selector, accountIdUser, accountId, erc20, amt);
        caller.callAs(user, address(driver), giveData);
        assertEq(drips.splittable(accountId, erc20), amt, "Invalid splittable after give");
    }

    modifier canBePausedTest() {
        vm.prank(admin);
        driver.pause();
        vm.expectRevert("Contract paused");
        _;
    }

    function testRequestUpdateOwnerCanBePaused() public canBePausedTest {
        driver.requestUpdateOwner(Forge.GitHub, "");
    }

    function testUpdateOwnerByGelatoCanBePaused() public canBePausedTest {
        driver.updateOwnerByGelato(0, address(0), address(0));
    }

    function testDepositUserFundsCanBePaused() public canBePausedTest {
        driver.depositUserFunds(address(0));
    }

    function testWithdrawUserFundsCanBePaused() public canBePausedTest {
        driver.withdrawUserFunds(0, payable(0));
    }

    function testCollectCanBePaused() public canBePausedTest {
        driver.collect(0, erc20, user);
    }

    function testGiveCanBePaused() public canBePausedTest {
        driver.give(0, 0, erc20, 0);
    }

    function testSetStreamsCanBePaused() public canBePausedTest {
        driver.setStreams(0, erc20, new StreamReceiver[](0), 0, new StreamReceiver[](0), 0, 0, user);
    }

    function testSetSplitsCanBePaused() public canBePausedTest {
        driver.setSplits(0, new SplitsReceiver[](0));
    }

    function testEmitAccountMetadataCanBePaused() public canBePausedTest {
        driver.emitAccountMetadata(0, noMetadata());
    }
}

contract GelatoTasksOwnerTest is Test {
    GelatoTasksOwner tasksOwner;
    address automate;

    function setUp() public {
        automate = address(bytes20("automate"));
        tasksOwner = new GelatoTasksOwner(IAutomate(automate));
    }

    function testOwner() public {
        assertEq(address(this), tasksOwner.owner(), "Invalid owner");
    }

    function testCancelTask() public {
        bytes32 taskId = "taskId";
        vm.expectCall(automate, abi.encodeCall(IAutomate.cancelTask, (taskId)), 1);
        vm.mockCall(automate, "", "");
        tasksOwner.cancelTask(taskId);
    }

    function testCancelTaskRevertsWhenNotCalledByOwner() public {
        vm.prank(address(bytes20("not owner")));
        vm.expectRevert("Callable only by the owner");
        tasksOwner.cancelTask(0);
    }

    function testCreateTask() public {
        address execAddress = address(bytes20("execAddress"));
        bytes memory execData = "execData";
        ModuleData memory moduleData = ModuleData(new Module[](1), new bytes[](1));
        moduleData.modules[0] = Module.PROXY;
        moduleData.args[0] = "moduleData";
        address feeToken = address(bytes20("feeToken"));
        bytes32 taskId = "taskId";

        vm.expectCall(
            automate,
            abi.encodeCall(IAutomate.createTask, (execAddress, execData, moduleData, feeToken)),
            1
        );
        vm.mockCall(automate, "", abi.encode(taskId));
        bytes32 actualTaskId = tasksOwner.createTask(execAddress, execData, moduleData, feeToken);
        assertEq(actualTaskId, taskId, "Invalid task ID");
    }

    function testCreateTaskRevertsWhenNotCalledByOwner() public {
        vm.prank(address(bytes20("not owner")));
        vm.expectRevert("Callable only by the owner");
        tasksOwner.createTask(
            address(0), "", ModuleData(new Module[](0), new bytes[](0)), address(0)
        );
    }
}
