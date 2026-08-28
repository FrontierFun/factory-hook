// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IStakingVaultFactory
 * @author Frontier
 * @notice Interface for the StakingVaultFactory contract.
 */
interface IStakingVaultFactory {
    /**
     * @notice Thrown when the caller is not the hook.
     */
    error OnlyHook();

    /**
     * @notice Thrown when the cooldown duration is invalid.
     */
    error InvalidCooldown();

    /**
     * @notice Thrown when a required address argument is the zero address.
     */
    error InvalidZeroAddress();

    /**
     * @notice Ownership renouncement is disabled: `deployVault` transfers each new vault to
     * `owner()`, so a zero owner would brick every staking-enabled coin deployment.
     */
    error RenounceDisabled();

    /**
     * @notice Emitted when a new StakingVault is deployed.
     * @param asset The asset token used by the vault.
     * @param vault The address of the deployed vault.
     * @param cooldownDuration The cooldown duration for the vault.
     */
    event VaultDeployed(IERC20 indexed asset, address indexed vault, uint256 cooldownDuration);

    /**
     * @notice Emitted when the cooldown duration is updated.
     * @param previousDuration The previous cooldown duration.
     * @param newDuration The new cooldown duration.
     */
    event CooldownDurationUpdated(uint24 previousDuration, uint24 newDuration);

    /**
     * @notice Emitted when the hook address is updated.
     * @param previousHook The previous hook address.
     * @param newHook The new hook address.
     */
    event HookUpdated(address indexed previousHook, address indexed newHook);

    /**
     * @notice Deploys a new StakingVault vault.
     * @dev Can only be called by the hook. The vault permanently binds the calling hook as its
     * swap-stream notifier and the factory's `HARVESTER` as the source of its POL-stream
     * notifier (the harvester's current distributor); a later `setHook` does not affect
     * deployed vaults.
     * @param asset The asset token to be staked.
     * @return vault Address of the deployed vault.
     */
    function deployVault(IERC20 asset) external returns (address vault);

    /**
     * @notice Returns the harvester baked into every deployed vault as the source of its
     * second authorised notifier (the current POL distributor).
     * @return The harvester address.
     */
    function HARVESTER() external view returns (address);

    /**
     * @notice Returns the cooldown duration for new vaults.
     * @return The cooldown duration in seconds applied to newly deployed vaults.
     */
    function cooldownDuration() external view returns (uint24);

    /**
     * @notice Returns the maximum allowed cooldown duration for new vaults (90 days).
     * @return The maximum cooldown duration in seconds.
     */
    function MAX_COOLDOWN_DURATION() external view returns (uint24);

    /**
     * @notice Returns the hook address.
     * @return The address of the hook authorised to deploy vaults.
     */
    function hook() external view returns (address);

    /**
     * @notice Returns the canonical WETH distributed by deployed vaults as their second reward stream.
     * @return The WETH address.
     */
    function WETH() external view returns (address);

    /**
     * @notice Sets the cooldown duration for new vaults.
     * @dev Only callable by the owner; must be non-zero and at most `MAX_COOLDOWN_DURATION`.
     * @param newCooldownDuration The new cooldown duration.
     */
    function setCooldownDuration(uint24 newCooldownDuration) external;

    /**
     * @notice Sets the hook address.
     * @dev Only callable by the owner; the new hook cannot be the zero address. Affects only
     * which hook may deploy future vaults — deployed vaults keep their construction-bound hook.
     * @param newHook The new hook address.
     */
    function setHook(address newHook) external;
}
