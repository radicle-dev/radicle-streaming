// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {AccountMetadata, Drips, StreamReceiver, IERC20, SplitsReceiver} from "./Drips.sol";
import {DriverTransferUtils} from "./DriverTransferUtils.sol";
import {Managed} from "./Managed.sol";
import {
    IAutomate,
    IGelato,
    IProxyModule,
    Module,
    ModuleData,
    TriggerType
} from "gelato-automate/integrations/Types.sol";
import {IAutomate as IAutomate2} from "gelato-automate/interfaces/IAutomate.sol";
import {IOpsProxyFactory} from "gelato-automate/interfaces/IOpsProxyFactory.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

/// @notice The supported forges where repositories are stored.
enum Forge {
    GitHub,
    GitLab
}

/// @notice A Drips driver implementing repository-based account identification.
/// Each repository stored in one of the supported forges has a deterministic account ID assigned.
/// By default the repositories have no owner and their accounts can't be controlled by anybody,
/// use `requestUpdateOwner` to update the owner.
contract RepoDriver is DriverTransferUtils, Managed {
    /// @notice The Drips address used by this driver.
    Drips public immutable drips;
    /// @notice The driver ID which this driver uses when calling Drips.
    uint32 public immutable driverId;
    /// @notice The Gelato Automate contract used for running oracle tasks.
    IAutomate public immutable gelatoAutomate;

    /// @notice The address collecting Gelato fees.
    address payable internal immutable gelatoFeeCollector;
    /// @notice The placeholder address meaning that the Gelato fee is paid in native tokens.
    address internal constant GELATO_NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    /// @notice The maximum possible request penalty which is the entire block gas limit.
    uint256 internal constant MAX_PENALTY = type(uint72).max;

    /// @notice The ERC-1967 storage slot holding a single `RepoDriverStorage` structure.
    bytes32 private immutable _repoDriverStorageSlot = _erc1967Slot("eip1967.repoDriver.storage");
    /// @notice The ERC-1967 storage slot holding a single `GelatoStorage` structure.
    bytes32 private immutable _gelatoStorageSlot = _erc1967Slot("eip1967.repoDriver.gelato.storage");

    /// @notice Emitted when the account ownership update is requested.
    /// @param accountId The ID of the account.
    /// @param forge The forge where the repository is stored.
    /// @param name The name of the repository.
    /// @param payer The address of the user paying the fees.
    /// The Gelato fee will be paid in native tokens when the actual owner update is made.
    /// The fee is paid from the funds deposited for the message sender calling this function.
    /// If these funds aren't enough, the missing part is paid from the common funds.
    event OwnerUpdateRequested(uint256 indexed accountId, Forge forge, bytes name, address payer);

    /// @notice Emitted when the account ownership is updated.
    /// @param accountId The ID of the account.
    /// @param owner The new owner of the repository.
    event OwnerUpdated(uint256 indexed accountId, address owner);

    /// @notice Emitted when Gelato task performing account ownership lookups is updated.
    /// @param gelatoTasksOwner The owner of the created task.
    /// @param taskId The ID of the created Gelato task.
    /// @param ipfsCid The IPFS CID of the code to be run
    /// by the  Gelato Web3 Function task to lookup the account ownership.
    /// @param maxRequestsPerBlock The maximum number of Gelato task runs triggerable in a block.
    /// The limit is disabled if both `maxRequestsPerBlock` and `maxRequestsPer31Days` are `0`.
    /// The limit is enforced by adding an artificial gas cost penalty
    /// to each call trigerring a task run.
    /// The penalty increases by a constant amount after each call
    /// and decreases linearly over time until it returns to `0`.
    /// @param maxRequestsPer31Days The maximum number of Gelato task runs
    /// triggerable in the rolling window of 31 days.
    event GelatoTaskUpdated(
        GelatoTasksOwner gelatoTasksOwner,
        bytes32 taskId,
        string ipfsCid,
        uint32 maxRequestsPerBlock,
        uint32 maxRequestsPer31Days
    );

    /// @notice Emitted when native tokens are deposited for the user.
    /// These funds will be used to pay Gelato fees for that user's requests.
    /// @param user The user for whom the deposit was made.
    /// @param amount The deposited amount.
    event UserFundsDeposited(address indexed user, uint256 amount);

    /// @notice Emitted when native tokens are withdrawn for the user.
    /// @param user The user who withdrew their funds.
    /// @param amount The amount that was withdrawn.
    /// @param receiver The address to which the withdrawn funds were sent.
    event UserFundsWithdrawn(address indexed user, uint256 amount, address payable receiver);

    /// @notice Emitted when the Gelato fee is paid.
    /// @param user The paying user.
    /// @param userFundsUsed The amount paid from the user's deposit.
    /// @param commonFundsUsed The amount paid from the common deposit.
    event GelatoFeePaid(address indexed user, uint256 userFundsUsed, uint256 commonFundsUsed);

    struct RepoDriverStorage {
        /// @notice The owners of the accounts.
        mapping(uint256 accountId => address) accountOwners;
    }

    struct GelatoStorage {
        /// @notice The amount of native tokens deposited by each user.
        /// Used to pay Gelato fees for that user's requests.
        mapping(address user => uint256 amount) userFunds;
        /// @notice The total amount of native tokens deposited by all users.
        uint256 userFundsTotal;
        /// @notice The owner of the Gelato tasks created by this contract.
        GelatoTasksOwner tasksOwner;
        /// @notice The address of the proxy delivering Gelato responses.
        address gelatoProxy;
        /// @notice The current state and configuration of the requests penalty.
        RequestsPenalty requestsPenalty;
    }

    /// @notice The current state and configuration of the requests penalty.
    struct RequestsPenalty {
        /// @notice The last request timestamp.
        uint40 lastRequestTimestamp;
        /// @notice The last request penalty.
        uint72 lastRequestPenalty;
        /// @notice The penalty increase whenever a request is made.
        uint72 penaltyIncreasePerRequest;
        /// @notice The penalty decrease per second.
        uint72 penaltyDecreasePerSecond;
    }

    modifier onlyOwner(uint256 accountId) {
        require(_msgSender() == ownerOf(accountId), "Caller is not the account owner");
        _;
    }

    /// @param drips_ The Drips contract to use.
    /// @param forwarder The ERC-2771 forwarder to trust. May be the zero address.
    /// @param driverId_ The driver ID to use when calling Drips.
    /// @param gelatoAutomate_ The Gelato Automate contract used for running oracle tasks
    constructor(Drips drips_, address forwarder, uint32 driverId_, IAutomate gelatoAutomate_)
        DriverTransferUtils(forwarder)
    {
        drips = drips_;
        driverId = driverId_;
        gelatoAutomate = gelatoAutomate_;
        IGelato gelato = IGelato(gelatoAutomate.gelato());
        gelatoFeeCollector = payable(gelato.feeCollector());
    }

    receive() external payable {}

    /// @notice Returns the address of the Drips contract to use for ERC-20 transfers.
    function _drips() internal view override returns (Drips) {
        return drips;
    }

    /// @notice Calculates the account ID.
    /// Every account ID is a 256-bit integer constructed by concatenating:
    /// `driverId (32 bits) | forgeId (8 bits) | nameEncoded (216 bits)`.
    /// When `forge` is GitHub and `name` is at most 27 bytes long,
    /// `forgeId` is 0 and `nameEncoded` is `name` right-padded with zeros
    /// When `forge` is GitHub and `name` is longer than 27 bytes,
    /// `forgeId` is 1 and `nameEncoded` is the lower 27 bytes of the hash of `name`.
    /// When `forge` is GitLab and `name` is at most 27 bytes long,
    /// `forgeId` is 2 and `nameEncoded` is `name` right-padded with zeros
    /// When `forge` is GitLab and `name` is longer than 27 bytes,
    /// `forgeId` is 3 and `nameEncoded` is the lower 27 bytes of the hash of `name`.
    /// @param forge The forge where the repository is stored.
    /// @param name The name of the repository.
    /// For GitHub and GitLab it must follow the `user_name/repository_name` structure
    /// and it must be formatted identically as in the repository's URL,
    /// including the case of each letter and special characters being removed.
    /// @return accountId The account ID.
    function calcAccountId(Forge forge, bytes calldata name)
        public
        view
        returns (uint256 accountId)
    {
        uint8 forgeId;
        uint216 nameEncoded;
        if (forge == Forge.GitHub) {
            if (name.length <= 27) {
                forgeId = 0;
                nameEncoded = uint216(bytes27(name));
            } else {
                forgeId = 1;
                // `nameEncoded` is the lower 27 bytes of the hash
                nameEncoded = uint216(uint256(keccak256(name)));
            }
        } else {
            if (name.length <= 27) {
                forgeId = 2;
                nameEncoded = uint216(bytes27(name));
            } else {
                forgeId = 3;
                // `nameEncoded` is the lower 27 bytes of the hash
                nameEncoded = uint216(uint256(keccak256(name)));
            }
        }
        // By assignment we get `accountId` value:
        // `zeros (224 bits) | driverId (32 bits)`
        accountId = driverId;
        // By bit shifting we get `accountId` value:
        // `zeros (216 bits) | driverId (32 bits) | zeros (8 bits)`
        // By bit masking we get `accountId` value:
        // `zeros (216 bits) | driverId (32 bits) | forgeId (8 bits)`
        accountId = (accountId << 8) | forgeId;
        // By bit shifting we get `accountId` value:
        // `driverId (32 bits) | forgeId (8 bits) | zeros (216 bits)`
        // By bit masking we get `accountId` value:
        // `driverId (32 bits) | forgeId (8 bits) | nameEncoded (216 bits)`
        accountId = (accountId << 216) | nameEncoded;
    }

    /// @notice Gets the account owner.
    /// @param accountId The ID of the account.
    /// @return owner The owner of the account.
    function ownerOf(uint256 accountId) public view returns (address owner) {
        return _repoDriverStorage().accountOwners[accountId];
    }

    /// @notice Updates the Gelato task performing account ownership lookups.
    /// Calling this function cancels all previously created tasks and creates a new one.
    /// Callable only by the admin or inside the constructor of a proxy delegating to this contract.
    /// @param ipfsCid The IPFS CID of the code to be run
    /// by the  Gelato Web3 Function task to lookup the account ownership.
    /// It must accept no arguments, expect `OwnerUpdateRequested` events when executed,
    /// and call `updateOwnerByGelato` with the results.
    /// @param maxRequestsPerBlock The maximum number of Gelato task runs triggerable in a block.
    /// To disable limits set both `maxRequestsPerBlock` and `maxRequestsPer31Days` to `0`.
    /// The limit is enforced by adding an artificial gas cost penalty
    /// to each call trigerring a task run.
    /// The penalty increases by a constant amount after each call
    /// and decreases linearly over time until it returns to `0`.
    /// @param maxRequestsPer31Days The maximum number of Gelato task runs
    /// triggerable in the rolling window of 31 days.
    function updateGelatoTask(
        string calldata ipfsCid,
        uint32 maxRequestsPerBlock,
        uint32 maxRequestsPer31Days
    ) public onlyAdminOrConstructor {
        _updateRequestsPenalty(maxRequestsPerBlock, maxRequestsPer31Days);
        GelatoTasksOwner tasksOwner = _initGelato();
        _cancelAllGelatoTasks(tasksOwner);
        bytes32 taskId = _createGelatoTask(tasksOwner, ipfsCid);
        emit GelatoTaskUpdated(
            tasksOwner, taskId, ipfsCid, maxRequestsPerBlock, maxRequestsPer31Days
        );
    }

    /// @notice The owner of the Gelato tasks created by this contract.
    /// @return tasksOwner The owner of the tasks or the zero address if no tasks have been created.
    function gelatoTasksOwner() public view returns (GelatoTasksOwner tasksOwner) {
        return _gelatoStorage().tasksOwner;
    }

    /// @notice Updates the requests penalty.
    /// @param maxRequestsPerBlock The maximum number of Gelato task runs triggerable in a block.
    /// To disable limits set both `maxRequestsPerBlock` and `maxRequestsPer31Days` to `0`.
    /// The limit is enforced by adding an artificial gas cost penalty
    /// to each call trigerring a task run.
    /// The penalty increases by a constant amount after each call
    /// and decreases linearly over time until it returns to `0`.
    /// @param maxRequestsPer31Days The maximum number of Gelato task runs
    /// triggerable in the rolling window of 31 days.
    function _updateRequestsPenalty(uint32 maxRequestsPerBlock, uint32 maxRequestsPer31Days)
        internal
    {
        if (maxRequestsPerBlock == 0 && maxRequestsPer31Days == 0) {
            delete _gelatoStorage().requestsPenalty;
            return;
        }
        require(maxRequestsPerBlock > 0, "maxRequestsPerBlock too low");
        // Each request has the penalty of the previous request plus `increasePerRequest`.
        // The maximum number of requests in a single block is possible when
        // the first request has no penalty, the next one has `increasePerRequest`,
        // the next one `2 * increasePerRequest` and so on.
        // The target is to fit at most `maxRequestsPerBlock` requests in `MAX_PENALTY`.
        // To do that calculate `increasePerRequest` so that
        // `maxRequestsPerBlock + 1` penalties fit in `MAX_PENALTY`
        // and then add `1` to `increasePerRequest` so only `maxRequestsPerBlock` penalties fit.
        //
        // The formula for `increasePerRequest` fitting `maxRequestsPerBlock + 1` penalties:
        // ```
        // 0 * increasePerRequest + 1 * increasePerRequest + ...
        //      + maxRequestsPerBlock * increasePerRequest == MAX_PENALTY
        // increasePerRequest * (0 + 1 + ... + maxRequestsPerBlock) == MAX_PENALTY
        // increasePerRequest * maxRequestsPerBlock * (maxRequestsPerBlock + 1) / 2 == MAX_PENALTY
        // increasePerRequest == MAX_PENALTY * 2 / (maxRequestsPerBlock * (maxRequestsPerBlock + 1))
        // ```
        uint256 increasePerRequest =
            MAX_PENALTY * 2 / (maxRequestsPerBlock * (maxRequestsPerBlock + uint256(1))) + 1;
        // The number of requests that can be made in a row before
        // the penalty becomes higher than `MAX_PENALTY`.
        uint256 maxRequestsInRow = MAX_PENALTY / increasePerRequest + 1;
        require(maxRequestsInRow < maxRequestsPer31Days, "maxRequestsPer31Days too low");
        // The maximum number of requests in the 31-day window is possible when
        // at the beginning the penalty is `0` and the first requests is made.
        // Next, for the entire 31-day period a request is made whenever the penalty returns to `0`.
        // Finally, exactly at the end of the window `maxRequestsInRow` requests are made
        // so the penalty of `MAX_PENALTY` is reached.
        // `decreasePerSecond` is calculated so that this scenario
        // allows no more than `maxRequestsPer31Days` requests in the 31-day window.
        uint256 decreasePerSecond =
            (maxRequestsPer31Days - maxRequestsInRow) * increasePerRequest / 31 days;
        if (decreasePerSecond > MAX_PENALTY) decreasePerSecond = MAX_PENALTY;
        _gelatoStorage().requestsPenalty = RequestsPenalty({
            lastRequestTimestamp: 0,
            lastRequestPenalty: 0,
            penaltyIncreasePerRequest: uint72(increasePerRequest),
            penaltyDecreasePerSecond: uint72(decreasePerSecond)
        });
    }

    /// @notice If not deployed, deploys and stores the Gelato tasks owner
    /// and stores the address of its proxy delivering Gelato responses.
    /// @return tasksOwner The owner of the Gelato task.
    function _initGelato() internal returns (GelatoTasksOwner tasksOwner) {
        tasksOwner = _gelatoStorage().tasksOwner;
        if (address(tasksOwner) != address(0)) return tasksOwner;
        // Each deployment on each chain gets a tasks owner with a unique address
        // and a separate Gelato subscription with an individual GU balance.
        tasksOwner = new GelatoTasksOwner{salt: bytes32(block.chainid)}(gelatoAutomate);
        _gelatoStorage().tasksOwner = tasksOwner;

        IProxyModule proxyModule = IProxyModule(gelatoAutomate.taskModuleAddresses(Module.PROXY));
        IOpsProxyFactory proxyFactory = IOpsProxyFactory(proxyModule.opsProxyFactory());
        bool isDeployed;
        (_gelatoStorage().gelatoProxy, isDeployed) = proxyFactory.getProxyOf(address(tasksOwner));
        if (!isDeployed) proxyFactory.deployFor(address(tasksOwner));
    }

    /// @notice Cancels all Gelato tasks owned by the task owner.
    /// @param tasksOwner The owner of the cancelled Gelato tasks.
    function _cancelAllGelatoTasks(GelatoTasksOwner tasksOwner) internal {
        // `IAutomate` interface doesn't cover `getTaskIdsByUser`.
        IAutomate2 gelatoAutomate2 = IAutomate2(address(gelatoAutomate));
        bytes32[] memory tasks = gelatoAutomate2.getTaskIdsByUser(address(tasksOwner));
        for (uint256 i = 0; i < tasks.length; i++) {
            tasksOwner.cancelTask(tasks[i]);
        }
    }

    /// @notice Creates a Gelato task.
    /// @param tasksOwner The owner of the created Gelato task.
    /// @param ipfsCid The IPFS CID of the code to be run
    /// by the  Gelato Web3 Function task to lookup the account ownership.
    /// It must accept no arguments, expect `OwnerUpdateRequested` events when executed,
    /// and call `updateOwnerByGelato` with the results.
    /// @return taskId The ID of the created Gelato task.
    function _createGelatoTask(GelatoTasksOwner tasksOwner, string calldata ipfsCid)
        internal
        returns (bytes32 taskId)
    {
        ModuleData memory moduleData = ModuleData(new Module[](3), new bytes[](3));

        // Receive responses via the proxy.
        moduleData.modules[0] = Module.PROXY;

        // Run the web3 function stored under `ipfsCid` with no arguments.
        moduleData.modules[1] = Module.WEB3_FUNCTION;
        moduleData.args[1] = abi.encode(ipfsCid, "");

        bytes32[][] memory topics = new bytes32[][](1);
        topics[0] = new bytes32[](1);
        topics[0][0] = OwnerUpdateRequested.selector;
        // Trigger when this address emits `OwnerUpdateRequested` with 1 block confirmation.
        moduleData.modules[2] = Module.TRIGGER;
        moduleData.args[2] = abi.encode(TriggerType.EVENT, abi.encode(this, topics, 1));

        // The task callback is the zero address called with the zero function selector.
        // These parameters are never used because the web3 function constructs the real callbacks.
        return tasksOwner.createTask(address(0), hex"00000000", moduleData, GELATO_NATIVE_TOKEN);
    }

    /// @notice Requests an update of the ownership of the account representing the repository.
    /// The actual update of the owner will be made in a future transaction.
    /// The Gelato fee will be paid in native tokens when the actual owner update is made.
    /// The fee is paid from the funds deposited for the message sender calling this function.
    /// If these funds aren't enough, the missing part is paid from the common funds.
    ///
    /// The repository must contain a `FUNDING.json` file in the project root in the default branch.
    /// The file must be a valid JSON with arbitrary data, but it must contain the owner address
    /// as a hexadecimal string under `drips` -> `<CHAIN NAME>` -> `ownedBy`, a minimal example:
    /// `{ "drips": { "ethereum": { "ownedBy": "0x0123456789abcDEF0123456789abCDef01234567" } } }`.
    /// If for whatever reason the owner address can't be obtained, it's assumed to be address zero.
    ///
    /// This function applies an artificial gas cost penalty to limit the number of calls.
    /// The penalty increases by a constant amount after each call
    /// and decreases linearly over time until it returns to `0`.
    /// @param forge The forge where the repository is stored.
    /// @param name The name of the repository.
    /// For GitHub and GitLab it must follow the `user_name/repository_name` structure
    /// and it must be formatted identically as in the repository's URL,
    /// including the case of each letter and special characters being removed.
    function requestUpdateOwner(Forge forge, bytes calldata name) public whenNotPaused {
        _applyRequestUpdateOwnerGasPenalty();
        emit OwnerUpdateRequested(calcAccountId(forge, name), forge, name, _msgSender());
    }

    /// @notice Applies an artificial gas cost penalty to limit the number of calls.
    /// The penalty increases by a constant amount after each call
    /// and decreases linearly over time until it returns to `0`.
    function _applyRequestUpdateOwnerGasPenalty() internal {
        uint72 penalty = _requestUpdateOwnerPenalty();
        uint256 gasPenalty = _penaltyToGas(penalty);
        for (uint256 initialGasLeft = gasleft(); initialGasLeft - gasleft() < gasPenalty;) {
            continue;
        }
        _gelatoStorage().requestsPenalty.lastRequestPenalty = penalty;
        _gelatoStorage().requestsPenalty.lastRequestTimestamp = uint40(block.timestamp);
    }

    /// @notice Calculates the current gas cost penalty of `requestUpdateOwner`.
    /// @return gasPenalty The gas cost penalty.
    function requestUpdateOwnerGasPenalty() public view returns (uint256 gasPenalty) {
        return _penaltyToGas(_requestUpdateOwnerPenalty());
    }

    /// @notice Calculates the unitless penalty of `requestUpdateOwner`.
    /// @return penalty The penalty.
    function _requestUpdateOwnerPenalty() internal view returns (uint72 penalty) {
        RequestsPenalty storage requestsPenalty = _gelatoStorage().requestsPenalty;
        penalty = requestsPenalty.lastRequestPenalty + requestsPenalty.penaltyIncreasePerRequest;
        uint256 penaltyDecrease = (block.timestamp - requestsPenalty.lastRequestTimestamp)
            * requestsPenalty.penaltyDecreasePerSecond;
        if (penaltyDecrease > penalty) penaltyDecrease = penalty;
        penalty -= uint72(penaltyDecrease);
    }

    /// @notice Calculates the gas cost penalty from the unitless penalty.
    /// @return gasPenalty The gas cost penalty.
    function _penaltyToGas(uint72 penalty) internal view returns (uint256 gasPenalty) {
        return block.gaslimit * penalty / MAX_PENALTY;
    }

    /// @notice Updates the account owner.
    /// Callable only via the Gelato proxy by the Gelato task created by this contract.
    /// @param accountId The ID of the account having the ownership updated.
    /// @param owner The new owner of the account.
    /// @param payer The address of the user paying the fees.
    /// The Gelato fee will be paid in native tokens when the actual owner update is made.
    /// The fee is paid from the funds deposited for the message sender calling this function.
    /// If these funds aren't enough, the missing part is paid from the common funds.
    function updateOwnerByGelato(uint256 accountId, address owner, address payer)
        public
        whenNotPaused
    {
        require(msg.sender == _gelatoStorage().gelatoProxy, "Callable only by Gelato");
        require(_repoDriverStorage().accountOwners[accountId] != owner, "New owner is the same");
        _repoDriverStorage().accountOwners[accountId] = owner;
        emit OwnerUpdated(accountId, owner);
        _payGelatoFee(payer);
    }

    /// @notice Pay the Gelato fee for the currently executed Gelato task.
    /// @param payer The address of the user paying the fees.
    /// The Gelato fee will be paid in native tokens when the actual owner update is made.
    /// The fee is paid from the funds deposited for the message sender calling this function.
    /// If these funds aren't enough, the missing part is paid from the common funds.
    function _payGelatoFee(address payer) internal {
        (uint256 amount, address token) = gelatoAutomate.getFeeDetails();
        require(token == GELATO_NATIVE_TOKEN, "Payment must be in native tokens");
        if (amount == 0) return;
        uint256 userFundsUsed = userFunds(payer);
        if (userFundsUsed >= amount) {
            userFundsUsed = amount;
        } else {
            require(commonFunds() >= amount - userFundsUsed, "Not enough funds");
        }
        if (userFundsUsed != 0) {
            _gelatoStorage().userFunds[payer] -= userFundsUsed;
            _gelatoStorage().userFundsTotal -= userFundsUsed;
        }
        Address.sendValue(gelatoFeeCollector, amount);
        emit GelatoFeePaid(payer, userFundsUsed, amount - userFundsUsed);
    }

    /// @notice The amount of native tokens deposited as common funds.
    /// Used to pay Gelato fees when the user's funds aren't enough.
    /// To deposit more tokens transfer them to this contract address.
    /// @return amount The deposited amount.
    function commonFunds() public view returns (uint256 amount) {
        return address(this).balance - _gelatoStorage().userFundsTotal;
    }

    /// @notice The amount of native tokens deposited by the user.
    /// Used to pay Gelato fees for that user's requests.
    /// If these funds aren't enough, the missing part is paid from the common funds.
    /// @return amount The deposited amount.
    function userFunds(address user) public view returns (uint256 amount) {
        return _gelatoStorage().userFunds[user];
    }

    /// @notice Deposits the native tokens sent with the message for the user.
    /// These funds will be used to pay Gelato fees for that user's requests.
    /// @param user The user for whom the deposit is made.
    function depositUserFunds(address user) public payable whenNotPaused {
        _gelatoStorage().userFunds[user] += msg.value;
        _gelatoStorage().userFundsTotal += msg.value;
        emit UserFundsDeposited(user, msg.value);
    }

    /// @notice Withdraws the native tokens deposited for the message sender.
    /// @param amount The amount to withdraw or `0` to withdraw all.
    /// @param receiver The address to send the withdrawn funds to.
    /// @return withdrawnAmount The amount that was withdrawn.
    function withdrawUserFunds(uint256 amount, address payable receiver)
        public
        whenNotPaused
        returns (uint256 withdrawnAmount)
    {
        address user = _msgSender();
        uint256 maxAmount = userFunds(user);
        if (amount == 0) {
            amount = maxAmount;
            if (amount == 0) return 0;
        } else {
            require(amount <= maxAmount, "Not enough user funds");
        }
        _gelatoStorage().userFunds[user] -= amount;
        _gelatoStorage().userFundsTotal -= amount;
        Address.sendValue(receiver, amount);
        emit UserFundsWithdrawn(user, amount, receiver);
        return amount;
    }

    /// @notice Collects the account's received already split funds
    /// and transfers them out of the Drips contract.
    /// @param accountId The ID of the collecting account.
    /// The caller must be the owner of the account.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param transferTo The address to send collected funds to
    /// @return amt The collected amount
    function collect(uint256 accountId, IERC20 erc20, address transferTo)
        public
        whenNotPaused
        onlyOwner(accountId)
        returns (uint128 amt)
    {
        amt = drips.collect(accountId, erc20);
        if (amt > 0) drips.withdraw(erc20, transferTo, amt);
    }

    /// @notice Gives funds from the account to the receiver.
    /// The receiver can split and collect them immediately.
    /// Transfers the funds to be given from the message sender's wallet to the Drips contract.
    /// @param accountId The ID of the giving account. The caller must be the owner of the account.
    /// @param receiver The receiver account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param amt The given amount
    function give(uint256 accountId, uint256 receiver, IERC20 erc20, uint128 amt)
        public
        whenNotPaused
        onlyOwner(accountId)
    {
        _giveAndTransfer(accountId, receiver, erc20, amt);
    }

    /// @notice Sets the account's streams configuration.
    /// Transfers funds between the message sender's wallet and the Drips contract
    /// to fulfil the change of the streams balance.
    /// @param accountId The ID of the configured account.
    /// The caller must be the owner of the account.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The current streams receivers list.
    /// It must be exactly the same as the last list set for the account with `setStreams`.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The streams balance change to be applied.
    /// Positive to add funds to the streams balance, negative to remove them.
    /// @param newReceivers The list of the streams receivers of the sender to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @param maxEndHint1 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The first hint for finding the maximum end time when all streams stop due to funds
    /// running out after the balance is updated and the new receivers list is applied.
    /// Hints have no effect on the results of calling this function, except potentially saving gas.
    /// Hints are Unix timestamps used as the starting points for binary search for the time
    /// when funds run out in the range of timestamps from the current block's to `2^32`.
    /// Hints lower than the current timestamp are ignored.
    /// You can provide zero, one or two hints. The order of hints doesn't matter.
    /// Hints are the most effective when one of them is lower than or equal to
    /// the last timestamp when funds are still streamed, and the other one is strictly larger
    /// than that timestamp,the smaller the difference between such hints, the higher gas savings.
    /// The savings are the highest possible when one of the hints is equal to
    /// the last timestamp when funds are still streamed, and the other one is larger by 1.
    /// It's worth noting that the exact timestamp of the block in which this function is executed
    /// may affect correctness of the hints, especially if they're precise.
    /// Hints don't provide any benefits when balance is not enough to cover
    /// a single second of streaming or is enough to cover all streams until timestamp `2^32`.
    /// Even inaccurate hints can be useful, and providing a single hint
    /// or two hints that don't enclose the time when funds run out can still save some gas.
    /// Providing poor hints that don't reduce the number of binary search steps
    /// may cause slightly higher gas usage than not providing any hints.
    /// @param maxEndHint2 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The second hint for finding the maximum end time, see `maxEndHint1` docs for more details.
    /// @param transferTo The address to send funds to in case of decreasing balance
    /// @return realBalanceDelta The actually applied streams balance change.
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
    ) public whenNotPaused onlyOwner(accountId) returns (int128 realBalanceDelta) {
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

    /// @notice Sets the account splits configuration.
    /// The configuration is common for all ERC-20 tokens.
    /// Nothing happens to the currently splittable funds, but when they are split
    /// after this function finishes, the new splits configuration will be used.
    /// Because anybody can call `split` on `Drips`, calling this function may be frontrun
    /// and all the currently splittable funds will be split using the old splits configuration.
    /// @param accountId The ID of the configured account.
    /// The caller must be the owner of the account.
    /// @param receivers The list of the account's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the account.
    /// If the sum of weights of all receivers is less than `_TOTAL_SPLITS_WEIGHT`,
    /// some funds won't be split, but they will be left for the account to collect.
    /// It's valid to include the account's own `accountId` in the list of receivers,
    /// but funds split to themselves return to their splittable balance and are not collectable.
    /// This is usually unwanted, because if splitting is repeated,
    /// funds split to themselves will be again split using the current configuration.
    /// Splitting 100% to self effectively blocks splitting unless the configuration is updated.
    function setSplits(uint256 accountId, SplitsReceiver[] calldata receivers)
        public
        whenNotPaused
        onlyOwner(accountId)
    {
        drips.setSplits(accountId, receivers);
    }

    /// @notice Emits the account's metadata.
    /// The keys and the values are not standardized by the protocol, it's up to the users
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param accountId The ID of the emitting account.
    /// The caller must be the owner of the account.
    /// @param accountMetadata The list of account metadata.
    function emitAccountMetadata(uint256 accountId, AccountMetadata[] calldata accountMetadata)
        public
        whenNotPaused
        onlyOwner(accountId)
    {
        if (accountMetadata.length == 0) return;
        drips.emitAccountMetadata(accountId, accountMetadata);
    }

    /// @notice Returns the RepoDriver storage.
    /// @return storageRef The storage.
    function _repoDriverStorage() internal view returns (RepoDriverStorage storage storageRef) {
        bytes32 slot = _repoDriverStorageSlot;
        // slither-disable-next-line assembly
        assembly {
            storageRef.slot := slot
        }
    }

    /// @notice Returns the Gelato storage.
    /// @return storageRef The storage.
    function _gelatoStorage() internal view returns (GelatoStorage storage storageRef) {
        bytes32 slot = _gelatoStorageSlot;
        // slither-disable-next-line assembly
        assembly {
            storageRef.slot := slot
        }
    }
}

/// @notice The lightweight contract capable of creating and cancelling Gelato tasks.
/// Used to run tasks using a Gelato subscription not attached to the owner's address.
contract GelatoTasksOwner {
    /// @notice The owner of this contract.
    address public immutable owner;
    /// @notice The Gelato Automate contract used for running oracle tasks.
    IAutomate internal immutable _gelatoAutomate;

    /// @param gelatoAutomate The Gelato Automate contract used for running oracle tasks.
    constructor(IAutomate gelatoAutomate) {
        owner = msg.sender;
        _gelatoAutomate = gelatoAutomate;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Callable only by the owner");
        _;
    }

    /// @notice Cancel the task owned by this contract. Only callable by the owner.
    /// @param taskId The ID of the cancelled task.
    function cancelTask(bytes32 taskId) public onlyOwner {
        _gelatoAutomate.cancelTask(taskId);
    }

    /// @notice Create a task owned by this contract. Only callable by the owner.
    /// @param execAddress The address that should be called by the new task.
    /// @param execDataOrSelector The calldata the address should be called by the new task.
    /// @param moduleData The modules defining the task configuration.
    /// @param feeToken The token used for paying the execution fees.
    /// Pass the zero address to use 1Balance and 0xEE..EE to use the native token.
    /// @return taskId The ID of the created task.
    function createTask(
        address execAddress,
        bytes calldata execDataOrSelector,
        ModuleData calldata moduleData,
        address feeToken
    ) public onlyOwner returns (bytes32 taskId) {
        return _gelatoAutomate.createTask(execAddress, execDataOrSelector, moduleData, feeToken);
    }
}

/// @notice The minimal dummy implementation of Gelato Automate
/// for testing RepoDriver on networks where Gelato isn't deployed.
contract DummyGelatoAutomate {
    function updateOwner(RepoDriver repoDriver, uint256 accountId, address owner) public {
        repoDriver.updateOwnerByGelato(accountId, owner, address(0));
    }

    function gelato() public view returns (address) {
        return address(this);
    }

    function feeCollector() public pure returns (address) {
        return address(0);
    }

    function taskModuleAddresses(Module) public view returns (address) {
        return address(this);
    }

    function opsProxyFactory() public view returns (address) {
        return address(this);
    }

    function getProxyOf(address) public view returns (address, bool) {
        return (address(this), true);
    }

    function getTaskIdsByUser(address) public pure returns (bytes32[] memory) {
        return new bytes32[](0);
    }

    function createTask(address, bytes calldata, ModuleData calldata, address)
        public
        pure
        returns (bytes32)
    {
        return 0;
    }

    function getFeeDetails() public pure returns (uint256, address) {
        return (0, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }
}
