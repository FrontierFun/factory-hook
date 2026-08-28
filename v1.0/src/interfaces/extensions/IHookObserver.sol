// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IHookObserver
 * @author Frontier
 * @notice One-way notification target: observers watch swaps and fee-regime changes. They
 * cannot redirect the swap's funds or alter its fill, but they are NOT fully powerless — see the
 * reentrancy note below. Safeguards target gas and non-interference:
 * - raw `call` under a shared gas budget; a greedy observer is cut off and its state changes
 *   revert — its own problem;
 * - revert AND returndata ignored (returndata is not even copied);
 * - called LAST, after the fee engine has fully settled and the fee/volatility transient slots
 *   are cleared, so a nested call corrupts no swap state.
 * Reentrancy — precise statement: the call runs inside the swap's PoolManager unlock, so a
 * nested `unlock` reverts (`AlreadyUnlocked`), but `swap`/`take`/`settle` (all `onlyWhenUnlocked`)
 * do NOT — a funded observer can run a nested swap. V4's per-address delta accounting isolates it
 * from the hook's position, so this yields no extraction; the one residual power is a DoS —
 * leaving an unsettled delta reverts the outer unlock (`CurrencyNotSettled`) and aborts the swap,
 * bounded to the observer's own pool.
 * The swapper bears the cost: each bound observer adds ~its share of the budget to the swap's max
 * cost on that pool — bindings are per-pool and chosen at creation; a pool without observers pays
 * nothing.
 */
interface IHookObserver {
    /**
     * @notice Called by the hook exactly once, when a pool binds this extension AS AN
     * OBSERVER, inside the coin's deploy transaction.
     * @dev The registration selector is role-specific on purpose: a contract that does not
     * implement it cannot be bound in this role — listing it in the payload's `observers`
     * reverts the deploy, so a role mix-up (e.g. a fee calculator bound as an observer, whose
     * schedule would never fire) is impossible rather than merely discouraged. Runs LAST in
     * `registerPool`, after all of the hook's own state writes, behind a reentrancy guard (S2)
     * — for observers this is the only registration-time write window; later notifications are
     * raw fire-and-forget calls that may also write state, under the shared gas budget.
     *
     * SECURITY (S1): pool ids are predictable before deployment (CREATE3 token addresses), so
     * an open registration can be poisoned ahead of the legitimate call. Implementations MUST
     * gate this on `msg.sender == hook`. Non-conformance disqualifies an extension from the
     * display whitelist.
     * @param poolId The V4 pool id being bound.
     * @param config The observer-specific sub-payload carried by the creator's hook config.
     */
    function onRegisterObserver(PoolId poolId, bytes calldata config) external;

    /**
     * @notice Notified after a swap fully settles.
     * @dev Attribution convention: credit the address embedded in `hookData` when present and
     * valid, else fall back to `tx.origin` — plain EOAs work bare, multisigs and AA wallets
     * ride the frontend, which always supplies `hookData`. Self-declaring a wrong address only
     * gifts one's own credit. Treat `hookData` as hostile; the hook length-bounds it.
     * @param poolId The V4 pool id that was swapped.
     * @param delta The swap's REAL balance delta (for exact-output swaps `amountSpecified` is
     * the output — accounting extensions need actual flows).
     * @param feeRate The applied total fee rate in pips.
     * @param feeAmount The non-LP fee amount charged on this swap (reward-type observers
     * should prefer fees paid over swap size: fairer across fee regimes, self-balancing
     * against farming).
     * @param hookData The swap's hook data, length-bounded by the hook, hostile.
     */
    function onAfterSwap(PoolId poolId, BalanceDelta delta, uint24 feeRate, uint256 feeAmount, bytes calldata hookData)
        external;

    /**
     * @notice Notified when the pool's applied fee changes (S4: regime-level, curve-agnostic —
     * the hook stores the last applied fee and notifies on change, whatever curve produced it).
     * @param poolId The V4 pool id.
     * @param previousFee The previously applied total fee rate in pips.
     * @param newFee The newly applied total fee rate in pips.
     */
    function onFeeChange(PoolId poolId, uint24 previousFee, uint24 newFee) external;
}
