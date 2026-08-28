// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCToken} from "src/interfaces/IBCToken.sol";
import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";
import {IStakingVaultFactory} from "src/interfaces/IStakingVaultFactory.sol";
import {IWETH} from "src/interfaces/IWETH.sol";
import {IFeeCalculator} from "src/interfaces/extensions/IFeeCalculator.sol";
import {IHookObserver} from "src/interfaces/extensions/IHookObserver.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/**
 * @title FactoryHook
 * @author Frontier
 * @notice Singleton Uniswap V4 hook governing every graduated BCToken pool: blocks swaps until
 * the coin graduates (`isLPd`), tracks realized volatility as time-decayed tick displacement,
 * and charges a three-step volatility fee split between LP positions and the protocol. The LP
 * share is delivered as V4's native dynamic fee (a per-swap `beforeSwap` LP-fee override); the
 * remaining non-LP share is captured as a hook delta and distributed — protocol treasury off
 * the top, then the after-protocol remainder to the staking vault and fee recipient (coin-side
 * directly, ETH-side wrapped to WETH so hostile recipients cannot block swaps).
 * @dev The pool is a dynamic-fee pool (`PoolKey.fee == DYNAMIC_FEE_FLAG`). Only the non-LP
 * share is taken with hook swap deltas; the LP share rides V4's native LP fee, grossed up so
 * the beforeSwap delta shrinking the input does not distort the LP/non-LP split. Liquidity
 * hook flags are deliberately OFF: third-party LPs are allowed and position mint/collect never
 * enters the hook. Volatility carries over between swaps: `beforeSwap` decays the stored
 * accumulator over the idle interval and adds the previous swap's tick displacement, itself
 * decayed over the same interval. A swap's price impact therefore raises the fee charged to
 * subsequent swaps, and decays away over `decayWindow` if none arrive. The truncated oracle is
 * checkpointed in `afterSwap` so idle intervals accrue at the tick the last swap left behind.
 */
contract FactoryHook is BaseHook, IFactoryHook {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    /// @notice Fee denominator: fees are expressed in hundredths of a bip (1e-6).
    uint256 private constant FEE_DENOMINATOR = 1e6;

    /// @notice Basis-point denominator for the LP / non-LP fee split.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Hard ceiling for any configured hook fee (10%, operator decision at step 2 —
    /// supersedes the step-1 5% posture; the sniper-window exception raises it further,
    /// bounded and declared per pool).
    uint24 public constant MAX_HOOK_FEE = 100_000;

    /// @notice The absolute protocol floor (Q18): whatever the creator configured, every swap
    /// pays the protocol at least this share of the swap amount (3 bps), clamped both when the
    /// non-LP rate is charged and when the waterfall splits it — independent of
    /// `protocolFeeRatio` and `lpShareBps`, so it survives every later ratio change.
    uint24 public constant PROTOCOL_FLOOR_PIPS = 300;

    /// @notice The hook config schema version this hook generation interprets. One generation
    /// = one schema; the byte exists for clean rejection of stale encodings at a generation
    /// switch and to keep historical payloads self-describing.
    uint8 public constant HOOK_CONFIG_VERSION = 2;

    /// @notice The protocol-wide flat fee (0.30%): the base of every pool whose creator does
    /// not customise, and the seed of every fee chain.
    uint24 public constant DEFAULT_FIXED_FEE = 3000;

    /// @notice LP share (bps) applied to a pool registered with an EMPTY payload — the protocol
    /// default (70%), mirroring `DEFAULT_FIXED_FEE`. A custom payload states `lpShareBps`
    /// literally (0 = no LP share); there is no `0 -> default` fallback in the custom path.
    uint16 public constant DEFAULT_LP_SHARE_BPS = 7000;

    /// @notice Clamp ceiling during a pool's declared sniper window (50%).
    uint24 public constant SNIPER_MAX_FEE = 500_000;

    /// @notice Longest declarable sniper window, in seconds after graduation (~1 hour).
    uint32 public constant MAX_SNIPER_WINDOW = 3600;

    /// @notice Maximum fee-chain length. Each stage costs its stipend on every swap.
    uint256 public constant MAX_FEE_CALCULATORS = 4;

    /// @notice Maximum bound observers (structural bound; gas is bounded by the shared budget).
    uint256 public constant MAX_OBSERVERS = 8;

    /// @notice Fixed gas stipend per fee-chain stage. Per-stage (not shared) so a failing
    /// stage is skipped deterministically without starving the stages after it.
    uint256 public constant CALC_GAS_STIPEND = 50_000;

    /// @notice Shared gas budget for ALL of a pool's observer notifications on one swap: the
    /// swap's worst-case observer overhead is this constant, whatever the observer count. A
    /// greedy observer starves the ones after it — the creator ordered the list and owns that
    /// trade-off.
    uint256 public constant OBSERVER_GAS_BUDGET = 600_000;

    /// @notice Longest `hookData` forwarded to observers; anything larger is treated as absent.
    uint256 public constant MAX_HOOKDATA_BYTES = 256;

    /// @notice Volatility decay window (seconds); hook-level — a volatility parameter, not a
    /// curve parameter (the curve lives in fee-calculator extensions).
    uint32 public constant DECAY_WINDOW = 600;

    /// @notice Volatility accumulator cap (ticks); decoupled from the retired curve's `t2`.
    uint88 public constant ACCUMULATOR_CAP = 900;

    /// @notice Observer call-mask bit: notify after each settled swap.
    uint8 public constant CALL_AFTER_SWAP = 1 << 0;

    /// @notice Observer call-mask bit: notify when the applied fee changes.
    uint8 public constant CALL_FEE_CHANGE = 1 << 1;

    /// @notice Maximum tick movement recorded per oracle observation, per Uniswap's truncated
    /// oracle research — damps single-block price manipulation of the TWAP accumulator.
    int24 public constant MAX_ABS_TICK_MOVE = 9116;

    /// @dev Transient storage slot holding the protocol (non-LP) pip rate between `beforeSwap`
    /// and `afterSwap` for exact-output swaps. Safe as a single slot: the two callbacks of one
    /// swap are adjacent within the PoolManager's non-reentrant unlock.
    bytes32 private constant PENDING_FEE_TSLOT = keccak256("FactoryHook.pendingFee");

    /// @dev Transient slot carrying the applied total fee rate from `beforeSwap` to
    /// `afterSwap`, where observers are notified and `lastAppliedFee` is checkpointed.
    bytes32 private constant APPLIED_FEE_TSLOT = keccak256("FactoryHook.appliedFee");

    /// @dev Transient reentrancy guard on `registerPool` (S2): extension registration calls arbitrary
    /// third-party code and there is no on-chain extension gating, so this lock is
    /// load-bearing, not defence in depth.
    bytes32 private constant REGISTER_LOCK_TSLOT = keccak256("FactoryHook.registerLock");

    /// @notice BCTokenFactory address.
    address public immutable BC_TOKEN_FACTORY;

    /// @notice Canonical WETH used for ETH-side fee payouts.
    address public immutable WETH;

    /// @notice StakingVaultFactoryAddress.
    address public stakingVaultFactory;

    /// @notice Percentage (0-100) of the non-LP fee share taken off the top for the protocol treasury on
    /// both legs.
    uint8 public protocolFeeRatio;

    /// @dev Per-pool hook state. Internal (not private) so test harnesses can reach it.
    mapping(PoolId => PoolState) internal _poolState;

    /**
     * @notice Restricts access to the BC token factory owner.
     */
    modifier onlyFactoryOwner() {
        if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).owner()) revert OnlyFactoryOwner();
        _;
    }

    /**
     * @notice Restricts access to the current liquidity manager.
     */
    modifier onlyLiquidityManager() {
        if (msg.sender != IBCTokenFactory(BC_TOKEN_FACTORY).liquidityManager()) revert OnlyLiquidityManager();
        _;
    }

    /**
     * @notice Restricts access to registered pools.
     * @param poolId The V4 pool id.
     */
    modifier onlyRegisteredPool(PoolId poolId) {
        if (!_poolState[poolId].registered) revert PoolNotRegistered();
        _;
    }

    /**
     * @notice Initialises the hook with references to external infrastructure.
     * @param _poolManager The Uniswap V4 pool manager.
     * @param _tokenFactory The BCToken factory whose owner serves as protocol admin.
     * @param _weth The canonical WETH used for ETH-side fee payouts.
     * @param _stakingVaultFactory The factory used to deploy staking vaults.
     */
    constructor(IPoolManager _poolManager, address _tokenFactory, address _weth, address _stakingVaultFactory)
        BaseHook(_poolManager)
    {
        BC_TOKEN_FACTORY = _tokenFactory;
        WETH = _weth;
        stakingVaultFactory = _stakingVaultFactory;
    }

    /**
     * @notice Accepts native ETH from the pool manager (fee `take`) and WETH (unwrap) only.
     */
    receive() external payable {
        if (msg.sender != address(poolManager) && msg.sender != WETH) revert InvalidEthSender();
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function registerPool(
        PoolKey calldata key,
        address coin,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig calldata stakingConfig,
        bytes calldata hookConfig
    ) external onlyLiquidityManager {
        if (
            address(key.hooks) != address(this) || !key.currency0.isAddressZero()
                || Currency.unwrap(key.currency1) != coin
        ) revert InvalidPoolKey();
        if (communityFeeRatio > 100) revert InvalidCommunityFeeRatio();

        PoolId poolId = key.toId();
        PoolState storage state = _poolState[poolId];
        if (state.registered) revert PoolAlreadyRegistered();

        // S2 reentrancy guard: extension registration below calls arbitrary third-party code, and there
        // is no on-chain extension gating — this lock is load-bearing.
        bytes32 lockSlot = REGISTER_LOCK_TSLOT;
        assembly ("memory-safe") {
            if tload(lockSlot) { revert(0, 0) }
            tstore(lockSlot, 1)
        }

        state.registered = true;
        state.coin = coin;
        state.communityFeeRatio = communityFeeRatio;
        state.fixedFee = DEFAULT_FIXED_FEE;
        state.lastAppliedFee = DEFAULT_FIXED_FEE;
        state.lpShareBps = DEFAULT_LP_SHARE_BPS;

        // The payload is interpreted only here, in the deploy transaction: an invalid payload
        // reverts the deploy. Empty payload = DEFAULT_FIXED_FEE, no extensions.
        bool custom = hookConfig.length != 0;
        HookConfigV2 memory config;
        if (custom) {
            config = _decodeAndValidateConfig(hookConfig);
            state.fixedFee = config.fixedFee;
            state.lastAppliedFee = config.fixedFee;
            state.lpShareBps = config.lpShareBps; // literal: 0 means no LP share
            state.sniperWindow = config.sniperWindow;
            for (uint256 i; i < config.feeCalculators.length; ++i) {
                state.feeCalculators.push(config.feeCalculators[i]);
            }
            for (uint256 i; i < config.observers.length; ++i) {
                state.observers
                    .push(BoundObserver({observer: config.observers[i].observer, calls: config.observers[i].calls}));
            }
        }

        // Deploys the pool's initial staking vault; the factory owner can replace or clear it
        // later via `setStakingVault`. When absent, coin-side fees fall back to the protocol
        // owner / fee recipient split.
        if (stakingConfig.deployStaking) {
            state.stakingVault = IStakingVaultFactory(stakingVaultFactory).deployVault(IERC20(coin));
        }

        emit PoolRegistered(poolId, coin, communityFeeRatio, state.stakingVault);
        if (custom) {
            emit FixedFeeChanged(poolId, state.fixedFee);

            // Extension registration runs LAST, after every hook state write (S2). The only
            // moment an extension may write state or revert — a revert fails the deploy.
            // The registration selector is role-specific (onRegisterCalculator vs
            // onRegisterObserver): a contract bound in a role it does not implement reverts the
            // deploy. Extensions MUST gate registration on msg.sender == hook (S1): pool ids
            // are predictable pre-deploy, so an open registration can be poisoned ahead of this
            // call.
            for (uint256 i; i < config.feeCalculators.length; ++i) {
                IFeeCalculator(config.feeCalculators[i]).onRegisterCalculator(poolId, config.calculatorConfigs[i]);
                emit CalculatorConfigured(poolId, config.feeCalculators[i], config.calculatorConfigs[i]);
            }
            for (uint256 i; i < config.observers.length; ++i) {
                IHookObserver(config.observers[i].observer).onRegisterObserver(poolId, config.observers[i].config);
                emit ObserverConfigured(poolId, config.observers[i].observer, config.observers[i].config);
            }
        }

        assembly ("memory-safe") {
            tstore(lockSlot, 0)
        }
    }

    /**
     * @notice Decodes and structurally validates a schema-v2 creator payload.
     * @dev First byte is the schema tag (must equal `HOOK_CONFIG_VERSION`), the rest one
     * abi-encoded `HookConfigV2`. Strict validation keeps the fuzz surface minimal: base fee
     * capped, chain and observer counts bounded, no zero addresses, matching config arity,
     * known observer call bits only, and the sniper window — which raises the clamp ceiling to
     * `SNIPER_MAX_FEE` — bounded and only declarable with a calculator chain (the tax itself
     * is a calculator). S6's combined worst case — `SNIPER_MAX_FEE` with the per-pool LP share at
     * its `lpShareBps = 10000` maximum — stays under V4's limits: the grossed-up LP override peaks
     * at ~50% << `MAX_LP_FEE` (even at 100% LP share the protocol keeps its reserved floor, so the
     * LP rate never reaches the full fee), and the gross-up denominator `1e6 − protocolRate` never
     * approaches degeneracy since `protocolRate ≤ SNIPER_MAX_FEE`.
     * @param hookConfig The non-empty payload.
     * @return config The validated configuration.
     */
    function _decodeAndValidateConfig(bytes calldata hookConfig) internal pure returns (HookConfigV2 memory config) {
        uint8 version = uint8(hookConfig[0]);
        if (version != HOOK_CONFIG_VERSION) revert UnsupportedHookConfigVersion(version);

        config = abi.decode(hookConfig[1:], (HookConfigV2));
        // Canonicality: the body must be exactly the canonical encoding of what it decodes to.
        // abi.decode tolerates trailing garbage and non-canonical layouts; re-encoding and
        // comparing closes that malleability in one check (one-time, deploy-transaction cost).
        if (keccak256(abi.encode(config)) != keccak256(hookConfig[1:])) revert InvalidHookConfig();

        if (config.fixedFee > MAX_HOOK_FEE) revert InvalidHookConfig();
        if (config.lpShareBps > BPS_DENOMINATOR) revert InvalidHookConfig();
        if (config.feeCalculators.length > MAX_FEE_CALCULATORS) revert InvalidHookConfig();
        if (config.calculatorConfigs.length != config.feeCalculators.length) revert InvalidHookConfig();
        if (config.observers.length > MAX_OBSERVERS) revert InvalidHookConfig();
        if (config.sniperWindow != 0 && (config.sniperWindow > MAX_SNIPER_WINDOW || config.feeCalculators.length == 0))
        {
            revert InvalidHookConfig();
        }

        for (uint256 i; i < config.feeCalculators.length; ++i) {
            if (config.feeCalculators[i] == address(0)) revert InvalidHookConfig();
        }
        for (uint256 i; i < config.observers.length; ++i) {
            ObserverConfig memory o = config.observers[i];
            if (o.observer == address(0)) revert InvalidHookConfig();
            if (o.calls == 0 || o.calls & ~(CALL_AFTER_SWAP | CALL_FEE_CHANGE) != 0) revert InvalidHookConfig();
        }
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function setProtocolFeeRatio(uint8 _protocolFeeRatio) external onlyFactoryOwner {
        if (_protocolFeeRatio > 100) revert InvalidProtocolFeeRatio();
        uint8 previous = protocolFeeRatio;
        protocolFeeRatio = _protocolFeeRatio;
        emit ProtocolFeeRatioUpdated(previous, _protocolFeeRatio);
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function setStakingVaultFactory(address _stakingVaultFactory) external onlyFactoryOwner {
        if (_stakingVaultFactory == address(0)) revert InvalidZeroAddress();
        if (IStakingVaultFactory(_stakingVaultFactory).hook() != address(this)) {
            revert InvalidStakingVaultFactory();
        }
        address previous = stakingVaultFactory;
        stakingVaultFactory = _stakingVaultFactory;
        emit StakingVaultFactoryUpdated(previous, _stakingVaultFactory);
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function setStakingVault(PoolId poolId, address stakingVault) external onlyFactoryOwner onlyRegisteredPool(poolId) {
        PoolState storage state = _poolState[poolId];
        if (
            stakingVault != address(0)
                && (IStakingVault(stakingVault).asset() != state.coin
                    || IStakingVault(stakingVault).hook() != address(this))
        ) {
            revert InvalidStakingVault();
        }
        address previous = state.stakingVault;
        state.stakingVault = stakingVault;
        emit StakingVaultUpdated(poolId, previous, stakingVault);
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function getPoolState(PoolId poolId) external view returns (PoolState memory) {
        return _poolState[poolId];
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function getCurrentFee(PoolId poolId) external view returns (uint24 fee) {
        return _poolState[poolId].lastAppliedFee;
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function previewFee(PoolId poolId, SwapParams calldata params)
        external
        view
        returns (uint24 totalFee, uint24 lpFee, uint24 nonLpFee)
    {
        PoolState storage state = _poolState[poolId];
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 stepFee = _quoteFeeChainView(state, poolId, _currentVolatility(state, poolId), tick, params);

        // Floor at 3 bps and split by lpShareBps (protocol floor reserved from within) — mirrors
        // the swap path exactly; a parity test guards against drift.
        uint256 total = stepFee < PROTOCOL_FLOOR_PIPS ? PROTOCOL_FLOOR_PIPS : stepFee;
        uint256 protocolRate = total * (BPS_DENOMINATOR - state.lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        totalFee = uint24(total);
        nonLpFee = uint24(protocolRate);
        lpFee = uint24(total - protocolRate);
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function getVolatility(PoolId poolId) external view returns (uint88) {
        return _currentVolatility(_poolState[poolId], poolId);
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function observe(PoolId poolId) external view returns (int56 tickCumulative, int24 truncatedTick) {
        PoolState storage state = _poolState[poolId];
        truncatedTick = state.truncatedTick;
        tickCumulative =
            state.tickCumulative + int56(truncatedTick) * int56(uint56(block.timestamp - state.lastSwapTimestamp));
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function factoryOwner() public view returns (address) {
        return IBCTokenFactory(BC_TOKEN_FACTORY).owner();
    }

    /**
     * @inheritdoc IFactoryHook
     */
    function factoryTreasury() public view returns (address) {
        return IBCTokenFactory(BC_TOKEN_FACTORY).treasury();
    }

    /**
     * @inheritdoc BaseHook
     */
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /**
     * @notice Validates pool initialization before the pool manager creates the pool.
     * @dev Two-factor pool-creation lock plus dynamic-fee guard: only the liquidity manager may
     * initialize, only after registering the pool via `registerPool` in the same transaction,
     * and only for a dynamic-fee pool (the LP share rides V4's native dynamic fee).
     * @param sender The address that called `IPoolManager.initialize`.
     * @param key The V4 pool key being initialized.
     * @return The `beforeInitialize` selector.
     */
    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (sender != IBCTokenFactory(BC_TOKEN_FACTORY).liquidityManager() || !_poolState[key.toId()].registered) {
            revert UnauthorizedPoolInitialization();
        }
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        return IHooks.beforeInitialize.selector;
    }

    /**
     * @notice Seeds the pool's volatility and oracle state after initialization.
     * @dev Bootstraps the volatility tracker and truncated oracle from the opening tick.
     * @param key The V4 pool key that was initialized.
     * @param tick The pool's opening tick.
     * @return The `afterInitialize` selector.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolState storage state = _poolState[key.toId()];
        state.referenceTick = tick;
        state.truncatedTick = tick;
        state.lastSwapTimestamp = uint32(block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice Gates the swap, updates volatility, and charges/schedules the non-LP fee share.
     * @dev Core swap gate + fee engine. Order: graduation gate → halt gate → volatility update
     * (pre-swap tick) → step fee → LP/non-LP split. The LP share is delivered as V4's native
     * dynamic fee via a per-swap LP-fee override; only the non-LP (protocol) share is captured
     * as a hook delta. For exact-input swaps the protocol share is taken here on the input
     * currency via a positive specified-currency hook delta; for exact-output swaps the protocol
     * pip rate is stashed in transient storage and charged in `_afterSwap` on the computed input.
     * The override rate is grossed up (`_lpFeeOverride`) so the beforeSwap delta shrinking the
     * input does not distort the LP/non-LP split.
     * @param key The V4 pool key being swapped through.
     * @param params The swap parameters (direction and specified amount).
     * @return The `beforeSwap` selector.
     * @return The hook delta taking the protocol share on exact-input swaps (zero otherwise).
     * @return The grossed-up LP-fee override carrying `OVERRIDE_FEE_FLAG`.
     */
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolState storage state = _poolState[poolId];

        if (!IBCToken(state.coin).isLPd()) revert NotLPd();

        uint256 stepFee;
        // Scoped so the tick/volatility slots are freed before the fee zone below.
        {
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            uint88 volatility = _updateVolatility(state, tick);
            stepFee = _runFeeChain(state, poolId, volatility, tick, params);
        }

        // Floor the total at the 3-bps minimum (Q18): the protocol floor is then always coverable
        // from WITHIN the fee — no surcharge mechanism, no sub-floor edge. Inlined here (not via
        // `_feeSplit`) to stay within the stack; `previewFee` mirrors it, guarded by a parity test.
        if (stepFee < PROTOCOL_FLOOR_PIPS) stepFee = PROTOCOL_FLOOR_PIPS;

        // Stash the applied total rate for afterSwap (observer notifications + the
        // lastAppliedFee checkpoint feeding CALL_FEE_CHANGE).
        {
            bytes32 appliedSlot = APPLIED_FEE_TSLOT;
            assembly ("memory-safe") {
                tstore(appliedSlot, stepFee)
            }
        }

        // Split by `lpShareBps`, reserving the protocol floor from within (the LP share yields).
        uint256 protocolRate = stepFee * (BPS_DENOMINATOR - state.lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        uint24 lpFeeOverride = _lpFeeOverride(stepFee - protocolRate, protocolRate);

        if (params.amountSpecified < 0) {
            // Exact input: protocol share comes off the specified (input) amount before the swap.
            uint256 feeAmount = uint256(-params.amountSpecified) * protocolRate / FEE_DENOMINATOR;
            if (feeAmount > 0) {
                uint256 floorAmount = uint256(-params.amountSpecified) * PROTOCOL_FLOOR_PIPS / FEE_DENOMINATOR;
                Currency input = params.zeroForOne ? key.currency0 : key.currency1;
                _distributeFee(poolId, state, input, feeAmount, floorAmount);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeAmount.toInt128(), 0), lpFeeOverride);
            }
        } else {
            // Exact output: input is unknown until the swap runs; stash the rate for afterSwap.
            bytes32 slot = PENDING_FEE_TSLOT;
            assembly ("memory-safe") {
                tstore(slot, protocolRate)
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /**
     * @notice Checkpoints the completed swap's tick into the truncated oracle and charges the
     * protocol share of exact-output swaps on the pool-computed input.
     * @dev The oracle checkpoint (`_checkpointSwap`) runs first and unconditionally, so it
     * applies to exact-input and exact-output swaps alike and on every return branch below: the
     * recorded oracle tick must always describe the last completed swap.
     * @dev Exact-output leg of the protocol-share engine: grosses the protocol share up from the
     * pool-computed input (`amount * protocolRate / (1e6 - protocolRate)`) so it is the same
     * share of the total paid as on the exact-input path (fee-inclusive input math). The input
     * delta already includes the native LP fee applied during the swap.
     * @param key The V4 pool key that was swapped through.
     * @param params The swap parameters (direction and specified amount).
     * @param delta The balance delta produced by the swap.
     * @return The `afterSwap` selector.
     * @return The hook delta taking the protocol share on exact-output swaps (zero otherwise).
     * @dev slither reentrancy-eth: the only state written after `_distributeFee`'s external calls
     * is `lastAppliedFee` (a lagging fee-display cache with no accounting role). Every external
     * target is trusted and callback-free (PoolManager, WETH, the protocol StakingVault); the sole
     * hostile surface — observers — runs after that write. Verified false positive.
     */
    // slither-disable-next-line reentrancy-eth
    function _afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (, int24 postSwapTick,,) = poolManager.getSlot0(poolId);
        _checkpointSwap(_poolState[poolId], postSwapTick);

        if (params.amountSpecified > 0) {
            bytes32 slot = PENDING_FEE_TSLOT;
            uint256 protocolRate;
            assembly ("memory-safe") {
                protocolRate := tload(slot)
                tstore(slot, 0)
            }
            if (protocolRate > 0) {
                (Currency input, int128 inputDelta) =
                    params.zeroForOne ? (key.currency0, delta.amount0()) : (key.currency1, delta.amount1());
                uint256 inputAmount = uint256(uint128(-inputDelta));
                uint256 feeAmount = inputAmount * protocolRate / (FEE_DENOMINATOR - protocolRate);
                if (feeAmount > 0) {
                    _distributeFee(
                        poolId,
                        _poolState[poolId],
                        input,
                        feeAmount,
                        inputAmount * PROTOCOL_FLOOR_PIPS / (FEE_DENOMINATOR - PROTOCOL_FLOOR_PIPS)
                    );
                    _settleSwapTail(poolId, delta, hookData, feeAmount);
                    return (IHooks.afterSwap.selector, feeAmount.toInt128());
                }
            }
        }
        _settleSwapTail(poolId, delta, hookData, _exactInFeeAmount(poolId, params));
        return (IHooks.afterSwap.selector, 0);
    }

    /**
     * @notice Recomputes the exact-input protocol fee charged in `beforeSwap`, for observer
     * reporting. Zero for exact-output swaps (their fee is computed in `afterSwap` directly).
     * @param poolId The pool whose `lpShareBps` split the applied fee.
     * @param params The swap parameters.
     * @return The non-LP fee amount charged on the exact-input path.
     */
    function _exactInFeeAmount(PoolId poolId, SwapParams calldata params) internal view returns (uint256) {
        if (params.amountSpecified >= 0) return 0;
        uint256 appliedRate;
        bytes32 slot = APPLIED_FEE_TSLOT;
        assembly ("memory-safe") {
            appliedRate := tload(slot)
        }
        // `appliedRate` is the clamped stepFee (>= PROTOCOL_FLOOR_PIPS), so the floor always fits.
        uint256 protocolRate = appliedRate * (BPS_DENOMINATOR - _poolState[poolId].lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        return uint256(-params.amountSpecified) * protocolRate / FEE_DENOMINATOR;
    }

    /**
     * @notice Post-accounting tail of every swap: checkpoints `lastAppliedFee` and notifies
     * the pool's observers, after the fee engine has fully settled.
     * @dev Observers are boxed in, but NOT by an unlock guard. They run inside the swap's
     * PoolManager unlock, so a nested `unlock` reverts (`AlreadyUnlocked`) — but `swap`, `take`,
     * `settle` and the other `onlyWhenUnlocked` ops are callable, so a funded observer CAN run a
     * nested swap. What actually contains it: (1) raw calls under the SHARED `OBSERVER_GAS_BUDGET`
     * with revert and returndata ignored (returndata never copied); (2) V4's per-address delta
     * accounting — a nested swap's deltas are keyed to the OBSERVER, isolated from the hook's
     * transient position, which is settled deterministically by the hook delta `afterSwap`
     * returns; (3) the fee is already distributed to its recipients before this runs, and the
     * fee/volatility tslots are read-and-cleared before the observer loop, so a nested same-pool
     * swap corrupts no outer state. The residual power is a DoS, not extraction: an observer that
     * runs a nested op and leaves an UNSETTLED delta makes the outer unlock revert
     * (`CurrencyNotSettled`), aborting the swap — bounded to its own pool (bindings are per-pool,
     * the creator's choice), the same blast radius as any malicious binding (§4.6). It cannot be
     * prevented from inside the hook (the observer can leave a delta via any pool), and a nested
     * op is no more powerful than a separate-transaction one. `hookData` longer than
     * `MAX_HOOKDATA_BYTES` is treated as absent.
     * @param poolId The V4 pool id.
     * @param delta The swap's real balance delta.
     * @param hookData The swap's hook data (hostile, length-bounded here).
     * @param feeAmount The non-LP fee amount charged on this swap.
     */
    function _settleSwapTail(PoolId poolId, BalanceDelta delta, bytes calldata hookData, uint256 feeAmount) internal {
        PoolState storage state = _poolState[poolId];

        uint24 appliedRate;
        bytes32 slot = APPLIED_FEE_TSLOT;
        assembly ("memory-safe") {
            appliedRate := tload(slot)
            tstore(slot, 0)
        }

        uint24 previousFee = state.lastAppliedFee;
        bool feeChanged = appliedRate != previousFee;
        if (feeChanged) state.lastAppliedFee = appliedRate;

        uint256 observerCount = state.observers.length;
        if (observerCount == 0) return;

        // Both notifications are loop-invariant: encode once, replay per observer.
        bytes memory afterSwapCall = abi.encodeCall(
            IHookObserver.onAfterSwap,
            (poolId, delta, appliedRate, feeAmount, hookData.length <= MAX_HOOKDATA_BYTES ? hookData : hookData[0:0])
        );
        bytes memory feeChangeCall =
            feeChanged ? abi.encodeCall(IHookObserver.onFeeChange, (poolId, previousFee, appliedRate)) : bytes("");

        uint256 budget = OBSERVER_GAS_BUDGET;
        for (uint256 i; i < observerCount && budget > 0; ++i) {
            BoundObserver storage bound = state.observers[i];
            if (bound.calls & CALL_AFTER_SWAP != 0) {
                budget = _notify(bound.observer, budget, afterSwapCall);
            }
            if (feeChanged && bound.calls & CALL_FEE_CHANGE != 0 && budget > 0) {
                budget = _notify(bound.observer, budget, feeChangeCall);
            }
        }
    }

    /**
     * @notice Fire-and-forget observer call under the shared gas budget.
     * @dev Raw call; success, revert and returndata are all ignored and returndata is never
     * copied. The gas actually consumed (call overhead included) is deducted from the budget,
     * so a greedy observer starves only the observers after it — an ordering its own creator
     * chose at binding.
     * @param target The observer.
     * @param budget The remaining shared gas budget.
     * @param data The encoded notification.
     * @return remaining The budget left after the call.
     */
    function _notify(address target, uint256 budget, bytes memory data) internal returns (uint256 remaining) {
        uint256 before = gasleft();
        assembly ("memory-safe") {
            pop(call(budget, target, 0, add(data, 32), mload(data), 0, 0))
        }
        uint256 spent = before - gasleft();
        remaining = spent >= budget ? 0 : budget - spent;
    }

    /**
     * @notice Distributes the non-LP fee share between protocol treasury, staking vault, and fee recipient.
     * @dev Distributes the non-LP share of a swap fee taken in `currency` via a two-level Model
     * C waterfall applied identically to both legs: the protocol treasury takes `protocolFeeRatio`
     * off the top, then the after-protocol remainder splits between the staking vault and fee
     * recipient by `communityFeeRatio` (all to the recipient when no vault exists). Coin-side
     * fees are paid directly from the pool manager; ETH-side fees are taken to this contract,
     * wrapped, and paid out in WETH so hostile recipients cannot block swaps. The vault's
     * ETH-leg portion is delivered as WETH and registered via `notifyWethReward`; its coin-leg
     * portion accrues to the share price as before, and is redirected to the fee recipient while
     * the vault holds no shares (a share price has no owner to appreciate for).
     * @dev The physical `poolManager.take` draws from the pool's current reserves of `currency`.
     * A swap whose input currency the pool has been fully drained of (e.g. an ETH-buy into a
     * pool sitting at the MIN tick with only coin liquidity) therefore cannot have its
     * input-currency fee taken and will revert — fees are distributed per swap, not deferred.
     * @param poolId The pool the fee was charged on, tagged onto the SwapFeeDistributed record.
     * @param state The pool state of the pool the fee was charged on.
     * @param currency The currency the fee was taken in (native ETH or the coin).
     * @param amount The total non-LP fee amount to distribute.
     * @param protocolFloor The 3 bps-of-swap floor amount (Q18): the protocol take is raised to
     * at least this, independent of `protocolFeeRatio`, capped by `amount`.
     */
    function _distributeFee(
        PoolId poolId,
        PoolState storage state,
        Currency currency,
        uint256 amount,
        uint256 protocolFloor
    ) internal {
        address recipient = IBCToken(state.coin).getFeeRecipient();
        address treasury = factoryTreasury();
        address vault = state.stakingVault;

        // Never pay address(0): the coin leg would revert every swap on the ERC20 zero-receiver
        // check and the ETH leg would silently burn the WETH. The factory validates the treasury
        // non-zero, but a zero read (e.g. a hook generation outliving the factory contract it
        // was built against) must still degrade to paying the coin's fee recipient, not halt
        // trading.
        if (treasury == address(0)) treasury = recipient;

        // Level 1: protocol takes protocolFeeRatio off the top of the non-LP share — never less
        // than the absolute 3 bps-of-swap floor (Q18), which survives every ratio change.
        (uint256 protocolAmount, uint256 remainder) = _split(amount, protocolFeeRatio);
        if (protocolAmount < protocolFloor) {
            protocolAmount = protocolFloor > amount ? amount : protocolFloor;
            remainder = amount - protocolAmount;
        }

        // Level 2: the after-protocol remainder splits between vault and recipient by
        // communityFeeRatio, or goes entirely to the recipient when no vault exists.
        bool vaultActive = vault != address(0);
        if (vaultActive && !currency.isAddressZero() && IStakingVault(vault).totalSupply() == 0) {
            vaultActive = false;
        }

        (uint256 vaultAmount, uint256 recipientAmount) =
            vaultActive ? _split(remainder, state.communityFeeRatio) : (uint256(0), remainder);

        if (currency.isAddressZero()) {
            poolManager.take(currency, address(this), amount);
            IWETH(WETH).deposit{value: amount}();

            if (protocolAmount > 0) IWETH(WETH).transfer(treasury, protocolAmount);
            if (vaultAmount > 0) {
                // Guard the vault notify: a misbehaving vault (owner-set via `setStakingVault`)
                // must never brick a swap. `notifyWethReward` is pure accounting — no balance
                // read — so notify first and fund the vault on success; on revert, redirect the
                // vault's share to the fee recipient (bumped before its transfer below) and carry
                // on. No gas cap: the vault is trusted, the guarded failure mode is a revert.
                try IStakingVault(vault).notifyWethReward(vaultAmount) {
                    IWETH(WETH).transfer(vault, vaultAmount);
                } catch {
                    recipientAmount += vaultAmount;
                    emit VaultNotifyFailed(state.coin, vault, vaultAmount);
                    // Zero the vault leg so the SwapFeeDistributed record below reflects what was
                    // actually paid to the vault (nothing) rather than the attempted amount.
                    vaultAmount = 0;
                }
            }
            if (recipientAmount > 0) IWETH(WETH).transfer(recipient, recipientAmount);
        } else {
            if (protocolAmount > 0) poolManager.take(currency, treasury, protocolAmount);
            if (vaultAmount > 0) poolManager.take(currency, vault, vaultAmount);
            if (recipientAmount > 0) poolManager.take(currency, recipient, recipientAmount);
        }

        // Per-swap non-LP fee attribution for off-chain indexers (protocol revenue, staker
        // rewards, fee-recipient income). Amounts are final: the vault leg is zeroed above on a
        // notify failure and folded into recipientAmount.
        emit SwapFeeDistributed(
            poolId, Currency.unwrap(currency), protocolAmount, vaultAmount, recipientAmount, treasury, vault, recipient
        );
    }

    /**
     * @notice Updates the volatility accumulator and accrues the oracle up to the current block,
     * returning the volatility the entering swap is priced against.
     * @dev Runs in `beforeSwap`. `referenceTick` holds the pre-swap tick of the PREVIOUS swap, so
     * the displacement term is that swap's own price move — carried over so a trade that moves
     * the price raises the fee for whoever trades next. Both the stored accumulator and the
     * displacement decay linearly over `decayWindow` since the previous swap, so the carry-over
     * fades on the same schedule instead of entering at full weight forever. The oracle accrues
     * the idle interval at the tick the last completed swap left behind (`truncatedTick` is
     * checkpointed post-swap in `_checkpointSwap`).
     * @param state The pool state to update.
     * @param tick The current (pre-swap) pool tick.
     * @return The volatility accumulator in ticks this swap is priced against.
     */
    function _updateVolatility(PoolState storage state, int24 tick) internal returns (uint88) {
        uint256 updated = _decayedAccumulator(state) + _displacement(state, tick, state.referenceTick);
        if (updated > ACCUMULATOR_CAP) updated = ACCUMULATOR_CAP;

        // Truncated oracle: accrue the recorded tick — the tick the last completed swap left
        // behind — over the idle interval. The recorded tick itself only follows completed swaps,
        // in `_checkpointSwap`, so its `MAX_ABS_TICK_MOVE` bound stays one step per swap.
        state.tickCumulative += int56(state.truncatedTick) * int56(uint56(block.timestamp - state.lastSwapTimestamp));

        state.volatilityAccumulator = uint88(updated);
        state.referenceTick = tick;
        state.lastSwapTimestamp = uint32(block.timestamp);
        return uint88(updated);
    }

    /**
     * @notice Checkpoints the truncated oracle at the tick a completed swap left behind.
     * @dev Runs unconditionally in `afterSwap`, on every branch and for both exact-input and
     * exact-output swaps, so the recorded oracle tick always describes the last completed swap
     * and idle intervals accrue at a price the pool actually sits at rather than a pre-swap tick
     * it has already left. Volatility is NOT touched here: `referenceTick` keeps the pre-swap
     * tick written by `_updateVolatility`, so the swap's own price move is read as (decayed)
     * displacement by the next swap instead of being folded in immediately.
     * @dev `lastSwapTimestamp` was advanced to this block by `_updateVolatility`, so the oracle
     * interval is already complete and nothing further accrues here.
     * @param state The pool state to update.
     * @param tick The pool tick the completed swap ended at.
     */
    function _checkpointSwap(PoolState storage state, int24 tick) internal {
        // Truncated oracle: the recorded tick follows the post-swap tick, bounded per swap.
        int24 truncatedTick = state.truncatedTick;
        if (tick - truncatedTick > MAX_ABS_TICK_MOVE) {
            truncatedTick += MAX_ABS_TICK_MOVE;
        } else if (tick - truncatedTick < -MAX_ABS_TICK_MOVE) {
            truncatedTick -= MAX_ABS_TICK_MOVE;
        } else {
            truncatedTick = tick;
        }
        state.truncatedTick = truncatedTick;
    }

    /**
     * @notice Computes the volatility a swap in this block would observe, without mutating state.
     * @dev View-side volatility: decayed accumulator plus decayed current-tick displacement,
     * capped at the upper step threshold `t2` — exactly the value `_updateVolatility` would
     * produce, so the quoted fee matches the one a swap would actually be charged. Both terms
     * reach zero once `decayWindow` has elapsed since the last swap, so a quiet period of
     * `decayWindow` returns the quote to the floor fee.
     * @param state The pool state to read.
     * @param poolId The V4 pool id.
     * @return The current volatility accumulator in ticks.
     */
    function _currentVolatility(PoolState storage state, PoolId poolId) internal view returns (uint88) {
        (, int24 tick,,) = poolManager.getSlot0(poolId);

        uint256 current = _decayedAccumulator(state) + _displacement(state, tick, state.referenceTick);
        if (current > ACCUMULATOR_CAP) current = ACCUMULATOR_CAP;
        return uint88(current);
    }

    /**
     * @notice Returns the stored volatility accumulator after time decay.
     * @dev Linearly decays the stored accumulator over `decayWindow` seconds since the last
     * volatility update.
     * @param state The pool state holding the stored accumulator and last update timestamp.
     * @return The decayed accumulator value in ticks.
     */
    function _decayedAccumulator(PoolState storage state) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - state.lastSwapTimestamp;
        if (elapsed >= DECAY_WINDOW) return 0;
        return uint256(state.volatilityAccumulator) * (DECAY_WINDOW - elapsed) / DECAY_WINDOW;
    }

    /**
     * @notice Computes the flagged LP-fee override delivering the LP share of the step fee.
     * @dev Grosses the LP-fee override up so the LP receives exactly `lpRate` of the original
     * swap notional despite the protocol delta (`protocolRate`) shrinking the input before core
     * applies the LP fee: `lpOverride = lpRate * 1e6 / (1e6 - protocolRate)`. The result is a
     * rate independent of swap size and direction. Always carries `OVERRIDE_FEE_FLAG` so every
     * swap uses exactly this LP fee (0 when the dynamic fee is disabled).
     * @param lpRate The LP share of the step fee in hundredths of a bip.
     * @param protocolRate The protocol (non-LP) share of the step fee in hundredths of a bip.
     * @return The grossed-up LP fee carrying `OVERRIDE_FEE_FLAG`.
     */
    /**
     * @notice Runs the pool's fee chain and clamps the result by the cage.
     * @dev The chain is seeded with the pool's base fee; each stage's output feeds the next; a
     * failed stage is skipped (its input passes through) and emits `FeeCalculatorFallback` —
     * the swap path can never be blocked by third-party code. The final value is clamped to
     * `MAX_HOOK_FEE`, raised to `SNIPER_MAX_FEE` while the pool's declared sniper window is
     * open (seconds since graduation, read from the coin's `lpdAt`).
     * @param state The pool state.
     * @param poolId The V4 pool id.
     * @param volatility The hook's volatility reading for this swap.
     * @param tick The current (pre-swap) pool tick.
     * @param params The swap parameters.
     * @return The applied total fee rate in pips.
     */
    function _runFeeChain(
        PoolState storage state,
        PoolId poolId,
        uint88 volatility,
        int24 tick,
        SwapParams calldata params
    ) internal returns (uint256) {
        uint24 baseFee = state.fixedFee;
        uint24 quoted = baseFee;

        uint256 length = state.feeCalculators.length;
        for (uint256 i; i < length; ++i) {
            address calculator = state.feeCalculators[i];
            (bool ok, uint24 output) = _staticQuote(calculator, poolId, quoted, baseFee, volatility, tick, params);
            if (ok) {
                quoted = output;
            } else {
                emit FeeCalculatorFallback(poolId, calculator);
            }
        }

        uint24 ceiling = MAX_HOOK_FEE;
        if (state.sniperWindow != 0 && block.timestamp < IBCToken(state.coin).lpdAt() + state.sniperWindow) {
            ceiling = SNIPER_MAX_FEE;
        }
        return quoted > ceiling ? ceiling : quoted;
    }

    /**
     * @notice Read-only twin of `_runFeeChain` for `previewFee`: same seed, staticcalls and cage
     * clamp, but a failing stage is silently skipped (no `FeeCalculatorFallback` event). Own stack
     * frame so `previewFee` stays within the stack limit.
     * @param state The pool state.
     * @param poolId The V4 pool id.
     * @param volatility The current volatility reading.
     * @param tick The current pool tick.
     * @param params The prospective swap parameters.
     * @return The clamped step fee (pips).
     */
    function _quoteFeeChainView(
        PoolState storage state,
        PoolId poolId,
        uint88 volatility,
        int24 tick,
        SwapParams calldata params
    ) internal view returns (uint256) {
        uint24 baseFee = state.fixedFee;
        uint24 quoted = baseFee;
        for (uint256 i; i < state.feeCalculators.length; ++i) {
            (bool ok, uint24 output) =
                _staticQuote(state.feeCalculators[i], poolId, quoted, baseFee, volatility, tick, params);
            if (ok) quoted = output;
        }
        uint24 ceiling = MAX_HOOK_FEE;
        if (state.sniperWindow != 0 && block.timestamp < IBCToken(state.coin).lpdAt() + state.sniperWindow) {
            ceiling = SNIPER_MAX_FEE;
        }
        return quoted > ceiling ? ceiling : quoted;
    }

    /**
     * @notice One fee-chain stage: a bounded staticcall into third-party code.
     * @dev The cage, EVM-enforced: staticcall (no state writes possible), fixed per-stage gas
     * stipend (deterministic skip — one stage's failure cannot starve the next), returndata
     * copied only when exactly 32 bytes (returndata-bomb-safe), value rejected unless it fits
     * a uint24.
     * @param calculator The stage to call.
     * @param poolId The V4 pool id.
     * @param previousFee The running fee entering this stage.
     * @param baseFee The pool's base fee (chain seed).
     * @param volatility The hook's volatility reading.
     * @param tick The current pool tick.
     * @param params The swap parameters.
     * @return ok Whether the stage returned a usable value.
     * @return fee The stage's output when `ok`.
     */
    function _staticQuote(
        address calculator,
        PoolId poolId,
        uint24 previousFee,
        uint24 baseFee,
        uint88 volatility,
        int24 tick,
        SwapParams calldata params
    ) internal view returns (bool ok, uint24 fee) {
        bytes memory data = abi.encodeCall(
            IFeeCalculator.quoteFee, (poolId, previousFee, baseFee, volatility, tick, params)
        );
        uint256 stipend = CALC_GAS_STIPEND;
        assembly ("memory-safe") {
            let success := staticcall(stipend, calculator, add(data, 32), mload(data), 0, 0)
            if and(success, eq(returndatasize(), 32)) {
                returndatacopy(0, 0, 32)
                let value := mload(0)
                if lt(value, 0x1000000) {
                    ok := 1
                    fee := value
                }
            }
        }
    }

    function _lpFeeOverride(uint256 lpRate, uint256 protocolRate) internal pure returns (uint24) {
        uint256 override_ = lpRate * FEE_DENOMINATOR / (FEE_DENOMINATOR - protocolRate);
        return uint24(override_) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /**
     * @notice Computes the time-decayed displacement of `tick` against the reference tick.
     * @dev `referenceTick` holds the pre-swap tick of the last swap, so the raw displacement is
     * that swap's own price move. It decays linearly over `decayWindow` since that swap — the
     * same schedule as `_decayedAccumulator` — so the carry-over reaches zero after a quiet
     * `decayWindow` instead of entering at full weight no matter how stale it is. Below the decay
     * horizon the two terms sum to exactly what an undecayed displacement folded into the
     * accumulator at the last swap would have decayed to.
     * @param state The pool state holding the last swap timestamp and fee config.
     * @param tick The current pool tick.
     * @param referenceTick The reference tick to measure against.
     * @return The decayed absolute tick displacement.
     */
    function _displacement(PoolState storage state, int24 tick, int24 referenceTick) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - state.lastSwapTimestamp;
        if (elapsed >= DECAY_WINDOW) return 0;
        uint256 displacement =
            uint256(tick >= referenceTick ? uint24(tick - referenceTick) : uint24(referenceTick - tick));
        return displacement * (DECAY_WINDOW - elapsed) / DECAY_WINDOW;
    }

    /**
     * @notice Splits an amount between two recipients by a percentage ratio.
     * @dev Splits `amount` between two recipients: A receives `amount * ratio / 100`, B the
     * remainder. Self-consistent rounding (`amountB = amount - amountA`) keeps take/settle
     * balanced to the wei — anything else reverts the swap with `CurrencyNotSettled`.
     * @param amount The amount to split.
     * @param ratio The percentage (0-100) of `amount` allotted to recipient A.
     * @return amountA The share allotted to recipient A.
     * @return amountB The remainder allotted to recipient B.
     */
    function _split(uint256 amount, uint256 ratio) internal pure returns (uint256 amountA, uint256 amountB) {
        amountA = amount * ratio / 100;
        amountB = amount - amountA;
    }
}
