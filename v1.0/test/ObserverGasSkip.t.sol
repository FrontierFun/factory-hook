// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {MinimalObserver} from "test/helpers/ExtensionMocks.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title ObserverGasSkipTest
/// @notice Settles whether a malicious swapper can gas-limit their tx to complete the swap while
/// skipping an observer. If no gas cap yields "swap succeeds AND observer
/// not notified", the EVM's 63/64 rule + the shared budget cap already prevent the attack — and
/// an observer cannot be skipped by under-gassing.
contract ObserverGasSkipTest is ExtensionCampaignBase {
    uint24 internal constant BASE_FEE = 4000;

    function test_swapperCannotSkipABestEffortObserver_byGasLimiting() public {
        MinimalObserver observer = new MinimalObserver();
        IFactoryHook.HookConfigV2 memory config = _emptyConfig(BASE_FEE);
        config.observers = new IFactoryHook.ObserverConfig[](1);
        config.observers[0] = IFactoryHook.ObserverConfig({
            observer: address(observer), calls: uint8(hook.CALL_AFTER_SWAP()), config: ""
        });
        (MockBCToken coin,) = _deployGraduated(config, false);

        uint256 amountIn = 0.01 ether;
        uint256 firstSuccess = 0;
        bool foundSkip = false;

        // Sweep gas caps finely across the revert/success boundary (min success ~200k for a
        // cheap observer). At every cap, capture (success, notified) under a snapshot.
        for (uint256 cap = 120_000; cap <= 500_000; cap += 2000) {
            uint256 snap = vm.snapshot();
            bool ok = _swapWithGasCap(address(coin), users.buyerTwo, amountIn, cap);
            uint256 count = observer.count(); // 0 if the inner swap reverted (state rolled back)
            vm.revertTo(snap);

            if (ok) {
                if (firstSuccess == 0) firstSuccess = cap;
                if (count == 0) foundSkip = true; // swap succeeded but the observer never ran
            }
        }

        emit log_named_uint("min successful gas cap", firstSuccess);
        assertGt(firstSuccess, 0, "some cap must succeed (sanity)");
        assertFalse(foundSkip, "no gas cap lets a swap succeed while skipping the observer");
    }
}
