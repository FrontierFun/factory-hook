// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {HookAddressMiner} from "script/utils/HookAddressMiner.sol";
import {MockTokenFactory} from "test/FactoryHookUnit.t.sol";
import {DeployV4Infra} from "test/helpers/DeployV4Infra.sol";
import {ERC20Mock} from "test/helpers/ERC20Mock.sol";
import {FactoryHookHarness} from "test/helpers/FactoryHookHarness.sol";
import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockStakingVault, MockStakingVaultFactory} from "test/helpers/ProtocolMocks.sol";

/// @title PoC_L04_TruncatedTickCapPerBlock_Unit
/// @notice Regression suite for audit finding L-04 ("Truncated-tick per-swap cap is manipulable
/// within a single block"). `FactoryHook._checkpointSwap` used to clamp the recorded oracle tick
/// against the PREVIOUS SWAP's recorded tick, so N swaps in one block bought N clamp steps and
/// `MAX_ABS_TICK_MOVE` bounded nothing a caller could not split around. The fix anchors every
/// checkpoint of a block to the tick the oracle held when the block opened (`anchorTick`), so:
///   1. any number of swaps in one block move the recorded tick by at most one step;
///   2. the recorded tick still follows the LAST completed swap inside that bound — an
///      intra-block push-then-revert settles back to the resting tick (a first-swap-wins gate
///      would have kept the pushed tick recorded at zero arbitrage exposure);
///   3. the bound advances exactly one step per block that swaps.
/// This contract drives `FactoryHookHarness` for exact ticks; the `_Live` contract below drives
/// the real hooked V4 pool through `BaseTest`.
contract PoC_L04_TruncatedTickCapPerBlock_Unit is Test, DeployV4Infra {
    uint160 internal constant HOOK_FLAGS = 0x30CC;

    FactoryHookHarness internal hook;
    MockTokenFactory internal tokenFactory;
    MockStakingVaultFactory internal stakingVaultFactory;
    ERC20Mock internal coin;
    PoolKey internal key;
    PoolId internal poolId;
    int24 internal cap;

    address internal owner = makeAddr("owner");

    /// @dev Swaps a manipulator packs into one block, and the tick they all end at:
    /// `SPLITS * MAX_ABS_TICK_MOVE`, so the pre-fix outcome (every split counted) and the fixed
    /// outcome (one step) differ by exactly `SPLITS`x.
    uint256 internal constant SPLITS = 6;
    int24 internal constant MANIPULATED_TICK = 54_696;
    uint256 internal constant TWAP_WINDOW = 600;
    uint256 internal constant BLOCK_TIME = 12;

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

        key = _keyFor(address(coin));
        poolId = key.toId();
        _register(key, address(coin));

        cap = hook.MAX_ABS_TICK_MOVE();
        assertEq(MANIPULATED_TICK, cap * int24(int256(SPLITS)), "manipulated tick is SPLITS caps away");

        // Anchor the oracle at tick 0 in a settled block: a full swap cycle (beforeSwap accrue +
        // afterSwap checkpoint) leaves the recorded tick at 0, then the block closes.
        vm.warp(1_000_000);
        hook.exposed_swapCycle(poolId, 0, 0);
        (, int24 anchored) = hook.observe(poolId);
        assertEq(anchored, int24(0), "oracle anchored at tick 0");
        _nextBlock();
    }

    /// @notice FIXED: `SPLITS` checkpoints at `SPLITS` caps away, inside one block, move the
    /// recorded tick by exactly ONE cap — the harm assertion of H-29 / L-04, inverted.
    function test_L04_FIXED_SplitSwapsInOneBlockMoveAtMostOneStep() public {
        uint256 attackBlockTimestamp = block.timestamp;

        for (uint256 i; i < SPLITS; ++i) {
            hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        }
        assertEq(block.timestamp, attackBlockTimestamp, "all checkpoints landed in one block");

        (, int24 recorded) = hook.observe(poolId);
        assertEq(recorded, cap, "FIXED: one block moves the recorded tick by exactly MAX_ABS_TICK_MOVE");
        assertLt(int256(recorded), int256(MANIPULATED_TICK), "the raw manipulated tick is not recorded");

        IFactoryHook.PoolState memory state = hook.getPoolState(poolId);
        assertEq(state.anchorTick, int24(0), "the block anchors on the tick it opened at");
        assertEq(uint256(state.anchorTimestamp), block.timestamp, "the anchor carries the block's timestamp");
    }

    /// @notice FIXED: splitting buys nothing downstream either — the split path and the
    /// single-observation path feed the same TWAP over the following window.
    function test_L04_FIXED_SplitPathTwapEqualsSingleObservationPath() public {
        uint256 snapshot = vm.snapshot();

        hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        int256 twapSingle = _twapOverWindow();

        vm.revertTo(snapshot);

        for (uint256 i; i < SPLITS; ++i) {
            hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        }
        int256 twapSplit = _twapOverWindow();

        assertEq(twapSingle, int256(cap), "single observation: TWAP is one step");
        assertEq(twapSplit, twapSingle, "FIXED: the split path reads exactly like one observation");
    }

    /// @notice FIXED: the recorded tick keeps following the last completed swap inside the bound,
    /// so a push-then-revert pair in one block settles back to the resting tick and the idle
    /// interval accrues nothing of the push. This is the property that separates anchoring from
    /// a write-once-per-block gate, which would have kept the pushed tick for the whole interval.
    function test_L04_FIXED_IntraBlockRoundTripLeavesTheRestingTick() public {
        hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        (, int24 pushed) = hook.observe(poolId);
        assertEq(pushed, cap, "the push is recorded, bounded");

        hook.exposed_checkpointSwap(poolId, 0);
        (, int24 settled) = hook.observe(poolId);
        assertEq(settled, int24(0), "FIXED: the revert swap brings the recorded tick back to the resting tick");

        (int56 cumBefore,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cumAfter,) = hook.observe(poolId);
        assertEq(cumAfter - cumBefore, int56(0), "the idle interval accrues at the resting tick");
    }

    /// @notice FIXED: within a block the recorded tick may sit anywhere in
    /// `[anchor - cap, anchor + cap]` — crossing from one side of the anchor to the other is
    /// allowed — but never outside it, and an in-bound tick is recorded exactly.
    function test_L04_FIXED_RecordedTickRangesWithinOneStepOfTheAnchorOnBothSides() public {
        hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
        (, int24 up) = hook.observe(poolId);
        assertEq(up, cap, "bounded above");

        hook.exposed_checkpointSwap(poolId, -MANIPULATED_TICK);
        (, int24 down) = hook.observe(poolId);
        assertEq(down, -cap, "bounded below, against the anchor rather than against +cap");

        hook.exposed_checkpointSwap(poolId, 123);
        (, int24 inside) = hook.observe(poolId);
        assertEq(inside, int24(123), "an in-bound tick is recorded exactly");
    }

    /// @notice FIXED: the bound advances exactly one step per block that swaps, however many
    /// swaps each block carries — reaching the manipulated tick takes `SPLITS` blocks, not one.
    function test_L04_FIXED_TheBoundAdvancesOneStepPerBlock() public {
        for (uint256 blockIndex = 1; blockIndex <= SPLITS + 1; ++blockIndex) {
            for (uint256 i; i < SPLITS; ++i) {
                hook.exposed_checkpointSwap(poolId, MANIPULATED_TICK);
            }
            (, int24 recorded) = hook.observe(poolId);
            int24 expected = blockIndex >= SPLITS ? MANIPULATED_TICK : cap * int24(int256(blockIndex));
            assertEq(recorded, expected, "one step per block, then pinned at the target");
            _nextBlock();
        }
    }

    /// @notice FIXED: a pool initialized and swapped in the same block is bounded against its
    /// opening tick — `_afterInitialize` seeds the anchor, so the opening block is no exception.
    function test_L04_FIXED_InitializeAndSwapInTheSameBlockClampAgainstTheOpeningTick() public {
        ERC20Mock fresh = new ERC20Mock("Fresh", "FRESH", 18);
        PoolKey memory freshKey = _keyFor(address(fresh));
        PoolId freshId = freshKey.toId();
        _register(freshKey, address(fresh));
        poolManager.initialize(freshKey, TickMath.getSqrtPriceAtTick(0));

        IFactoryHook.PoolState memory state = hook.getPoolState(freshId);
        assertEq(state.anchorTick, int24(0), "initialize seeds the anchor at the opening tick");
        assertEq(uint256(state.anchorTimestamp), block.timestamp, "initialize stamps the anchor");

        for (uint256 i; i < SPLITS; ++i) {
            hook.exposed_checkpointSwap(freshId, MANIPULATED_TICK);
        }
        (, int24 recorded) = hook.observe(freshId);
        assertEq(recorded, cap, "FIXED: the opening block is bounded against the opening tick");
    }

    /// @notice FIXED, fuzzed: for ANY sequence of post-swap ticks landing in one block, the
    /// recorded tick is the last one clamped to one step of the anchor — never more.
    function testFuzz_L04_FIXED_AnySplitSequenceInOneBlockStaysWithinOneStep(int24[8] memory ticks) public {
        int24 last;
        for (uint256 i; i < ticks.length; ++i) {
            last = int24(bound(int256(ticks[i]), int256(TickMath.MIN_TICK), int256(TickMath.MAX_TICK)));
            hook.exposed_checkpointSwap(poolId, last);
        }

        (, int24 recorded) = hook.observe(poolId);
        int24 expected = last > cap ? cap : (last < -cap ? -cap : last);
        assertEq(recorded, expected, "FIXED: last tick, clamped to one step of the anchor");
    }

    function _keyFor(address currency1) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(currency1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
    }

    function _register(PoolKey memory poolKey, address currency1) internal {
        hook.registerPool(
            poolKey,
            currency1,
            0,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
    }

    function _twapOverWindow() internal returns (int256) {
        (int56 cumBefore,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cumAfter,) = hook.observe(poolId);
        return (int256(cumAfter) - int256(cumBefore)) / int256(TWAP_WINDOW);
    }

    function _nextBlock() internal {
        vm.warp(block.timestamp + BLOCK_TIME);
        vm.roll(block.number + 1);
    }
}

/// @title PoC_L04_TruncatedTickCapPerBlock_Live
/// @notice The L-04 guarantees on the REAL hooked V4 pool — real swaps through the router, no
/// harness, no internal-function exposure. Mirrors the attack `PoC_H364` used to assert the
/// harm with: one trade split into several swaps inside a single block.
contract PoC_L04_TruncatedTickCapPerBlock_Live is HookTestBase {
    using StateLibrary for IPoolManager;

    PoolId internal poolId;
    address internal manipulator;
    int24 internal cap;

    uint256 internal constant SPLITS = 5;
    uint256 internal constant SPLIT_SIZE = 40 ether;
    uint256 internal constant TWAP_WINDOW = 600;
    uint256 internal constant BLOCK_TIME = 12;

    function setUp() public virtual override {
        super.setUp();
        _graduate(coin);

        poolId = _poolId(address(coin));
        cap = hook.MAX_ABS_TICK_MOVE();
        manipulator = makeAddr("Manipulator");
        vm.deal(manipulator, 10_000 ether);

        // Anchor the oracle: one swap in a settled block establishes the recorded tick the
        // attack block opens at.
        _swapEthForCoin(address(coin), manipulator, 1 ether);
        _nextBlock();
    }

    /// @notice FIXED: five 40 ETH swaps in one block — a raw pool move of several caps — move
    /// the recorded tick by exactly one cap.
    function test_L04_FIXED_SplitSwapsInOneBlockMoveTheOracleOneStep() public {
        uint256 attackBlockTimestamp = block.timestamp;
        (, int24 recordedAtBlockStart) = hook.observe(poolId);
        int24 poolTickBefore = _currentTick();

        for (uint256 i; i < SPLITS; ++i) {
            _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        }
        assertEq(block.timestamp, attackBlockTimestamp, "all swaps occurred in one block");

        int256 rawMove = _abs(int256(_currentTick()) - int256(poolTickBefore));
        (, int24 recordedAfter) = hook.observe(poolId);
        int256 moved = _abs(int256(recordedAfter) - int256(recordedAtBlockStart));

        console2.log("raw pool tick move in the block:", rawMove);
        console2.log("recorded oracle move in the block:", moved);
        console2.log("MAX_ABS_TICK_MOVE:", cap);

        assertGt(rawMove, int256(cap) * 2, "the pool itself moved several caps, so the clamp binds");
        assertEq(moved, int256(cap), "FIXED: the recorded tick moved exactly one cap in the block");
    }

    /// @notice FIXED: the TWAP a consumer reads over the window after the attack block sits
    /// within one step of where the oracle opened the block.
    function test_L04_FIXED_DownstreamTwapDriftIsBoundedByOneStep() public {
        (, int24 recordedAtBlockStart) = hook.observe(poolId);

        for (uint256 i; i < SPLITS; ++i) {
            _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        }

        (int56 cumBefore,) = hook.observe(poolId);
        vm.warp(block.timestamp + TWAP_WINDOW);
        (int56 cumAfter,) = hook.observe(poolId);

        int256 twap = (int256(cumAfter) - int256(cumBefore)) / int256(TWAP_WINDOW);
        assertLe(
            _abs(twap - int256(recordedAtBlockStart)),
            int256(cap),
            "FIXED: downstream TWAP drift is bounded by one step"
        );
    }

    /// @notice FIXED: a push-then-revert inside one block leaves the oracle at the resting tick,
    /// not at the pushed bound — the round trip costs the manipulator fees and moves nothing.
    function test_L04_FIXED_PushThenRevertInOneBlockLeavesTheRestingTick() public {
        (, int24 anchor) = hook.observe(poolId);

        uint256 coinBought = _swapEthForCoin(address(coin), manipulator, SPLITS * SPLIT_SIZE);
        (, int24 pushed) = hook.observe(poolId);
        assertEq(_abs(int256(pushed) - int256(anchor)), int256(cap), "the push is recorded at the bound");

        _swapCoinForEth(address(coin), manipulator, coinBought);
        int24 resting = _currentTick();
        (, int24 recorded) = hook.observe(poolId);

        assertEq(recorded, _clamp(resting, anchor), "FIXED: the revert swap brings the oracle back to the resting tick");
        assertLt(_abs(int256(recorded) - int256(anchor)), int256(cap), "nothing of the push survives the round trip");
    }

    /// @notice FIXED: only a move that survives the block boundary reaches the oracle — the next
    /// block may move it one more step, from where the previous block left it.
    function test_L04_FIXED_TheNextBlockMovesOneMoreStep() public {
        (, int24 start) = hook.observe(poolId);

        for (uint256 i; i < SPLITS; ++i) {
            _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        }
        (, int24 afterBlockOne) = hook.observe(poolId);
        assertEq(_abs(int256(afterBlockOne) - int256(start)), int256(cap), "block one: one step");

        _nextBlock();
        _swapEthForCoin(address(coin), manipulator, SPLIT_SIZE);
        (, int24 afterBlockTwo) = hook.observe(poolId);

        assertEq(
            _abs(int256(afterBlockTwo) - int256(afterBlockOne)),
            int256(cap),
            "block two: one more step from where block one left the oracle"
        );
        assertEq(_abs(int256(afterBlockTwo) - int256(start)), int256(cap) * 2, "two blocks, two steps");
    }

    function _clamp(int24 tick, int24 anchor) internal view returns (int24) {
        if (tick - anchor > cap) return anchor + cap;
        if (tick - anchor < -cap) return anchor - cap;
        return tick;
    }

    function _currentTick() internal view returns (int24 t) {
        (, t,,) = poolManager.getSlot0(poolId);
    }

    function _nextBlock() internal {
        vm.warp(block.timestamp + BLOCK_TIME);
        vm.roll(block.number + 1);
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }
}
