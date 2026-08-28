// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";

/// @title Fuzz tests for the FactoryHook fee engine over REAL pool swaps
/// @notice Property coverage: the hook fee always lands within the configured band, the
/// distribution conserves the fee to the wei, and the hook never retains funds.
contract HookSwapFuzzTest is HookTestBase {
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    PoolId internal poolId;
    address internal stakingVault;

    function setUp() public override {
        super.setUp();
        poolId = _poolId(address(coin));
        stakingVault = hook.getPoolState(poolId).stakingVault;
        _graduate(coin);

        // A real staker, so the coin leg routes its share to the vault: coin-side rewards are
        // share-price appreciation, which the hook skips while the vault holds no shares.
        vm.prank(users.buyerOne);
        coin.transfer(users.buyerThree, 1_000_000e18);
        _stakeIntoVault(address(coin), users.buyerThree, 1_000_000e18);
    }

    /// @notice Exact-input ETH swaps: treasury + vault + recipient together receive exactly the
    /// captured non-LP fee `amountIn * protocolRate / 1e6` in WETH, where
    /// `protocolRate = fee * 3000 / 10000` and fee is the pre-swap current step fee.
    function testFuzz_exactInEth_feeConservedAndBounded(uint256 amountIn, uint8 ratio) public {
        amountIn = bound(amountIn, 1e9, 1 ether);
        ratio = uint8(bound(ratio, 0, 100));
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(ratio);

        uint256 fee = hook.getCurrentFee(poolId);
        assertGe(fee, 3000, "fee below floor");
        assertLe(fee, 12_000, "fee above cap");

        // The hook captures only the non-LP (protocol) share: protocolRate = fee * 3000 / 10000.
        // On the ETH leg the captured fee is split treasury + vault + recipient (all WETH).
        uint256 protocolRate = fee * 3000 / 10_000;
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);

        uint256 distributed = (weth.balanceOf(users.treasury) - treasuryBefore)
            + (weth.balanceOf(address(this)) - recipientBefore) + (weth.balanceOf(stakingVault) - vaultBefore);
        assertEq(distributed, capturedFee, "fee not conserved");
        assertEq(
            weth.balanceOf(users.treasury) - treasuryBefore,
            _treasuryShareWithFloor(capturedFee, amountIn, ratio),
            "treasury share wrong"
        );
        assertEq(address(hook).balance, 0, "hook residue: native");
        assertEq(weth.balanceOf(address(hook)), 0, "hook residue: weth");
    }

    /// @dev The treasury's level-1 take under the Q18 floor: `ratio`% of the captured fee, never
    /// below the protocol floor share of the swap input, capped by the captured fee itself.
    function _treasuryShareWithFloor(uint256 capturedFee, uint256 amountIn, uint256 ratio)
        internal
        view
        returns (uint256 share)
    {
        share = capturedFee * ratio / 100;
        uint256 floorAmount = amountIn * hook.PROTOCOL_FLOOR_PIPS() / FEE_DENOMINATOR;
        if (share < floorAmount) share = floorAmount > capturedFee ? capturedFee : floorAmount;
    }

    /// @notice Exact-input coin swaps: treasury + staking vault + fee recipient together receive
    /// exactly the captured non-LP fee `amountIn * protocolRate / 1e6` in coin
    /// (protocolFeeRatio 0, communityFeeRatio 50 fixture).
    function testFuzz_exactInCoin_feeConservedAndBounded(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e9, 5_000_000e18);
        vm.prank(users.buyerOne);
        coin.transfer(users.buyerTwo, amountIn);

        uint256 fee = hook.getCurrentFee(poolId);
        // Only the non-LP share is captured; protocolFeeRatio defaults to 0 so the treasury takes
        // exactly the protocol floor (in pips of the swap) (Q18) and the rest is the vault/recipient remainder.
        uint256 protocolRate = fee * 3000 / 10_000;
        uint256 capturedFee = amountIn * protocolRate / FEE_DENOMINATOR;

        uint256 treasuryBefore = coin.balanceOf(users.treasury);
        uint256 vaultBefore = coin.balanceOf(stakingVault);
        uint256 recipientBefore = coin.balanceOf(address(this));

        _swapCoinForEth(address(coin), users.buyerTwo, amountIn);

        uint256 distributed = (coin.balanceOf(users.treasury) - treasuryBefore)
            + (coin.balanceOf(stakingVault) - vaultBefore) + (coin.balanceOf(address(this)) - recipientBefore);
        assertEq(distributed, capturedFee, "fee not conserved");
        uint256 remainder = capturedFee - _treasuryShareWithFloor(capturedFee, amountIn, 0);
        assertEq(coin.balanceOf(stakingVault) - vaultBefore, remainder * 50 / 100, "vault share wrong");
        assertEq(coin.balanceOf(address(hook)), 0, "hook residue: coin");
    }

    /// @notice Exact-output swaps: the captured fee equals `poolInput * protocolRate / (1e6 -
    /// protocolRate)` (protocolRate = fee * 3000 / 10000) so the hook fee is a protocolRate/1e6
    /// share of the total paid, regardless of output size.
    function testFuzz_exactOutEth_grossUpHolds(uint256 amountOut) public {
        amountOut = bound(amountOut, 1e15, 10_000_000e18);

        uint256 fee = hook.getCurrentFee(poolId);
        uint256 protocolRate = fee * 3000 / 10_000;
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(address(this));
        uint256 vaultBefore = weth.balanceOf(stakingVault);
        uint256 buyerEthBefore = users.buyerTwo.balance;

        PoolKey memory key = _poolKey(address(coin));
        vm.prank(users.buyerTwo);
        try swapRouter.swap{value: users.buyerTwo.balance}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(amountOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            // Only the non-LP rate is captured, grossed up on the pool input; the ETH-leg fee is
            // split treasury + vault + recipient (all WETH).
            uint256 feeReceived = (weth.balanceOf(users.treasury) - treasuryBefore)
                + (weth.balanceOf(address(this)) - recipientBefore) + (weth.balanceOf(stakingVault) - vaultBefore);
            uint256 totalPaid = buyerEthBefore - users.buyerTwo.balance;
            uint256 poolInput = totalPaid - feeReceived;
            assertEq(feeReceived, poolInput * protocolRate / (FEE_DENOMINATOR - protocolRate), "gross-up mismatch");
        } catch {
            // Output larger than the range liquidity can serve (price limit hit) is a valid
            // pool-level revert; the property only constrains successful swaps.
        }
        assertEq(address(hook).balance, 0, "hook residue: native");
    }

    /// @notice The current fee remains inside [floorFee, capFee] after any swap/warp sequence.
    function testFuzz_currentFee_alwaysWithinBand(uint256 amountIn, uint32 warp1, uint32 warp2) public {
        amountIn = bound(amountIn, 1e12, 1 ether);
        warp1 = uint32(bound(warp1, 0, 2000));
        warp2 = uint32(bound(warp2, 0, 2000));

        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);
        skip(warp1);
        assertGe(hook.getCurrentFee(poolId), 3000);
        assertLe(hook.getCurrentFee(poolId), 12_000);

        uint256 coinBalance = coin.balanceOf(users.buyerTwo);
        if (coinBalance > 1e9) {
            _swapCoinForEth(address(coin), users.buyerTwo, coinBalance / 2);
        }
        skip(warp2);
        assertGe(hook.getCurrentFee(poolId), 3000);
        assertLe(hook.getCurrentFee(poolId), 12_000);
    }

    /// @notice The truncated oracle's recorded tick never moves more than MAX_ABS_TICK_MOVE
    /// per observation, no matter the swap size.
    function testFuzz_truncatedOracle_boundedStep(uint256 amountIn, uint32 gap) public {
        amountIn = bound(amountIn, 1e12, 50 ether);
        gap = uint32(bound(gap, 1, 1 days));

        (, int24 tickBefore) = hook.observe(poolId);
        vm.deal(users.buyerTwo, amountIn + 1 ether);
        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);
        skip(gap);
        // A second tiny swap advances the oracle.
        _swapEthForCoin(address(coin), users.buyerTwo, 1e9);

        (, int24 tickAfter) = hook.observe(poolId);
        int256 step = int256(tickAfter) - int256(tickBefore);
        if (step < 0) step = -step;
        // Two observations happened; each may move at most MAX_ABS_TICK_MOVE.
        assertLe(step, int256(2) * 9116, "truncation cap exceeded");
    }
}
