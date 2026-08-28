// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";

/**
 * @title IFactoryHook
 * @author Frontier
 * @notice Interface for the singleton Uniswap V4 hook that governs all graduated BCToken pools:
 * gates swaps until graduation, runs a tick-displacement volatility accumulator that drives a
 * dynamic swap fee, and distributes that fee between staking vault / protocol treasury / token
 * fee recipient.
 */
interface IFactoryHook {
    /**
     * @notice One observer binding: the target and which notifications it receives.
     * @param observer The observer contract (must implement `IHookObserver`).
     * @param calls Bitmask of notifications: bit 0 = after-swap, bit 1 = fee-change.
     * @param config Registration sub-payload forwarded to the observer's `onRegisterObserver`;
     * not stored by the hook.
     */
    struct ObserverConfig {
        address observer;
        uint8 calls;
        bytes config;
    }

    /**
     * @notice Schema v2 payload body: the creator's fee pipeline and observer set, bound
     * immutably at pool creation.
     * @dev Encoded as `abi.encodePacked(uint8(2), abi.encode(HookConfigV2))`. An empty payload
     * means `DEFAULT_FIXED_FEE` with no extensions. Composition semantics belong to the
     * calculators themselves: the hook seeds the chain with the pool's base fee and threads
     * each stage's output into the next; a failed stage is skipped (its input passes through)
     * and the final value is clamped by the cage.
     * @param fixedFee The pool's base fee in pips — the chain seed, and the whole fee when the
     * chain is empty. Bounded by `MAX_HOOK_FEE`.
     * @param lpShareBps LP share of the total fee, in bps (0..10000). Literal — `0` gives the LPs
     * nothing (the whole fee is the non-LP waterfall); the remainder `10000 - lpShareBps` is the
     * non-LP share. The protocol floor is reserved from within this split at swap time, never
     * added on top. There is no implicit default — the caller states the share explicitly.
     * @param feeCalculators The fee chain, called strictly in order (0..MAX_FEE_CALCULATORS).
     * @param calculatorConfigs Registration sub-payload per calculator (same length).
     * @param sniperWindow Seconds after graduation during which the clamp ceiling rises to
     * `SNIPER_MAX_FEE`. Zero = none; bounded by `MAX_SNIPER_WINDOW`; requires a non-empty
     * calculator chain (the tax itself is a calculator).
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
     * @notice A bound observer as stored by the hook (registration config not retained).
     * @param observer The observer contract.
     * @param calls Bitmask of notifications: bit 0 = after-swap, bit 1 = fee-change.
     */
    struct BoundObserver {
        address observer;
        uint8 calls;
    }

    /**
     * @notice Per-pool state tracked by the hook.
     * @param coin The BCToken paired against native ETH in this pool.
     * @param registered Whether the pool was registered by the liquidity manager.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol fee remainder directed
     * to the staking vault (the rest going to the fee recipient), applied to both legs.
     * @param referenceTick The pool tick observed at the last volatility update.
     * @param lastSwapTimestamp Timestamp of the last volatility/oracle update.
     * @param stakingVault The staking vault receiving coin-side community fees (or address(0)).
     * @param volatilityAccumulator Decayed accumulated tick displacement.
     * @param truncatedTick Manipulation-damped oracle tick (movement capped per observation).
     * @param tickCumulative Cumulative sum of `truncatedTick` over time (V3-style accumulator).
     * @param fixedFee The pool's base fee in pips (chain seed; the whole fee when no chain).
     * @param lastAppliedFee The total fee rate applied by the last swap (fee-change signal).
     * @param lpShareBps LP share of the total fee, in bps (the rest is the non-LP waterfall);
     * literal, `0` = no LP share.
     * @param sniperWindow Seconds after graduation with the raised clamp ceiling (0 = none).
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
        address[] feeCalculators;
        BoundObserver[] observers;
    }

    /**
     * @notice Emitted when a pool is registered with the hook.
     * @param poolId The V4 pool id.
     * @param coin The BCToken paired with native ETH.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol fee remainder directed to staking.
     * @param stakingVault The deployed staking vault, or address(0) when staking is disabled.
     */
    event PoolRegistered(PoolId indexed poolId, address indexed coin, uint8 communityFeeRatio, address stakingVault);

    /**
     * @notice Emitted when the protocol fee ratio is updated.
     * @param oldRatio The previous ratio.
     * @param newRatio The new ratio.
     */
    event ProtocolFeeRatioUpdated(uint8 oldRatio, uint8 newRatio);

    /**
     * @notice Emitted when the staking vault factory is updated.
     * @param oldFactory The previous staking vault factory.
     * @param newFactory The new staking vault factory.
     */
    event StakingVaultFactoryUpdated(address indexed oldFactory, address indexed newFactory);

    /**
     * @notice Emitted when a pool's staking vault is changed.
     * @param poolId The V4 pool id.
     * @param oldVault The previous staking vault, or address(0) when none was set.
     * @param newVault The new staking vault, or address(0) when staking payouts are disabled.
     */
    event StakingVaultUpdated(PoolId indexed poolId, address indexed oldVault, address indexed newVault);

    /**
     * @notice Emitted once, at registration, for a pool whose creator customised the base fee.
     * The base fee is immutable afterwards — like the extension bindings (Q14), the fee
     * pipeline is fixed at creation.
     * @param poolId The V4 pool id.
     * @param fixedFee The base fee in pips.
     */
    event FixedFeeChanged(PoolId indexed poolId, uint24 fixedFee);

    /**
     * @notice Emitted once per fee-calculator binding, at registration, after the calculator's
     * `onRegisterCalculator` succeeded. The hook does not store the sub-payload.
     * @param poolId The V4 pool id.
     * @param calculator The bound fee calculator.
     * @param config The raw `onRegisterCalculator` sub-payload (empty selects the extension's defaults).
     */
    event CalculatorConfigured(PoolId indexed poolId, address indexed calculator, bytes config);

    /**
     * @notice Emitted once per observer binding, at registration, after the observer's
     * `onRegisterObserver` succeeded. The hook does not store the sub-payload.
     * @param poolId The V4 pool id.
     * @param observer The bound observer.
     * @param config The raw `onRegisterObserver` sub-payload.
     */
    event ObserverConfigured(PoolId indexed poolId, address indexed observer, bytes config);

    /**
     * @notice Emitted when a fee-chain stage failed and was skipped — its input passed through
     * to the next stage (S7). Never emitted on the nominal path; a broken or breaker-tripped
     * calculator silently degrading pools must be observable off-chain.
     * @param poolId The V4 pool id.
     * @param calculator The calculator that failed.
     */
    event FeeCalculatorFallback(PoolId indexed poolId, address indexed calculator);

    /**
     * @notice Emitted when a pool's staking vault reverted on `notifyWethReward` during fee
     * distribution: the vault's WETH share was redirected to the fee recipient so the swap could
     * not be bricked by a misbehaving vault.
     * @param coin The pool's coin.
     * @param vault The vault whose notify reverted.
     * @param amount The WETH amount redirected to the fee recipient.
     */
    event VaultNotifyFailed(address indexed coin, address indexed vault, uint256 amount);

    /**
     * @notice Emitted once per fee leg on every swap, breaking down the non-LP fee distribution
     * so off-chain indexers can attribute protocol revenue, staker rewards and fee-recipient
     * income per swap. The LP share is NOT included here — it stays in the pool via the fee
     * override and is carried by Uniswap's own `Swap` event; total fee = LP share + the sum here.
     * @param poolId The pool the fee was charged on.
     * @param currency The currency the fee was taken in (address(0) for native ETH, else the coin).
     * @param protocolAmount The share paid to the protocol treasury (raised to at least the 3-bps floor).
     * @param vaultAmount The share actually paid to the staking vault (0 when no active vault or the notify reverted).
     * @param recipientAmount The share paid to the coin's fee recipient (absorbs the vault share on notify failure).
     * @param protocolRecipient The address that received the protocol share (the treasury, or
     * the fee recipient when the treasury is unset).
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

    /**
     * @notice Caller is not the BC token factory owner.
     */
    error OnlyFactoryOwner();

    /**
     * @notice Caller is not the current liquidity manager.
     */
    error OnlyLiquidityManager();

    /**
     * @notice Pool initialization attempted by an unauthorized sender or for an unregistered pool.
     */
    error UnauthorizedPoolInitialization();

    /**
     * @notice The pool key does not match the expected native-ETH/coin layout for this hook.
     */
    error InvalidPoolKey();

    /**
     * @notice Pool initialization attempted with a static fee; the hook requires a dynamic-fee pool.
     */
    error NotDynamicFee();

    /**
     * @notice The community fee ratio exceeds 100.
     */
    error InvalidCommunityFeeRatio();

    /**
     * @notice The protocol fee ratio exceeds 100.
     */
    error InvalidProtocolFeeRatio();

    /**
     * @notice The staking vault's underlying asset does not match the pool's coin, or the
     * vault is not bound to this hook.
     */
    error InvalidStakingVault();

    /**
     * @notice The staking vault factory's `hook` does not resolve back to this hook.
     */
    error InvalidStakingVaultFactory();

    /**
     * @notice A zero address was supplied where one is not allowed.
     */
    error InvalidZeroAddress();

    /**
     * @notice The pool is already registered with the hook.
     */
    error PoolAlreadyRegistered();

    /**
     * @notice The pool is not registered with the hook.
     */
    error PoolNotRegistered();

    /**
     * @notice The coin has not graduated yet; swaps are blocked.
     */
    error NotLPd();

    /**
     * @notice Native ETH was sent by an address other than the pool manager or WETH.
     */
    error InvalidEthSender();

    /**
     * @notice The hook config payload is structurally invalid: wrong length, non-zero unused
     * fields, or fee values out of order / above `MAX_HOOK_FEE`.
     */
    error InvalidHookConfig();

    /**
     * @notice The hook config payload names a schema version this hook generation does not
     * know.
     * @param version The unsupported version byte.
     */
    error UnsupportedHookConfigVersion(uint8 version);

    /**
     * @notice Registers a pool with the hook prior to initialization.
     * @dev Only callable by the liquidity manager. Must be called immediately before
     * `IPoolManager.initialize` — `beforeInitialize` rejects unregistered pools. The payload is
     * validated here, in the deploy transaction, so an invalid payload reverts the deploy.
     * @param key The V4 pool key (native ETH as currency0, coin as currency1, this hook).
     * @param coin The BCToken paired with native ETH.
     * @param communityFeeRatio Percentage (0-100) of the after-protocol fee remainder directed to staking.
     * @param stakingConfig Staking vault configuration for this pool.
     * @param hookConfig The opaque creator payload threaded from `deploy` — empty for protocol
     * defaults, otherwise schema-versioned (first byte) and interpreted only here.
     */
    function registerPool(
        PoolKey calldata key,
        address coin,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig calldata stakingConfig,
        bytes calldata hookConfig
    ) external;

    /**
     * @notice Sets the percentage of the non-LP fee share taken off the top for the protocol
     * treasury, applied identically to both the ETH and coin legs.
     * @param _protocolFeeRatio The new ratio (0-100).
     */
    function setProtocolFeeRatio(uint8 _protocolFeeRatio) external;

    /**
     * @notice Sets the staking vault factory used for newly registered pools.
     * @dev The new factory's `hook` must resolve back to this hook, otherwise `registerPool`
     * would revert inside `deployVault`'s `onlyHook` guard and block coin deployments.
     * @param _stakingVaultFactory The new staking vault factory address.
     */
    function setStakingVaultFactory(address _stakingVaultFactory) external;

    /**
     * @notice Sets or replaces the staking vault receiving a pool's community fee share.
     * @dev A non-zero vault must have the pool's coin as its ERC4626 underlying asset and must
     * be bound to this hook, so it can never reject this hook's `notifyWethReward` at payout
     * time. Setting address(0) disables the staking split: the full after-protocol remainder of
     * the non-LP fee goes to the token's fee recipient.
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
     * @notice Returns the pool's currently effective fee reference: the rate the last swap
     * actually paid, or the base fee while the pool has not swapped yet.
     * @dev With a fee chain bound, the per-swap rate is context-dependent (volatility, sniper
     * window, caller); this is a display/monitoring value, not a quote.
     * @param poolId The V4 pool id.
     * @return fee The fee in hundredths of a bip.
     */
    function getCurrentFee(PoolId poolId) external view returns (uint24 fee);

    /**
     * @notice Previews the fee a swap would pay at the current pool state, without executing it:
     * runs the fee chain read-only, applies the 3-bps minimum, and splits by `lpShareBps`.
     * @dev The total is charged as an LP-fee override (`lpFee`) plus a non-LP hook delta
     * (`nonLpFee`); an aggregator reading only the pool's LP fee would miss the non-LP portion, so
     * this decomposition (or a full V4Quoter simulation) is the way to preview the true cost.
     * Uses the current volatility/tick, so it matches a swap executed now on the same params.
     * @param poolId The V4 pool id.
     * @param params The prospective swap parameters (direction and specified amount).
     * @return totalFee The total swap fee in pips (>= 3 bps).
     * @return lpFee The LP share of the fee in pips.
     * @return nonLpFee The non-LP (protocol/vault/recipient) share in pips.
     */
    function previewFee(PoolId poolId, SwapParams calldata params)
        external
        view
        returns (uint24 totalFee, uint24 lpFee, uint24 nonLpFee);

    /**
     * @notice Returns the current decayed volatility accumulator for a pool, including the
     * displacement of the current tick against the reference tick.
     * @param poolId The V4 pool id.
     * @return The volatility accumulator in ticks.
     */
    function getVolatility(PoolId poolId) external view returns (uint88);

    /**
     * @notice Returns the truncated tick-cumulative oracle, extrapolated to the current
     * timestamp. Per Uniswap's truncated oracle research, the recorded tick may move at most
     * a bounded amount per observation, damping single-block price manipulation.
     * @dev Consumers snapshot `(tickCumulative, timestamp)` at two moments and derive the
     * time-weighted average tick as `(cum2 - cum1) / (t2 - t1)` (V2-accumulator style).
     * @dev The recorded tick follows each swap's RESULTING price, so an idle interval is
     * extrapolated at the tick the pool actually sits at rather than at a pre-swap tick it has
     * already left.
     * @param poolId The V4 pool id.
     * @return tickCumulative The cumulative truncated tick as of `block.timestamp`.
     * @return truncatedTick The current truncated oracle tick.
     */
    function observe(PoolId poolId) external view returns (int56 tickCumulative, int24 truncatedTick);

    /**
     * @notice Returns the BC token factory owner, treated as the protocol admin.
     * @return The factory owner address.
     */
    function factoryOwner() external view returns (address);

    /**
     * @notice Returns the BC token factory's protocol treasury, the recipient of the swap-fee
     * protocol share.
     * @return The protocol treasury address.
     */
    function factoryTreasury() external view returns (address);

    /**
     * @notice Returns the percentage (0-100) of the non-LP fee share taken off the top for the
     * protocol treasury on both legs.
     * @return The protocol fee ratio.
     */
    function protocolFeeRatio() external view returns (uint8);

    /**
     * @notice Returns the staking vault factory used for newly registered pools.
     * @return The staking vault factory address.
     */
    function stakingVaultFactory() external view returns (address);

    /**
     * @notice Returns the BC token factory whose owner is the protocol admin.
     * @return The BC token factory address.
     */
    function BC_TOKEN_FACTORY() external view returns (address);

    /**
     * @notice Returns the canonical WETH used for ETH-side fee payouts.
     * @return The WETH address.
     */
    function WETH() external view returns (address);
}
