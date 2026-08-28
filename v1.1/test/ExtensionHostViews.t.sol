// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {FactoryHookUnitTest} from "test/FactoryHookUnit.t.sol";
import {FixedQuoteCalculator} from "test/helpers/ExtensionMocks.sol";
import {HookTestBase} from "test/helpers/HookTestBase.sol";

/// @title ExtensionHostViewsTest
/// @notice The `IExtensionHost` surface v1.1 adds to the hook (the hook-registry change): the
/// frozen per-pool views extensions read instead of decoding `PoolState`. Added for this
/// package — in the protocol repo these views are exercised through the extension suites
/// (`HookGenerationSwitch`, `DynamicFeeExtension`, ...), which are outside a hook-only package.
contract ExtensionHostViewsTest is FactoryHookUnitTest {
    function test_extensionHostViews_zeroForAnUnregisteredPool() public view {
        assertEq(hook.poolCoin(poolId), address(0), "no coin before registration");
        assertEq(hook.poolFixedFee(poolId), 0, "no base fee before registration");
        assertEq(hook.poolSniperWindow(poolId), 0, "no sniper window before registration");
    }

    function test_extensionHostViews_mirrorPoolStateAfterRegistration() public {
        _register(false, 50);
        IFactoryHook.PoolState memory state = hook.getPoolState(poolId);

        assertEq(hook.poolCoin(poolId), state.coin, "poolCoin mirrors PoolState.coin");
        assertEq(hook.poolCoin(poolId), address(coin), "and it is the registered coin");
        assertEq(hook.poolFixedFee(poolId), state.fixedFee, "poolFixedFee mirrors PoolState.fixedFee");
        assertEq(hook.poolFixedFee(poolId), hook.DEFAULT_FIXED_FEE(), "empty payload: the default base fee");
        assertEq(hook.poolSniperWindow(poolId), state.sniperWindow, "poolSniperWindow mirrors PoolState.sniperWindow");
    }

    function test_extensionHostViews_reflectACustomPayload() public {
        address[] memory chain = new address[](1);
        chain[0] = address(new FixedQuoteCalculator(5000));
        IFactoryHook.HookConfigV2 memory config = IFactoryHook.HookConfigV2({
            fixedFee: 5000,
            lpShareBps: 7000,
            feeCalculators: chain,
            calculatorConfigs: new bytes[](1),
            sniperWindow: 1800,
            observers: new IFactoryHook.ObserverConfig[](0)
        });
        hook.registerPool(
            key,
            address(coin),
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            abi.encodePacked(uint8(2), abi.encode(config))
        );

        assertEq(hook.poolFixedFee(poolId), 5000, "the payload's base fee");
        assertEq(hook.poolSniperWindow(poolId), 1800, "the payload's sniper window");
    }

    function test_extensionHostConstants_matchTheHookCage() public view {
        assertEq(hook.MAX_HOOK_FEE(), 100_000, "10% ceiling");
        assertEq(hook.SNIPER_MAX_FEE(), 500_000, "50% sniper ceiling");
        assertEq(hook.MAX_SNIPER_WINDOW(), 3600, "one-hour window bound");
    }
}

/// @notice The two factory-resolved views, read through the integration base's mock factory
/// (the unit base's `MockTokenFactory` deliberately has no `treasury()`).
contract FactoryViewsTest is HookTestBase {
    function test_factoryViews_resolveThroughTheTokenFactory() public {
        assertEq(hook.factoryOwner(), users.owner, "owner read from the token factory");
        assertEq(hook.factoryTreasury(), users.treasury, "treasury read from the token factory");

        factory.setTreasury(makeAddr("new-treasury"));
        assertEq(hook.factoryTreasury(), makeAddr("new-treasury"), "never cached: follows the factory");
    }
}
