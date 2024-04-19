// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {Caller} from "src/Caller.sol";
import {Forge, RepoDriver} from "src/RepoDriver.sol";
import {
    AccountMetadata,
    StreamConfigImpl,
    Drips,
    StreamsHistory,
    StreamReceiver,
    SplitsReceiver
} from "src/Drips.sol";
import {ManagedProxy} from "src/Managed.sol";
import {BufferChainlink, CBORChainlink} from "chainlink/Chainlink.sol";
import {ERC677ReceiverInterface} from "chainlink/interfaces/ERC677ReceiverInterface.sol";
import {OperatorInterface} from "chainlink/interfaces/OperatorInterface.sol";
import {LinkTokenInterface} from "chainlink/interfaces/LinkTokenInterface.sol";
import {console2, Test} from "forge-std/Test.sol";
import {
    ERC20,
    IERC20,
    ERC20PresetFixedSupply
} from "openzeppelin-contracts/token/ERC20/presets/ERC20PresetFixedSupply.sol";

using CBORChainlink for BufferChainlink.buffer;

contract TestLinkToken is ERC20("", "") {
    function mint(address receiver, uint256 amount) public {
        _mint(receiver, amount);
    }

    function transferAndCall(address to, uint256 value, bytes calldata data)
        external
        returns (bool success)
    {
        super.transfer(to, value);
        ERC677ReceiverInterface(to).onTokenTransfer(msg.sender, value, data);
        return true;
    }
}

contract MockDummy {
    fallback() external payable {
        revert("Call not mocked");
    }
}

contract RepoDriverTest is Test {
    Drips internal drips;
    Caller internal caller;
    RepoDriver internal driver;
    uint256 internal driverNonce;
    IERC20 internal erc20;

    address internal admin = address(1);
    address internal user = address(2);
    uint256 internal accountId;
    uint256 internal accountId1;
    uint256 internal accountId2;
    uint256 internal accountIdUser;

    bytes internal constant ERROR_NOT_OWNER = "Caller is not the account owner";
    bytes internal constant ERROR_ALREADY_INITIALIZED = "Already initialized";

    uint256 internal constant CHAIN_ID_MAINNET = 1;
    uint256 internal constant CHAIN_ID_GOERLI = 5;
    uint256 internal constant CHAIN_ID_SEPOLIA = 11155111;

    function setUp() public {
        Drips dripsLogic = new Drips(10);
        drips = Drips(address(new ManagedProxy(dripsLogic, address(this))));

        caller = new Caller();

        // Make RepoDriver's driver ID non-0 to test if it's respected by RepoDriver
        drips.registerDriver(address(1));
        drips.registerDriver(address(1));
        deployDriver(CHAIN_ID_MAINNET);

        accountId = initialUpdateOwner(address(this), "this/repo1");
        accountId1 = initialUpdateOwner(address(this), "this/repo2");
        accountId2 = initialUpdateOwner(address(this), "this/repo3");
        accountIdUser = initialUpdateOwner(user, "user/repo");

        erc20 = new ERC20PresetFixedSupply("test", "test", type(uint136).max, address(this));
        erc20.approve(address(driver), type(uint256).max);
        erc20.transfer(user, erc20.totalSupply() / 100);
        vm.prank(user);
        erc20.approve(address(driver), type(uint256).max);
    }

    function deployDriver(uint256 chainId) internal {
        vm.chainId(chainId);
        deployDriverUninitialized();
        initializeAnyApiOperator(
            OperatorInterface(address(new MockDummy())), keccak256("job ID"), 2
        );
        TestLinkToken linkToken = TestLinkToken(address(driver.linkToken()));
        vm.etch(address(linkToken), address(new TestLinkToken()).code);
        linkToken.mint(address(this), 100);
        linkToken.mint(address(driver), 100);
    }

    function deployDriverUninitialized() internal {
        uint32 driverId = drips.registerDriver(address(this));
        RepoDriver driverLogic = new RepoDriver(drips, address(caller), driverId);
        driver = RepoDriver(address(new ManagedProxy(driverLogic, admin)));
        drips.updateDriverAddress(driverId, address(driver));
        driverNonce = 0;
    }

    function noMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](0);
    }

    function someMetadata() internal pure returns (AccountMetadata[] memory accountMetadata) {
        accountMetadata = new AccountMetadata[](1);
        accountMetadata[0] = AccountMetadata("key", "value");
    }

    function assertAnyApiOperator(
        OperatorInterface expectedOperator,
        bytes32 expectedJobId,
        uint96 expectedDefaultFee
    ) internal {
        (OperatorInterface operator, bytes32 jobId, uint96 defaultFee) = driver.anyApiOperator();
        assertEq(address(operator), address(expectedOperator), "Invalid operator after the update");
        assertEq(jobId, expectedJobId, "Invalid job ID after the update");
        assertEq(defaultFee, expectedDefaultFee, "Invalid default fee after the update");
    }

    function initializeAnyApiOperator(OperatorInterface operator, bytes32 jobId, uint96 defaultFee)
        internal
    {
        driver.initializeAnyApiOperator(operator, jobId, defaultFee);
        assertAnyApiOperator(operator, jobId, defaultFee);
    }

    function updateAnyApiOperator(OperatorInterface operator, bytes32 jobId, uint96 defaultFee)
        internal
    {
        vm.prank(admin);
        driver.updateAnyApiOperator(operator, jobId, defaultFee);
        assertAnyApiOperator(operator, jobId, defaultFee);
    }

    function initialUpdateOwner(address owner, string memory name)
        internal
        returns (uint256 ownedAccountId)
    {
        Forge forge = Forge.GitHub;
        updateOwner(
            forge,
            bytes(name),
            owner,
            string.concat("https://raw.githubusercontent.com/", name, "/HEAD/FUNDING.json"),
            "drips,ethereum,ownedBy"
        );
        return driver.calcAccountId(forge, bytes(name));
    }

    function updateOwner(
        Forge forge,
        bytes memory name,
        address owner,
        string memory url,
        string memory path
    ) internal {
        bytes32 requestId = requestUpdateOwner(forge, name, url, path);
        updateOwnerByAnyApi(requestId, owner);
        assertOwner(forge, name, owner);
    }

    function requestUpdateOwner(
        Forge forge,
        bytes memory name,
        string memory url,
        string memory path
    ) internal returns (bytes32 requestId) {
        (OperatorInterface operator,, uint96 fee) = driver.anyApiOperator();
        LinkTokenInterface linkToken = driver.linkToken();
        uint256 driverBalance = linkToken.balanceOf(address(driver));
        uint256 operatorBalance = linkToken.balanceOf(address(operator));

        mockOperatorRequest(url, path, driverNonce, fee);
        driver.requestUpdateOwner(forge, name);
        vm.clearMockedCalls();

        assertEq(
            linkToken.balanceOf(address(driver)), driverBalance - fee, "Invalid driver balance"
        );
        assertEq(
            linkToken.balanceOf(address(operator)),
            operatorBalance + fee,
            "Invalid operator balance"
        );
        return calcRequestId(driverNonce++);
    }

    function mockOperatorRequest(string memory url, string memory path, uint256 nonce, uint256 fee)
        internal
    {
        (OperatorInterface operator, bytes32 jobId,) = driver.anyApiOperator();

        BufferChainlink.buffer memory buffer;
        buffer = BufferChainlink.init(buffer, 256);
        buffer.encodeString("get");
        buffer.encodeString(url);
        buffer.encodeString("path");
        buffer.encodeString(path);

        vm.mockCall(
            address(operator),
            abi.encodeCall(
                ERC677ReceiverInterface.onTokenTransfer,
                (
                    address(driver),
                    fee,
                    abi.encodeCall(
                        OperatorInterface.operatorRequest,
                        (
                            address(0),
                            0,
                            jobId,
                            RepoDriver.updateOwnerByAnyApi.selector,
                            nonce,
                            2,
                            buffer.buf
                        )
                    )
                )
            ),
            ""
        );
    }

    function updateOwnerByAnyApi(bytes32 requestId, address owner) internal {
        (OperatorInterface operator,,) = driver.anyApiOperator();
        vm.prank(address(operator));
        driver.updateOwnerByAnyApi(requestId, abi.encodePacked(owner));
    }

    function assertOwner(Forge forge, bytes memory name, address expectedOwner) internal {
        uint256 repoAccountId = driver.calcAccountId(forge, name);
        assertEq(driver.ownerOf(repoAccountId), expectedOwner, "Invalid account owner");
    }

    function calcRequestId(uint256 nonce) internal view returns (bytes32 requestId) {
        return keccak256(abi.encodePacked(address(driver), nonce));
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

    function testUpdateAnyApiOperator() public {
        (OperatorInterface operator, bytes32 jobId, uint96 defaultFee) = driver.anyApiOperator();
        OperatorInterface newOperator = OperatorInterface(address(~uint160(address(operator))));
        updateAnyApiOperator(newOperator, ~jobId, ~defaultFee);
    }

    function testUpdateAnyApiOperatorRevertsIfNotCalledByAdmin() public {
        vm.expectRevert("Caller not the admin");
        driver.updateAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);
    }

    function testInitializeAnyApiOperator() public {
        deployDriverUninitialized();
        initializeAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);
    }

    function testInitializeAnyApiOperatorRevertsIfCalledTwice() public {
        deployDriverUninitialized();
        initializeAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);

        vm.expectRevert(ERROR_ALREADY_INITIALIZED);
        driver.initializeAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);
    }

    function testInitializeAnyApiOperatorRevertsIfCalledAfterUpdate() public {
        deployDriverUninitialized();
        updateAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);

        vm.expectRevert(ERROR_ALREADY_INITIALIZED);
        driver.initializeAnyApiOperator(OperatorInterface(address(1234)), keccak256("job ID"), 123);
    }

    function testUpdateOwnerGitHubMainnet() public {
        updateOwner(
            Forge.GitHub,
            "me/repo",
            user,
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy"
        );
    }

    function testUpdateOwnerGitLabMainnet() public {
        updateOwner(
            Forge.GitLab,
            "me/repo",
            user,
            "https://gitlab.com/me/repo/-/raw/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy"
        );
    }

    function testUpdateOwnerGitHubGoerli() public {
        deployDriver(CHAIN_ID_GOERLI);
        updateOwner(
            Forge.GitHub,
            "me/repo",
            user,
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,goerli,ownedBy"
        );
    }

    function testUpdateOwnerGitHubSepolia() public {
        deployDriver(CHAIN_ID_SEPOLIA);
        updateOwner(
            Forge.GitHub,
            "me/repo",
            user,
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,sepolia,ownedBy"
        );
    }

    function testUpdateOwnerGitHubOtherChain() public {
        deployDriver(1234567890);
        updateOwner(
            Forge.GitHub,
            "me/repo",
            user,
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,other,ownedBy"
        );
    }

    function testRequestUpdateOwnerRevertsWhenNotEnoughLink() public {
        uint256 balance = driver.linkToken().balanceOf(address(driver));
        (OperatorInterface operator, bytes32 jobId,) = driver.anyApiOperator();
        updateAnyApiOperator(operator, jobId, uint96(balance) + 1);
        vm.expectRevert("Link balance too low");
        driver.requestUpdateOwner(Forge.GitHub, "me/repo");
    }

    function testRequestUpdateOwnerRevertsWhenOperatorAddressIsZero() public {
        (, bytes32 jobId, uint96 fee) = driver.anyApiOperator();
        updateAnyApiOperator(OperatorInterface(address(0)), jobId, fee);
        vm.expectRevert("Operator address not set");
        driver.requestUpdateOwner(Forge.GitHub, "me/repo");
    }

    function testUpdateOwnerByAnyApiRevertsIfNotCalledByTheOperator() public {
        bytes32 requestId = requestUpdateOwner(
            Forge.GitHub,
            "me/repo",
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy"
        );
        vm.expectRevert("Callable only by the operator");
        driver.updateOwnerByAnyApi(requestId, abi.encodePacked(user));
    }

    function testUpdateOwnerByAnyApiRevertsIfUnknownRequestId() public {
        (OperatorInterface operator,,) = driver.anyApiOperator();
        vm.prank(address(operator));
        vm.expectRevert("Unknown request ID");
        driver.updateOwnerByAnyApi(keccak256("requestId"), abi.encodePacked(user));
    }

    function testUpdateOwnerByAnyApiRevertsIfReusedRequestId() public {
        bytes32 requestId = requestUpdateOwner(
            Forge.GitHub,
            "me/repo",
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy"
        );
        (OperatorInterface operator,,) = driver.anyApiOperator();

        vm.prank(address(operator));
        driver.updateOwnerByAnyApi(requestId, abi.encodePacked(user));

        vm.prank(address(operator));
        vm.expectRevert("Unknown request ID");
        driver.updateOwnerByAnyApi(requestId, abi.encodePacked(user));
    }

    function testUpdateOwnerByAnyApiRevertsIfOwnerIsNotAddress() public {
        bytes32 requestId = requestUpdateOwner(
            Forge.GitHub,
            "me/repo",
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy"
        );
        (OperatorInterface operator,,) = driver.anyApiOperator();

        vm.prank(address(operator));
        vm.expectRevert("Invalid owner length");
        driver.updateOwnerByAnyApi(requestId, abi.encodePacked(user, uint8(0)));
    }

    function testOnTokenTransfer() public {
        (OperatorInterface operator,,) = driver.anyApiOperator();
        LinkTokenInterface linkToken = driver.linkToken();
        uint256 thisBalance = linkToken.balanceOf(address(this));
        uint256 operatorBalance = linkToken.balanceOf(address(operator));
        uint256 fee = thisBalance / 2;

        mockOperatorRequest(
            "https://raw.githubusercontent.com/me/repo/HEAD/FUNDING.json",
            "drips,ethereum,ownedBy",
            driverNonce,
            fee
        );
        linkToken.transferAndCall(
            address(driver),
            fee,
            abi.encodeCall(driver.requestUpdateOwner, (Forge.GitHub, "me/repo"))
        );

        assertEq(linkToken.balanceOf(address(this)), thisBalance - fee, "Invalid this balance");
        assertEq(
            linkToken.balanceOf(address(operator)),
            operatorBalance + fee,
            "Invalid operator balance"
        );
        updateOwnerByAnyApi(calcRequestId(driverNonce), user);
    }

    function testOnTokenTransferRevertsIfNotLinkIsReceived() public {
        TestLinkToken notLinkToken = new TestLinkToken();
        notLinkToken.mint(address(this), 1);
        vm.expectRevert("Callable only by the Link token");
        notLinkToken.transferAndCall(
            address(driver), 1, abi.encodeCall(driver.requestUpdateOwner, (Forge.GitHub, "me/repo"))
        );
    }

    function testOnTokenTransferRevertsIfPayloadIsNotCalldata() public {
        LinkTokenInterface linkToken = driver.linkToken();
        vm.expectRevert("Data not a valid calldata");
        linkToken.transferAndCall(address(driver), 1, "abc");
    }

    function testOnTokenTransferRevertsIfPayloadHasInvalidSelector() public {
        LinkTokenInterface linkToken = driver.linkToken();
        vm.expectRevert("Data not requestUpdateOwner");
        linkToken.transferAndCall(
            address(driver),
            1,
            abi.encodeWithSelector(driver.updateOwnerByAnyApi.selector, Forge.GitHub, "me/repo")
        );
    }

    function testOnTokenTransferRevertsIfPayloadIsNotValidCalldata() public {
        LinkTokenInterface linkToken = driver.linkToken();
        vm.expectRevert(bytes(""));
        linkToken.transferAndCall(
            address(driver),
            1,
            abi.encodeWithSelector(driver.requestUpdateOwner.selector, "me/repo")
        );
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

    function testInitializeAnyApiOperatorCanBePaused() public canBePausedTest {
        driver.initializeAnyApiOperator(OperatorInterface(address(0)), 0, 0);
    }

    function testUpdateAnyApiOperatorCanBePaused() public canBePausedTest {
        driver.updateAnyApiOperator(OperatorInterface(address(0)), 0, 0);
    }

    function testRequestUpdateOwnerCanBePaused() public canBePausedTest {
        driver.requestUpdateOwner(Forge.GitHub, "");
    }

    function testOnTokenTransferCanBePaused() public canBePausedTest {
        driver.onTokenTransfer(address(0), 0, "");
    }

    function testUpdateOwnerByAnyApiCanBePaused() public canBePausedTest {
        driver.updateOwnerByAnyApi(0, "");
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
