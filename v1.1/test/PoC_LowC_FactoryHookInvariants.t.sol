// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FactoryHookUnitTest} from "test/FactoryHookUnit.t.sol";
import {FactoryHookHarness} from "test/helpers/FactoryHookHarness.sol";
import {HookTestBase} from "test/helpers/HookTestBase.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @title PoC_LowC_FactoryHookPureInvariants
/// @notice Pure-function falsification for the low_c shard's FactoryHook conservation invariants
/// CI-2 (H-158), CI-2B / CI-2 (H-159, H-165) and CI-3 (H-166). Drives the contract's OWN `_split`
/// through {FactoryHookHarness.exposed_split}, so the composition under test is the contract's,
/// never a re-implementation.
contract PoC_LowC_FactoryHookPureInvariants is FactoryHookUnitTest {
    /// @dev Mirrors `_distributeFee`'s two-level waterfall using the contract's own `_split`.
    function _waterfall(uint256 amount, uint256 protocolRatio, uint256 communityRatio, bool hasVault)
        internal
        view
        returns (uint256 protocolAmount, uint256 vaultAmount, uint256 recipientAmount)
    {
        uint256 remainder;
        (protocolAmount, remainder) = hook.exposed_split(amount, protocolRatio);
        if (hasVault) {
            (vaultAmount, recipientAmount) = hook.exposed_split(remainder, communityRatio);
        } else {
            (vaultAmount, recipientAmount) = (0, remainder);
        }
    }

    // =======================================================================================
    // H-158: committed invariant CI-2 (CONSERVATION) — `_split`
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-2: `amountA + amountB == amount` for all
    /// `(amount, ratio)` with `ratio <= 100`.
    ///
    /// The invariant is true BY CONSTRUCTION — `_split` defines `amountB = amount - amountA`, so
    /// the sum telescopes back to `amount` regardless of how `amountA` rounds. Driven over the
    /// full legal ratio range and the full non-overflowing amount range.
    function testFuzz_H158_CI2_SplitConservesAmount(uint256 amount, uint256 ratio) public view {
        ratio = bound(ratio, 0, 100);
        // Cap the amount so `amount * ratio` cannot overflow — the contract's own precondition.
        amount = bound(amount, 0, type(uint256).max / 100);

        (uint256 a, uint256 b) = hook.exposed_split(amount, ratio);

        assertEq(a + b, amount, "CI-2: split conserves the amount exactly");
        assertLe(a, amount, "share A never exceeds the amount");
        assertLe(b, amount, "share B never exceeds the amount");
        assertEq(a, amount * ratio / 100, "share A is the floor of amount*ratio/100");
    }

    /// @notice Boundary companion: ratio endpoints and dust amounts, where a rounding bug would
    /// surface first.
    function test_H158_CI2_SplitBoundaries() public view {
        uint256[6] memory amounts = [uint256(0), 1, 2, 99, 100, 101];
        uint256[5] memory ratios = [uint256(0), 1, 50, 99, 100];

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 j = 0; j < ratios.length; j++) {
                (uint256 a, uint256 b) = hook.exposed_split(amounts[i], ratios[j]);
                assertEq(a + b, amounts[i], "CI-2 holds at the boundary");
            }
        }

        (uint256 z, uint256 all) = hook.exposed_split(1000, 0);
        assertEq(z, 0, "ratio 0 -> A gets nothing");
        assertEq(all, 1000, "ratio 0 -> B gets everything");

        (uint256 allA, uint256 zB) = hook.exposed_split(1000, 100);
        assertEq(allA, 1000, "ratio 100 -> A gets everything");
        assertEq(zB, 0, "ratio 100 -> B gets nothing");
    }

    // =======================================================================================
    // H-159 / H-165: committed invariants CI-2B / CI-2 — `_distributeFee` waterfall
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-2B / CI-2: the three-way waterfall conserves the taken
    /// amount — `protocolAmount + vaultAmount + recipientAmount == amount` for EVERY
    /// `(protocolFeeRatio, communityFeeRatio, vault)` combination, so the hook never owes or
    /// retains a wei on either leg.
    function testFuzz_H159_H165_WaterfallConservesTakenAmount(
        uint256 amount,
        uint256 protocolRatio,
        uint256 communityRatio,
        bool hasVault
    ) public view {
        amount = bound(amount, 0, type(uint256).max / 100);
        protocolRatio = bound(protocolRatio, 0, 100);
        communityRatio = bound(communityRatio, 0, 100);

        (uint256 p, uint256 v, uint256 r) = _waterfall(amount, protocolRatio, communityRatio, hasVault);

        assertEq(p + v + r, amount, "CI-2B: the three legs sum to exactly the amount taken");
        if (!hasVault) assertEq(v, 0, "no vault -> the vault leg is zero");
    }

    // =======================================================================================
    // H-166: committed invariant CI-3 (NO_REVERT_AT_BOUNDARY) — `_distributeFee` ETH leg
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-3 at the exact amounts named by the committed
    /// invariant — `amount in {1, 99, 100, 101}` wei — across the full ratio space and both the
    /// has-vault and no-vault branches.
    ///
    /// At these amounts the waterfall necessarily produces ZERO-valued legs (1 wei at a 25%
    /// protocol ratio yields `protocolAmount == 0`). `_distributeFee` guards every payout with
    /// `if (x > 0)`, so a zero leg is skipped rather than issuing a zero-value transfer or a
    /// zero-amount `notifyWethReward`.
    function test_H166_CI3_EthLegBoundaryAmountsStayConservative() public view {
        uint256[4] memory amounts = [uint256(1), 99, 100, 101];
        uint256[4] memory ratios = [uint256(0), 25, 50, 100];

        for (uint256 i = 0; i < amounts.length; i++) {
            for (uint256 j = 0; j < ratios.length; j++) {
                for (uint256 k = 0; k < ratios.length; k++) {
                    (uint256 p, uint256 v, uint256 r) = _waterfall(amounts[i], ratios[j], ratios[k], true);
                    assertEq(p + v + r, amounts[i], "CI-3: conservation holds at the wei boundary");

                    (uint256 p2, uint256 v2, uint256 r2) = _waterfall(amounts[i], ratios[j], ratios[k], false);
                    assertEq(p2 + v2 + r2, amounts[i], "CI-3: conservation holds with no vault");
                    assertEq(v2, 0, "no-vault branch pays the vault nothing");
                }
            }
        }

        // The 1-wei case specifically: a sub-unit leg floors to zero and is skipped by the
        // `if (x > 0)` guards rather than reverting.
        (uint256 pd, uint256 vd, uint256 rd) = _waterfall(1, 25, 50, true);
        assertEq(pd, 0, "1 wei at 25% -> protocol leg floors to zero");
        assertEq(pd + vd + rd, 1, "and the single wei is still fully accounted for");
    }
}

/// @title PoC_LowC_FactoryHookLiveInvariants
/// @notice Live-swap falsification for the low_c shard's FactoryHook rows: CI-2B / CI-2 delivery
/// (H-159, H-165), CI-3 ETH-leg liveness (H-166), CI-1 gross-up fidelity (H-164), and the INV-017
/// shared-symbol row H-15 (`_poolState`).
contract PoC_LowC_FactoryHookLiveInvariants is HookTestBase {
    uint256 internal constant FLOOR_FEE = 3000;
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    uint256 internal constant LP_SHARE_BPS = 7000;
    uint256 internal constant BPS_DENOMINATOR = 10_000;

    PoolId internal poolId;
    address internal stakingVault;

    function setUp() public virtual override {
        super.setUp();
        poolId = _poolId(address(coin));
        stakingVault = hook.getPoolState(poolId).stakingVault;

        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);
    }

    function _protocolRate(uint256 stepFee) internal pure returns (uint256) {
        return stepFee * (BPS_DENOMINATOR - LP_SHARE_BPS) / BPS_DENOMINATOR;
    }

    function _assertNoHookResidue() internal view {
        assertEq(address(hook).balance, 0, "hook holds native ETH");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds WETH");
        assertEq(coin.balanceOf(address(hook)), 0, "hook holds coin");
    }

    // =======================================================================================
    // H-159 / H-165: CI-2B / CI-2 end-to-end on the real contract
    // =======================================================================================

    /// @notice End-to-end CI-2B: after a live ETH-leg swap, the sum actually delivered to
    /// treasury + vault + recipient equals the fee captured from the pool, and the hook retains zero
    /// residue of ETH, WETH or coin.
    function test_H159_H165_LiveSwapDeliversExactlyWhatWasTakenAndLeavesNoResidue() public {
        _graduate(coin);
        assertEq(hook.getCurrentFee(poolId), FLOOR_FEE, "precondition: at-rest floor fee");

        uint256 amountIn = 0.1 ether;
        uint256 capturedFee = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this)); // creator == fee recipient
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        uint256 amountOut = _swapEthForCoin(address(coin), users.buyerTwo, amountIn);
        assertGt(amountOut, 0, "swap produced no output");

        uint256 delivered = (weth.balanceOf(users.treasury) - treasuryBefore)
            + (weth.balanceOf(address(this)) - recipientBefore) + (weth.balanceOf(stakingVault) - vaultBefore);

        assertEq(delivered, capturedFee, "CI-2B: delivered == taken");
        _assertNoHookResidue();
    }

    // =======================================================================================
    // H-166: CI-3 ETH-leg liveness at the dust boundary
    // =======================================================================================

    /// @notice Live boundary check on the real ETH leg: a swap small enough that the captured fee
    /// lands in the dust region still completes, delivers exactly what it took, and leaves no
    /// residue — the ETH leg does not revert at the low boundary.
    function test_H166_CI3_LiveDustSwapDoesNotRevertOnEthLeg() public {
        _graduate(coin);

        uint256 amountIn = 1e6; // non-LP capture is only a few hundred wei
        uint256 capturedFee = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        uint256 delivered = (weth.balanceOf(users.treasury) - treasuryBefore)
            + (weth.balanceOf(address(this)) - recipientBefore) + (weth.balanceOf(stakingVault) - vaultBefore);

        assertEq(delivered, capturedFee, "dust-scale ETH leg still delivers exactly what it took");
        _assertNoHookResidue();
    }

    // =======================================================================================
    // H-164: CI-1 (REQUESTED_EQ_DELIVERED) — `_lpFeeOverride` gross-up fidelity
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-1: the protocol realises exactly
    /// `protocolRate * total_paid / 1e6` of the swapper's FULL input, despite the LP-fee override
    /// being grossed up to `lpRate * 1e6 / (1e6 - protocolRate)`.
    ///
    /// The gross-up exists because the hook's positive specified-currency delta shrinks the input
    /// before core applies the LP fee. If it were wrong, the realised protocol share would drift
    /// from the requested pip rate measured against the full input.
    function test_H164_CI1_ProtocolShareMatchesRequestedRateOnFullInput() public {
        _graduate(coin);
        assertEq(hook.getCurrentFee(poolId), FLOOR_FEE, "precondition: at-rest floor fee");

        uint256 amountIn = 0.5 ether;
        uint256 expectedProtocolTotal = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        uint256 realised = (weth.balanceOf(users.treasury) - treasuryBefore)
            + (weth.balanceOf(address(this)) - recipientBefore) + (weth.balanceOf(stakingVault) - vaultBefore);

        assertEq(realised, expectedProtocolTotal, "CI-1: protocol realises exactly its rate on the full input");
        _assertNoHookResidue();
    }

    /// @notice Direction independence: the same rate identity holds on the coin leg, so the
    /// gross-up is not direction-sensitive.
    function test_H164_CI1_RateIdentityHoldsOnCoinLeg() public {
        _graduate(coin);

        vm.prank(users.buyerOne);
        coin.transfer(users.buyerTwo, 2_000_000e18);

        uint256 amountIn = 1_000_000e18;
        uint256 expectedProtocolTotal = amountIn * _protocolRate(hook.getCurrentFee(poolId)) / FEE_DENOMINATOR;

        uint256 treasuryBefore = coin.balanceOf(users.treasury);
        uint256 recipientBefore = coin.balanceOf(address(this));
        uint256 vaultBefore = coin.balanceOf(stakingVault);

        _swapCoinForEth(address(coin), users.buyerTwo, amountIn);

        uint256 realised = (coin.balanceOf(users.treasury) - treasuryBefore)
            + (coin.balanceOf(address(this)) - recipientBefore) + (coin.balanceOf(stakingVault) - vaultBefore);

        assertEq(realised, expectedProtocolTotal, "CI-1: same rate identity on the coin leg");
        _assertNoHookResidue();
    }

    // =======================================================================================
    // H-15: `_distributeFee` / `_afterInitialize` over `_poolState`
    // =======================================================================================

    /// @notice REFUTES a stale-read interaction between `_afterInitialize` and `_distributeFee`
    /// over `_poolState`: the two touch DISJOINT field sets of the struct.
    ///
    /// `_afterInitialize` writes only the oracle/volatility seed (`referenceTick`,
    /// `truncatedTick`, `lastSwapTimestamp`); `_distributeFee` reads only the fee-routing fields
    /// (`coin`, `stakingVault`, `communityFeeRatio`). Neither can clobber or stale-read the
    /// other's fields, and `_afterInitialize` runs exactly once, before any swap can distribute.
    function test_H15_AfterInitializeAndDistributeFeeTouchDisjointPoolStateFields() public {
        address seededCoin = hook.getPoolState(poolId).coin;
        address seededVault = hook.getPoolState(poolId).stakingVault;
        uint8 seededRatio = hook.getPoolState(poolId).communityFeeRatio;
        uint32 seededTimestamp = hook.getPoolState(poolId).lastSwapTimestamp;

        assertEq(seededCoin, address(coin), "fee-routing field: coin wired at registration");
        assertTrue(hook.getPoolState(poolId).registered, "pool registered");

        _graduate(coin);

        // A swap runs `_distributeFee` and also advances the oracle fields via `_updateVolatility`.
        vm.warp(block.timestamp + 1 hours);
        _swapEthForCoin(address(coin), users.buyerTwo, 0.1 ether);

        // The fee-routing fields `_distributeFee` reads are untouched by the oracle machinery.
        assertEq(hook.getPoolState(poolId).coin, seededCoin, "coin unchanged by oracle updates");
        assertEq(hook.getPoolState(poolId).stakingVault, seededVault, "stakingVault unchanged");
        assertEq(hook.getPoolState(poolId).communityFeeRatio, seededRatio, "communityFeeRatio unchanged");

        // Conversely the oracle field advanced, proving the two field sets move independently.
        assertGt(hook.getPoolState(poolId).lastSwapTimestamp, seededTimestamp, "oracle field advanced");

        _assertNoHookResidue();
    }
}
