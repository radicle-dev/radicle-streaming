// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.7;

import {ERC20DripsHub, Receiver} from "./ERC20DripsHub.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IDai is IERC20 {
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

struct PermitArgs {
    uint256 nonce;
    uint256 expiry;
    uint8 v;
    bytes32 r;
    bytes32 s;
}

/// @notice Drips hub contract for DAI token.
/// See the base `DripsHub` contract docs for more details.
contract DaiDripsHub is ERC20DripsHub {
    /// @notice The address of the Dai contract which tokens the drips hub works with.
    /// Always equal to `erc20`, but more strictly typed.
    IDai public immutable dai;

    /// @notice See `ERC20DripsHub` constructor documentation for more details.
    constructor(uint64 cycleSecs, IDai _dai) ERC20DripsHub(cycleSecs, _dai) {
        dai = _dai;
    }

    /// @notice Updates all the sender parameters of the sender of the message
    /// and permits spending sender's Dai by the drips hub.
    /// This function is an extension of `updateSender`, see its documentation for more details.
    ///
    /// The sender must sign a Dai permission document allowing the drips hub to spend their funds.
    /// These parameters will be passed to the Dai contract by this function.
    /// @param permitArgs The Dai permission arguments.
    function updateSenderAndPermit(
        uint64 lastUpdate,
        uint128 lastBalance,
        Receiver[] calldata currReceivers,
        int128 balanceDelta,
        Receiver[] calldata newReceivers,
        PermitArgs calldata permitArgs
    ) public returns (uint128 newBalance, int128 realBalanceDelta) {
        _permit(permitArgs);
        return updateSender(lastUpdate, lastBalance, currReceivers, balanceDelta, newReceivers);
    }

    /// @notice Updates all the parameters of an account of the sender of the message
    /// and permits spending sender's Dai by the drips hub.
    /// This function is an extension of `updateSender`, see its documentation for more details.
    ///
    /// The sender must sign a Dai permission document allowing the drips hub to spend their funds.
    /// These parameters will be passed to the Dai contract by this function.
    /// @param permitArgs The Dai permission arguments.
    function updateSenderAndPermit(
        uint256 account,
        uint64 lastUpdate,
        uint128 lastBalance,
        Receiver[] calldata currReceivers,
        int128 balanceDelta,
        Receiver[] calldata newReceivers,
        PermitArgs calldata permitArgs
    ) public returns (uint128 newBalance, int128 realBalanceDelta) {
        _permit(permitArgs);
        return
            updateSender(
                account,
                lastUpdate,
                lastBalance,
                currReceivers,
                balanceDelta,
                newReceivers
            );
    }

    /// @notice Gives funds from the sender of the message to the receiver
    /// and permits spending sender's Dai by the drips hub.
    /// This function is an extension of `give`, see its documentation for more details.
    ///
    /// The sender must sign a Dai permission document allowing the drips hub to spend their funds.
    /// These parameters will be passed to the Dai contract by this function.
    /// @param permitArgs The Dai permission arguments.
    function giveAndPermit(
        address receiver,
        uint128 amt,
        PermitArgs calldata permitArgs
    ) public {
        _permit(permitArgs);
        give(receiver, amt);
    }

    /// @notice Gives funds from the account of the sender of the message to the receiver
    /// and permits spending sender's Dai by the drips hub.
    /// This function is an extension of `give` see its documentation for more details.
    ///
    /// The sender must sign a Dai permission document allowing the drips hub to spend their funds.
    /// These parameters will be passed to the Dai contract by this function.
    /// @param permitArgs The Dai permission arguments.
    function giveAndPermit(
        uint256 account,
        address receiver,
        uint128 amt,
        PermitArgs calldata permitArgs
    ) public {
        _permit(permitArgs);
        give(account, receiver, amt);
    }

    /// @notice Permits the drips hub to spend the message sender's Dai.
    /// @param permitArgs The Dai permission arguments.
    function _permit(PermitArgs calldata permitArgs) internal {
        dai.permit(
            msg.sender,
            address(this),
            permitArgs.nonce,
            permitArgs.expiry,
            true,
            permitArgs.v,
            permitArgs.r,
            permitArgs.s
        );
    }
}
