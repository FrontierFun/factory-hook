// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IWETH
 * @author Frontier
 * @notice Minimal interface for the canonical wrapped-ETH token, restricted to the calls the
 * protocol makes: wrapping, unwrapping, and ERC20 approval/transfer of the wrapped balance.
 */
interface IWETH {
    /**
     * @notice Wraps the ETH sent with the call into WETH credited to the caller.
     */
    function deposit() external payable;

    /**
     * @notice Unwraps `amount` wei of the caller's WETH back into native ETH.
     * @dev Needed by the fee recipients that settle native `currency0` on a V4 pool.
     * @param amount The WETH to unwrap, in wei.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Approves `spender` to transfer up to `amount` wei of the caller's WETH.
     * @param spender The address allowed to spend.
     * @param amount The allowance in wei.
     * @return True on success (canonical WETH always returns true).
     */
    function approve(address spender, uint256 amount) external returns (bool);

    /**
     * @notice Transfers `amount` wei of WETH from the caller to `to`.
     * @param to The recipient address.
     * @param amount The amount in wei.
     * @return True on success (canonical WETH always returns true).
     */
    function transfer(address to, uint256 amount) external returns (bool);
}
