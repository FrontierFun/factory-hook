// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title ICooldownHolder
 * @author Frontier
 * @notice Interface for the CooldownHolder contract that holds assets during cooldown.
 */
interface ICooldownHolder {
    /// @notice Caller is not the staking vault.
    error OnlyStakingVault();

    /**
     * @notice The token held during cooldown.
     * @return The held token.
     */
    function bcToken() external view returns (IERC20);

    /**
     * @notice The staking vault authorised to call `withdraw`.
     * @return The staking vault address.
     */
    function stakingVault() external view returns (address);

    /**
     * @notice Sends `amount` of the held token to `to`; only the staking vault may call.
     * @param to Address to send the assets to.
     * @param amount Amount of assets to withdraw.
     */
    function withdraw(address to, uint256 amount) external;
}
