// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IExtensionHost
 * @author Frontier
 * @notice The hook surface extensions read. Frozen across hook generations: a new generation
 * keeps every function here with the same semantics, so one extension deployment serves them all.
 */
interface IExtensionHost {
    /**
     * @notice The ceiling the fee chain's output is clamped to, in pips.
     * @return The ceiling, in pips.
     */
    function MAX_HOOK_FEE() external view returns (uint24);

    /**
     * @notice The raised ceiling inside a pool's declared sniper window, in pips.
     * @return The raised ceiling, in pips.
     */
    function SNIPER_MAX_FEE() external view returns (uint24);

    /**
     * @notice The longest sniper window a pool may declare, in seconds.
     * @return The longest window, in seconds.
     */
    function MAX_SNIPER_WINDOW() external view returns (uint32);

    /**
     * @notice The coin paired with native ETH in a registered pool.
     * @param poolId The V4 pool id.
     * @return The coin (`address(0)` when the pool is not registered).
     */
    function poolCoin(PoolId poolId) external view returns (address);

    /**
     * @notice A registered pool's base fee, in pips.
     * @param poolId The V4 pool id.
     * @return The base fee, in pips.
     */
    function poolFixedFee(PoolId poolId) external view returns (uint24);

    /**
     * @notice A registered pool's declared sniper window, in seconds (0 = none).
     * @param poolId The V4 pool id.
     * @return The window in seconds, 0 when none.
     */
    function poolSniperWindow(PoolId poolId) external view returns (uint32);
}
