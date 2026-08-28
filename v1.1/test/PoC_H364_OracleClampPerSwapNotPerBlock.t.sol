// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {console2} from "forge-std/console2.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";

/// @title PoC_H364_OracleClampPerSwapNotPerBlock
/// @notice Regression for H-364 (audit L-04), FIXED: the truncated-oracle clamp in
/// `FactoryHook._checkpointSwap` used to be applied once per INVOCATION, against the previous
/// swap's recorded tick, so the number of clamp steps taken inside a block was chosen by the
/// caller. Every checkpoint of a block is now clamped against the tick the oracle held when the
/// block opened (`anchorTick`), making `MAX_ABS_TICK_MOVE` a per-block ceiling. This suite keeps
/// the original attack — one trade split into several swaps in one block on the REAL hooked V4
/// pool — and asserts the bound now holds. The full property set lives in
/// `PoC_L04_TruncatedTickCapPerBlock`.
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

    /// @notice FIXED: the recorded oracle tick moves by at most ONE `MAX_ABS_TICK_MOVE` inside a
    /// single block, however many swaps the caller splits the trade into.
    function test_H364_FIXED_SplitSwapsInOneBlockStayWithinThePerBlockCap() public {
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

        assertLe(moved, int256(cap), "FIXED: single-block oracle move is bounded by MAX_ABS_TICK_MOVE");
        assertEq(moved, int256(cap), "the pool moved further than one cap, so the bound is what was recorded");
    }

    /// @notice FIXED (downstream): the tick that accrues into `tickCumulative` after the attack
    /// block is the bounded one, so a consumer deriving a TWAP as (cum2-cum1)/(t2-t1) reads an
    /// average tick within one damping step of where the oracle opened the block.
    function test_H364_FIXED_DownstreamTwapStaysWithinOneStep() public {
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

        int256 drift = _abs(twap - int256(recordedAtBlockStart));
        assertLe(drift, int256(cap), "FIXED: downstream TWAP stays within one damping step");
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
