// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {FixedQuoteCalculator, RecordingObserver} from "test/helpers/ExtensionMocks.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title RegistrationEventsTest
/// @notice The self-documenting registration events through the REAL pipeline:
/// - `CalculatorConfigured` / `ObserverConfigured` on the hook carry each binding's RAW
///   config sub-payload at `registerPool` — the bytes' only on-chain record (the hook never
///   stores them), so indexers capture configs generically and decode off-chain per catalog.
/// - `FeeRecipientAssigned` on the factory states the coin's BIRTH fee recipient, emitted
///   ALWAYS (`address(0)` = creator fallback) so "no event" is never ambiguous with
///   "not yet indexed".
contract RegistrationEventsTest is ExtensionCampaignBase {
    bytes32 internal constant CALCULATOR_CONFIGURED_SIG = keccak256("CalculatorConfigured(bytes32,address,bytes)");
    bytes32 internal constant OBSERVER_CONFIGURED_SIG = keccak256("ObserverConfigured(bytes32,address,bytes)");

    /// @dev Deploys a coin while recording logs; returns the deployed coin and the logs.
    function _deployRecorded(IFactoryHook.HookConfigV2 memory config, address alternativeFeeRecipient, bytes32 salt)
        internal
        returns (MockBCToken deployed, Vm.Log[] memory logs)
    {
        vm.recordLogs();
        deployed = _deployCoin(
            string.concat("Events Coin ", vm.toString(salt)),
            "EVNT",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: alternativeFeeRecipient}),
            _payload(config)
        );
        logs = vm.getRecordedLogs();
    }

    /// @dev Finds the single log with `sig` emitted by `emitter` (fails the test if not exactly one).
    function _single(Vm.Log[] memory logs, bytes32 sig, address emitter) internal pure returns (Vm.Log memory found) {
        uint256 hits;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == sig) {
                found = logs[i];
                hits++;
            }
        }
        require(hits == 1, "expected exactly one matching log");
    }

    function test_registerPool_emitsRawConfigPerBinding() public {
        // One calculator and one observer, each with a distinctive raw sub-payload the mocks
        // ignore — proving the bytes pass through verbatim, accepted-then-emitted.
        address calculator = address(new FixedQuoteCalculator(5000));
        address observer = address(new RecordingObserver());
        bytes memory calculatorConfig = abi.encode(uint256(0xC0FFEE), uint256(42));
        bytes memory observerConfig = abi.encode(uint256(0xBEEF));

        IFactoryHook.HookConfigV2 memory config = _emptyConfig(4000);
        config.feeCalculators = new address[](1);
        config.feeCalculators[0] = calculator;
        config.calculatorConfigs = new bytes[](1);
        config.calculatorConfigs[0] = calculatorConfig;
        config.observers = new IFactoryHook.ObserverConfig[](1);
        config.observers[0] = IFactoryHook.ObserverConfig({
            observer: observer, calls: uint8(hook.CALL_AFTER_SWAP()), config: observerConfig
        });

        (MockBCToken deployed, Vm.Log[] memory logs) =
            _deployRecorded(config, address(0), keccak256("events-raw-config"));
        PoolId poolId = _poolId(address(deployed));

        Vm.Log memory calcLog = _single(logs, CALCULATOR_CONFIGURED_SIG, address(hook));
        assertEq(calcLog.topics[1], PoolId.unwrap(poolId), "calculator event keyed by poolId");
        assertEq(address(uint160(uint256(calcLog.topics[2]))), calculator, "calculator address indexed");
        assertEq(abi.decode(calcLog.data, (bytes)), calculatorConfig, "raw calculator sub-payload verbatim");

        Vm.Log memory obsLog = _single(logs, OBSERVER_CONFIGURED_SIG, address(hook));
        assertEq(obsLog.topics[1], PoolId.unwrap(poolId), "observer event keyed by poolId");
        assertEq(address(uint160(uint256(obsLog.topics[2]))), observer, "observer address indexed");
        assertEq(abi.decode(obsLog.data, (bytes)), observerConfig, "raw observer sub-payload verbatim");
    }

    function test_registerPool_emptyPayload_emitsNoConfigEvents() public {
        // No custom payload -> no bindings -> no config events (and no spurious ones).
        (, Vm.Log[] memory logs) = _deployRecorded(_emptyConfig(3000), address(0), keccak256("events-no-config"));
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != CALCULATOR_CONFIGURED_SIG, "no calculator event");
            assertTrue(logs[i].topics[0] != OBSERVER_CONFIGURED_SIG, "no observer event");
        }
    }
}
