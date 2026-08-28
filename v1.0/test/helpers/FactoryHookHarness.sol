// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {FactoryHook} from "src/hook/FactoryHook.sol";

/// @title FactoryHookHarness
/// @notice Test double exposing FactoryHook internals for direct unit coverage of the fee and
/// volatility math without driving full pool swaps.
contract FactoryHookHarness is FactoryHook {
    constructor(IPoolManager _poolManager, address _tokenFactory, address _weth, address _stakingVaultFactory)
        FactoryHook(_poolManager, _tokenFactory, _weth, _stakingVaultFactory)
    {}

    /// @dev Runs the pool's fee-calculator chain exactly as `_beforeSwap` would: seed with the
    /// pool's base fee, thread stage outputs, skip failed stages, clamp by the active ceiling.
    function exposed_runFeeChain(PoolId poolId, uint88 volatility, int24 tick, SwapParams calldata params)
        external
        returns (uint256)
    {
        return _runFeeChain(_poolState[poolId], poolId, volatility, tick, params);
    }

    /// @dev One caged fee-chain stage: bounded staticcall into `calculator`.
    function exposed_staticQuote(
        address calculator,
        PoolId poolId,
        uint24 previousFee,
        uint24 baseFee,
        uint88 volatility,
        int24 tick,
        SwapParams calldata params
    ) external view returns (bool ok, uint24 fee) {
        return _staticQuote(calculator, poolId, previousFee, baseFee, volatility, tick, params);
    }

    function exposed_split(uint256 amount, uint256 ratio) external pure returns (uint256 amountA, uint256 amountB) {
        return _split(amount, ratio);
    }

    /// @dev Time-decayed displacement of `tick` against the pool's stored reference tick.
    function exposed_displacement(PoolId poolId, int24 tick) external view returns (uint256) {
        return _displacement(_poolState[poolId], tick, _poolState[poolId].referenceTick);
    }

    function exposed_updateVolatility(PoolId poolId, int24 tick) external returns (uint88) {
        return _updateVolatility(_poolState[poolId], tick);
    }

    /// @dev The `afterSwap` half of the per-swap update: checkpoints the tick a completed swap
    /// ended at into the truncated oracle.
    function exposed_checkpointSwap(PoolId poolId, int24 tick) external {
        _checkpointSwap(_poolState[poolId], tick);
    }

    /// @dev Runs the full per-swap sequence for a pre/post tick pair: `beforeSwap`'s
    /// decay-and-accrue (whose result prices the swap), then `afterSwap`'s oracle checkpoint.
    /// @return pricedAt The volatility the swap would have been priced against.
    function exposed_swapCycle(PoolId poolId, int24 preTick, int24 postTick) external returns (uint88 pricedAt) {
        pricedAt = _updateVolatility(_poolState[poolId], preTick);
        _checkpointSwap(_poolState[poolId], postTick);
    }

    function exposed_decayedAccumulator(PoolId poolId) external view returns (uint256) {
        return _decayedAccumulator(_poolState[poolId]);
    }

    /// @dev Writes raw volatility-tracking state for edge-case tests.
    function setVolatilityState(
        PoolId poolId,
        int24 referenceTick,
        uint32 lastSwapTimestamp,
        uint88 volatilityAccumulator
    ) external {
        PoolState storage state = _poolState[poolId];
        state.referenceTick = referenceTick;
        state.lastSwapTimestamp = lastSwapTimestamp;
        state.volatilityAccumulator = volatilityAccumulator;
    }

    /// @dev Writes the pool's fee pipeline directly (base fee, chain, sniper window) so chain
    /// unit tests need no full registerPool payload round-trip.
    function setFeePipeline(PoolId poolId, uint24 fixedFee, address[] calldata feeCalculators, uint32 sniperWindow)
        external
    {
        PoolState storage state = _poolState[poolId];
        state.fixedFee = fixedFee;
        delete state.feeCalculators;
        for (uint256 i; i < feeCalculators.length; ++i) {
            state.feeCalculators.push(feeCalculators[i]);
        }
        state.sniperWindow = sniperWindow;
    }
}
