// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title PoC_H328_PendingFeeTslotGuardAsymmetry
/// @notice Harm test for H-328: the `PENDING_FEE_TSLOT` transient slot
/// (`src/hook/FactoryHook.sol:89-92`) is WRITTEN in the `else` branch of
/// `if (params.amountSpecified < 0)` (`:396-411`), i.e. under `amountSpecified >= 0`, but is
/// CONSUMED-and-cleared only under `if (params.amountSpecified > 0)` (`:434-440`). The claim is
/// that this `>= 0` / `> 0` asymmetry leaves a stale protocol-fee rate in the slot which then
/// leaks into an unrelated later swap. This test drives both halves of that claim.
contract PoC_H328_PendingFeeTslotGuardAsymmetry is HookTestBase {
    address internal stakingVault;

    /// @dev A second graduated pool whose own rate is ZERO (gen-2: fixed at creation via the
    /// v2 payload — the runtime `changeDynamicFeeStatus` lever this test previously used is
    /// gone). The transient slots are single and global, so a swap on this pool inside the same
    /// test transaction is the cleanest probe for a stale rate left by a swap on the other pool.
    MockBCToken internal zeroCoin;

    function setUp() public virtual override {
        super.setUp();
        _graduate(coin);
        stakingVault = hook.getPoolState(_poolId(address(coin))).stakingVault;

        IFactoryHook.HookConfigV2 memory zeroConfig = IFactoryHook.HookConfigV2({
            fixedFee: 0,
            lpShareBps: 7000,
            feeCalculators: new address[](0),
            calculatorConfigs: new bytes[](0),
            sniperWindow: 0,
            observers: new IFactoryHook.ObserverConfig[](0)
        });
        zeroCoin = _deployCoin(
            "ZeroRate",
            "ZERO",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            abi.encodePacked(uint8(2), abi.encode(zeroConfig))
        );
        _graduate(zeroCoin);
    }

    /// @dev Exact-OUTPUT ETH->coin swap: `amountSpecified > 0`, so it takes the tstore branch in
    /// `beforeSwap` and the tload/clear branch in `afterSwap`.
    function _exactOutputBuyOn(address target, address who, uint256 coinOut, uint256 ethBudget) internal {
        PoolKey memory key = _poolKey(target);
        vm.prank(who);
        swapRouter.swap{value: ethBudget}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(coinOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _exactOutputBuy(address who, uint256 coinOut, uint256 ethBudget) internal {
        _exactOutputBuyOn(address(coin), who, coinOut, ethBudget);
    }

    /// @dev Total WETH paid out by `_distributeFee` on the ETH leg (treasury + vault + recipient).
    /// Both pools' recipients resolve to this test contract, so the sum covers either pool.
    function _totalProtocolWeth() internal view returns (uint256) {
        return weth.balanceOf(users.treasury) + weth.balanceOf(stakingVault) + weth.balanceOf(address(this));
    }

    /// @notice The divergent input that the asymmetry is about - `amountSpecified == 0`, the one
    /// value that satisfies the write guard (`>= 0`) but NOT the consume guard (`> 0`) - never
    /// reaches the hook at all: the PoolManager rejects it at
    /// `lib/v4-periphery/lib/v4-core/src/PoolManager.sol:193`, BEFORE `beforeSwap` is invoked at
    /// `:202`. The write-without-consume state is therefore unreachable through the only caller
    /// the hook's callbacks accept (`onlyPoolManager`).
    function test_H328_ZeroAmountSwapIsRejectedBeforeTheHookIsEverCalled() public {
        PoolKey memory key = _poolKey(address(coin));

        vm.prank(users.buyerTwo);
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @notice CLAIMED HARM under test: a stale rate written by one swap is charged against an
    /// unrelated later swap. Both swaps run inside ONE Foundry test transaction, so transient
    /// storage is NOT cleared between them - if a leak existed, this is where it would show.
    ///
    /// Swap 1: exact-output on the default-fee pool -> protocolRate > 0 -> writes the slot.
    /// Swap 2: exact-output on the ZERO-rate pool -> protocolRate == 0 -> writes nothing, so its
    ///         `afterSwap` tload can only see a leftover from swap 1 (the slots are global, not
    ///         per-pool).
    /// A leak would charge swap 2 a protocol fee it does not owe.
    function test_H328_NoStaleRateLeaksIntoAnUnrelatedLaterSwap() public {
        // ---- Swap 1: writes and (per the code) consumes the transient slot. ----
        uint256 beforeSwap1 = _totalProtocolWeth();
        _exactOutputBuy(users.buyerTwo, 1_000_000e18, 1 ether);
        uint256 feeSwap1 = _totalProtocolWeth() - beforeSwap1;
        assertGt(feeSwap1, 0, "precondition: swap 1 really did charge a protocol fee (slot was written)");

        // ---- Swap 2: the zero-rate pool, same transaction, same transient-storage context. Its
        // own charge is exactly the protocol floor (Q18): anything beyond it would be swap 1's
        // stale rate leaking through. ----
        uint256 beforeSwap2 = _totalProtocolWeth();
        uint256 buyerBefore = users.buyerThree.balance;
        _exactOutputBuyOn(address(zeroCoin), users.buyerThree, 1_000_000e18, 1 ether);
        uint256 feeSwap2 = _totalProtocolWeth() - beforeSwap2;

        // HARM ASSERTION: swap 2 owes exactly the floor share of what the buyer paid — the
        // fee-inclusive identity `fee = totalPaid * rate / 1e6`. Anything above IS the stale
        // rate from swap 1 leaking through the transient slot.
        assertApproxEqAbs(
            feeSwap2,
            (buyerBefore - users.buyerThree.balance) * uint256(hook.PROTOCOL_FLOOR_PIPS()) / 1e6,
            1,
            "HARM ASSERTION: no stale protocol-fee rate leaked into the later swap"
        );
        // Sanity: the floor rate is strictly below the stale step rate (300 vs 900 pips with
        // the default config), so a leak would show as a strictly larger charge.
        assertLt(feeSwap2, feeSwap1, "sanity: swap 2's floor charge is below swap 1's stale rate");
    }

    /// @notice Variant (relaxed along the "which swap kind follows" dimension): the same
    /// zero-rate probe after an exact-INPUT swap, which takes the other `beforeSwap` branch
    /// entirely and never writes the slot.
    function test_H328_Variant_NoLeakAfterAnExactInputSwap() public {
        _swapEthForCoin(address(coin), users.buyerTwo, 0.5 ether);

        uint256 before = _totalProtocolWeth();
        uint256 buyerBefore = users.buyerThree.balance;
        _exactOutputBuyOn(address(zeroCoin), users.buyerThree, 1_000_000e18, 1 ether);
        assertApproxEqAbs(
            _totalProtocolWeth() - before,
            (buyerBefore - users.buyerThree.balance) * uint256(hook.PROTOCOL_FLOOR_PIPS()) / 1e6,
            1,
            "HARM ASSERTION: no leak after an exact-input swap either, only the protocol floor"
        );
    }
}
