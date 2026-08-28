// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStakingVaultFactory
 * @author Frontier
 * @notice Deploys one StakingVault per staking-enabled coin, on the hook's request.
 */
interface IStakingVaultFactory {
    /// @notice Caller is not the hook.
    error OnlyHook();

    /// @notice Cooldown is zero or above `MAX_COOLDOWN_DURATION`.
    error InvalidCooldown();

    /// @notice A required address argument was zero.
    error InvalidZeroAddress();

    /**
     * @notice Renouncing is disabled: `deployVault` transfers each vault to `owner()`, so a zero owner would
     * brick every staking-enabled coin deployment.
     */
    error RenounceDisabled();

    /**
     * @notice A StakingVault was deployed for `asset`.
     * @param asset The asset token used by the vault.
     * @param vault The address of the deployed vault.
     * @param cooldownDuration Seconds.
     */
    event VaultDeployed(IERC20 indexed asset, address indexed vault, uint256 cooldownDuration);

    /**
     * @notice The cooldown applied to future vaults changed.
     * @param previousDuration The previous cooldown duration.
     * @param newDuration The new cooldown duration.
     */
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);

    /**
     * @notice The hook allowed to deploy vaults changed.
     * @param previousHook The previous hook address.
     * @param newHook The new hook address.
     */
    event HookUpdated(address indexed previousHook, address indexed newHook);

    /**
     * @notice Deploys a StakingVault for `asset`; only the hook may call.
     * @dev The vault permanently binds the calling hook as its swap-stream notifier and `HARVESTER` as the
     * source of its POL-stream notifier; a later `setHook` does not affect deployed vaults.
     * @param asset The asset token to be staked.
     * @return vault Address of the deployed vault.
     */
    function deployVault(IERC20 asset) external returns (address vault);

    /**
     * @notice The harvester every vault resolves its POL-stream notifier (the current distributor) from.
     * @return The harvester address.
     */
    function HARVESTER() external view returns (address);

    /**
     * @notice Cooldown in seconds applied to newly deployed vaults.
     * @return The cooldown duration in seconds applied to newly deployed vaults.
     */
    function cooldownDuration() external view returns (uint24);

    /**
     * @notice Ceiling on `cooldownDuration`: 90 days, in seconds.
     * @return The maximum cooldown duration in seconds.
     */
    function MAX_COOLDOWN_DURATION() external view returns (uint24);

    /**
     * @notice The hook authorised to deploy vaults.
     * @return The address of the hook authorised to deploy vaults.
     */
    function hook() external view returns (address);

    /**
     * @notice WETH, distributed by vaults as their second reward stream.
     * @return The WETH address.
     */
    function WETH() external view returns (address);

    /**
     * @notice Sets the cooldown for future vaults; owner only, non-zero and at most `MAX_COOLDOWN_DURATION`.
     * @param newCooldownDuration The new cooldown duration.
     */
    function setCooldownDuration(uint24 newCooldownDuration) external;

    /**
     * @notice Sets which hook may deploy future vaults; owner only. Deployed vaults keep their bound hook.
     * @dev The new hook cannot be the zero address.
     * @param newHook The new hook address.
     */
    function setHook(address newHook) external;
}
