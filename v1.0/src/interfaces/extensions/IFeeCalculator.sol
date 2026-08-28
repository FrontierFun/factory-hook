// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/**
 * @title IFeeCalculator
 * @author Frontier
 * @notice A pool's pluggable fee brain: quotes the total swap fee rate the hook applies.
 * Because it influences the swap price, it is fully boxed in — the cage is EVM-enforced,
 * not conventional:
 * - called via **staticcall** with a fixed, low gas stipend; returndata copy bounded to
 *   exactly 32 bytes;
 * - output clamped to `[0, MAX_HOOK_FEE]`, plus the pool's declared sniper-window exception;
 * - **any failure — revert, out-of-gas, malformed return, tripped circuit breaker — makes the
 *   hook skip the stage: the running fee (the previous stage's output, or the pool's base fee
 *   for the first stage) passes through unchanged** (observable via `FeeCalculatorFallback`);
 *   the swap path can never be blocked by third-party code.
 * @dev Volatility is protocol-defined: the base hook keeps the volatility engine and passes
 * the reading in — custom volatility measures need a future hook generation, not an
 * extension. `quoteFee` deliberately receives no `hookData`, so pricing can never depend on
 * caller-supplied data; the only identity channel under this signature is `tx.origin`.
 * Official calculators are deliberately ownerless — no breaker, no admin lever; a bound
 * config is immutable and all safety lives in registration-time validation plus this cage.
 * Third-party calculators may carry admin levers, but the cage bounds what any lever can do
 * (a revert only ever skips the stage).
 */
interface IFeeCalculator {
    /**
     * @notice Called by the hook exactly once, when a pool binds this extension AS A FEE
     * CALCULATOR, inside the coin's deploy transaction.
     * @dev The registration selector is role-specific on purpose: a contract that does not
     * implement it cannot be bound in this role — listing it in the payload's `feeCalculators`
     * reverts the deploy, so a role mix-up is impossible rather than merely discouraged. Runs
     * LAST in `registerPool`, after all of the hook's own state writes, behind a reentrancy
     * guard (S2) — the ONLY moment the extension may write state or revert (a revert fails the
     * deploy).
     *
     * SECURITY (S1): pool ids are predictable before deployment (CREATE3 token addresses), so
     * an open registration can be poisoned ahead of the legitimate call. Implementations MUST
     * gate this on `msg.sender == hook`. Non-conformance disqualifies an extension from the
     * display whitelist.
     * @param poolId The V4 pool id being bound.
     * @param config The calculator-specific sub-payload carried by the creator's hook config.
     */
    function onRegisterCalculator(PoolId poolId, bytes calldata config) external;

    /**
     * @notice Quotes the total fee rate for the entering swap, as one stage of the pool's fee
     * chain.
     * @dev Chain composition: the hook seeds the chain with the pool's base fee and threads
     * each stage's output into the next as `previousFee`; a stage that has nothing to say
     * returns `previousFee` unchanged (identity). `baseFee` lets a stage detect upstream
     * activity (`previousFee > baseFee` means an earlier stage raised the fee). A failed stage
     * is skipped — its input passes through — and the final chain output is clamped by the
     * cage. Must stay within the per-stage gas stipend; an over-consuming implementation is
     * cut off and skipped.
     * @param poolId The V4 pool id being swapped.
     * @param previousFee The running fee in pips: the previous stage's output, or `baseFee`
     * for the first stage.
     * @param baseFee The pool's base fee in pips (the chain seed).
     * @param volatility The hook's volatility reading (time-decayed tick displacement).
     * @param tick The current (pre-swap) pool tick.
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
