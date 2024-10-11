// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IWrappedNativeToken} from "./IWrappedNativeToken.sol";
import {Address} from "openzeppelin-contracts/utils/Address.sol";

/// @notice A helper contract for unwrapping wrapped native tokens.
/// It's especially useful if the exact amount to unwrap isn't known upfront.
/// To use it, send the wrapped tokens to this contract address and call `unwrap`.
///
/// Remember that anybody can call `unwrap`, so if any 3rd party can execute logic
/// between the native tokens are sent and unwrapped, the funds will likely be stolen.
/// This means that the tokens should be unwrapped in the same transaction in which they were sent
/// and that no untrusted contracts should be called while this contracts holds any tokens.
contract NativeTokenUnwrapper {
    /// @notice The ERC-20 contract wrapping the native tokens.
    IWrappedNativeToken public immutable wrappedNativeToken;

    /// @notice Emitted when wrapped native tokens are unwrapped.
    /// @param recipient The recipient of the native tokens.
    /// @param amount The unwrapped amount.
    event Unwrapped(address indexed recipient, uint256 amount);

    /// @param wrappedNativeToken_ The ERC-20 contract wrapping the native tokens.
    constructor(IWrappedNativeToken wrappedNativeToken_) {
        wrappedNativeToken = wrappedNativeToken_;
    }

    receive() external payable {}

    /// @notice Unwraps all wrapped native tokens held by this contract
    /// and sends the native tokens to the recipient.
    /// Anybody can call this function and unwrap all the tokens.
    /// @param recipient The recipient of the native tokens.
    /// @return amount The unwrapped amount.
    function unwrap(address payable recipient) public returns (uint256 amount) {
        amount = wrappedNativeToken.balanceOf(address(this));
        if (amount > 0) {
            wrappedNativeToken.withdraw(amount);
            Address.sendValue(recipient, amount);
        }
        emit Unwrapped(recipient, amount);
    }
}
