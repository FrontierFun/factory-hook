// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";

import {HookAddressMiner} from "script/utils/HookAddressMiner.sol";
import {MockTokenFactory} from "test/FactoryHookUnit.t.sol";
import {DeployV4Infra} from "test/helpers/DeployV4Infra.sol";
import {ERC20Mock} from "test/helpers/ERC20Mock.sol";
import {FactoryHookHarness} from "test/helpers/FactoryHookHarness.sol";
import {MockStakingVault, MockStakingVaultFactory} from "test/helpers/ProtocolMocks.sol";

/// @title PoC_H29_TruncatedOraclePerObservationClamp
/// @notice Regression for H-29 (audit L-04), FIXED: `FactoryHook`'s truncated-tick oracle used
/// to clamp the recorded tick by `MAX_ABS_TICK_MOVE` **per checkpoint**, against the previous
/// swap's recorded tick, so the attacker chose how many clamp steps a block took — N swaps in
/// one block moved the recorded tick by N * MAX_ABS_TICK_MOVE. `_checkpointSwap` now clamps
/// every checkpoint of a block against the tick the oracle held when the block opened
/// (`anchorTick`), so the same split sequence moves it by exactly one step. The full property
/// set lives in `PoC_L04_TruncatedTickCapPerBlock`; this suite keeps the original exact-tick
/// attack and asserts the bound.
contract PoC_H29_TruncatedOraclePerObservationClamp is Test, DeployV4Infra {
    uint160 internal constant HOOK_FLAGS = 0x30CC;

    FactoryHookHarness internal hook;
    MockTokenFactory internal tokenFactory;
    MockStakingVaultFactory internal stakingVaultFactory;
    ERC20Mock internal coin;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = makeAddr("owner");

    /// @dev The tick an attacker pushes the pool to inside a single block. Deliberately
    /// 6 * MAX_ABS_TICK_MOVE so the "damped" and "undamped" outcomes differ by exactly 6x.
    int24 internal constant MANIPULATED_TICK = 54_696; // 6 * 9116
    uint256 internal constant SPLITS = 6;
    uint256 internal constant TWAP_WINDOW = 600; // seconds observed after the manipulation block

    receive() external payable {}

    function setUp() public virtual {
        deployV4Infra();

        tokenFactory = new MockTokenFactory(owner, address(this));
        stakingVaultFactory = new MockStakingVaultFactory(owner, address(0), address(weth));
        coin = new ERC20Mock("Coin", "COIN", 18);

        bytes memory constructorArgs =
            abi.encode(poolManager, address(tokenFactory), address(weth), address(stakingVaultFactory));
        (address predictedHook, bytes32 salt) =
            HookAddressMiner.find(address(this), HOOK_FLAGS, type(FactoryHookHarness).creationCode, constructorArgs);
        hook = new FactoryHookHarness{salt: salt}(
            poolManager, address(tokenFactory), address(weth), address(stakingVaultFactory)
        );
        assertEq(address(hook), predictedHook);

        vm.prank(owner);
        stakingVaultFactory.setHook(address(hook));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(coin)),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        hook.registerPool(
            key,
            address(coin),
            0,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );

        // Anchor the oracle at tick 0 in a settled block before the attack block. A full swap
        // cycle (beforeSwap accrue + afterSwap checkpoint) leaves both the reference tick and the
        // recorded oracle tick at 0.
        vm.warp(1_000_000);
        hook.exposed_swapCycle(poolId, 0, 0);
        (, int24 anchored) = hook.observe(poolId);
        assertEq(anchored, int24(0), "oracle anchored at tick 0");
    }

    /// @notice BASELINE: with ONE observation in the manipulation block, the clamp works as
    /// advertised - the recorded tick moves at most MAX_ABS_TICK_MOVE.
    function test_H29_Baseline_SingleObservationIsClamped() public {
        vm.warp(block.timestamp + 12); // the manipulation block

        hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);

        (, int24 recorded) = hook.observe(poolId);
        assertEq(recorded, hook.MAX_ABS_TICK_MOVE(), "one observation moves the tick by exactly the cap");
        assertLt(int256(recorded), int256(MANIPULATED_TICK), "the raw manipulated tick is NOT recorded");
    }

    /// @notice FIXED: the SAME price move, in the SAME single block, split into N swaps moves the
    /// recorded oracle tick by exactly ONE `MAX_ABS_TICK_MOVE` — the same as a single observation.
    function test_H29_FIXED_SplitSwapsInOneBlockAreClampedLikeOneObservation() public {
        vm.warp(block.timestamp + 12); // the manipulation block
        uint256 attackBlockTimestamp = block.timestamp;

        for (uint256 i; i < SPLITS; ++i) {
            // No vm.warp between iterations: every observation happens in ONE block, exactly as
            // N swaps bundled into one transaction/bundle would.
            hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        }
        assertEq(block.timestamp, attackBlockTimestamp, "all observations occurred in a single block");

        (, int24 recorded) = hook.observe(poolId);

        assertEq(recorded, hook.MAX_ABS_TICK_MOVE(), "FIXED: the split sequence moves the tick by exactly the cap");
        assertLt(int256(recorded), int256(MANIPULATED_TICK), "the raw manipulated tick is NOT recorded");
    }

    /// @notice FIXED (downstream): the damped tick is what accrues into `tickCumulative` after
    /// the attack block on both paths, so a consumer deriving a TWAP as (cum2-cum1)/(t2-t1) over
    /// the following window reads the same average tick whether the block held one swap or N.
    function test_H29_FIXED_SplitPathTwapMatchesTheDampedPath() public {
        // ---- Path A: honest single observation (the damped reference outcome). ----
        uint256 snapshot = vm.snapshot();

        vm.warp(block.timestamp + 12);
        hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        (int56 cumA1,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cumA2,) = hook.observe(poolId);
        int256 twapDamped = (int256(cumA2) - int256(cumA1)) / int256(TWAP_WINDOW);

        // ---- Path B: the SAME block, the SAME end price, split into N swaps. ----
        vm.revertTo(snapshot);

        vm.warp(block.timestamp + 12);
        for (uint256 i; i < SPLITS; ++i) {
            hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        }
        (int56 cumB1,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cumB2,) = hook.observe(poolId);
        int256 twapSplit = (int256(cumB2) - int256(cumB1)) / int256(TWAP_WINDOW);

        assertEq(twapDamped, int256(hook.MAX_ABS_TICK_MOVE()), "damped path: TWAP is capped at one step");
        // FIXED: identical block, identical final price — and the TWAP a consumer reads is identical.
        assertEq(twapSplit, twapDamped, "FIXED: the split path TWAP equals the damped path TWAP");
    }
}
