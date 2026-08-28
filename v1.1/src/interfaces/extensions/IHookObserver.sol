// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IHookObserver
 * @author Frontier
 * @notice One-way notification target for swaps and fee-regime changes. The hook reaches it with a raw
 * `call` under a shared gas budget, ignores its revert and returndata, and calls it last, after the fee
 * engine has settled and its transient slots are cleared; a greedy observer is cut off and reverts alone.
 * @dev The call runs inside the swap's PoolManager unlock, so a nested `unlock` reverts but a funded
 * observer can run a nested swap. Per-address delta accounting yields it no extraction; the residual power
 * is a DoS (an unsettled delta reverts the outer swap), bounded to the observer's own pool.
 */
interface IHookObserver {
    /**
     * @notice Called by the hook once, when a pool binds this extension as an observer. Runs last in
     * `registerPool`, inside the coin's deploy transaction, and is the only registration-time write window.
     * @dev (S1) Pool ids are predictable before deployment, so implementations MUST gate this on
     * `msg.sender == hook`.
     * @param poolId The V4 pool id being bound.
     * @param config The observer-specific sub-payload of the creator's hook config.
     */
    function onRegisterObserver(PoolId poolId, bytes calldata config) external;

    /**
     * @notice Notified after a swap fully settles.
     * @dev Attribution: credit the address in `hookData` when present and valid, else `tx.origin`. Treat
     * `hookData` as hostile; the hook only length-bounds it.
     * @param poolId The V4 pool id that was swapped.
     * @param delta The swap's real balance delta (for exact-output swaps `amountSpecified` is the output).
     * @param feeRate The applied total fee rate in pips.
     * @param feeAmount The non-LP fee amount charged on this swap.
     * @param hookData The swap's hook data, length-bounded by the hook, hostile.
     */
    function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24 feeRate, uint256 feeAmount, bytes calldata hookData)
        external;

    /**
     * @notice Notified when the pool's applied fee changes, whatever curve produced it.
     * @param poolId The V4 pool id.
     * @param previousFee The previously applied total fee rate in pips.
     * @param newFee The newly applied total fee rate in pips.
     */
    function onFeeChange(PoolId poolId, uint24 previousFee, uint24 newFee) external;
}
