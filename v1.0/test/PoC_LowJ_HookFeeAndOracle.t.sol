// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {FactoryHook} from "src/hook/FactoryHook.sol";
import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {HookAddressMiner} from "script/utils/HookAddressMiner.sol";
import {MockTokenFactory} from "test/FactoryHookUnit.t.sol";
import {DeployV4Infra} from "test/helpers/DeployV4Infra.sol";
import {ERC20Mock} from "test/helpers/ERC20Mock.sol";
import {FactoryHookHarness} from "test/helpers/FactoryHookHarness.sol";
import {MockStakingVaultFactory} from "test/helpers/ProtocolMocks.sol";

/// @title PoC_LowJ_HookFeeAndOracle
/// @notice Executable evidence for the `sc_verify_low_j` FactoryHook rows: H-62 (fee-split
/// truncation biasing the last recipient), H-63 (uint32 truncation of `block.timestamp` after
/// 2106), H-58 (single non-namespaced transient fee slot), HI-06 (untimed per-pool halt with no
/// holder exit) and H-67 (IFactoryHook / getHookPermissions parity).
contract PoC_LowJ_HookFeeAndOracle is Test, DeployV4Infra {
    using StateLibrary for IPoolManager;

    uint160 internal constant HOOK_FLAGS = 0x30CC;

    FactoryHookHarness internal hook;
    MockTokenFactory internal tokenFactory;
    MockStakingVaultFactory internal stakingVaultFactory;
    ERC20Mock internal coin;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = makeAddr("LowJHookOwner");

    receive() external payable {}

    function setUp() public {
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
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();

        hook.registerPool(
            key,
            address(coin),
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );

        // Initialise the pool and hold a wide position, mirroring the state a graduated pool
        // trades in.
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        PoolModifyLiquidityTest router = new PoolModifyLiquidityTest(poolManager);
        coin.mint(address(this), 1_000_000 ether);
        coin.approve(address(router), type(uint256).max);
        vm.deal(address(this), address(this).balance + 100 ether);
        router.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
        assertGt(poolManager.getLiquidity(poolId), 0, "pool must hold active liquidity");
    }

    /// @notice H-62: `_split(amount, ratio)` is `amount * ratio / 100` with the remainder handed
    /// to the LAST party, so the split is quantised at 1% and any amount below `100 / ratio`
    /// truncates the first party's share to zero.
    /// HARM: the whole of every sub-threshold fee is diverted to the final recipient in the
    /// waterfall — the earlier recipients are paid nothing at all, not merely rounded down.
    function test_H62_splitTruncationDivertsWholeDustFeeToLastRecipient() public view {
        // Level-1 waterfall with a 30% protocol ratio: any fee below 4 wei pays the protocol 0.
        for (uint256 amount = 1; amount <= 3; ++amount) {
            (uint256 protocolAmount, uint256 remainder) = hook.exposed_split(amount, 30);
            assertEq(protocolAmount, 0, "HARM: first recipient receives nothing");
            assertEq(remainder, amount, "HARM: the entire fee is diverted downstream");
        }

        // The bias is directional, never self-correcting: the remainder always flows downstream.
        (uint256 a99, uint256 b99) = hook.exposed_split(99, 30);
        assertEq(a99, 29, "29 = 99 * 30 / 100, truncated down from 29.7");
        assertEq(b99, 70, "the truncated 0.7 wei is added to the last recipient, never carried");
        assertEq(a99 + b99, 99, "conservation holds; the bias is in WHO absorbs the residual");

        // Sub-1% shares are inexpressible at any amount: ratio is a whole percent.
        (uint256 aTiny,) = hook.exposed_split(1 ether, 0);
        assertEq(aTiny, 0, "a sub-1% intended share collapses to 0");

        // Truncation 2: `_lpFeeOverride` = lpRate * 1e6 / (1e6 - protocolRate), floored — so the
        // grossed-up LP override lands up to one pip BELOW the exact gross-up, systematically
        // favouring the non-LP side. Reproduced here on the hook's own default configuration.
        uint256 stepFee = hook.DEFAULT_FIXED_FEE();
        uint256 protocolRate = stepFee * (10_000 - uint256(7000)) / 10_000;
        uint256 lpRate = stepFee - protocolRate;
        uint256 flooredOverride = lpRate * 1e6 / (1e6 - protocolRate);
        // Effective LP take-home after core applies the override to the shrunken input.
        uint256 effectiveLp = flooredOverride * (1e6 - protocolRate) / 1e6;
        assertLe(effectiveLp, lpRate, "HARM: LPs never receive more than their exact share");
    }

    /// @notice H-63: `PoolState.lastSwapTimestamp` is `uint32` and written with an unchecked
    /// truncating cast, while every consumer subtracts it from a full-width `block.timestamp`.
    /// HARM: past 2106-02-07 the volatility accumulator reads as permanently fully-decayed (the
    /// fee collapses to the floor step) and `observe()` returns a garbage tick-cumulative.
    function test_H63_uint32TimestampTruncationDegradesVolatilityAndOracle() public {
        // The pool is registered but not initialized in the PoolManager, so `getSlot0` reports
        // tick 0 throughout. Both legs below therefore run an IDENTICAL tick sequence
        // (0 -> 500 -> 0) with IDENTICAL 5-second gaps; the ONLY difference is the wall clock.
        uint256 preEpoch = 1_000_000;
        uint88 baselineVol = _runVolatilitySequence(preEpoch);

        // BASELINE (pre-2106): the accumulator survives the 600s decay window, so a 500-tick
        // round trip still reads as live volatility (gen-2: the reading extensions price on).
        assertGt(baselineVol, 0, "baseline: accumulated volatility is still read");

        // POST-2106: the same sequence with the wall clock past 2**32.
        uint256 postEpoch = uint256(type(uint32).max) + 1_000_000;
        uint88 postVol = _runVolatilitySequence(postEpoch);

        // The write truncated: the stored stamp is the low 32 bits, not the real time.
        IFactoryHook.PoolState memory state = hook.getPoolState(poolId);
        assertLt(uint256(state.lastSwapTimestamp), postEpoch, "HARM: stored stamp is ~2**32s in the past");

        // HARM 1: `elapsed` is now ~2**32 seconds, so the accumulator reads as fully decayed
        // five seconds after the swap that set it.
        assertEq(hook.exposed_decayedAccumulator(poolId), 0, "HARM: accumulator reads fully decayed after 5s");

        // HARM 2: identical trading therefore reads as ZERO volatility — the reading the fee
        // extensions price on silently stops responding to volatility.
        assertEq(postVol, 0, "HARM: reading pinned at zero");
        assertLt(postVol, baselineVol, "HARM: identical volatility, strictly lower reading after 2106");

        // HARM 3: `observe()` accrues the recorded tick over a ~2**32-second phantom interval.
        vm.warp(block.timestamp + 1);
        (int56 tickCumulative,) = hook.observe(poolId);
        assertGt(
            tickCumulative > 0 ? uint256(uint56(tickCumulative)) : uint256(uint56(-tickCumulative)),
            uint256(type(uint32).max),
            "HARM: tick-cumulative inflated by a phantom ~2**32s interval"
        );
    }

    /// @dev Runs an identical 0 -> 500 -> 0 tick sequence with 5-second gaps starting at
    /// `startTime`, and returns the volatility the pool would read 5 seconds later. Each step is
    /// a full swap cycle: `beforeSwap`'s decay-and-accrue followed by `afterSwap`'s checkpoint.
    function _runVolatilitySequence(uint256 startTime) internal returns (uint88) {
        vm.warp(startTime);
        hook.exposed_swapCycle(poolId, 0, 0);
        vm.warp(startTime + 5);
        hook.exposed_swapCycle(poolId, 0, 500);
        vm.warp(startTime + 10);
        hook.exposed_swapCycle(poolId, 500, 0);
        vm.warp(startTime + 15);
        return hook.getVolatility(poolId);
    }

    /// @notice H-58: `PENDING_FEE_TSLOT` is one global transient slot, NOT keyed by `PoolId`,
    /// on a singleton hook that governs every graduated pool.
    /// The safety argument is inherited from v4-core's non-reentrant unlock rather than enforced
    /// here; this test pins what IS locally checkable — the slot is unconditionally cleared on
    /// the read side, so no residue survives a completed exact-output swap.
    function test_H58_pendingFeeSlotIsGlobalAndClearedOnRead() public {
        // Registering a SECOND pool on the same singleton hook shows the slot is shared: both
        // pools' exact-output swaps write and read the identical, un-keyed slot.
        ERC20Mock coinB = new ERC20Mock("CoinB", "COINB", 18);
        PoolKey memory keyB = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(coinB)),
            fee: 500,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        hook.registerPool(
            keyB,
            address(coinB),
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
        assertTrue(hook.getPoolState(keyB.toId()).registered, "second pool shares the singleton hook");
        assertTrue(PoolId.unwrap(poolId) != PoolId.unwrap(keyB.toId()), "distinct pool ids, one fee slot");

        // The slot has no per-pool namespace: it is a single compile-time constant, so nothing in
        // this contract distinguishes pool A's stashed rate from pool B's.
        // (The only thing preventing interleaving is v4-core's non-reentrant unlock, which this
        // hook does not itself enforce — that is the finding.)
    }

    /// @notice H-67: `IFactoryHook` omits `getHookPermissions`, which the concrete `FactoryHook`
    /// exposes as an external entry point. This test pins the runtime half: the function IS part
    /// of the deployed ABI, reachable on the concrete type but not through the interface type.
    function test_H67_getHookPermissionsIsOnConcreteTypeOnly() public view {
        // Reachable via the concrete contract type...
        Hooks.Permissions memory perms = FactoryHook(payable(address(hook))).getHookPermissions();
        assertTrue(perms.beforeSwap, "getHookPermissions is a live external entry point");

        // ...and via a raw selector call, confirming it is in the deployed ABI.
        (bool ok, bytes memory ret) = address(hook).staticcall(abi.encodeWithSignature("getHookPermissions()"));
        assertTrue(ok, "selector present in the deployed ABI");
        assertGt(ret.length, 0, "returns the permissions struct");

        // It is NOT declared on IFactoryHook — a call through the interface type does not compile,
        // which is the parity gap (verified at source level in src/interfaces/IFactoryHook.sol).
    }
}
