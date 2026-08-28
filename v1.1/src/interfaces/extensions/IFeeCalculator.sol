// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title IFeeCalculator
 * @author Frontier
 * @notice A pool's pluggable fee stage: quotes the total swap fee rate the hook applies. It is caged by
 * the EVM: a staticcall with a fixed gas stipend and a 32-byte returndata copy, output clamped to
 * `[0, MAX_HOOK_FEE]`, and any failure skips the stage so the running fee passes through unchanged.
 * @dev `quoteFee` receives no `hookData`, so pricing can never depend on caller-supplied data; volatility
 * is protocol-defined and passed in by the hook.
 */
interface IFeeCalculator {
    /**
     * @notice Called by the hook once, when a pool binds this extension as a fee calculator. Runs last in
     * `registerPool`, inside the coin's deploy transaction, and is the only moment the extension may write
     * state or revert (a revert fails the deploy).
     * @dev (S1) Pool ids are predictable before deployment, so implementations MUST gate this on
     * `msg.sender == hook`.
     * @param poolId The V4 pool id being bound.
     * @param config The calculator-specific sub-payload of the creator's hook config.
     */
    function onRegisterCalculator(PoolId poolId, bytes calldata config) external;

    /**
     * @notice Quotes the running fee for the entering swap as one stage of the pool's fee chain: the hook
     * seeds the chain with `baseFee`, threads each stage's output into the next as `previousFee`, and a
     * stage with nothing to say returns `previousFee` unchanged.
     * @dev `previousFee > baseFee` signals an earlier stage raised the fee. Must fit the per-stage gas
     * stipend: an over-consuming or reverting stage is skipped and its input passes through.
     * @param poolId The V4 pool id being swapped.
     * @param previousFee The running fee in pips: the previous stage's output, or `baseFee` for the first.
     * @param baseFee The pool's base fee in pips, the chain seed.
     * @param volatility The hook's volatility reading (time-decayed tick displacement).
     * @param tick The pre-swap pool tick.
     * @param params The swap parameters (direction and specified amount).
     * @return The new running fee rate in pips (hundredths of a bip).
     */
    function quoteFee(
        PoolId poolId,
        uint24 previousFee,
        uint24 baseFee,
        uint88 volatility,
        int24 tick,
        SwapParams calldata params
    ) external view returns (uint24);
}
