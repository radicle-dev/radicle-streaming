// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.24;

import {
    AccountMetadata,
    IERC20,
    MaxEndHints,
    SplitsReceiver,
    StreamConfig,
    StreamReceiver,
    StreamsHistory
} from "./DripsLib.sol";

/// @notice Drips protocol automatically streams and splits funds between accounts.
///
/// The account can transfer some funds to their streams balance in the contract
/// and configure a list of receivers, to whom they want to stream these funds.
/// As soon as the streams balance is enough to cover at least 1 second of streaming
/// to the configured receivers, the funds start streaming automatically.
/// Every second funds are deducted from the streams balance and moved to their receivers.
/// The process stops automatically when the streams balance is not enough to cover another second.
///
/// Every account has a receiver balance, in which they have funds received from other accounts.
/// The streamed funds are added to the receiver balances in global cycles.
/// Every `cycleSecs` seconds the protocol adds streamed funds to the receivers' balances,
/// so recently streamed funds may not be receivable immediately.
/// `cycleSecs` is a constant configured when the Drips contract is deployed.
/// The receiver balance is independent from the streams balance,
/// to stream received funds they need to be first collected and then added to the streams balance.
///
/// The account can share collected funds with other accounts by using splits.
/// When collecting, the account gives each of their splits receivers
/// a fraction of the received funds.
/// Funds received from splits are available for collection immediately regardless of the cycle.
/// They aren't exempt from being split, so they too can be split when collected.
/// Accounts can build chains and networks of splits between each other.
/// Anybody can request collection of funds for any account,
/// which can be used to enforce the flow of funds in the network of splits.
///
/// The concept of something happening periodically, e.g. every second or every `cycleSecs` are
/// only high-level abstractions for the account, Ethereum isn't really capable of scheduling work.
/// The actual implementation emulates that behavior by calculating the results of the scheduled
/// events based on how many seconds have passed and only when the account needs their outcomes.
///
/// The contract can store at most `type(int128).max` which is `2 ^ 127 - 1` units of each token.
interface IDrips {
    /// @notice Emitted when a driver is registered
    /// @param driverId The driver ID
    /// @param driverAddr The driver address
    event DriverRegistered(uint32 indexed driverId, address indexed driverAddr);

    /// @notice Emitted when a driver address is updated
    /// @param driverId The driver ID
    /// @param oldDriverAddr The old driver address
    /// @param newDriverAddr The new driver address
    event DriverAddressUpdated(
        uint32 indexed driverId, address indexed oldDriverAddr, address indexed newDriverAddr
    );

    /// @notice Emitted when funds are withdrawn.
    /// @param erc20 The used ERC-20 token.
    /// @param receiver The address that the funds are sent to.
    /// @param amt The withdrawn amount.
    event Withdrawn(IERC20 indexed erc20, address indexed receiver, uint256 amt);

    /// @notice Emitted when streams are received.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param amt The received amount.
    /// @param receivableCycles The number of cycles which still can be received.
    event ReceivedStreams(
        uint256 indexed accountId, IERC20 indexed erc20, uint128 amt, uint32 receivableCycles
    );

    /// @notice Emitted when streams are squeezed.
    /// @param accountId The squeezing account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param senderId The ID of the streaming account from whom funds are squeezed.
    /// @param amt The squeezed amount.
    /// @param streamsHistoryHashes The history hashes of all squeezed streams history entries.
    /// Each history hash matches `streamsHistoryHash` emitted in its `StreamsSet`
    /// when the squeezed streams configuration was set.
    /// Sorted in the oldest streams configuration to the newest.
    event SqueezedStreams(
        uint256 indexed accountId,
        IERC20 indexed erc20,
        uint256 indexed senderId,
        uint128 amt,
        bytes32[] streamsHistoryHashes
    );

    /// @notice Emitted when an account splits funds.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param amt The amount that was split.
    event Split(uint256 indexed accountId, IERC20 indexed erc20, uint128 amt);

    /// @notice Emitted when an account collects funds
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param collected The collected amount
    event Collected(uint256 indexed accountId, IERC20 indexed erc20, uint128 collected);

    /// @notice Emitted when funds are given from the account to the receiver.
    /// @param accountId The account ID.
    /// @param receiver The receiver account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param amt The given amount
    event Given(
        uint256 indexed accountId, uint256 indexed receiver, IERC20 indexed erc20, uint128 amt
    );

    /// @notice Emitted when the streams configuration of an account is updated.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// @param receiversHash The streams receivers list hash.
    /// @param streamsHistoryHash The streams history hash that was valid right before the update.
    /// @param balance The account's streams balance. These funds will be streamed to the receivers.
    /// @param maxEnd The maximum end time of streaming, when funds run out.
    /// If funds run out after the timestamp `type(uint32).max`, it's set to `type(uint32).max`.
    /// If the balance is 0 or there are no receivers, it's set to the current timestamp.
    event StreamsSet(
        uint256 indexed accountId,
        IERC20 indexed erc20,
        bytes32 indexed receiversHash,
        bytes32 streamsHistoryHash,
        uint128 balance,
        uint32 maxEnd
    );

    /// @notice Emitted when a streams receivers list may be used for the first time.
    /// @param receiversHash The streams receivers list hash
    /// @param receivers The list of the streams receivers.
    event StreamReceiversSeen(bytes32 indexed receiversHash, StreamReceiver[] receivers);

    /// @notice Emitted when the account's splits are updated.
    /// @param accountId The account ID.
    /// @param receiversHash The splits receivers list hash.
    event SplitsSet(uint256 indexed accountId, bytes32 indexed receiversHash);

    /// @notice Emitted when a splits receivers list may be used for the first time.
    /// @param receiversHash The splits receivers list hash
    /// @param receivers The list of the splits receivers.
    event SplitsReceiversSeen(bytes32 indexed receiversHash, SplitsReceiver[] receivers);

    /// @notice Emitted by the account to broadcast metadata.
    /// The key and the value are not standardized by the protocol, it's up to the users
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param accountId The ID of the account emitting metadata
    /// @param key The metadata key
    /// @param value The metadata value
    event AccountMetadataEmitted(uint256 indexed accountId, bytes32 indexed key, bytes value);

    /// @notice Returns the length of the cycle in seconds. This value never changes.
    /// On every timestamp `T`, which is a multiple of `cycleSecs`, the receivers
    /// gain access to steams received during `T - cycleSecs` to `T - 1`.
    /// @return cycleSecs_ The length of the cycle in seconds. Always higher than 1.
    function cycleSecs() external view returns (uint32 cycleSecs_);

    /// @notice Registers a driver.
    /// The driver is assigned a unique ID and a range of account IDs it can control.
    /// That range consists of all 2^224 account IDs with highest 32 bits equal to the driver ID.
    /// Every account ID is a 256-bit integer constructed by concatenating:
    /// `driverId (32 bits) | driverCustomData (224 bits)`.
    /// Every driver ID is assigned only to a single address,
    /// but a single address can have multiple driver IDs assigned to it.
    /// @param driverAddr The address of the driver. Must not be zero address.
    /// It should be a smart contract capable of dealing with the Drips API.
    /// It shouldn't be an EOA because the API requires making multiple calls per transaction.
    /// @return driverId The registered driver ID.
    function registerDriver(address driverAddr) external returns (uint32 driverId);

    /// @notice Returns the driver address.
    /// @param driverId The driver ID to look up.
    /// @return driverAddr The address of the driver.
    /// If the driver hasn't been registered yet, returns address 0.
    function driverAddress(uint32 driverId) external view returns (address driverAddr);

    /// @notice Updates the driver address. Must be called from the current driver address.
    /// @param driverId The driver ID.
    /// @param newDriverAddr The new address of the driver.
    /// It should be a smart contract capable of dealing with the Drips API.
    /// It shouldn't be an EOA because the API requires making multiple calls per transaction.
    function updateDriverAddress(uint32 driverId, address newDriverAddr) external;

    /// @notice Returns the driver ID which will be assigned for the next registered driver.
    /// @return driverId The next driver ID.
    function nextDriverId() external view returns (uint32 driverId);

    /// @notice Returns the amount currently stored in the protocol of the given token.
    /// The sum of streaming and splitting balances can never exceed `DripsLib.MAX_TOTAL_BALANCE`.
    /// The amount of tokens held by the Drips contract exceeding the sum of
    /// streaming and splitting balances can be `withdraw`n.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return streamsBalance The balance currently stored in the protocol in streaming.
    /// It's the sum of all the funds of all the users
    /// that are in the streams balances, are squeezable or are receivable.
    /// @return splitsBalance The balance currently stored in the protocol in splitting.
    /// It's the sum of all the funds of all the users that are splittable or are collectable.
    function balances(IERC20 erc20)
        external
        view
        returns (uint256 streamsBalance, uint256 splitsBalance);

    /// @notice Transfers withdrawable funds to an address.
    /// The withdrawable funds are held by the Drips contract,
    /// but not used in the protocol, so they are free to be transferred out.
    /// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
    /// or used in the protocol before any 3rd parties have a chance to do that.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param receiver The address to send withdrawn funds to.
    /// @param amt The withdrawn amount.
    /// It must be at most the difference between the balance of the token held by the Drips
    /// contract address and the sum of balances managed by the protocol as indicated by `balances`.
    function withdraw(IERC20 erc20, address receiver, uint256 amt) external;

    /// @notice Counts cycles from which streams can be collected.
    /// This function can be used to detect that there are
    /// too many cycles to analyze in a single transaction.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return cycles The number of cycles which can be flushed
    function receivableStreamsCycles(uint256 accountId, IERC20 erc20)
        external
        view
        returns (uint32 cycles);

    /// @notice Calculate effects of calling `receiveStreams` with the given parameters.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param maxCycles The maximum number of received streams cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivableAmt The amount which would be received
    function receiveStreamsResult(uint256 accountId, IERC20 erc20, uint32 maxCycles)
        external
        view
        returns (uint128 receivableAmt);

    /// @notice Receive streams for the account.
    /// Received streams cycles won't need to be analyzed ever again.
    /// Calling this function does not collect but makes the funds ready to be split and collected.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param maxCycles The maximum number of received streams cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivedAmt The received amount
    function receiveStreams(uint256 accountId, IERC20 erc20, uint32 maxCycles)
        external
        returns (uint128 receivedAmt);

    /// @notice Receive streams from the currently running cycle from a single sender.
    /// It doesn't receive streams from the finished cycles, to do that use `receiveStreams`.
    /// Squeezed funds won't be received in the next calls to `squeezeStreams` or `receiveStreams`.
    /// Only funds streamed before `block.timestamp` can be squeezed.
    /// @param accountId The ID of the account receiving streams to squeeze funds for.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param senderId The ID of the streaming account to squeeze funds from.
    /// @param historyHash The sender's history hash that was valid right before
    /// they set up the sequence of configurations described by `streamsHistory`.
    /// @param streamsHistory The sequence of the sender's streams configurations.
    /// It can start at an arbitrary past configuration, but must describe all the configurations
    /// which have been used since then including the current one, in the chronological order.
    /// Only streams described by `streamsHistory` will be squeezed.
    /// If `streamsHistory` entries have no receivers, they won't be squeezed.
    /// @return amt The squeezed amount.
    function squeezeStreams(
        uint256 accountId,
        IERC20 erc20,
        uint256 senderId,
        bytes32 historyHash,
        StreamsHistory[] calldata streamsHistory
    ) external returns (uint128 amt);

    /// @notice Calculate effects of calling `squeezeStreams` with the given parameters.
    /// See its documentation for more details.
    /// @param accountId The ID of the account receiving streams to squeeze funds for.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param senderId The ID of the streaming account to squeeze funds from.
    /// @param historyHash The sender's history hash that was valid right before `streamsHistory`.
    /// @param streamsHistory The sequence of the sender's streams configurations.
    /// @return amt The squeezed amount.
    function squeezeStreamsResult(
        uint256 accountId,
        IERC20 erc20,
        uint256 senderId,
        bytes32 historyHash,
        StreamsHistory[] calldata streamsHistory
    ) external view returns (uint128 amt);

    /// @notice Returns account's received but not split yet funds.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return amt The amount received but not split yet.
    function splittable(uint256 accountId, IERC20 erc20) external view returns (uint128 amt);

    /// @notice Calculate the result of splitting an amount using the current splits configuration.
    /// Fractions of tokens are always rounded either up or down depending on the amount
    /// being split, the receiver's position on the list and the other receivers' weights.
    /// @param accountId The account ID.
    /// @param currReceivers The list of the account's current splits receivers.
    /// It must be exactly the same as the last list set for the account with `setSplits`.
    /// If the splits have never been set, pass an empty array.
    /// @param amount The amount being split.
    /// @return collectableAmt The amount made collectable for the account
    /// on top of what was collectable before.
    /// @return splitAmt The amount split to the account's splits receivers
    function splitResult(uint256 accountId, SplitsReceiver[] calldata currReceivers, uint128 amount)
        external
        view
        returns (uint128 collectableAmt, uint128 splitAmt);

    /// @notice Splits the account's splittable funds among receivers.
    /// The entire splittable balance of the given ERC-20 token is split.
    /// Fractions of tokens are always rounded either up or down depending on the amount
    /// being split, the receiver's position on the list and the other receivers' weights.
    /// All split funds are split using the current splits configuration.
    /// Because the account can update their splits configuration at any time,
    /// it is possible that calling this function will be frontrun,
    /// and all the splittable funds will become splittable only using the new configuration.
    /// The account must be trusted with how funds sent to them will be splits,
    /// in the end they can do with their funds whatever they want by changing the configuration.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The list of the account's current splits receivers.
    /// It must be exactly the same as the last list set for the account with `setSplits`.
    /// If the splits have never been set, pass an empty array.
    /// @return collectableAmt The amount made collectable for the account
    /// on top of what was collectable before.
    /// @return splitAmt The amount split to the account's splits receivers
    function split(uint256 accountId, IERC20 erc20, SplitsReceiver[] calldata currReceivers)
        external
        returns (uint128 collectableAmt, uint128 splitAmt);

    /// @notice Returns account's received funds already split and ready to be collected.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return amt The collectable amount.
    function collectable(uint256 accountId, IERC20 erc20) external view returns (uint128 amt);

    /// @notice Collects account's received already split funds and makes them withdrawable.
    /// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
    /// or used in the protocol before any 3rd parties have a chance to do that.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return amt The collected amount
    function collect(uint256 accountId, IERC20 erc20) external returns (uint128 amt);

    /// @notice Gives funds from the account to the receiver.
    /// The receiver can split and collect them immediately.
    /// Requires that the tokens used to give are already sent to Drips and are withdrawable.
    /// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
    /// or used in the protocol before any 3rd parties have a chance to do that.
    /// @param accountId The account ID.
    /// @param receiver The receiver account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param amt The given amount
    function give(uint256 accountId, uint256 receiver, IERC20 erc20, uint128 amt) external;

    /// @notice Current account streams state.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @return streamsHash The current streams receivers list hash, see `hashStreams`
    /// @return streamsHistoryHash The current streams history hash, see `hashStreamsHistory`.
    /// @return updateTime The time when streams have been configured for the last time.
    /// @return balance The balance when streams have been configured for the last time.
    /// @return maxEnd The current maximum end time of streaming.
    function streamsState(uint256 accountId, IERC20 erc20)
        external
        view
        returns (
            bytes32 streamsHash,
            bytes32 streamsHistoryHash,
            uint32 updateTime,
            uint128 balance,
            uint32 maxEnd
        );

    /// @notice The account's streams balance at the given timestamp.
    /// @param accountId The account ID.
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The current streams receivers list.
    /// It must be exactly the same as the last list set for the account with `setStreams`.
    /// @param timestamp The timestamp for which balance should be calculated.
    /// It can't be lower than the timestamp of the last call to `setStreams`.
    /// If it's bigger than `block.timestamp`, then it's a prediction assuming
    /// that `setStreams` won't be called before `timestamp`.
    /// @return balance The account balance on `timestamp`
    function balanceAt(
        uint256 accountId,
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        uint32 timestamp
    ) external view returns (uint128 balance);

    /// @notice Sets the account's streams configuration.
    /// Requires that the tokens used to increase the streams balance
    /// are already sent to Drips and are withdrawable.
    /// If the streams balance is decreased, the released tokens become withdrawable.
    /// Anybody can call `withdraw`, so all withdrawable funds should be withdrawn
    /// or used in the protocol before any 3rd parties have a chance to do that.
    /// @param accountId The account ID.
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
    /// If it's positive, the balance is increased by `balanceDelta`.
    /// If it's zero, the balance doesn't change.
    /// If it's negative, the balance is decreased by `balanceDelta`,
    /// but the change is capped at the current balance amount, so it doesn't go below 0.
    /// Passing `type(int128).min` always decreases the current balance to 0.
    /// @param newReceivers The list of the streams receivers of the account to be set.
    /// Must be sorted by the account IDs and then by the stream configurations,
    /// without identical elements and without 0 amtPerSecs.
    /// @param maxEndHints An optional parameter allowing gas optimization.
    /// Pass a list of 8 zero value hints to ignore it, it's represented as an integer `0`.
    /// The list of hints for finding the maximum end time when all streams stop due to funds
    /// running out after the balance is updated and the new receivers list is applied.
    /// Hints have no effect on the results of calling this function, except potentially saving gas.
    /// Hints are Unix timestamps used as the starting points for binary search for the time
    /// when funds run out in the range of timestamps from the current block's to `2^32`.
    /// Hints lower than the current timestamp including the zero value hints are ignored.
    /// If you provide fewer than 8 non-zero value hints make them the rightmost values to save gas.
    /// It's the best approach to make the most risky and precise hints the rightmost ones.
    /// Hints are the most effective when one of them is lower than or equal to
    /// the last timestamp when funds are still streamed, and the other one is strictly larger
    /// than that timestamp, the smaller the difference between such hints, the more gas is saved.
    /// The savings are the highest possible when one of the hints is equal to
    /// the last timestamp when funds are still streamed, and the other one is larger by 1.
    /// It's worth noting that the exact timestamp of the block in which this function is executed
    /// may affect correctness of the hints, especially if they're precise.
    /// Hints don't provide any benefits when balance is not enough to cover
    /// a single second of streaming or is enough to cover all streams until timestamp `2^32`.
    /// Even inaccurate hints can be useful, and providing a single hint
    /// or hints that don't enclose the time when funds run out can still save some gas.
    /// Providing poor hints that don't reduce the number of binary search steps
    /// may cause slightly higher gas usage than not providing any hints.
    /// @return realBalanceDelta The actually applied streams balance change.
    /// It's equal to the passed `balanceDelta`, unless it's negative
    /// and it gets capped at the current balance amount.
    /// If it's lower than zero, it's the negative of the amount that became withdrawable.
    function setStreams(
        uint256 accountId,
        IERC20 erc20,
        StreamReceiver[] calldata currReceivers,
        int128 balanceDelta,
        StreamReceiver[] calldata newReceivers,
        MaxEndHints maxEndHints
    ) external returns (int128 realBalanceDelta);

    /// @notice Calculates the hash of the streams configuration.
    /// It's used to verify if streams configuration is the previously set one.
    /// @param receivers The list of the streams receivers.
    /// Must be sorted by the account IDs and then by the stream configurations,
    /// without identical elements and without 0 amtPerSecs.
    /// If the streams have never been set, pass an empty array.
    /// @return streamsHash The hash of the streams configuration
    function hashStreams(StreamReceiver[] calldata receivers)
        external
        pure
        returns (bytes32 streamsHash);

    /// @notice Calculates the hash of the streams history
    /// after the streams configuration is updated.
    /// @param oldStreamsHistoryHash The history hash
    /// that was valid before the streams were updated.
    /// The `streamsHistoryHash` of the account before they set streams for the first time is `0`.
    /// @param streamsHash The hash of the streams receivers being set.
    /// @param updateTime The timestamp when the streams were updated.
    /// @param maxEnd The maximum end of the streams being set.
    /// @return streamsHistoryHash The hash of the updated streams history.
    function hashStreamsHistory(
        bytes32 oldStreamsHistoryHash,
        bytes32 streamsHash,
        uint32 updateTime,
        uint32 maxEnd
    ) external pure returns (bytes32 streamsHistoryHash);

    /// @notice Sets the account splits configuration.
    /// The configuration is common for all ERC-20 tokens.
    /// Nothing happens to the currently splittable funds, but when they are split
    /// after this function finishes, the new splits configuration will be used.
    /// Because anybody can call `split`, calling this function may be frontrun
    /// and all the currently splittable funds will be split using the old splits configuration.
    /// @param accountId The account ID.
    /// @param receivers The list of the account's splits receivers to be set.
    /// Must be sorted by the account IDs, without duplicate account IDs and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the account.
    /// If the sum of weights of all receivers is less than `DripsLib.TOTAL_SPLITS_WEIGHT`,
    /// some funds won't be split, but they will be left for the account to collect.
    /// Fractions of tokens are always rounded either up or down depending on the amount
    /// being split, the receiver's position on the list and the other receivers' weights.
    /// It's valid to include the account's own `accountId` in the list of receivers,
    /// but funds split to themselves return to their splittable balance and are not collectable.
    /// This is usually unwanted, because if splitting is repeated,
    /// funds split to themselves will be again split using the current configuration.
    /// Splitting 100% to self effectively blocks splitting unless the configuration is updated.
    function setSplits(uint256 accountId, SplitsReceiver[] calldata receivers) external;

    /// @notice Current account's splits hash, see `hashSplits`.
    /// @param accountId The account ID.
    /// @return currSplitsHash The current account's splits hash
    function splitsHash(uint256 accountId) external view returns (bytes32 currSplitsHash);

    /// @notice Calculates the hash of the list of splits receivers.
    /// @param receivers The list of the splits receivers.
    /// Must be sorted by the account IDs, without duplicate account IDs and without 0 weights.
    /// @return receiversHash The hash of the list of splits receivers.
    function hashSplits(SplitsReceiver[] calldata receivers)
        external
        pure
        returns (bytes32 receiversHash);

    /// @notice Emits account metadata.
    /// The keys and the values are not standardized by the protocol, it's up to the users
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param accountId The account ID.
    /// @param accountMetadata The list of account metadata.
    function emitAccountMetadata(uint256 accountId, AccountMetadata[] calldata accountMetadata)
        external;
}