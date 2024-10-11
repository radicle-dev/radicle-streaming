// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.20;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

/// @notice The ERC-20 contract wrapping the native tokens.
/// This interface is implemented by many contracts, e.g. WETH9, WETH10, WFIL and their derivatives.
interface IWrappedNativeToken is IERC20 {
    /// @notice Wraps native tokens.
    /// The message sender receives the amount of tokens equal to the message value.
    function deposit() external payable;

    /// @notice Unwraps native tokens.
    /// The message sender burns an amount of tokens
    /// and the equal amount of native tokens is transferred to their address.
    /// @param amount The amount of tokens to unwrap.
    function withdraw(uint256 amount) external;
}
