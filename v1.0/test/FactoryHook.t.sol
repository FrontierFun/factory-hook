// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";

import {FixedQuoteCalculator, RevertingCalculator} from "test/helpers/ExtensionMocks.sol";
import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title FactoryHookTest
/// @notice Integration coverage of the FactoryHook fee engine through REAL pool swaps: the
/// graduation gate, halt switch, volatility-scaled fee on all four swap modes, coin/ETH-side
/// distribution splits, and the truncated oracle. Complements FactoryHookUnit.t.sol.
contract FactoryHookTest is HookTestBase {
    using StateLibrary for IPoolManager;

    // The pool's flat base fee: registered with an empty payload, so DEFAULT_FIXED_FEE (3000)
    // applies to every swap — gen-2 pools have no in-hook volatility curve.
    uint256 internal constant BASE_FEE = 3000;
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    // Default LP share of the total step fee; the hook captures only the (10000 - lpShareBps)
    // non-LP remainder as a hook delta. The LP share rides V4's native dynamic fee.
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

    /// @dev Non-LP (protocol) pip rate the hook captures for a total step fee `R`, mirroring
    /// FactoryHook: protocolRate = R * (10000 - lpShareBps) / 10000. With defaults this is
    /// R * 3000 / 10000, i.e. the hook captures 30% of the notional fee; LPs get 70%.
    function _protocolRate(uint256 stepFee) internal pure returns (uint256) {
        return stepFee * (BPS_DENOMINATOR - LP_SHARE_BPS) / BPS_DENOMINATOR;
    }

    /// @dev The treasury's level-1 take under the Q18 floor: `ratio`% of the captured fee, never
    /// below `PROTOCOL_FLOOR_PIPS` of the swap amount, capped by the captured fee itself.
    function _treasuryShare(uint256 capturedFee, uint256 amountIn, uint256 ratio)
        internal
        view
        returns (uint256 share)
    {
        share = capturedFee * ratio / 100;
        uint256 floorAmount = amountIn * hook.PROTOCOL_FLOOR_PIPS() / FEE_DENOMINATOR;
        if (share < floorAmount) share = floorAmount > capturedFee ? capturedFee : floorAmount;
    }

    /// @dev Verifies the staking vault booked `expectedVault` WETH from an ETH-leg fee: its WETH
    /// balance rises by that amount, and the reward is registered either as `pendingWeth` (when
    /// the vault has zero share supply, as in this fixture) or as `wethRewardPerShare` (non-zero
    /// supply). The vault's ETH-side community share arrives as WETH via `notifyWethReward`.
    function _assertVaultWethReward(
        uint256 vaultWethBefore,
        uint256 pendingBefore,
        uint256 rpsBefore,
        uint256 expectedVault
    ) internal view {
        assertEq(weth.balanceOf(stakingVault) - vaultWethBefore, expectedVault, "vault WETH delta");
        if (expectedVault == 0) return;
        if (IStakingVault(stakingVault).totalSupply() == 0) {
            assertEq(IStakingVault(stakingVault).pendingWeth() - pendingBefore, expectedVault, "vault pendingWeth");
        } else {
            assertGt(IStakingVault(stakingVault).wethRewardPerShare(), rpsBefore, "vault rewardPerShare");
        }
    }

    /// @dev Encodes the ERC-7751 wrapped revert the PoolManager produces when a hook callback
    /// reverts with `selector`.
    function _wrappedBeforeSwapRevert(bytes4 selector) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            IHooks.beforeSwap.selector,
            abi.encodeWithSelector(selector),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    function _assertNoHookResidue() internal view {
        assertEq(address(hook).balance, 0, "hook holds native ETH");
        assertEq(weth.balanceOf(address(hook)), 0, "hook holds WETH");
        assertEq(coin.balanceOf(address(hook)), 0, "hook holds coin");
    }
}

contract SwapGateTest is FactoryHookTest {
    function test_revertsIf_notGraduated() public {
        PoolKey memory key = _poolKey(address(coin));
        vm.expectRevert(_wrappedBeforeSwapRevert(IFactoryHook.NotLPd.selector));
        vm.prank(users.buyerTwo);
        swapRouter.swap{value: 0.1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -0.1e18, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}

contract ExactInFeeTest is FactoryHookTest {
    function test_ethInput_chargesFloorFeeAndSplitsWeth() public {
        _graduate(coin);
        // First swap after graduation: volatility accumulator and displacement are zero, so the
        // total step fee is exactly the floor fee.
        assertEq(hook.getCurrentFee(poolId), BASE_FEE, "pre-swap fee not the flat base fee");

        // Fee-split derivation (exact input, ETH leg, coin has a staking vault):
        //   R            = floorFee                       = 3000  (total step fee)
        //   protocolRate = R * (10000 - 7000) / 10000     = 900   (non-LP pip rate captured)
        //   capturedFee  = amountIn * protocolRate / 1e6          (the 30% non-LP portion)
        //   treasury     = max(capturedFee * protocolFeeRatio(25) / 100, Q18 floor of the swap)
        //   remainder    = capturedFee - treasury
        //   vault        = remainder * communityFeeRatio(50) / 100   (paid as WETH)
        //   recipient    = remainder - vault
        uint256 amountIn = 0.1 ether;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;
        uint256 expectedTreasury = _treasuryShare(capturedFee, amountIn, 25);
        uint256 remainder = capturedFee - expectedTreasury;
        uint256 expectedVault = remainder * 50 / 100;
        uint256 expectedRecipient = remainder - expectedVault;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this)); // creator = fee recipient
        uint256 vaultWethBefore = weth.balanceOf(stakingVault);
        uint256 pendingBefore = IStakingVault(stakingVault).pendingWeth();
        uint256 rpsBefore = IStakingVault(stakingVault).wethRewardPerShare();

        uint256 amountOut = _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        assertGt(amountOut, 0, "no output");
        assertEq(weth.balanceOf(users.treasury) - treasuryBefore, expectedTreasury, "treasury WETH share");
        assertEq(weth.balanceOf(address(this)) - recipientBefore, expectedRecipient, "recipient share");
        _assertVaultWethReward(vaultWethBefore, pendingBefore, rpsBefore, expectedVault);
        _assertNoHookResidue();
    }

    function test_coinInput_splitsBetweenTreasuryVaultAndRecipient() public {
        _graduate(coin);
        // Give the swapper coins without moving the pool: transfer from the graduation buyer.
        vm.prank(users.buyerOne);
        coin.transfer(users.buyerTwo, 2_000_000e18);

        // A real staker: the coin leg only routes to the vault while it holds shares, since the
        // coin-side reward is share-price appreciation.
        vm.prank(users.buyerOne);
        coin.transfer(users.buyerThree, 1_000_000e18);
        _stakeIntoVault(address(coin), users.buyerThree, 1_000_000e18);

        // Fee-split derivation (exact input, coin leg, coin has a staking vault):
        //   R            = floorFee                       = 3000
        //   protocolRate = R * 3000 / 10000               = 900
        //   capturedFee  = amountIn * protocolRate / 1e6
        //   treasury     = max(capturedFee * protocolFeeRatio(25) / 100, Q18 floor of the swap)
        //   remainder    = capturedFee - treasury
        //   vault        = remainder * communityFeeRatio(50) / 100   (paid in coin via take)
        //   recipient    = remainder - vault
        uint256 amountIn = 1_000_000e18;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;
        uint256 expectedTreasury = _treasuryShare(capturedFee, amountIn, 25);
        uint256 remainder = capturedFee - expectedTreasury;
        uint256 expectedVault = remainder * 50 / 100;
        uint256 expectedRecipient = remainder - expectedVault;

        uint256 treasuryBefore = coin.balanceOf(users.treasury);
        uint256 vaultBefore = coin.balanceOf(stakingVault);
        uint256 recipientBefore = coin.balanceOf(address(this));

        uint256 ethOut = _swapCoinForEth(address(coin), users.buyerTwo, amountIn);

        assertGt(ethOut, 0, "no output");
        assertEq(coin.balanceOf(users.treasury) - treasuryBefore, expectedTreasury, "treasury share");
        assertEq(coin.balanceOf(stakingVault) - vaultBefore, expectedVault, "vault share");
        assertEq(coin.balanceOf(address(this)) - recipientBefore, expectedRecipient, "recipient share");
        _assertNoHookResidue();
    }

    function test_coinInput_withoutVault_splitsProtocolTreasury() public {
        // Second coin without staking vault: coin-side fees fall back to treasury/recipient split.
        MockBCToken noVaultCoin = _deployCoin(
            "NoVault",
            "NOVLT",
            0,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
        _graduate(noVaultCoin);
        PoolId id = _poolId(address(noVaultCoin));
        assertEq(hook.getPoolState(id).stakingVault, address(0), "vault unexpectedly deployed");

        vm.prank(users.buyerOne);
        noVaultCoin.transfer(users.buyerTwo, 2_000_000e18);

        // No vault: the after-protocol remainder goes entirely to the fee recipient.
        //   capturedFee = amountIn * protocolRate / 1e6
        //   treasury    = max(capturedFee * protocolFeeRatio(25) / 100, Q18 floor of the swap)
        //   recipient   = capturedFee - treasury
        uint256 amountIn = 1_000_000e18;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;
        uint256 expectedTreasury = _treasuryShare(capturedFee, amountIn, 25); // protocolFeeRatio = 25, Q18 floor
        uint256 expectedRecipient = capturedFee - expectedTreasury;

        uint256 treasuryBefore = noVaultCoin.balanceOf(users.treasury);
        uint256 recipientBefore = noVaultCoin.balanceOf(address(this));

        _swapCoinForEth(address(noVaultCoin), users.buyerTwo, amountIn);

        assertEq(noVaultCoin.balanceOf(users.treasury) - treasuryBefore, expectedTreasury, "treasury coin share");
        assertEq(noVaultCoin.balanceOf(address(this)) - recipientBefore, expectedRecipient, "recipient share");
    }

    function test_zeroProtocolFeeRatio_ethSideTreasuryGetsNothing() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(0);
        _graduate(coin);

        // protocolFeeRatio == 0: the treasury takes exactly the protocol floor (in pips of the swap) (Q18); the
        // rest of the captured fee is the remainder, split between the vault
        // (communityFeeRatio 50) and the recipient.
        uint256 amountIn = 0.1 ether;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;
        uint256 treasuryFloor = amountIn * uint256(hook.PROTOCOL_FLOOR_PIPS()) / FEE_DENOMINATOR;
        uint256 expectedVault = (capturedFee - treasuryFloor) * 50 / 100;
        uint256 expectedRecipient = capturedFee - treasuryFloor - expectedVault;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultWethBefore = weth.balanceOf(stakingVault);
        uint256 pendingBefore = IStakingVault(stakingVault).pendingWeth();
        uint256 rpsBefore = IStakingVault(stakingVault).wethRewardPerShare();

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        assertEq(
            weth.balanceOf(users.treasury) - treasuryBefore, treasuryFloor, "treasury gets exactly the protocol floor"
        );
        assertEq(weth.balanceOf(address(this)) - recipientBefore, expectedRecipient, "recipient share");
        _assertVaultWethReward(vaultWethBefore, pendingBefore, rpsBefore, expectedVault);
        _assertNoHookResidue();
    }

    function test_hundredProtocolFeeRatio_sendsAllEthSideToTreasury() public {
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(100);
        _graduate(coin);

        // protocolFeeRatio == 100: treasury takes the entire captured fee off the top, leaving a
        // zero remainder for the vault and recipient.
        uint256 amountIn = 0.1 ether;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultWethBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        assertEq(weth.balanceOf(users.treasury) - treasuryBefore, capturedFee, "treasury full captured fee");
        assertEq(weth.balanceOf(address(this)), recipientBefore, "recipient should get nothing");
        assertEq(weth.balanceOf(stakingVault), vaultWethBefore, "vault should get nothing");
        _assertNoHookResidue();
    }
}

contract ExactOutFeeTest is FactoryHookTest {
    function test_ethInput_grossesUpOnComputedInput() public {
        _graduate(coin);

        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 vaultBefore = weth.balanceOf(stakingVault);
        uint256 coinBefore = coin.balanceOf(users.buyerTwo);

        PoolKey memory key = _poolKey(address(coin));
        vm.prank(users.buyerTwo);
        BalanceDelta delta = swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1_000_000e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(coin.balanceOf(users.buyerTwo) - coinBefore, 1_000_000e18, "exact output not honored");

        // Only the non-LP (protocol) rate is captured, grossed up on the pool-computed input:
        //   protocolRate = floorFee * 3000 / 10000
        //   fee          = poolInput * protocolRate / (1e6 - protocolRate)
        // On the ETH leg the captured fee is split treasury + vault + recipient (all WETH), so the
        // total fee received is the sum across all three.
        uint256 totalPaid = uint256(uint128(uint256(-int256(delta.amount0()))));
        uint256 feeReceived = (weth.balanceOf(address(this)) - recipientBefore)
            + (weth.balanceOf(users.treasury) - treasuryBefore) + (weth.balanceOf(stakingVault) - vaultBefore);
        uint256 poolInput = totalPaid - feeReceived;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        assertEq(feeReceived, poolInput * protocolRate / (FEE_DENOMINATOR - protocolRate), "gross-up mismatch");
        _assertNoHookResidue();
    }

    function test_coinInput_grossesUpOnComputedInput() public {
        _graduate(coin);
        vm.prank(users.buyerOne);
        coin.transfer(users.buyerTwo, 10_000_000e18);

        uint256 treasuryBefore = coin.balanceOf(users.treasury);
        uint256 vaultBefore = coin.balanceOf(stakingVault);
        uint256 recipientBefore = coin.balanceOf(address(this));

        PoolKey memory key = _poolKey(address(coin));
        vm.startPrank(users.buyerTwo);
        coin.approve(address(swapRouter), type(uint256).max);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: int256(0.001e18), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();

        // Non-LP rate grossed up on the pool-computed coin input; the captured fee is split
        // treasury + vault + recipient (all coin), so the total fee received is the sum across all.
        uint256 totalPaid = uint256(uint128(uint256(-int256(delta.amount1()))));
        uint256 feeReceived = (coin.balanceOf(users.treasury) - treasuryBefore)
            + (coin.balanceOf(stakingVault) - vaultBefore) + (coin.balanceOf(address(this)) - recipientBefore);
        uint256 poolInput = totalPaid - feeReceived;
        uint256 protocolRate = _protocolRate(BASE_FEE);
        assertEq(feeReceived, poolInput * protocolRate / (FEE_DENOMINATOR - protocolRate), "gross-up mismatch");
        _assertNoHookResidue();
    }

    /// @notice A 1-wei coin output requires an ETH input so tiny the grossed-up protocol fee
    /// truncates to zero: `_exactInFeeAmount`'s fallthrough path (reached when the protocolRate
    /// stash produced no charge in `afterSwap`'s first branch) is exercised with nothing to
    /// distribute.
    function test_exactOutput_feeTruncatesToZero_noDistribution() public {
        _graduate(coin);

        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        PoolKey memory key = _poolKey(address(coin));
        vm.prank(users.buyerTwo);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: 1, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        assertEq(weth.balanceOf(users.treasury), treasuryBefore, "no treasury fee on a truncated-to-zero swap");
        assertEq(weth.balanceOf(address(this)), recipientBefore, "no recipient fee on a truncated-to-zero swap");
        assertEq(weth.balanceOf(stakingVault), vaultBefore, "no vault fee on a truncated-to-zero swap");
    }
}

contract PreviewFeeTest is FactoryHookTest {
    /// @dev Deploys a coin with a custom fee chain: a reverting stage (must be silently
    /// skipped on the view path, unlike the real swap path's `FeeCalculatorFallback` event)
    /// followed by a stage quoting above `MAX_HOOK_FEE`, plus a sniper window —
    /// `_quoteFeeChainView` must mirror `_runFeeChain`'s skip-and-clamp behaviour exactly.
    function test_previewFee_sniperWindow_allowsAboveHookCeiling_andSkipsFailingStage() public {
        address[] memory chain = new address[](2);
        chain[0] = address(new RevertingCalculator());
        chain[1] = address(new FixedQuoteCalculator(250_000));

        IFactoryHook.HookConfigV2 memory config = IFactoryHook.HookConfigV2({
            fixedFee: 3000,
            lpShareBps: 7000,
            feeCalculators: chain,
            calculatorConfigs: new bytes[](2),
            sniperWindow: 3600,
            observers: new IFactoryHook.ObserverConfig[](0)
        });

        MockBCToken sniped = _deployCoin(
            "Sniped",
            "SNIPE",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            abi.encodePacked(uint8(2), abi.encode(config))
        );
        _graduate(sniped);
        PoolId snipedPoolId = _poolId(address(sniped));

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        (uint24 totalFee,,) = hook.previewFee(snipedPoolId, params);
        assertEq(totalFee, 250_000, "reverting stage must be skipped and the sniper ceiling must apply");

        skip(3601);
        (uint24 afterWindow,,) = hook.previewFee(snipedPoolId, params);
        assertEq(afterWindow, hook.MAX_HOOK_FEE(), "outside the window the base ceiling clamps");
    }

    /// @notice A pool whose LP share leaves almost nothing for the protocol: the split rate
    /// must floor at `PROTOCOL_FLOOR_PIPS`, exactly mirroring the real swap path's floor.
    function test_previewFee_nonLpRateFlooredAtProtocolMinimum() public {
        IFactoryHook.HookConfigV2 memory config = IFactoryHook.HookConfigV2({
            fixedFee: 1000,
            lpShareBps: 9900,
            feeCalculators: new address[](0),
            calculatorConfigs: new bytes[](0),
            sniperWindow: 0,
            observers: new IFactoryHook.ObserverConfig[](0)
        });

        MockBCToken lowNonLp = _deployCoin(
            "LowNonLp",
            "LNL",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            abi.encodePacked(uint8(2), abi.encode(config))
        );
        _graduate(lowNonLp);
        PoolId lowNonLpPoolId = _poolId(address(lowNonLp));

        SwapParams memory params = SwapParams({
            zeroForOne: true, amountSpecified: -0.01 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
        (uint24 totalFee, uint24 lpFee, uint24 nonLpFee) = hook.previewFee(lowNonLpPoolId, params);

        assertEq(totalFee, 1000, "unfloored total should be the flat fee");
        assertEq(nonLpFee, hook.PROTOCOL_FLOOR_PIPS(), "non-LP rate must floor at the protocol minimum");
        assertEq(lpFee, totalFee - nonLpFee, "LP share is whatever remains after the floor");
    }
}

contract VolatilityFeeTest is FactoryHookTest {
    /// @notice Gen-2: a pool with no fee-calculator chain charges its flat base fee whatever
    /// the volatility does — the engine keeps measuring underneath (for extensions and the
    /// oracle), but no in-hook curve consumes it anymore.
    function test_flatFeeStaysWhileVolatilityMoves() public {
        _graduate(coin);
        assertEq(hook.getCurrentFee(poolId), BASE_FEE);

        // A sizable swap moves the tick; the volatility reading rises, the applied fee does not.
        _swapEthForCoin(address(coin), users.buyerTwo, 1 ether);
        assertGt(hook.getVolatility(poolId), 0, "volatility engine still measures the move");
        assertEq(hook.getCurrentFee(poolId), BASE_FEE, "flat fee is volatility-blind");

        // A second swap folds the displacement into the accumulator; after a full decay window
        // the reading is back to zero and the fee never moved.
        _swapEthForCoin(address(coin), users.buyerTwo, 0.001 ether);
        skip(601);
        assertEq(hook.getVolatility(poolId), 0, "reading decays to zero");
        assertEq(hook.getCurrentFee(poolId), BASE_FEE, "fee unchanged throughout");
    }

    function test_truncatedOracle_meanTickTracksPool() public {
        _graduate(coin);
        (int56 cumBefore,) = hook.observe(poolId);

        _swapEthForCoin(address(coin), users.buyerTwo, 0.5 ether);
        skip(600);

        (int56 cumAfter, int24 truncatedTick) = hook.observe(poolId);
        int56 meanTick = (cumAfter - cumBefore) / 600;
        assertLe(int256(meanTick), int256(TickMath.MAX_TICK));
        assertGe(int256(meanTick), int256(TickMath.MIN_TICK));
        assertLe(int256(truncatedTick), int256(TickMath.MAX_TICK));
    }
}

contract ThirdPartyLpTest is FactoryHookTest {
    function test_ethSideLpAllowed_preGraduation() public {
        // Pre-graduation third-party ETH-side LPing is possible (liquidity hooks are off) and
        // harmless: the tick cannot move (swaps are gated) and the coin is transfer-restricted.
        PoolKey memory key = _poolKey(address(coin));
        (, int24 seedTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        int24 lower = (seedTick / 60) * 60 + 60;
        int24 upper = lower + 600;

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] =
            abi.encode(key, lower, upper, uint256(1e15), type(uint128).max, uint128(0), users.buyerTwo, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1);
        params[2] = abi.encode(key.currency0, users.buyerTwo);

        vm.prank(users.buyerTwo);
        positionManager.modifyLiquidities{value: 1 ether}(abi.encode(actions, params), block.timestamp);

        // Graduation still succeeds with the third-party position in place.
        _graduate(coin);
        assertTrue(coin.isLPd());
    }
}
