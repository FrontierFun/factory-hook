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
import {IExtensionHost} from "src/interfaces/extensions/IExtensionHost.sol";
import {IFeeCalculator} from "src/interfaces/extensions/IFeeCalculator.sol";
import {IHookObserver} from "src/interfaces/extensions/IHookObserver.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

/**
 * @title FactoryHook
 * @author Frontier
 * @notice Singleton Uniswap V4 hook for every graduated BCToken pool: blocks swaps until the coin
 * graduates, tracks volatility as time-decayed tick displacement, and charges a fee split between
 * LPs (V4's native dynamic fee) and the non-LP share (hook delta paid to treasury, vault, recipient).
 * @dev Liquidity hook flags are OFF: third-party LPs are allowed. Volatility carries over between
 * swaps and decays over `DECAY_WINDOW`; the truncated oracle is checkpointed in `afterSwap` so
 * idle intervals accrue at the tick the last swap left behind.
 */
contract FactoryHook is BaseHook, IFactoryHook {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;
    using SafeCast for uint256;

    /// @notice Fee denominator: fees are in pips (hundredths of a bip, 1e-6).
    uint256 private constant FEE_DENOMINATOR = 1e6;

    /// @notice Basis-point denominator for the LP / non-LP split.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @notice Ceiling for any hook fee outside the sniper window (10%).
    uint24 public constant MAX_HOOK_FEE = 100_000;

    /// @notice Absolute protocol floor (3 bps of the swap amount), clamped on every swap.
    /// Independent of `protocolFeeRatio` and `lpShareBps`, so it survives every ratio change.
    uint24 public constant PROTOCOL_FLOOR_PIPS = 300;

    /// @notice Hook config schema version this hook generation accepts (first payload byte).
    uint8 public constant HOOK_CONFIG_VERSION = 2;

    /// @notice Protocol-wide flat fee (0.30%): the base of every pool and the seed of every fee chain.
    uint24 public constant DEFAULT_FIXED_FEE = 3000;

    /// @notice LP share (bps) of a pool registered with an empty payload (70%).
    /// A custom payload states `lpShareBps` literally: 0 means no LP share, there is no default fallback.
    uint16 public constant DEFAULT_LP_SHARE_BPS = 7000;

    /// @notice Fee ceiling during a pool's declared sniper window (50%).
    uint24 public constant SNIPER_MAX_FEE = 500_000;

    /// @notice Longest declarable sniper window, in seconds after graduation.
    uint32 public constant MAX_SNIPER_WINDOW = 3600;

    /// @notice Maximum fee-chain length; each stage costs its stipend on every swap.
    uint256 public constant MAX_FEE_CALCULATORS = 4;

    /// @notice Maximum bound observers per pool; gas is bounded by `OBSERVER_GAS_BUDGET`, not by count.
    uint256 public constant MAX_OBSERVERS = 8;

    /// @notice Gas stipend per fee-chain stage, so a failing stage is skipped without starving the next.
    uint256 public constant CALC_GAS_STIPEND = 50_000;

    /// @notice Shared gas budget for all observer notifications of one swap; a greedy observer starves the next.
    uint256 public constant OBSERVER_GAS_BUDGET = 600_000;

    /// @notice Longest `hookData` forwarded to observers; anything larger is treated as absent.
    uint256 public constant MAX_HOOKDATA_BYTES = 256;

    /// @notice Volatility decay window (seconds).
    uint32 public constant DECAY_WINDOW = 600;

    /// @notice Volatility accumulator cap (ticks).
    uint88 public constant ACCUMULATOR_CAP = 900;

    /// @notice Observer call-mask bit: notify after each settled swap.
    uint8 public constant CALL_AFTER_SWAP = 1 << 0;

    /// @notice Observer call-mask bit: notify when the applied fee changes.
    uint8 public constant CALL_FEE_CHANGE = 1 << 1;

    /// @notice Maximum move of the recorded oracle tick per block (truncated oracle), measured from `anchorTick`.
    int24 public constant MAX_ABS_TICK_MOVE = 9116;

    /// @dev Transient slot carrying the non-LP pip rate from `beforeSwap` to `afterSwap` on exact-output swaps.
    /// One slot is safe: both callbacks of one swap run adjacently inside the PoolManager's unlock.
    bytes32 private constant PENDING_FEE_TSLOT = keccak256("FactoryHook.pendingFee");

    /// @dev Transient slot carrying the applied total fee rate from `beforeSwap` to `afterSwap`.
    bytes32 private constant APPLIED_FEE_TSLOT = keccak256("FactoryHook.appliedFee");

    /// @dev Transient reentrancy lock on `registerPool` (S2): extension registration calls arbitrary code.
    /// Load-bearing, not defence in depth — there is no onchain extension gating.
    bytes32 private constant REGISTER_LOCK_TSLOT = keccak256("FactoryHook.registerLock");

    /// @notice The BCTokenFactory; its owner is the protocol admin.
    address public immutable BC_TOKEN_FACTORY;

    /// @notice Canonical WETH used for ETH-side fee payouts.
    address public immutable WETH;

    /// @notice The StakingVaultFactory used to deploy per-pool vaults.
    address public stakingVaultFactory;

    /// @notice Percentage (0-100) of the non-LP fee share taken off the top for the protocol treasury.
    uint8 public protocolFeeRatio;

    /// @dev Per-pool hook state; internal so test harnesses can reach it.
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
     * @notice Wires the hook to the pool manager, the BCToken factory, WETH and the staking vault factory.
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

    /// @inheritdoc IFactoryHook
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

        // S2 lock: extension registration below calls arbitrary third-party code; load-bearing, not defence in depth.
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

        bool custom = hookConfig.length != 0;
        HookConfigV2 memory config;
        if (custom) {
            config = _decodeAndValidateConfig(hookConfig);
            state.fixedFee = config.fixedFee;
            state.lastAppliedFee = config.fixedFee;
            state.lpShareBps = config.lpShareBps;
            state.sniperWindow = config.sniperWindow;
            for (uint256 i; i < config.feeCalculators.length; ++i) {
                state.feeCalculators.push(config.feeCalculators[i]);
            }
            for (uint256 i; i < config.observers.length; ++i) {
                state.observers
                    .push(BoundObserver({observer: config.observers[i].observer, calls: config.observers[i].calls}));
            }
        }

        if (stakingConfig.deployStaking) {
            state.stakingVault = IStakingVaultFactory(stakingVaultFactory).deployVault(IERC20(coin));
        }

        emit PoolRegistered(poolId, coin, communityFeeRatio, state.stakingVault);
        if (custom) {
            emit FixedFeeChanged(poolId, state.fixedFee);

            // Runs last, after every hook state write (S2): the only moment an extension may write state or
            // revert. Extensions must gate on msg.sender == hook (S1) — pool ids are predictable pre-deploy.
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
     * @notice Decodes and structurally validates a schema-v2 creator payload: the version byte, then
     * one abi-encoded `HookConfigV2`.
     * @dev A sniper window raises the clamp ceiling to `SNIPER_MAX_FEE`, so it is bounded and only
     * declarable with a calculator chain. Even at `lpShareBps = 10000` the grossed-up LP override
     * stays well under `MAX_LP_FEE`, because the protocol floor is reserved from within the fee.
     * @param hookConfig The non-empty payload.
     * @return config The validated configuration.
     */
    function _decodeAndValidateConfig(bytes calldata hookConfig) internal pure returns (HookConfigV2 memory config) {
        uint8 version = uint8(hookConfig[0]);
        if (version != HOOK_CONFIG_VERSION) revert UnsupportedHookConfigVersion(version);

        config = abi.decode(hookConfig[1:], (HookConfigV2));
        // abi.decode tolerates trailing garbage and non-canonical layouts; re-encoding and comparing closes that.
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

    /// @inheritdoc IFactoryHook
    function setProtocolFeeRatio(uint8 _protocolFeeRatio) external onlyFactoryOwner {
        if (_protocolFeeRatio > 100) revert InvalidProtocolFeeRatio();
        uint8 previous = protocolFeeRatio;
        protocolFeeRatio = _protocolFeeRatio;
        emit ProtocolFeeRatioUpdated(previous, _protocolFeeRatio);
    }

    /// @inheritdoc IFactoryHook
    function setStakingVaultFactory(address _stakingVaultFactory) external onlyFactoryOwner {
        if (_stakingVaultFactory == address(0)) revert InvalidZeroAddress();
        if (IStakingVaultFactory(_stakingVaultFactory).hook() != address(this)) {
            revert InvalidStakingVaultFactory();
        }
        address previous = stakingVaultFactory;
        stakingVaultFactory = _stakingVaultFactory;
        emit StakingVaultFactoryUpdated(previous, _stakingVaultFactory);
    }

    /// @inheritdoc IFactoryHook
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

    /// @inheritdoc IFactoryHook
    function getPoolState(PoolId poolId) external view returns (PoolState memory) {
        return _poolState[poolId];
    }

    /// @inheritdoc IExtensionHost
    function poolCoin(PoolId poolId) external view returns (address) {
        return _poolState[poolId].coin;
    }

    /// @inheritdoc IExtensionHost
    function poolFixedFee(PoolId poolId) external view returns (uint24) {
        return _poolState[poolId].fixedFee;
    }

    /// @inheritdoc IExtensionHost
    function poolSniperWindow(PoolId poolId) external view returns (uint32) {
        return _poolState[poolId].sniperWindow;
    }

    /// @inheritdoc IFactoryHook
    function getCurrentFee(PoolId poolId) external view returns (uint24 fee) {
        return _poolState[poolId].lastAppliedFee;
    }

    /// @inheritdoc IFactoryHook
    function previewFee(PoolId poolId, SwapParams calldata params)
        external
        view
        returns (uint24 totalFee, uint24 lpFee, uint24 nonLpFee)
    {
        PoolState storage state = _poolState[poolId];
        (, int24 tick,,) = poolManager.getSlot0(poolId);
        uint256 stepFee = _quoteFeeChainView(state, poolId, _currentVolatility(state, poolId), tick, params);

        // Must mirror `_beforeSwap`'s floor-then-split exactly.
        uint256 total = stepFee < PROTOCOL_FLOOR_PIPS ? PROTOCOL_FLOOR_PIPS : stepFee;
        uint256 protocolRate = total * (BPS_DENOMINATOR - state.lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        totalFee = uint24(total);
        nonLpFee = uint24(protocolRate);
        lpFee = uint24(total - protocolRate);
    }

    /// @inheritdoc IFactoryHook
    function getVolatility(PoolId poolId) external view returns (uint88) {
        return _currentVolatility(_poolState[poolId], poolId);
    }

    /// @inheritdoc IFactoryHook
    function observe(PoolId poolId) external view returns (int56 tickCumulative, int24 truncatedTick) {
        PoolState storage state = _poolState[poolId];
        truncatedTick = state.truncatedTick;
        tickCumulative =
            state.tickCumulative + int56(truncatedTick) * int56(uint56(block.timestamp - state.lastSwapTimestamp));
    }

    /// @inheritdoc IFactoryHook
    function factoryOwner() public view returns (address) {
        return IBCTokenFactory(BC_TOKEN_FACTORY).owner();
    }

    /// @inheritdoc IFactoryHook
    function factoryTreasury() public view returns (address) {
        return IBCTokenFactory(BC_TOKEN_FACTORY).treasury();
    }

    /// @inheritdoc BaseHook
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
     * @notice Only the liquidity manager may initialize, only a pool registered via `registerPool`,
     * and only as a dynamic-fee pool.
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
     * @notice Seeds the volatility tracker and truncated oracle from the opening tick.
     * @param key The V4 pool key that was initialized.
     * @param tick The pool's opening tick.
     * @return The `afterInitialize` selector.
     */
    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        PoolState storage state = _poolState[key.toId()];
        state.referenceTick = tick;
        state.truncatedTick = tick;
        state.anchorTick = tick;
        state.anchorTimestamp = uint32(block.timestamp);
        state.lastSwapTimestamp = uint32(block.timestamp);
        return IHooks.afterInitialize.selector;
    }

    /**
     * @notice Gates the swap on graduation, updates volatility, runs the fee chain and splits the fee.
     * @dev The LP share is delivered as a grossed-up LP-fee override (`_lpFeeOverride`); only the
     * non-LP share is a hook delta. Exact input: taken here on the input currency. Exact output: the
     * pip rate is stashed in `PENDING_FEE_TSLOT` and charged in `_afterSwap` on the computed input.
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
        {
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            uint88 volatility = _updateVolatility(state, tick);
            stepFee = _runFeeChain(state, poolId, volatility, tick, params);
        }

        // Floor the total so the protocol floor is always coverable from within; `previewFee` mirrors this.
        if (stepFee < PROTOCOL_FLOOR_PIPS) stepFee = PROTOCOL_FLOOR_PIPS;

        {
            bytes32 appliedSlot = APPLIED_FEE_TSLOT;
            assembly ("memory-safe") {
                tstore(appliedSlot, stepFee)
            }
        }

        // The protocol floor is reserved from within: the LP share yields.
        uint256 protocolRate = stepFee * (BPS_DENOMINATOR - state.lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        uint24 lpFeeOverride = _lpFeeOverride(stepFee - protocolRate, protocolRate);

        if (params.amountSpecified < 0) {
            uint256 feeAmount = uint256(-params.amountSpecified) * protocolRate / FEE_DENOMINATOR;
            if (feeAmount > 0) {
                uint256 floorAmount = uint256(-params.amountSpecified) * PROTOCOL_FLOOR_PIPS / FEE_DENOMINATOR;
                Currency input = params.zeroForOne ? key.currency0 : key.currency1;
                _distributeFee(poolId, state, input, feeAmount, floorAmount);
                return (IHooks.beforeSwap.selector, toBeforeSwapDelta(feeAmount.toInt128(), 0), lpFeeOverride);
            }
        } else {
            bytes32 slot = PENDING_FEE_TSLOT;
            assembly ("memory-safe") {
                tstore(slot, protocolRate)
            }
        }

        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFeeOverride);
    }

    /**
     * @notice Checkpoints the truncated oracle, then charges the non-LP share of exact-output swaps
     * on the pool-computed input, grossed up (`amount * rate / (1e6 - rate)`) to match the
     * exact-input share, and settles the swap tail.
     * @dev `_checkpointSwap` runs first and on every branch, so the recorded tick always describes
     * the last completed swap. slither reentrancy-eth is a false positive: the only state written
     * after `_distributeFee`'s trusted external calls is `lastAppliedFee`, a display cache.
     * @param key The V4 pool key that was swapped through.
     * @param params The swap parameters (direction and specified amount).
     * @param delta The balance delta produced by the swap.
     * @param hookData The swap's hook data, forwarded untouched to the observer tail.
     * @return The `afterSwap` selector.
     * @return The hook delta taking the protocol share on exact-output swaps (zero otherwise).
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
     * @notice Recomputes the exact-input non-LP fee charged in `beforeSwap`, for observer reporting;
     * zero for exact-output swaps.
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
        uint256 protocolRate = appliedRate * (BPS_DENOMINATOR - _poolState[poolId].lpShareBps) / BPS_DENOMINATOR;
        if (protocolRate < PROTOCOL_FLOOR_PIPS) protocolRate = PROTOCOL_FLOOR_PIPS;
        return uint256(-params.amountSpecified) * protocolRate / FEE_DENOMINATOR;
    }

    /**
     * @notice Post-accounting tail of every swap: checkpoints `lastAppliedFee`, then notifies observers.
     * @dev Observers run inside the swap's unlock and can run nested V4 ops, so they are caged: raw
     * calls under the shared `OBSERVER_GAS_BUDGET`, revert and returndata ignored, fee tslots
     * read-and-cleared and the fee already distributed before the loop. Residual power is a DoS on
     * the observer's own pool, not extraction.
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
     * @notice Fire-and-forget observer call under the shared gas budget: revert and returndata
     * ignored, returndata never copied, gas actually consumed deducted from the budget.
     * @dev A greedy observer starves only the observers bound after it.
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
     * @notice Distributes the non-LP fee share: the treasury takes `protocolFeeRatio` off the top,
     * never below `protocolFloor` (3 bps of the swap, capped by `amount`); the remainder splits between
     * vault and fee recipient by `communityFeeRatio`. ETH is paid as WETH so a hostile recipient cannot
     * block swaps.
     * @dev `poolManager.take` draws from the pool's current reserves of `currency`: a swap whose input
     * currency the pool is fully drained of reverts — fees are distributed per swap, not deferred.
     * @param poolId The pool the fee was charged on, tagged onto the SwapFeeDistributed record.
     * @param state The pool state of the pool the fee was charged on.
     * @param currency The currency the fee was taken in (native ETH or the coin).
     * @param amount The total non-LP fee amount to distribute.
     * @param protocolFloor The 3 bps-of-swap floor amount (Q18): the protocol take is raised to at least this,
     * independent of `protocolFeeRatio`, capped by `amount`.
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

        // A zero treasury must degrade to the fee recipient, not halt trading (the coin leg would revert).
        if (treasury == address(0)) treasury = recipient;

        (uint256 protocolAmount, uint256 remainder) = _split(amount, protocolFeeRatio);
        if (protocolAmount < protocolFloor) {
            protocolAmount = protocolFloor > amount ? amount : protocolFloor;
            remainder = amount - protocolAmount;
        }

        // Coin-leg fees accrue to the vault's share price, which has no owner while it holds no shares.
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
                // A misbehaving vault must never brick a swap: notify first (pure accounting, no balance read),
                // fund on success, redirect to the recipient on revert.
                try IStakingVault(vault).notifyWethReward(vaultAmount) {
                    IWETH(WETH).transfer(vault, vaultAmount);
                } catch {
                    recipientAmount += vaultAmount;
                    emit VaultNotifyFailed(state.coin, vault, vaultAmount);
                    vaultAmount = 0;
                }
            }
            if (recipientAmount > 0) IWETH(WETH).transfer(recipient, recipientAmount);
        } else {
            if (protocolAmount > 0) poolManager.take(currency, treasury, protocolAmount);
            if (vaultAmount > 0) poolManager.take(currency, vault, vaultAmount);
            if (recipientAmount > 0) poolManager.take(currency, recipient, recipientAmount);
        }

        emit SwapFeeDistributed(
            poolId, Currency.unwrap(currency), protocolAmount, vaultAmount, recipientAmount, treasury, vault, recipient
        );
    }

    /**
     * @notice Updates the volatility accumulator and accrues the oracle up to this block, returning
     * the volatility the entering swap is priced against.
     * @dev `referenceTick` is the previous swap's pre-swap tick, so the displacement term is that
     * swap's own price move, decayed over `DECAY_WINDOW` like the accumulator. The oracle accrues the
     * idle interval at `truncatedTick`, which only moves in `_checkpointSwap`.
     * @param state The pool state to update.
     * @param tick The current (pre-swap) pool tick.
     * @return The volatility accumulator in ticks this swap is priced against.
     */
    function _updateVolatility(PoolState storage state, int24 tick) internal returns (uint88) {
        uint256 updated = _decayedAccumulator(state) + _displacement(state, tick, state.referenceTick);
        if (updated > ACCUMULATOR_CAP) updated = ACCUMULATOR_CAP;

        state.tickCumulative += int56(state.truncatedTick) * int56(uint56(block.timestamp - state.lastSwapTimestamp));

        state.volatilityAccumulator = uint88(updated);
        state.referenceTick = tick;
        state.lastSwapTimestamp = uint32(block.timestamp);
        return uint88(updated);
    }

    /**
     * @notice Checkpoints the truncated oracle at the tick a completed swap left behind, clamped to
     * `MAX_ABS_TICK_MOVE` from the tick the block opened at.
     * @dev The clamp is anchored on the block's opening tick, not the previous swap: a swap-to-swap
     * clamp could be walked anywhere inside one block by splitting a trade. Volatility is not touched
     * here, so the next swap reads this swap's move as decayed displacement.
     * @param state The pool state to update.
     * @param tick The pool tick the completed swap ended at.
     */
    function _checkpointSwap(PoolState storage state, int24 tick) internal {
        int24 anchor;
        if (state.anchorTimestamp != uint32(block.timestamp)) {
            anchor = state.truncatedTick;
            state.anchorTick = anchor;
            state.anchorTimestamp = uint32(block.timestamp);
        } else {
            anchor = state.anchorTick;
        }

        if (tick - anchor > MAX_ABS_TICK_MOVE) {
            tick = anchor + MAX_ABS_TICK_MOVE;
        } else if (tick - anchor < -MAX_ABS_TICK_MOVE) {
            tick = anchor - MAX_ABS_TICK_MOVE;
        }
        state.truncatedTick = tick;
    }

    /**
     * @notice View twin of `_updateVolatility`: the volatility a swap in this block would be priced
     * against, without mutating state.
     * @dev Both terms reach zero once `DECAY_WINDOW` has elapsed, so a quiet window returns the quote to the floor fee.
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
     * @notice The stored accumulator, linearly decayed over `DECAY_WINDOW` since the last swap.
     * @param state The pool state holding the stored accumulator and last update timestamp.
     * @return The decayed accumulator value in ticks.
     */
    function _decayedAccumulator(PoolState storage state) internal view returns (uint256) {
        uint256 elapsed = block.timestamp - state.lastSwapTimestamp;
        if (elapsed >= DECAY_WINDOW) return 0;
        return uint256(state.volatilityAccumulator) * (DECAY_WINDOW - elapsed) / DECAY_WINDOW;
    }

    /**
     * @notice Runs the pool's fee chain and clamps the result: seeded with the base fee, each stage
     * feeds the next, a failed stage is skipped (emitting `FeeCalculatorFallback`), and the result is
     * clamped to `MAX_HOOK_FEE`, or `SNIPER_MAX_FEE` while the declared sniper window is open. Pips.
     * @dev The sniper window counts seconds since graduation, read from the coin's `lpdAt`.
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
     * @notice Read-only twin of `_runFeeChain` for `previewFee`; a failing stage is skipped silently.
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
     * @notice One fee-chain stage: a staticcall into third-party code under `CALC_GAS_STIPEND`,
     * returndata copied only when exactly 32 bytes (returndata-bomb-safe), rejected unless it fits a uint24.
     * @dev The stipend is per stage, so one stage's failure can never starve the next.
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

    /**
     * @notice Grosses the LP rate up so LPs receive exactly `lpRate` of the original notional despite
     * the protocol delta shrinking the input: `lpRate * 1e6 / (1e6 - protocolRate)`, flagged with
     * `OVERRIDE_FEE_FLAG`. Rates are in pips.
     * @param lpRate The LP share of the step fee in pips.
     * @param protocolRate The protocol (non-LP) share of the step fee in pips.
     * @return The grossed-up LP fee carrying `OVERRIDE_FEE_FLAG`; independent of swap size and direction.
     */
    function _lpFeeOverride(uint256 lpRate, uint256 protocolRate) internal pure returns (uint24) {
        uint256 override_ = lpRate * FEE_DENOMINATOR / (FEE_DENOMINATOR - protocolRate);
        return uint24(override_) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
    }

    /**
     * @notice Absolute displacement of `tick` from `referenceTick`, linearly decayed over
     * `DECAY_WINDOW` since the last swap — the same schedule as `_decayedAccumulator`.
     * @dev `referenceTick` is the last swap's pre-swap tick; decaying keeps a stale carry-over from entering the fee
     * at full weight.
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
     * @notice Splits `amount`: A gets `amount * ratio / 100`, B the remainder. Self-consistent rounding
     * keeps take/settle balanced to the wei; anything else reverts the swap with `CurrencyNotSettled`.
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
