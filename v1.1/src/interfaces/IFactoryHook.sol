// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IExtensionHost} from "src/interfaces/extensions/IExtensionHost.sol";

/**
 * @title IFactoryHook
 * @author Frontier
 * @notice Singleton Uniswap V4 hook over every graduated BCToken pool: gates swaps until graduation, derives a
 * dynamic fee from a tick-displacement volatility accumulator and splits it between staking vault, protocol
 * treasury and the token's fee recipient.
 */
interface IFactoryHook is IExtensionHost {
    /**
     * @notice One observer binding. `calls` is a bitmask (bit 0 = after-swap, bit 1 = fee-change); `config` is
     * forwarded to the observer's `onRegisterObserver` and not stored by the hook.
     * @param observer The observer contract (must implement `IHookObserver`).
     * @param calls Bitmask of notifications: bit 0 = after-swap, bit 1 = fee-change.
     * @param config Registration sub-payload forwarded to the observer's `onRegisterObserver`; not stored by the hook.
     */
    struct ObserverConfig {
        address observer;
        uint8 calls;
        bytes config;
    }

    /**
     * @notice Schema v2 payload body: the creator's fee pipeline and observer set, fixed at pool creation.
     * Encoded as `abi.encodePacked(uint8(2), abi.encode(HookConfigV2))`; an empty payload means
     * `DEFAULT_FIXED_FEE` with no extensions.
     *
     * `fixedFee` is in pips and seeds the calculator chain (at most `MAX_HOOK_FEE`); `lpShareBps` is the literal
     * LP share in bps (0..10000, 0 = none), the protocol floor being reserved from within the rest; `sniperWindow`
     * is seconds after graduation with the raised clamp ceiling (0 = none, at most `MAX_SNIPER_WINDOW`, needs a
     * non-empty chain).
     * @dev The hook seeds the chain with `fixedFee`, threads each stage's output into the next, skips a failed stage
     * and clamps the result.
     * @param fixedFee The pool's base fee in pips — the chain seed, and the whole fee when the chain is empty. Bounded
     * by `MAX_HOOK_FEE`.
     * @param lpShareBps LP share of the total fee, in bps (0..10000). Literal — `0` gives the LPs nothing (the whole
     * fee
     * is the non-LP waterfall); the remainder `10000 - lpShareBps` is the non-LP share. The protocol floor is reserved
     * from within this split at swap time, never added on top. There is no implicit default — the caller states the
     * share explicitly.
     * @param feeCalculators The fee chain, called strictly in order (0..MAX_FEE_CALCULATORS).
     * @param calculatorConfigs Registration sub-payload per calculator (same length).
     * @param sniperWindow Seconds after graduation during which the clamp ceiling rises to `SNIPER_MAX_FEE`. Zero =
     * none; bounded by `MAX_SNIPER_WINDOW`; requires a non-empty calculator chain (the tax itself is a calculator).
     * @param observers Observer bindings (0..MAX_OBSERVERS), sharing `OBSERVER_GAS_BUDGET`.
     */
    struct HookConfigV2 {
        uint24 fixedFee;
        uint16 lpShareBps;
        address[] feeCalculators;
        bytes[] calculatorConfigs;
        uint32 sniperWindow;
        ObserverConfig[] observers;
    }

    /**
     * @notice A bound observer as stored by the hook; `calls` is the same bitmask as `ObserverConfig.calls`.
     * @param observer The observer contract.
     * @param calls Bitmask of notifications: bit 0 = after-swap, bit 1 = fee-change.
     */
    struct BoundObserver {
        address observer;
        uint8 calls;
    }

    /**
     * @notice Per-pool state. `communityFeeRatio` is the percentage (0-100) of the after-protocol remainder paid
     * to the staking vault; `fixedFee` and `lastAppliedFee` are in pips, `lpShareBps` in bps (literal, 0 = none),
     * `sniperWindow` in seconds.
     *
     * `anchorTick` is the oracle tick the current block opened at; every checkpoint in the block clamps against it.
     * @dev FROZEN PREFIX: `coin` through `stakingVault` are decoded by `PolDistributor` on every hook generation.
     * Never reorder, resize or remove them; new members go after `stakingVault`.
     * @param coin The BCToken paired against native ETH in this pool.
     * @param registered Whether the pool was registered by the liquidity manager.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol fee remainder directed to the staking vault
     * (the
     * rest going to the fee recipient), applied to both legs.
     * @param referenceTick The pool tick observed at the last volatility update.
     * @param lastSwapTimestamp Timestamp of the last volatility/oracle update.
     * @param stakingVault The staking vault receiving coin-side community fees (or address(0)).
     * @param volatilityAccumulator Decayed accumulated tick displacement.
     * @param truncatedTick Manipulation-damped oracle tick (movement capped per block).
     * @param tickCumulative Cumulative sum of `truncatedTick` over time (V3-style accumulator).
     * @param fixedFee The pool's base fee in pips (chain seed; the whole fee when no chain).
     * @param lastAppliedFee The total fee rate applied by the last swap (fee-change signal).
     * @param lpShareBps LP share of the total fee, in bps (the rest is the non-LP waterfall); literal, `0` = no LP
     * share.
     * @param sniperWindow Seconds after graduation with the raised clamp ceiling (0 = none).
     * @param anchorTick The oracle tick the current block opened at: the `truncatedTick` left by the last block that
     * swapped. Every checkpoint in the block clamps against it, so the recorded tick moves at most `MAX_ABS_TICK_MOVE`
     * per block however many swaps land in it.
     * @param anchorTimestamp Timestamp of the block `anchorTick` was taken in.
     * @param feeCalculators The pool's fee chain, in call order.
     * @param observers The pool's bound observers.
     */
    struct PoolState {
        address coin;
        bool registered;
        uint8 communityFeeRatio;
        int24 referenceTick;
        uint32 lastSwapTimestamp;
        address stakingVault;
        uint88 volatilityAccumulator;
        int24 truncatedTick;
        int56 tickCumulative;
        uint24 fixedFee;
        uint24 lastAppliedFee;
        uint16 lpShareBps;
        uint32 sniperWindow;
        int24 anchorTick;
        uint32 anchorTimestamp;
        address[] feeCalculators;
        BoundObserver[] observers;
    }

    /**
     * @notice A pool was registered; `communityFeeRatio` is the percentage (0-100) of the after-protocol remainder
     * paid to `stakingVault` (address(0) when staking is disabled).
     * @param poolId The V4 pool id.
     * @param coin The BCToken paired with native ETH.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol fee remainder directed to staking.
     * @param stakingVault The deployed staking vault, or address(0) when staking is disabled.
     */
    event PoolRegistered(PoolId indexed poolId, address indexed coin, uint8 communityFeeRatio, address stakingVault);

    /**
     * @notice The protocol fee ratio (0-100) changed.
     * @param oldRatio The previous ratio.
     * @param newRatio The new ratio.
     */
    event ProtocolFeeRatioUpdated(uint8 oldRatio, uint8 newRatio);

    /**
     * @notice The staking vault factory changed.
     * @param oldFactory The previous staking vault factory.
     * @param newFactory The new staking vault factory.
     */
    event StakingVaultFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    /**
     * @notice A pool's staking vault changed; address(0) means staking payouts are disabled.
     * @param poolId The V4 pool id.
     * @param oldVault The previous staking vault, or address(0) when none was set.
     * @param newVault The new staking vault, or address(0) when staking payouts are disabled.
     */
    event StakingVaultUpdated(PoolId indexed poolId, address indexed oldVault, address indexed newVault);

    /**
     * @notice Emitted once, at registration, when the creator customised the base fee; `fixedFee` is in pips and
     * immutable afterwards.
     * @param poolId The V4 pool id.
     * @param fixedFee The base fee in pips.
     */
    event FixedFeeChanged(PoolId indexed poolId, uint24 fixedFee);

    /**
     * @notice Emitted once per fee-calculator binding at registration, after `onRegisterCalculator` succeeded;
     * `config` is the raw sub-payload (empty selects the extension's defaults), not stored by the hook.
     * @param poolId The V4 pool id.
     * @param calculator The bound fee calculator.
     * @param config The raw `onRegisterCalculator` sub-payload (empty selects the extension's defaults).
     */
    event CalculatorConfigured(PoolId indexed poolId, address indexed calculator, bytes config);

    /**
     * @notice Emitted once per observer binding at registration, after `onRegisterObserver` succeeded; `config` is
     * the raw sub-payload, not stored by the hook.
     * @param poolId The V4 pool id.
     * @param observer The bound observer.
     * @param config The raw `onRegisterObserver` sub-payload.
     */
    event ObserverConfigured(PoolId indexed poolId, address indexed observer, bytes config);

    /**
     * @notice A fee-chain stage failed and was skipped, its input passing through to the next stage (S7). Never
     * emitted on the nominal path.
     * @param poolId The V4 pool id.
     * @param calculator The calculator that failed.
     */
    event FeeCalculatorFallback(PoolId indexed poolId, address indexed calculator);

    /**
     * @notice A pool's staking vault reverted on `notifyWethReward`; its WETH share (`amount`) was redirected to
     * the fee recipient so the swap could not be bricked.
     * @param coin The pool's coin.
     * @param vault The vault whose notify reverted.
     * @param amount The WETH amount redirected to the fee recipient.
     */
    event VaultNotifyFailed(address indexed coin, address indexed vault, uint256 amount);

    /**
     * @notice Emitted once per fee leg on every swap with the non-LP fee breakdown. The LP share is not included:
     * it stays in the pool and is carried by Uniswap's own `Swap` event; total fee = LP share + the sum here.
     * @param poolId The pool the fee was charged on.
     * @param currency address(0) for native ETH, else the coin.
     * @param protocolAmount The protocol treasury share, raised to at least the 3-bps floor.
     * @param vaultAmount The share actually paid to the vault (0 when no active vault or the notify reverted).
     * @param recipientAmount The fee recipient's share; absorbs the vault share on notify failure.
     * @param protocolRecipient The treasury, or the fee recipient when the treasury is unset.
     * @param vault The pool's configured staking vault (address(0) when none).
     * @param feeRecipient The coin's fee recipient that received the recipient share.
     */
    event SwapFeeDistributed(
        PoolId indexed poolId,
        address currency,
        uint256 protocolAmount,
        uint256 vaultAmount,
        uint256 recipientAmount,
        address protocolRecipient,
        address vault,
        address feeRecipient
    );

    /// @notice Caller is not the BC token factory owner.
    error OnlyFactoryOwner();

    /// @notice Caller is not the current liquidity manager.
    error OnlyLiquidityManager();

    /// @notice Pool initialization by an unauthorized sender or for an unregistered pool.
    error UnauthorizedPoolInitialization();

    /// @notice The pool key does not match the native-ETH/coin layout this hook expects.
    error InvalidPoolKey();

    /// @notice The pool was initialized with a static fee; the hook requires a dynamic-fee pool.
    error NotDynamicFee();

    /// @notice The community fee ratio exceeds 100.
    error InvalidCommunityFeeRatio();

    /// @notice The protocol fee ratio exceeds 100.
    error InvalidProtocolFeeRatio();

    /// @notice The staking vault's underlying asset is not the pool's coin, or the vault is not bound to this hook.
    error InvalidStakingVault();

    /// @notice The staking vault factory's `hook` does not resolve back to this hook.
    error InvalidStakingVaultFactory();

    /// @notice A zero address was supplied where one is not allowed.
    error InvalidZeroAddress();

    /// @notice The pool is already registered with the hook.
    error PoolAlreadyRegistered();

    /// @notice The pool is not registered with the hook.
    error PoolNotRegistered();

    /// @notice The coin has not graduated yet; swaps are blocked.
    error NotLPd();

    /// @notice Native ETH was sent by an address other than the pool manager or WETH.
    error InvalidEthSender();

    /**
     * @notice The hook config payload is structurally invalid: wrong length, non-zero unused fields, or fee values
     * out of order or above `MAX_HOOK_FEE`.
     */
    error InvalidHookConfig();

    /**
     * @notice The hook config payload names a schema version this hook generation does not know.
     * @param version The unsupported version byte.
     */
    error UnsupportedHookConfigVersion(uint8 version);

    /**
     * @notice Registers a pool with the hook; liquidity manager only, called immediately before
     * `IPoolManager.initialize` since `beforeInitialize` rejects unregistered pools. The payload is validated
     * here, in the deploy transaction, so an invalid payload reverts the deploy.
     * @param key Native ETH as currency0, the coin as currency1, this hook.
     * @param coin The BCToken paired with native ETH.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol remainder paid to staking.
     * @param stakingConfig Staking vault configuration for this pool.
     * @param hookConfig Creator payload: empty for protocol defaults, else its first byte is the schema version.
     */
    function registerPool(
        PoolKey calldata key,
        address coin,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig calldata stakingConfig,
        bytes calldata hookConfig
    ) external;

    /**
     * @notice Sets the percentage of the non-LP fee share taken off the top for the protocol treasury, applied
     * identically to both the ETH and coin legs.
     * @param _protocolFeeRatio The new ratio (0-100).
     */
    function setProtocolFeeRatio(uint8 _protocolFeeRatio) external;

    /**
     * @notice Sets the staking vault factory used for newly registered pools.
     * @dev The factory's `hook` must resolve back to this hook, otherwise `registerPool` reverts inside
     * `deployVault`'s `onlyHook` guard and blocks coin deployments.
     * @param _stakingVaultFactory The new staking vault factory address.
     */
    function setStakingVaultFactory(address _stakingVaultFactory) external;

    /**
     * @notice Sets or replaces the staking vault receiving a pool's community fee share; address(0) disables the
     * split and the full after-protocol remainder of the non-LP fee goes to the token's fee recipient.
     * @dev A non-zero vault must have the pool's coin as its ERC4626 asset and be bound to this hook, so it can
     * never reject `notifyWethReward` at payout time.
     * @param poolId The V4 pool id.
     * @param stakingVault The new staking vault, or address(0) to disable staking payouts.
     */
    function setStakingVault(PoolId poolId, address stakingVault) external;

    /**
     * @notice Returns the full per-pool state.
     * @param poolId The V4 pool id.
     * @return The pool state struct.
     */
    function getPoolState(PoolId poolId) external view returns (PoolState memory);

    /**
     * @notice The rate the last swap actually paid, or the base fee while the pool has not swapped yet; a display
     * value, not a quote, since a bound fee chain makes the per-swap rate context-dependent.
     * @param poolId The V4 pool id.
     * @return fee In pips (hundredths of a bip).
     */
    function getCurrentFee(PoolId poolId) external view returns (uint24 fee);

    /**
     * @notice Previews the fee a swap would pay at the current pool state without executing it: runs the chain
     * read-only, applies the 3-bps minimum and splits by `lpShareBps`.
     * @dev The total is charged as an LP-fee override plus a non-LP hook delta, so reading only the pool's LP fee
     * misses `nonLpFee`; use this decomposition or a full V4Quoter simulation to preview the true cost.
     * @param poolId The V4 pool id.
     * @param params The prospective swap (direction and specified amount).
     * @return totalFee In pips, at least 3 bps.
     * @return lpFee The LP share, in pips.
     * @return nonLpFee The protocol/vault/recipient share, in pips.
     */
    function previewFee(PoolId poolId, SwapParams calldata params)
        external
        view
        returns (uint24 totalFee, uint24 lpFee, uint24 nonLpFee);

    /**
     * @notice The decayed volatility accumulator in ticks, including the current tick's displacement from the
     * reference tick.
     * @param poolId The V4 pool id.
     * @return The volatility accumulator in ticks.
     */
    function getVolatility(PoolId poolId) external view returns (uint88);

    /**
     * @notice Returns the truncated tick-cumulative oracle extrapolated to `block.timestamp`. The recorded tick
     * moves at most `MAX_ABS_TICK_MOVE` per block, measured against the tick the block opened at, so splitting a
     * trade into many swaps buys no extra movement and an intra-block round trip leaves no trace.
     * @dev Snapshot `(tickCumulative, timestamp)` twice and derive the time-weighted average tick as
     * `(cum2 - cum1) / (t2 - t1)`. The tick follows each swap's resulting price, so an idle interval extrapolates
     * at the tick the pool actually sits at.
     * @param poolId The V4 pool id.
     * @return tickCumulative The cumulative truncated tick as of `block.timestamp`.
     * @return truncatedTick The current truncated oracle tick.
     */
    function observe(PoolId poolId) external view returns (int56 tickCumulative, int24 truncatedTick);

    /**
     * @notice The BC token factory owner, treated as the protocol admin.
     * @return The factory owner address.
     */
    function factoryOwner() external view returns (address);

    /**
     * @notice The BC token factory's protocol treasury, recipient of the swap-fee protocol share.
     * @return The protocol treasury address.
     */
    function factoryTreasury() external view returns (address);

    /**
     * @notice Percentage (0-100) of the non-LP fee share taken off the top for the protocol treasury on both legs.
     * @return The protocol fee ratio.
     */
    function protocolFeeRatio() external view returns (uint8);

    /**
     * @notice The staking vault factory used for newly registered pools.
     * @return The staking vault factory address.
     */
    function stakingVaultFactory() external view returns (address);

    /**
     * @notice The BC token factory whose owner is the protocol admin.
     * @return The BC token factory address.
     */
    function BC_TOKEN_FACTORY() external view returns (address);

    /**
     * @notice The canonical WETH used for ETH-side fee payouts.
     * @return The WETH address.
     */
    function WETH() external view returns (address);
}
