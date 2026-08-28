// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {FactoryHookUnitTest} from "test/FactoryHookUnit.t.sol";
import {MockStakingVault} from "test/helpers/ProtocolMocks.sol";

/// @notice Any contract answering `asset()` satisfies the ONLY check `setStakingVault` performs
/// (`src/hook/FactoryHook.sol:225`). It carries no factory provenance whatsoever.
contract RogueVault {
    address public asset;

    constructor(address asset_) {
        asset = asset_;
    }
}

/// @title PoC_LowI_HookVolatilityAndGates
/// @notice Executable evidence for the `sc_verify_low_i` FactoryHook rows:
/// H-93 (decay re-anchoring), HL-13 (`setStakingVault` provenance gap) and the
/// H-86 / H-87 permissionless-setter claims (refuted — both carry `onlyFactoryOwner`).
contract PoC_LowI_HookVolatilityAndGates is FactoryHookUnitTest {
    function setUp() public override {
        super.setUp();
        _register(false, 0);
    }

    // ===================================================================================
    // H-93: `_updateVolatility` (src/hook/FactoryHook.sol:513-535) writes
    // `state.lastSwapTimestamp = block.timestamp` on EVERY swap, and `_decayedAccumulator`
    // (:562-570) measures decay only from that timestamp. Decay is therefore re-anchored per
    // swap: the accumulator falls geometrically per swap instead of reaching zero after
    // `decayWindow` of wall-clock time.
    // ===================================================================================

    /// @notice HARM: after a FULL `decayWindow` of elapsed time, a pool that saw ordinary
    /// zero-displacement swap traffic still charges `midFee`, while an idle pool with the exact
    /// same starting volatility has decayed to the floor. Traders pay the elevated fee purely
    /// because unrelated swaps kept re-anchoring the decay clock.
    function test_H93_HARM_ReanchoredDecayKeepsTheReadingElevatedAfterAFullWindow() public {
        uint32 window = hook.DECAY_WINDOW(); // 600
        uint88 start = hook.ACCUMULATOR_CAP(); // 900, the saturated accumulator

        // ---- Control: an idle pool. One full window of wall-clock, no swaps. ----
        uint256 snap = vm.snapshot();
        hook.setVolatilityState(poolId, int24(0), uint32(block.timestamp), start);
        vm.warp(block.timestamp + window);
        uint256 idle = hook.exposed_decayedAccumulator(poolId);
        assertEq(idle, 0, "control: an idle pool decays fully to zero over one decayWindow");
        vm.revertTo(snap);

        // ---- Treatment: the SAME wall-clock window, but ten ordinary swaps inside it. Each
        // swap sits at the reference tick, so it contributes ZERO displacement — it adds no
        // volatility at all, it only re-anchors the clock. ----
        hook.setVolatilityState(poolId, int24(0), uint32(block.timestamp), start);
        uint256 t0 = block.timestamp;
        uint32 step = window / 10; // 60s
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + step);
            hook.exposed_updateVolatility(poolId, int24(0));
        }
        assertEq(block.timestamp - t0, window, "exactly one decayWindow of wall-clock elapsed");

        uint88 traded = hook.getPoolState(poolId).volatilityAccumulator;

        // HARM 1: the accumulator did not reach zero, despite a full window and zero new
        // volatility. 900 * (9/10)^10 = 312.
        assertGt(traded, 0, "HARM: accumulator survives a full decayWindow when swaps re-anchor it");
        assertEq(traded, 312, "geometric per-swap decay, not linear decay to zero");

        // HARM 2: every volatility-consuming fee calculator on the pool still sees an elevated
        // reading for a volatility event that, by the documented decay model, should already
        // have expired. (Since gen-2 the fee mapping lives in extensions; the step-boundary
        // consequence is asserted in the DynamicFeeExtension parity suite.)
        assertGt(traded, idle, "HARM: elevated over the idle control a full window after the event");

        emit log_named_uint("idle-pool accumulator after one window", idle);
        emit log_named_uint("traded-pool accumulator after the same window", traded);
    }

    /// @notice Property form: for any swap cadence strictly inside the window, the accumulator
    /// after a full window of wall-clock is strictly positive — i.e. the "decays to zero over
    /// decayWindow" reading never holds under traffic.
    function testFuzz_H93_ReanchoringSurvivesAnyIntraWindowCadence(uint32 stepRaw) public {
        uint32 window = hook.DECAY_WINDOW();
        uint32 step = uint32(bound(uint256(stepRaw), 1, uint256(window) - 1));

        hook.setVolatilityState(poolId, int24(0), uint32(block.timestamp), hook.ACCUMULATOR_CAP());

        uint256 deadline = block.timestamp + window;
        uint256 iterations;
        while (block.timestamp + step <= deadline && iterations < 64) {
            vm.warp(block.timestamp + step);
            hook.exposed_updateVolatility(poolId, int24(0));
            iterations++;
        }

        // Anything that re-anchored at least once is still carrying volatility a full window on.
        if (iterations > 0 && iterations < 64) {
            assertGt(
                hook.getPoolState(poolId).volatilityAccumulator,
                0,
                "HARM: per-swap re-anchoring leaves residual volatility after a full window"
            );
        }
    }

    // ===================================================================================
    // HL-13: `setStakingVault` used to check only `IStakingVault(stakingVault).asset()`, so any
    // contract answering `asset()` was accepted with no provenance. It now also requires the
    // vault's deploying factory to authorise this hook as a notifier.
    // ===================================================================================

    /// @notice FIXED: a contract whose only qualification is a one-line `asset()` answer is no
    /// longer accepted — it cannot answer `stakingVaultFactory()` with a registry authorising
    /// this hook, so the binding check rejects it and no community fee can be routed to an
    /// unprovenanced contract.
    function test_HL13_FIXED_AssetAnsweringContractIsRejectedAsTheStakingVault() public {
        RogueVault rogue = new RogueVault(address(coin));

        assertEq(hook.getPoolState(poolId).stakingVault, address(0), "no vault installed at registration");
        assertEq(rogue.asset(), address(coin), "the rogue passes the asset check alone");

        // The rogue has no `stakingVaultFactory()` at all, so the binding probe reverts and the
        // set fails.
        vm.prank(owner);
        vm.expectRevert();
        hook.setStakingVault(poolId, address(rogue));

        assertEq(hook.getPoolState(poolId).stakingVault, address(0), "the rogue was not installed");

        // A real StakingVault bound to this hook remains installable.
        address bound = address(new MockStakingVault(IERC20(address(coin)), address(hook), address(weth)));
        vm.prank(owner);
        hook.setStakingVault(poolId, bound);
        assertEq(hook.getPoolState(poolId).stakingVault, bound, "a hook-bound vault is accepted");
    }

    // ===================================================================================
    // H-86 / H-87: claimed to "write state with no access gate". Both carry `onlyFactoryOwner`
    // (src/hook/FactoryHook.sol:203, :213 with the modifier at :113-116). REFUTATION.
    // ===================================================================================

    /// @notice REFUTES H-86 and H-87: an arbitrary caller cannot write either slot.
    function test_H86_H87_REFUTED_BothSettersAreFactoryOwnerGated() public {
        address stranger = makeAddr("stranger");

        vm.startPrank(stranger);
        vm.expectRevert(IFactoryHook.OnlyFactoryOwner.selector);
        hook.setProtocolFeeRatio(50);

        vm.expectRevert(IFactoryHook.OnlyFactoryOwner.selector);
        hook.setStakingVaultFactory(makeAddr("otherFactory"));
        vm.stopPrank();

        // Unchanged by the attempts.
        assertEq(hook.protocolFeeRatio(), 0, "protocolFeeRatio untouched by the stranger");
        assertEq(hook.stakingVaultFactory(), address(stakingVaultFactory), "stakingVaultFactory untouched");

        // ...and the owner can, confirming the gate is the only thing that blocked the stranger.
        vm.startPrank(owner);
        hook.setProtocolFeeRatio(50);
        vm.stopPrank();
        assertEq(hook.protocolFeeRatio(), 50, "owner writes succeed");
    }

    /// @dev Silences the unused-import warning for the registration struct.
    function test_LowI_registrationStructIsUsed() public pure {
        IBCTokenFactory.StakingConfig memory cfg =
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
        assertEq(cfg.alternativeFeeRecipient, address(0));
    }

    /// @dev Keeps the PoolId import load-bearing for readers of this file.
    function test_LowI_poolIdIsTheRegisteredPool() public view {
        PoolId id = poolId;
        assertTrue(hook.getPoolState(id).registered, "pool registered in setUp");
    }
}
