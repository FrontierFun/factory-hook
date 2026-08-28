// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ICooldownHolder
 * @author Frontier
 * @notice Interface for the CooldownHolder contract that holds assets during cooldown.
 */
interface ICooldownHolder {
    /**
     * @notice Thrown when caller is not the staking vault.
     */
    error OnlyStakingVault();

    /**
     * @notice Returns the token being held during cooldown.
     * @return The held token.
     */
    function bcToken() external view returns (IERC20);

    /**
     * @notice Returns the staking vault authorized to call `withdraw`.
     * @return The staking vault address.
     */
    function stakingVault() external view returns (address);

    /**
     * @notice Withdraw assets to a recipient.
     * @dev Only callable by the staking vault.
     * @param to Address to send the assets to.
     * @param amount Amount of assets to withdraw.
     */
    function withdraw(address to, uint256 amount) external;
}
