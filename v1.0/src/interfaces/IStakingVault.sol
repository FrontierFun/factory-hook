// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CooldownHolder} from "src/CooldownHolder.sol";

/**
 * @title IStakingVault
 * @author Frontier
 * @notice Interface for the StakingVault vault with cooldown withdrawals and fee distribution.
 * @dev Extends ERC4626 with cooldown-based withdrawal system and fee management.
 */
interface IStakingVault is IERC4626 {
    /**
     * @notice User cooldown information.
     * @param cooldownEnd Timestamp when cooldown ends.
     * @param underlyingAmount Amount of assets locked in cooldown.
     */
    struct UserCooldown {
        uint256 cooldownEnd;
        uint256 underlyingAmount;
    }

    /**
     * @notice Thrown when an address parameter is zero.
     */
    error AddressZero();

    /**
     * @notice Thrown when cooldown period is invalid.
     */
    error InvalidCooldown();

    /**
     * @notice Thrown when trying to recover the vault's asset token.
     */
    error CannotRecoverAsset();

    /**
     * @notice Thrown when trying to recover the WETH reward token.
     */
    error CannotRecoverReward();

    /**
     * @notice Thrown when a WETH reward notification comes from an address that is neither the
     * construction-bound hook nor the harvester's current distributor.
     */
    error UnauthorizedNotifier();

    /**
     * @notice Thrown when withdrawal amount exceeds maximum allowed.
     */
    error ExcessiveWithdrawAmount();

    /**
     * @notice Thrown when redeem amount exceeds maximum allowed.
     */
    error ExcessiveRedeemAmount();

    /**
     * @notice Thrown when cooldown has not completed.
     */
    error CooldownNotComplete();

    /**
     * @notice Thrown when user has nothing to claim.
     */
    error NothingToClaim();

    /**
     * @notice Thrown when operation is not allowed in current mode.
     */
    error OperationNotAllowed();

    /**
     * @notice Thrown when amount is zero.
     */
    error AmountZero();

    /**
     * @notice Emitted when a user requests a withdrawal by assets.
     * @param user The address that requested the withdrawal.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares that will be burned.
     * @param assetsBeforeWithdraw The user's total asset value before the withdrawal.
     */
    event WithdrawRequested(address indexed user, uint256 assets, uint256 shares, uint256 assetsBeforeWithdraw);

    /**
     * @notice Emitted when a user requests a redemption by shares.
     * @param user The address that requested the redemption.
     * @param shares The amount of shares to redeem.
     * @param assets The amount of assets that will be received.
     * @param assetsBeforeWithdraw The user's total asset value before the redemption.
     */
    event RedemptionRequested(address indexed user, uint256 shares, uint256 assets, uint256 assetsBeforeWithdraw);

    /**
     * @notice Emitted when a withdrawal is claimed after cooldown.
     * @param user The user who claimed.
     * @param receiver The address that received the assets.
     * @param assets The amount of assets transferred.
     */
    event WithdrawalClaimed(address indexed user, address indexed receiver, uint256 assets);

    /**
     * @notice Emitted when the cooldown duration is updated.
     * @param previousDuration The previous cooldown duration.
     * @param newDuration The new cooldown duration.
     */
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);

    /**
     * @notice Emitted when ERC20 tokens are recovered from the vault.
     * @param token The address of the recovered token.
     * @param amount The amount of tokens recovered.
     * @param recipient The address that received the recovered tokens.
     */
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice Emitted when a WETH reward is notified to the vault.
     * @param amount The WETH amount added to the reward stream.
     */
    event WethRewardNotified(uint256 amount);

    /**
     * @notice Emitted when a user claims their accrued WETH rewards.
     * @param user The user claiming.
     * @param amount The WETH amount transferred to the user.
     */
    event WethClaimed(address indexed user, uint256 amount);

    /**
     * @notice Request withdrawal by specifying asset amount.
     * @dev Initiates cooldown period for the assets.
     * @param assets Amount of assets to withdraw.
     * @return shares Amount of shares that will be burned.
     */
    function requestWithdraw(uint256 assets) external returns (uint256 shares);

    /**
     * @notice Request redemption by specifying share amount.
     * @dev Initiates cooldown period for the shares.
     * @param shares Amount of shares to redeem.
     * @return assets Amount of assets that will be received.
     */
    function requestRedeem(uint256 shares) external returns (uint256 assets);

    /**
     * @notice Claim assets after cooldown period (must claim full amount).
     * @dev Claims all assets that have completed cooldown.
     * @param receiver Address to receive the assets.
     */
    function unstake(address receiver) external;

    /**
     * @notice Notifies the vault of a WETH reward transferred in by an authorised notifier.
     * @dev Only callable by the hook bound at construction (swap fee stream) or the
     * harvester's current distributor (POL fee stream). The caller must transfer `amount` WETH
     * to the vault before calling: the function is declaration-based and pulls nothing, so the
     * authorisation is the vault's solvency guarantee. Buffers into `pendingWeth` when total
     * supply is zero.
     * @param amount The WETH amount to distribute pro-rata to shareholders.
     */
    function notifyWethReward(uint256 amount) external;

    /**
     * @notice Claims the caller's accrued WETH rewards.
     * @return amount The WETH amount transferred to the caller.
     */
    function claimWeth() external returns (uint256 amount);

    /**
     * @notice Set a new cooldown duration.
     * @dev Only callable by owner, max 90 days.
     * @param duration The new cooldown duration.
     */
    function setCooldownDuration(uint24 duration) external;

    /**
     * @notice Recover accidentally sent ERC20 tokens.
     * @dev Cannot recover the vault's asset token.
     * @param token The token to recover.
     * @param amount The amount to recover.
     * @param recipient Where to send the recovered tokens.
     */
    function recoverERC20(address token, uint256 amount, address recipient) external;

    /**
     * @notice Get cooldown status for a user.
     * @param user The user address to check.
     * @return amount Amount of assets in cooldown.
     * @return cooldownEnd Timestamp when cooldown ends.
     * @return isReady Whether the cooldown is complete.
     */
    function getCooldownStatus(address user) external view returns (uint256 amount, uint256 cooldownEnd, bool isReady);

    /**
     * @notice Get user cooldown information.
     * @param user The user address.
     * @return cooldownEnd Timestamp when cooldown ends.
     * @return underlyingAmount Amount of assets in cooldown.
     */
    function cooldowns(address user) external view returns (uint256 cooldownEnd, uint256 underlyingAmount);

    /**
     * @notice Get the current cooldown duration.
     * @return The cooldown duration in seconds.
     */
    function cooldownDuration() external view returns (uint24);

    /**
     * @notice Get the maximum cooldown duration that can be configured (90 days).
     * @return The maximum cooldown duration in seconds.
     */
    function MAX_COOLDOWN_DURATION() external view returns (uint24);

    /**
     * @notice Get the cooldown holder contract that holds assets during cooldown.
     * @return The cooldown holder address.
     */
    function cooldownHolder() external view returns (CooldownHolder);

    /**
     * @notice Returns the hook authorised to notify WETH rewards, fixed for the life of the
     * vault.
     * @return The hook address.
     */
    function hook() external view returns (address);

    /**
     * @notice Returns the harvester whose current distributor may also notify WETH rewards,
     * fixed for the life of the vault.
     * @return The harvester address.
     */
    function harvester() external view returns (address);

    /**
     * @notice Returns the WETH accrued to a user, including not-yet-crystallised rewards.
     * @param user The user to query.
     * @return The claimable WETH amount.
     */
    function earnedWeth(address user) external view returns (uint256);

    /**
     * @notice Returns the cumulative WETH reward per share, scaled by 1e18.
     * @return The reward-per-share accumulator.
     */
    function wethRewardPerShare() external view returns (uint256);

    /**
     * @notice Returns WETH buffered while total supply was zero, folded in on the next non-zero
     * notify.
     * @return The pending WETH amount.
     */
    function pendingWeth() external view returns (uint256);

    /**
     * @notice Returns the WETH crystallised to a user and awaiting claim.
     * @param user The user to query.
     * @return The accrued WETH amount.
     */
    function accruedWeth(address user) external view returns (uint256);

    /**
     * @notice Returns a user's reward checkpoint, `balanceOf(user) * wethRewardPerShare / 1e18`
     * at the user's last settlement.
     * @param user The user to query.
     * @return The user's WETH reward debt checkpoint.
     */
    function userRewardDebt(address user) external view returns (uint256);

    /**
     * @notice Returns the canonical WETH distributed as the second reward stream.
     * @return The WETH address.
     */
    function WETH() external view returns (address);
}
