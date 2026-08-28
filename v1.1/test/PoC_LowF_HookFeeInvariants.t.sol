// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";

import {FactoryHookUnitTest} from "test/FactoryHookUnit.t.sol";
import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title PoC_LowF_HookFeeWaterfallInvariants
/// @notice Falsification harness for the `sc_verify_low_f` FactoryHook rows H-280 (CI-4
/// CONSERVATION) and H-281 (CI-4B NO_REVERT_AT_BOUNDARY) at
/// `src/hook/FactoryHook.sol:L472` (`_distributeFee`).
///
/// The waterfall is driven through the contract's OWN `_split` via
/// {FactoryHookHarness.exposed_split}, so the composition under test is the contract's, never a
/// re-implementation.
contract PoC_LowF_HookFeeWaterfallInvariants is FactoryHookUnitTest {
    /// @dev Mirrors `_distributeFee`'s two-level Model C waterfall exactly.
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
    // H-280: committed invariant CI-4 (CONSERVATION) - _distributeFee
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-4:
    /// `protocolAmount + vaultAmount + recipientAmount == amount` for every split.
    ///
    /// The attempt FAILS - the invariant survives, and it is true BY CONSTRUCTION rather than by
    /// a guard that could be bypassed. `_split` defines `amountB = amount - amountA`, so each
    /// level telescopes: level 1 gives `protocolAmount + remainder == amount` exactly, and level 2
    /// decomposes `remainder` the same way. No rounding mode, ratio value, or vault-presence
    /// branch can make the three legs sum to anything other than `amount`.
    function testFuzz_H280_CI4_WaterfallConservesTheDistributedAmount(
        uint256 amount,
        uint256 protocolRatio,
        uint256 communityRatio,
        bool hasVault
    ) public view {
        amount = bound(amount, 0, type(uint256).max / 100);
        protocolRatio = bound(protocolRatio, 0, 100);
        communityRatio = bound(communityRatio, 0, 100);

        (uint256 p, uint256 v, uint256 r) = _waterfall(amount, protocolRatio, communityRatio, hasVault);

        assertEq(p + v + r, amount, "CI-4: the three legs sum to exactly the distributed amount");
        if (!hasVault) assertEq(v, 0, "no vault -> the vault leg is zero and the remainder is the recipient's");
    }

    /// @notice CI-4 across the full legal ratio grid at hand-picked awkward amounts, including
    /// prime-ish values where both levels round down simultaneously. The residue that floor
    /// rounding leaves behind always lands in the LAST leg, never in nobody's.
    function test_H280_CI4_ConservationAtAdversarialRoundingPoints() public view {
        uint256[6] memory amounts = [uint256(1), 3, 97, 99, 101, 999_999_999_999];
        uint256[5] memory ratios = [uint256(0), 1, 33, 99, 100];

        for (uint256 i; i < amounts.length; ++i) {
            for (uint256 j; j < ratios.length; ++j) {
                for (uint256 k; k < ratios.length; ++k) {
                    (uint256 p, uint256 v, uint256 r) = _waterfall(amounts[i], ratios[j], ratios[k], true);
                    assertEq(p + v + r, amounts[i], "CI-4 holds with a vault");

                    (uint256 p2, uint256 v2, uint256 r2) = _waterfall(amounts[i], ratios[j], ratios[k], false);
                    assertEq(p2 + v2 + r2, amounts[i], "CI-4 holds without a vault");
                    assertEq(v2, 0, "no-vault branch pays the vault nothing");
                }
            }
        }
    }

    // =======================================================================================
    // H-281: committed invariant CI-4B (NO_REVERT_AT_BOUNDARY) - _distributeFee
    // =======================================================================================

    /// @notice FALSIFICATION ATTEMPT for CI-4B at the exact boundary set the invariant names:
    /// `amount == 1 wei`, `protocolFeeRatio in {0, 100}`, `communityFeeRatio in {0, 100}` and
    /// `stakingVault == address(0)`.
    ///
    /// The attempt FAILS - none of these boundaries produces a revert or a mis-accounting.
    /// A sub-unit leg floors to zero, and every payout in `_distributeFee` is guarded by
    /// `if (x > 0)`, so a zero leg is SKIPPED rather than issuing a zero-value `take`, a
    /// zero-value WETH transfer, or a zero-amount `notifyWethReward`.
    function test_H281_CI4B_EveryNamedBoundaryStaysConservativeAndZeroLegsAreSkipped() public view {
        // amount == 1 wei, both ratios at each extreme, both vault branches.
        uint256[2] memory extremes = [uint256(0), 100];
        for (uint256 j; j < extremes.length; ++j) {
            for (uint256 k; k < extremes.length; ++k) {
                (uint256 p, uint256 v, uint256 r) = _waterfall(1, extremes[j], extremes[k], true);
                assertEq(p + v + r, 1, "1 wei is fully accounted for at every ratio extreme");

                (uint256 p2, uint256 v2, uint256 r2) = _waterfall(1, extremes[j], extremes[k], false);
                assertEq(p2 + v2 + r2, 1, "1 wei is fully accounted for with no vault");
                assertEq(v2, 0, "stakingVault == address(0) -> vault leg skipped");
            }
        }

        // protocolFeeRatio == 100: the protocol takes everything, both downstream legs are zero
        // and are therefore skipped rather than transferred.
        (uint256 pAll, uint256 vAll, uint256 rAll) = _waterfall(1 ether, 100, 50, true);
        assertEq(pAll, 1 ether, "protocolFeeRatio == 100 routes the whole amount to the protocol");
        assertEq(vAll, 0, "vault leg is zero");
        assertEq(rAll, 0, "recipient leg is zero");

        // protocolFeeRatio == 0: nothing is taken off the top, the remainder is the full amount.
        (uint256 pNone, uint256 vNone, uint256 rNone) = _waterfall(1 ether, 0, 100, true);
        assertEq(pNone, 0, "protocolFeeRatio == 0 takes nothing off the top");
        assertEq(vNone, 1 ether, "communityFeeRatio == 100 routes the remainder to the vault");
        assertEq(rNone, 0, "recipient leg is zero");

        // communityFeeRatio == 0: the whole remainder reaches the fee recipient.
        (, uint256 vZero, uint256 rZero) = _waterfall(1 ether, 25, 0, true);
        assertEq(vZero, 0, "communityFeeRatio == 0 pays the vault nothing");
        assertEq(rZero, 0.75 ether, "and the recipient takes the whole after-protocol remainder");

        // The 1-wei dust case specifically: the leg that floors to zero is skipped, and the wei
        // is still fully accounted for.
        (uint256 pd, uint256 vd, uint256 rd) = _waterfall(1, 25, 50, true);
        assertEq(pd, 0, "1 wei at 25% floors the protocol leg to zero");
        assertEq(vd, 0, "and the vault leg too");
        assertEq(pd + vd + rd, 1, "the single wei still lands entirely on the recipient");
    }
}

/// @title PoC_LowF_HookFeeLiveInvariants
/// @notice Live-swap falsification for H-280 (CI-4) and H-281 (CI-4B) against the real deployed
/// hook: what the pool gives up must equal what the three legs receive, and the named boundary
/// configurations must not revert a real swap.
contract PoC_LowF_HookFeeLiveInvariants is HookTestBase {
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
    }

    function _protocolRate(uint256 stepFee) internal pure returns (uint256) {
        return stepFee * (BPS_DENOMINATOR - LP_SHARE_BPS) / BPS_DENOMINATOR;
    }

    /// @dev The sum of the three CI-4 legs, measured in WETH on the real recipients.
    function _delivered(uint256 treasuryBefore, uint256 recipientBefore, uint256 vaultBefore)
        internal
        view
        returns (uint256)
    {
        return (weth.balanceOf(users.treasury) - treasuryBefore) + (weth.balanceOf(address(this)) - recipientBefore)
            + (weth.balanceOf(stakingVault) - vaultBefore);
    }

    /// @notice Live CI-4: after a real ETH-leg swap the amount delivered to treasury + vault +
    /// recipient equals exactly the fee the hook captured, and the hook keeps no residue.
    function test_H280_CI4_LiveSwapDeliversExactlyTheCapturedFee() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);

        _graduate(coin);
        assertEq(hook.getCurrentFee(poolId), FLOOR_FEE, "precondition: at-rest floor fee");

        uint256 amountIn = 0.1 ether;
        uint256 captured = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        assertGt(_swapEthForCoin(address(coin), users.buyerTwo, amountIn), 0, "swap produced no output");

        assertEq(_delivered(treasuryBefore, recipientBefore, vaultBefore), captured, "CI-4: delivered == captured");
        assertEq(address(hook).balance, 0, "hook retains no native ETH");
        assertEq(weth.balanceOf(address(hook)), 0, "hook retains no WETH");
    }

    /// @notice Live CI-4B at `protocolFeeRatio == 100`: the protocol takes the whole non-LP share,
    /// both downstream legs are zero, and the swap still completes.
    function test_H281_CI4B_LiveSwapAtProtocolRatio100DoesNotRevert() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(100);

        _graduate(coin);

        uint256 amountIn = 0.05 ether;
        uint256 captured = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        assertEq(weth.balanceOf(users.treasury) - treasuryBefore, captured, "the protocol takes the whole non-LP share");
        assertEq(weth.balanceOf(stakingVault) - vaultBefore, 0, "the vault leg is skipped, not reverted");
        assertEq(weth.balanceOf(address(this)) - recipientBefore, 0, "the recipient leg is skipped, not reverted");
        assertEq(_delivered(treasuryBefore, recipientBefore, vaultBefore), captured, "CI-4 still holds at the extreme");
    }

    /// @notice Live CI-4B at `protocolFeeRatio == 0`: nothing is taken off the top and the swap
    /// still completes with the remainder split between vault and recipient.
    function test_H281_CI4B_LiveSwapAtProtocolRatio0DoesNotRevert() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(0);

        _graduate(coin);

        uint256 amountIn = 0.05 ether;
        uint256 captured = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        assertEq(
            weth.balanceOf(users.treasury) - treasuryBefore,
            amountIn * uint256(hook.PROTOCOL_FLOOR_PIPS()) / FEE_DENOMINATOR,
            "at ratio 0 the protocol leg is exactly the protocol floor (Q18)"
        );
        assertEq(_delivered(treasuryBefore, recipientBefore, vaultBefore), captured, "CI-4 still holds at the extreme");
    }

    /// @notice Live CI-4B with `stakingVault == address(0)`: a coin deployed with no staking vault
    /// registers a pool whose vault slot is zero. The whole after-protocol remainder reaches the
    /// fee recipient and the swap completes - the no-vault branch does not revert.
    function test_H281_CI4B_LiveSwapWithNoStakingVaultDoesNotRevert() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);

        // The original deploys as `users.creator`; here the coin's fee recipient is pointed at
        // `users.creator` instead (this contract is every mock coin's creator).
        MockBCToken noVaultCoin = _deployCoin(
            "NOVAULT",
            "NOVAULT",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
        noVaultCoin.setAlternativeFeeRecipient(users.creator);

        _graduate(noVaultCoin);

        PoolId noVaultPool = _poolId(address(noVaultCoin));
        assertEq(hook.getPoolState(noVaultPool).stakingVault, address(0), "precondition: the pool has no vault");

        uint256 amountIn = 0.05 ether;
        uint256 captured = amountIn * _protocolRate(FLOOR_FEE) / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(users.creator);

        _swapEthForCoin(address(noVaultCoin), users.buyerTwo, amountIn);

        uint256 delivered =
            (weth.balanceOf(users.treasury) - treasuryBefore) + (weth.balanceOf(users.creator) - recipientBefore);
        assertEq(delivered, captured, "CI-4 holds on the no-vault branch: delivered == captured");
        assertEq(weth.balanceOf(address(hook)), 0, "hook retains no WETH");
    }
}
