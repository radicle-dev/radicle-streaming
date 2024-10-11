// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Caller} from "src/Caller.sol";
import {NFTDriver} from "src/NFTDriver.sol";
import {
    AccountMetadata,
    StreamConfigImpl,
    Drips,
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

contract NFTDriverTest is Test {
    Drips internal drips;
    Caller internal caller;
    NFTDriver internal driver;
    IERC20 internal erc20;

    address internal admin = address(1);
    address internal user = address(2);
    uint256 internal tokenId;
    uint256 internal tokenId1;
    uint256 internal tokenId2;
    uint256 internal tokenIdUser;

    bytes internal constant ERROR_NOT_OWNER = "ERC721: caller is not token owner or approved";
    bytes internal constant ERROR_ALREADY_MINTED = "ERC721: token already minted";

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this), "")));

        caller = new Caller();

        // Make NFTDriver's driver ID non-0 to test if it's respected by NFTDriver
        drips.registerDriver(address(1));
        drips.registerDriver(address(1));
        uint32 driverId = drips.registerDriver(address(this));
        NFTDriver driverLogic = new NFTDriver(drips, address(caller), driverId);
        driver = NFTDriver(address(new ManagedProxy(driverLogic, admin, "")));
        drips.updateDriverAddress(driverId, address(driver));

        tokenId = driver.mint(address(this), noMetadata());
        tokenId1 = driver.mint(address(this), noMetadata());
        tokenId2 = driver.mint(address(this), noMetadata());
        tokenIdUser = driver.mint(user, noMetadata());

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
        erc20.transfer(user, erc20.totalSupply() / 100);
        vm.prank(user);
        erc20.approve(address(driver), type(uint256).max);
    }

    function noMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](0);
    }

    function someMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
    }

    function assertTokenDoesNotExist(uint256 nonExistentTokenId) internal {
        vm.expectRevert("ERC721: invalid token ID");
        driver.ownerOf(nonExistentTokenId);
    }

    function testName() public {
        assertEq(driver.name(), "Drips identity", "Invalid token name");
    }

    function testSymbol() public {
        assertEq(driver.symbol(), "DHI", "Invalid token symbol");
    }

    function testApproveLetsUseIdentity() public {
        vm.prank(user);
        driver.approve(address(this), tokenIdUser);
        driver.collect(tokenIdUser, erc20, address(user));
    }

    function testApproveAllLetsUseIdentity() public {
        vm.prank(user);
        driver.setApprovalForAll(address(this), true);
        driver.collect(tokenIdUser, erc20, address(user));
    }

    function testMintIncreasesTokenId() public {
        uint256 nextTokenId = driver.nextTokenId();
        assertTokenDoesNotExist(nextTokenId);

        uint256 newTokenId = driver.mint(user, someMetadata());

        assertEq(newTokenId, nextTokenId, "Invalid new tokenId");
        assertEq(driver.nextTokenId(), newTokenId + 1, "Invalid next tokenId");
        assertEq(driver.ownerOf(newTokenId), user, "Invalid token owner");
    }

    function testSafeMintIncreasesTokenId() public {
        uint256 nextTokenId = driver.nextTokenId();
        assertTokenDoesNotExist(nextTokenId);

        uint256 newTokenId = driver.safeMint(user, someMetadata());

        assertEq(newTokenId, nextTokenId, "Invalid new tokenId");
        assertEq(driver.nextTokenId(), newTokenId + 1, "Invalid next tokenId");
        assertEq(driver.ownerOf(newTokenId), user, "Invalid token owner");
    }

    function testMintWithSaltUsesUpSalt() public {
        uint64 salt = 123;
        uint256 newTokenId = driver.calcTokenIdWithSalt(address(this), salt);
        assertFalse(driver.isSaltUsed(address(this), salt), "Salt already used");
        assertTokenDoesNotExist(newTokenId);

        uint256 mintedTokenId = driver.mintWithSalt(salt, user, someMetadata());

        assertEq(mintedTokenId, newTokenId, "Invalid new tokenId");
        assertTrue(driver.isSaltUsed(address(this), salt), "Salt not used");
        assertEq(driver.ownerOf(newTokenId), user, "Invalid token owner");
    }

    function testSafeMintWithSaltUsesUpSalt() public {
        uint64 salt = 123;
        uint256 newTokenId = driver.calcTokenIdWithSalt(address(this), salt);
        assertFalse(driver.isSaltUsed(address(this), salt), "Salt already used");
        assertTokenDoesNotExist(newTokenId);

        uint256 mintedTokenId = driver.safeMintWithSalt(salt, user, someMetadata());

        assertEq(mintedTokenId, newTokenId, "Invalid new tokenId");
        assertTrue(driver.isSaltUsed(address(this), salt), "Salt not used");
        assertEq(driver.ownerOf(newTokenId), user, "Invalid token owner");
    }

    function testUsedSaltCanNotBeUsedToMint() public {
        uint64 salt = 123;
        uint256 newTokenId = driver.mintWithSalt(salt, user, noMetadata());

        vm.expectRevert(ERROR_ALREADY_MINTED);
        driver.mintWithSalt(salt, user, noMetadata());

        vm.prank(user);
        driver.burn(newTokenId);
        vm.expectRevert(ERROR_ALREADY_MINTED);
        driver.mintWithSalt(salt, user, noMetadata());
    }

    function testUsedSaltCanNotBeUsedToSafeMint() public {
        uint64 salt = 123;
        uint256 newTokenId = driver.safeMintWithSalt(salt, user, noMetadata());

        vm.expectRevert(ERROR_ALREADY_MINTED);
        driver.safeMintWithSalt(salt, user, noMetadata());

        vm.prank(user);
        driver.burn(newTokenId);
        vm.expectRevert(ERROR_ALREADY_MINTED);
        driver.safeMintWithSalt(salt, user, noMetadata());
    }

    function testSetTokenURI() public {
        assertEq(driver.tokenURI(tokenId1), "", "Invalid initial token URI");
        string memory URI = "some URI";
        driver.setTokenURI(tokenId1, URI);
        assertEq(driver.tokenURI(tokenId1), URI, "Invalid final token URI");
    }

    function testSetTokenURIRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.setTokenURI(tokenIdUser, "some URI");
    }

    function testCollect() public {
        uint128 amt = 5;
        driver.give(tokenId1, tokenId2, erc20, amt);
        drips.split(tokenId2, erc20, new SplitsReceiver[](0));
        uint256 balance = erc20.balanceOf(address(this));

        uint128 collected = driver.collect(tokenId2, erc20, address(this));

        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(address(this)), balance + amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testCollectTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        driver.give(tokenId1, tokenId2, erc20, amt);
        drips.split(tokenId2, erc20, new SplitsReceiver[](0));
        address transferTo = address(1234);

        uint128 collected = driver.collect(tokenId2, erc20, transferTo);

        assertEq(collected, amt, "Invalid collected");
        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
    }

    function testCollectRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.collect(tokenIdUser, erc20, address(this));
    }

    function testGive() public {
        uint128 amt = 5;
        uint256 balance = erc20.balanceOf(address(this));

        driver.give(tokenId1, tokenId2, erc20, amt);

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance");
        assertEq(drips.splittable(tokenId2, erc20), amt, "Invalid received amount");
    }

    function testGiveRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.give(tokenIdUser, tokenId, erc20, 5);
    }

    function testSetStreams() public {
        uint128 amt = 5;

        // Top-up

        StreamReceiver[] memory receivers = new StreamReceiver[](1);
        receivers[0] =
            StreamReceiver(tokenId2, StreamConfigImpl.create(0, drips.minAmtPerSec(), 0, 0));
        uint256 balance = erc20.balanceOf(address(this));

        int128 realBalanceDelta = driver.setStreams(
            tokenId1, erc20, new StreamReceiver[](0), int128(amt), receivers, 0, 0, address(this)
        );

        assertEq(erc20.balanceOf(address(this)), balance - amt, "Invalid balance after top-up");
        assertEq(erc20.balanceOf(address(drips)), amt, "Invalid Drips balance after top-up");
        (,,, uint128 streamsBalance,) = drips.streamsState(tokenId1, erc20);
        assertEq(streamsBalance, amt, "Invalid streams balance after top-up");

        assertEq(realBalanceDelta, int128(amt), "Invalid streams balance delta after top-up");
        (bytes32 streamsHash,,,,) = drips.streamsState(tokenId1, erc20);
        assertEq(streamsHash, drips.hashStreams(receivers), "Invalid streams hash after top-up");

        // Withdraw
        balance = erc20.balanceOf(address(user));

        realBalanceDelta = driver.setStreams(
            tokenId1, erc20, receivers, -int128(amt), receivers, 0, 0, address(user)
        );

        assertEq(erc20.balanceOf(address(user)), balance + amt, "Invalid balance after withdrawal");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance after withdrawal");
        (,,, streamsBalance,) = drips.streamsState(tokenId1, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance after withdrawal");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta after withdrawal");
    }

    function testSetStreamsDecreasingBalanceTransfersFundsToTheProvidedAddress() public {
        uint128 amt = 5;
        StreamReceiver[] memory receivers = new StreamReceiver[](0);
        driver.setStreams(tokenId, erc20, receivers, int128(amt), receivers, 0, 0, address(this));
        address transferTo = address(1234);

        int128 realBalanceDelta =
            driver.setStreams(tokenId, erc20, receivers, -int128(amt), receivers, 0, 0, transferTo);

        assertEq(erc20.balanceOf(transferTo), amt, "Invalid balance");
        assertEq(erc20.balanceOf(address(drips)), 0, "Invalid Drips balance");
        (,,, uint128 streamsBalance,) = drips.streamsState(tokenId1, erc20);
        assertEq(streamsBalance, 0, "Invalid streams balance");
        assertEq(realBalanceDelta, -int128(amt), "Invalid streams balance delta");
    }

    function testSetStreamsRevertsWhenNotTokenHolder() public {
        StreamReceiver[] memory noReceivers = new StreamReceiver[](0);
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.setStreams(tokenIdUser, erc20, noReceivers, 0, noReceivers, 0, 0, address(this));
    }

    function testSetSplits() public {
        SplitsReceiver[] memory receivers = new SplitsReceiver[](1);
        receivers[0] = SplitsReceiver(tokenId2, 1);

        driver.setSplits(tokenId, receivers);

        bytes32 actual = drips.splitsHash(tokenId);
        bytes32 expected = drips.hashSplits(receivers);
        assertEq(actual, expected, "Invalid splits hash");
    }

    function testSetSplitsRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.setSplits(tokenIdUser, new SplitsReceiver[](0));
    }

    function testEmitAccountMetadata() public {
        driver.emitAccountMetadata(tokenId, someMetadata());
    }

    function testEmitAccountMetadataRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.emitAccountMetadata(tokenIdUser, someMetadata());
    }

    function testBurn() public {
        driver.burn(tokenId1);
        assertTokenDoesNotExist(tokenId1);
    }

    function testBurnRevertsWhenNotTokenHolder() public {
        vm.expectRevert(ERROR_NOT_OWNER);
        driver.burn(tokenIdUser);
    }

    function testForwarderIsTrustedInErc721Calls() public {
        vm.prank(user);
        caller.authorize(address(this));
        assertEq(driver.ownerOf(tokenIdUser), user, "Invalid token owner before transfer");

        bytes memory transferFromData =
            abi.encodeCall(driver.transferFrom, (user, address(this), tokenIdUser));
        caller.callAs(user, address(driver), transferFromData);

        assertEq(driver.ownerOf(tokenIdUser), address(this), "Invalid token owner after transfer");
    }

    function testForwarderIsTrustedInDriverCalls() public {
        vm.prank(user);
        caller.authorize(address(this));
        assertEq(drips.splittable(tokenId, erc20), 0, "Invalid splittable before give");
        uint128 amt = 10;

        bytes memory giveData = abi.encodeCall(driver.give, (tokenIdUser, tokenId, erc20, amt));
        caller.callAs(user, address(driver), giveData);

        assertEq(drips.splittable(tokenId, erc20), amt, "Invalid splittable after give");
    }

    modifier canBePausedTest() {
        vm.prank(admin);
        driver.pause();
        vm.expectRevert("Contract paused");
        _;
    }

    function testMintCanBePaused() public canBePausedTest {
        driver.mint(user, noMetadata());
    }

    function testSafeMintCanBePaused() public canBePausedTest {
        driver.safeMint(user, noMetadata());
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

    function testBurnCanBePaused() public canBePausedTest {
        driver.burn(0);
    }

    function testApproveCanBePaused() public canBePausedTest {
        driver.approve(user, 0);
    }

    function testSafeTransferFromCanBePaused() public canBePausedTest {
        driver.safeTransferFrom(user, user, 0);
    }

    function testSafeTransferFromWithDataCanBePaused() public canBePausedTest {
        driver.safeTransferFrom(user, user, 0, new bytes(0));
    }

    function testSetApprovalForAllCanBePaused() public canBePausedTest {
        driver.setApprovalForAll(user, false);
    }

    function testTransferFromCanBePaused() public canBePausedTest {
        driver.transferFrom(user, user, 0);
    }
}
