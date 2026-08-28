// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {CooldownHolder} from "src/CooldownHolder.sol";

/**
 * @title IStakingVault
 * @author Frontier
 * @notice ERC4626 vault with cooldown withdrawals and a pro-rata WETH reward stream.
 */
interface IStakingVault is IERC4626 {
    /**
     * @notice A user's pending withdrawal: the assets locked and the timestamp the cooldown ends.
     * @param cooldownEnd Timestamp when cooldown ends.
     * @param underlyingAmount Amount of assets locked in cooldown.
     */
    struct UserCooldown {
        uint256 cooldownEnd;
        uint256 underlyingAmount;
    }

    /// @notice An address argument is zero.
    error AddressZero();

    /// @notice The cooldown duration is out of range.
    error InvalidCooldown();

    /// @notice The vault's asset token cannot be recovered.
    error CannotRecoverAsset();

    /// @notice The WETH reward token cannot be recovered.
    error CannotRecoverReward();

    /// @notice The WETH reward notifier is neither the bound hook nor the harvester's current distributor.
    error UnauthorizedNotifier();

    /// @notice The withdrawal exceeds the maximum allowed.
    error ExcessiveWithdrawAmount();

    /// @notice The redemption exceeds the maximum allowed.
    error ExcessiveRedeemAmount();

    /// @notice The cooldown has not elapsed.
    error CooldownNotComplete();

    /// @notice The user has no cooldown to claim.
    error NothingToClaim();

    /// @notice The ERC4626 `withdraw` / `redeem` entry points are disabled; use the cooldown flow.
    error OperationNotAllowed();

    /// @notice The amount is zero.
    error AmountZero();

    /**
     * @notice A withdrawal by asset amount entered cooldown.
     * @param user The address that requested the withdrawal.
     * @param assets The amount of assets to withdraw.
     * @param shares The amount of shares that will be burned.
     * @param assetsBeforeWithdraw The user's total asset value before the request.
     */
    event WithdrawRequested(address indexed user, uint256 assets, uint256 shares, uint256 assetsBeforeWithdraw);

    /**
     * @notice A redemption by share amount entered cooldown.
     * @param user The address that requested the redemption.
     * @param shares The amount of shares to redeem.
     * @param assets The amount of assets that will be received.
     * @param assetsBeforeWithdraw The user's total asset value before the request.
     */
    event RedemptionRequested(address indexed user, uint256 shares, uint256 assets, uint256 assetsBeforeWithdraw);

    /**
     * @notice Cooled-down assets were transferred to `receiver`.
     * @param user The user who claimed.
     * @param receiver The address that received the assets.
     * @param assets The amount of assets transferred.
     */
    event WithdrawalClaimed(address indexed user, address indexed receiver, uint256 assets);

    /**
     * @notice The cooldown duration changed.
     * @param previousDuration The previous cooldown duration.
     * @param newDuration The new cooldown duration.
     */
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);

    /**
     * @notice Stray ERC20 tokens were recovered from the vault.
     * @param token The address of the recovered token.
     * @param amount The amount of tokens recovered.
     * @param recipient The address that received the recovered tokens.
     */
    event TokensRecovered(address indexed token, uint256 amount, address indexed recipient);

    /**
     * @notice WETH was added to the reward stream.
     * @param amount The WETH amount added to the reward stream.
     */
    event WethRewardNotified(uint256 amount);

    /**
     * @notice A user claimed accrued WETH rewards.
     * @param user The user claiming.
     * @param amount The WETH amount transferred to the user.
     */
    event WethClaimed(address indexed user, uint256 amount);

    /**
     * @notice Requests a withdrawal of `assets`, starting the cooldown.
     * @param assets Amount of assets to withdraw.
     * @return shares The shares that will be burned.
     */
    function requestWithdraw(uint256 assets) external returns (uint256 shares);

    /**
     * @notice Requests a redemption of `shares`, starting the cooldown.
     * @param shares Amount of shares to redeem.
     * @return assets The assets that will be received after the cooldown.
     */
    function requestRedeem(uint256 shares) external returns (uint256 assets);

    /**
     * @notice Claims the caller's full cooled-down amount to `receiver`.
     * @param receiver Address to receive the assets.
     */
    function unstake(address receiver) external;

    /**
     * @notice Declares `amount` WETH already transferred to the vault as a new reward, distributed pro-rata
     * to shareholders.
     * @dev Callable only by the construction-bound hook or the harvester's current distributor. Nothing is
     * pulled, so this authorisation is the vault's solvency guarantee. Buffered into `pendingWeth` while total
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
     * @notice Sets the cooldown duration. Owner only, at most `MAX_COOLDOWN_DURATION`.
     * @param duration In seconds.
     */
    function setCooldownDuration(uint24 duration) external;

    /**
     * @notice Recovers stray ERC20 tokens. Owner only; the asset and WETH cannot be recovered.
     * @param token The token to recover.
     * @param amount The amount to recover.
     * @param recipient Where to send the recovered tokens.
     */
    function recoverERC20(address token, uint256 amount, address recipient) external;

    /**
     * @notice Returns a user's cooldown: locked assets, end timestamp and whether it can be claimed.
     * @param user The user address to check.
     * @return amount Amount of assets in cooldown.
     * @return cooldownEnd Timestamp when cooldown ends.
     * @return isReady Whether the cooldown is complete.
     */
    function getCooldownStatus(address user) external view returns (uint256 amount, uint256 cooldownEnd, bool isReady);

    /**
     * @notice Returns a user's raw `UserCooldown` record.
     * @param user The user address.
     * @return cooldownEnd Timestamp when cooldown ends.
     * @return underlyingAmount Amount of assets in cooldown.
     */
    function cooldowns(address user) external view returns (uint256 cooldownEnd, uint256 underlyingAmount);

    /**
     * @notice Returns the cooldown duration in seconds.
     * @return The cooldown duration in seconds.
     */
    function cooldownDuration() external view returns (uint24);

    /**
     * @notice Returns the upper bound on `cooldownDuration`, in seconds (90 days).
     * @return The maximum cooldown duration in seconds.
     */
    function MAX_COOLDOWN_DURATION() external view returns (uint24);

    /**
     * @notice Returns the contract holding assets during cooldown.
     * @return The cooldown holder address.
     */
    function cooldownHolder() external view returns (CooldownHolder);

    /**
     * @notice Returns the hook authorised to notify WETH rewards, fixed at construction.
     * @return The hook address.
     */
    function hook() external view returns (address);

    /**
     * @notice Returns the harvester whose current distributor may notify WETH rewards, fixed at construction.
     * @return The harvester address.
     */
    function harvester() external view returns (address);

    /**
     * @notice Returns the WETH claimable by a user, including rewards not yet crystallised.
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
     * @notice Returns WETH buffered while total supply was zero, folded in on the next notify.
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
     * @notice Returns a user's reward checkpoint, `balanceOf(user) * wethRewardPerShare / 1e18` at last settlement.
     * @param user The user to query.
     * @return The user's WETH reward debt checkpoint.
     */
    function userRewardDebt(address user) external view returns (uint256);

    /**
     * @notice Returns the WETH token distributed as the reward stream.
     * @return The WETH address.
     */
    function WETH() external view returns (address);
}
