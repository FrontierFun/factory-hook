// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title ExtensionCampaignBase
/// @notice Shared plumbing for the gen-2 extension campaigns: v2 payload builders and a
/// one-call deploy of a coin carrying an arbitrary fee pipeline.
abstract contract ExtensionCampaignBase is HookTestBase {
    uint256 internal campaignSaltNonce;

    function _emptyConfig(uint24 fixedFee) internal pure returns (IFactoryHook.HookConfigV2 memory) {
        return IFactoryHook.HookConfigV2({
            fixedFee: fixedFee,
            lpShareBps: 7000, // the classic 70/30 split; overridden per test as needed
            feeCalculators: new address[](0),
            calculatorConfigs: new bytes[](0),
            sniperWindow: 0,
            observers: new IFactoryHook.ObserverConfig[](0)
        });
    }

    /// @dev Wires `calculators` (with empty sub-payloads) into `config` in payload order.
    function _withChain(IFactoryHook.HookConfigV2 memory config, address[] memory calculators)
        internal
        pure
        returns (IFactoryHook.HookConfigV2 memory)
    {
        config.feeCalculators = calculators;
        config.calculatorConfigs = new bytes[](calculators.length);
        return config;
    }

    /// @dev Wires observers (all with the same `calls` bits and empty sub-payloads).
    function _withObservers(IFactoryHook.HookConfigV2 memory config, address[] memory observers, uint8 calls)
        internal
        pure
        returns (IFactoryHook.HookConfigV2 memory)
    {
        config.observers = new IFactoryHook.ObserverConfig[](observers.length);
        for (uint256 i; i < observers.length; ++i) {
            config.observers[i] = IFactoryHook.ObserverConfig({observer: observers[i], calls: calls, config: ""});
        }
        return config;
    }

    function _payload(IFactoryHook.HookConfigV2 memory config) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), abi.encode(config));
    }

    /// @dev Deploys a fresh coin carrying `config`, graduated and ready to swap.
    function _deployGraduated(IFactoryHook.HookConfigV2 memory config, bool deployStaking)
        internal
        returns (MockBCToken deployed, PoolId poolId)
    {
        string memory name = string.concat("Campaign ", vm.toString(campaignSaltNonce++));
        deployed = _deployCoin(
            name,
            "CAMP",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: deployStaking, alternativeFeeRecipient: address(0)}),
            _payload(config)
        );
        _graduate(deployed);
        poolId = _poolId(address(deployed));
    }

    /// @dev Exact-OUTPUT ETH->coin swap on `target`'s pool (v1 ExactOut scenario shape).
    function _exactOutputBuyOn(address target, address who, uint256 coinOut, uint256 ethBudget) internal {
        PoolKey memory key = _poolKey(target);
        vm.prank(who);
        swapRouter.swap{value: ethBudget}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(coinOut), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Runs an exact-in ETH->coin swap under a hard gas cap, returning whether it succeeded
    /// (the router call is made low-level so a revert surfaces as `ok == false`, not a bubbling
    /// revert). Used by the observer gas-skip proof.
    function _swapWithGasCap(address target, address who, uint256 amountIn, uint256 gasCap) internal returns (bool ok) {
        PoolKey memory key = _poolKey(target);
        bytes memory cd = abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                SwapParams({
                    zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
        vm.prank(who);
        (ok,) = address(swapRouter).call{gas: gasCap, value: amountIn}(cd);
    }

    /// @dev Exact-INPUT ETH->coin swap expected to revert (the router bubbles hook/settlement
    /// reverts up wrapped, so the caller asserts a plain revert).
    function _swapEthForCoinExpectRevert(address target, address who, uint256 amountIn) internal {
        PoolKey memory key = _poolKey(target);
        vm.prank(who);
        vm.expectRevert();
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Exact-INPUT ETH->coin swap carrying arbitrary hookData (the HookTestBase helper always
    /// sends empty hookData).
    function _swapEthForCoinWithHookData(address target, address who, uint256 amountIn, bytes memory hookData)
        internal
    {
        PoolKey memory key = _poolKey(target);
        vm.prank(who);
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }
}
