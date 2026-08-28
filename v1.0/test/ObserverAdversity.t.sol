// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {
    FixedQuoteCalculator,
    GreedyObserver,
    MinimalObserver,
    NestedSwapObserver,
    NestedUnlockObserver,
    RecordingObserver,
    RevertingObserver
} from "test/helpers/ExtensionMocks.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title ObserverAdversityTest
/// @notice Observers through REAL swaps: correct notifications on the nominal path, and the
/// powerlessness guarantees under fire — a greedy observer starves only its successors, a
/// reverting one is ignored, reentry into the PoolManager is impossible, hookData is
/// length-bounded, and the swap always settles.
contract ObserverAdversityTest is ExtensionCampaignBase {
    uint24 internal constant BASE_FEE = 4000;
    uint256 internal constant FEE_DENOMINATOR = 1e6;

    function _deployWithObservers(address[] memory observers, uint8 calls)
        internal
        returns (MockBCToken deployed, PoolId poolId)
    {
        return _deployGraduated(_withObservers(_emptyConfig(BASE_FEE), observers, calls), false);
    }

    function _single(address observer, uint8 calls) internal returns (MockBCToken deployed, PoolId poolId) {
        address[] memory observers = new address[](1);
        observers[0] = observer;
        return _deployWithObservers(observers, calls);
    }

    function test_afterSwap_notifiedWithTheRealFeeFigures() public {
        RecordingObserver observer = new RecordingObserver();
        (MockBCToken deployed, PoolId poolId) = _single(address(observer), uint8(hook.CALL_AFTER_SWAP()));

        uint256 amountIn = 0.1 ether;
        _swapEthForCoin(address(deployed), users.buyerTwo, amountIn);

        assertEq(observer.afterSwapCount(), 1, "one swap, one notification");
        assertEq(PoolId.unwrap(observer.lastPoolId()), PoolId.unwrap(poolId));
        assertEq(observer.lastFeeRate(), BASE_FEE, "notified with the applied total rate");
        // Exact-in ETH leg: the non-LP fee amount the hook actually charged.
        uint256 expectedFee = amountIn * (BASE_FEE * (10_000 - uint256(uint256(7000))) / 10_000) / FEE_DENOMINATOR;
        assertEq(observer.lastFeeAmount(), expectedFee, "notified with the charged fee amount");
        assertEq(observer.lastHookData().length, 0, "empty hookData passes through empty");
    }

    function test_feeChange_notifiedOnRegimeChangeOnly() public {
        // A pool whose chain quotes a fee distinct from its base fee: the FIRST swap moves the
        // applied fee 2500 -> 3000 (regime change), a second quiet swap does not. (The original
        // suite binds `DynamicFeeExtension`, whose curve floor is 3000; a fixed 3000 quote gives
        // the hook the same regime change without the extension.)
        FixedQuoteCalculator ext = new FixedQuoteCalculator(3000);
        RecordingObserver observer = new RecordingObserver();

        address[] memory chain = new address[](1);
        chain[0] = address(ext);
        address[] memory observers = new address[](1);
        observers[0] = address(observer);
        IFactoryHook.HookConfigV2 memory config =
            _withObservers(_withChain(_emptyConfig(2500), chain), observers, uint8(hook.CALL_FEE_CHANGE()));
        (MockBCToken deployed,) = _deployGraduated(config, false);

        _swapEthForCoin(address(deployed), users.buyerTwo, 0.001 ether);
        assertEq(observer.feeChangeCount(), 1, "first swap changes the regime");
        assertEq(observer.lastPreviousFee(), 2500, "from the registration seed");
        assertEq(observer.lastNewFee(), 3000, "to the chain's quote");

        _swapEthForCoin(address(deployed), users.buyerTwo, 0.001 ether);
        assertEq(observer.feeChangeCount(), 1, "same regime, no second notification");
        assertEq(observer.afterSwapCount(), 0, "CALL_AFTER_SWAP not subscribed");
    }

    function test_greedyObserver_starvesOnlyItsSuccessors() public {
        // Binding order is the creator's choice: the greedy observer burns the shared budget,
        // the recorder behind it is skipped, the swap settles regardless.
        RecordingObserver recorder = new RecordingObserver();
        address[] memory observers = new address[](2);
        observers[0] = address(new GreedyObserver());
        observers[1] = address(recorder);
        (MockBCToken deployed,) = _deployWithObservers(observers, uint8(hook.CALL_AFTER_SWAP()));

        uint256 amountOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertGt(amountOut, 0, "the swap must settle whatever the observers burn");
        assertEq(recorder.afterSwapCount(), 0, "the successor was starved of budget");
    }

    function test_revertingObserver_isIgnored_successorsStillNotified() public {
        RecordingObserver recorder = new RecordingObserver();
        address[] memory observers = new address[](2);
        observers[0] = address(new RevertingObserver());
        observers[1] = address(recorder);
        (MockBCToken deployed,) = _deployWithObservers(observers, uint8(hook.CALL_AFTER_SWAP()));

        _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertEq(recorder.afterSwapCount(), 1, "a cheap revert must not starve the next observer");
    }

    function test_nestedUnlock_reverts_andIsIgnored() public {
        // The one reentrancy fact that IS blocked: a nested `unlock` reverts (AlreadyUnlocked),
        // so the observer's call reverts and the hook ignores it. A nested `swap` is a different
        // story — see the two tests below.
        NestedUnlockObserver observer = new NestedUnlockObserver(address(poolManager));
        (MockBCToken deployed,) = _single(address(observer), uint8(hook.CALL_AFTER_SWAP()));

        uint256 amountOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertGt(amountOut, 0, "the swap settles");
        assertFalse(observer.reentered(), "a nested unlock reverts");
    }

    function test_nestedSwap_thatSettles_isIsolated_outerFillUnchanged() public {
        // V4 permits a nested swap during the notification (swap is onlyWhenUnlocked). An
        // observer that fully settles it cannot touch the outer swap: per-address delta
        // accounting isolates it, so the outer buyer's fill is byte-identical to the
        // observer-free control, and the hook holds no residue.
        NestedSwapObserver observer = new NestedSwapObserver(address(poolManager), 0.001 ether, true);
        vm.deal(address(observer), 1 ether);
        (MockBCToken deployed,) = _single(address(observer), uint8(hook.CALL_AFTER_SWAP()));
        observer.arm(_poolKey(address(deployed)));

        // Control: the same outer swap on a coin with NO observer bound.
        (MockBCToken control,) = _deployGraduated(_emptyConfig(BASE_FEE), false);
        uint256 controlSnap = vm.snapshot();
        uint256 controlOut = _swapEthForCoin(address(control), users.buyerTwo, 0.05 ether);
        vm.revertTo(controlSnap);

        uint256 outerOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);

        assertEq(observer.swaps(), 1, "the nested swap ran exactly once");
        assertGt(IERC20(address(deployed)).balanceOf(address(observer)), 0, "observer paid its own way, got coin");
        assertEq(outerOut, controlOut, "the outer fill is unchanged by the observer's nested swap");
        assertEq(address(hook).balance, 0, "no native residue on the hook");
        assertEq(weth.balanceOf(address(hook)), 0, "no WETH residue on the hook");
    }

    function test_nestedSwap_withoutSettling_abortsTheSwap_dosBoundedToOwnPool() public {
        // The one residual power: a nested swap left UNSETTLED makes the outer unlock revert
        // (CurrencyNotSettled). This is a DoS, not extraction — and bounded to the observer's own
        // pool (bindings are per-pool). A second coin with no such observer keeps trading.
        NestedSwapObserver observer = new NestedSwapObserver(address(poolManager), 0.001 ether, false);
        vm.deal(address(observer), 1 ether);
        (MockBCToken deployed,) = _single(address(observer), uint8(hook.CALL_AFTER_SWAP()));
        observer.arm(_poolKey(address(deployed)));

        // Every swap on this pool now aborts — the leftover delta trips the unlock's settlement
        // check.
        _swapEthForCoinExpectRevert(address(deployed), users.buyerTwo, 0.05 ether);

        // Blast radius is that pool only: a sibling coin without the observer trades fine.
        (MockBCToken healthy,) = _deployGraduated(_emptyConfig(BASE_FEE), false);
        assertGt(_swapEthForCoin(address(healthy), users.buyerThree, 0.05 ether), 0, "sibling pool unaffected");
    }

    function test_hookData_lengthBounded() public {
        RecordingObserver observer = new RecordingObserver();
        (MockBCToken deployed,) = _single(address(observer), uint8(hook.CALL_AFTER_SWAP()));

        // Within the bound: passed through verbatim.
        bytes memory small = new bytes(100);
        small[0] = 0xAB;
        _swapEthForCoinWithHookData(address(deployed), users.buyerTwo, 0.01 ether, small);
        assertEq(observer.lastHookData(), small, "in-bound hookData passes verbatim");

        // Past MAX_HOOKDATA_BYTES: treated as absent, never forwarded.
        _swapEthForCoinWithHookData(address(deployed), users.buyerTwo, 0.01 ether, new bytes(300));
        assertEq(observer.lastHookData().length, 0, "oversized hookData is dropped");
    }

    function test_maxConfiguration_swapSettles_lightObserversAllServed() public {
        // The gas envelope: a maxed-out pool (4 calculators + 8 observers) still swaps, and the
        // shared 600k budget comfortably serves 8 light observers.
        address[] memory chain = new address[](4);
        for (uint256 i; i < 4; ++i) {
            chain[i] = address(new FixedQuoteCalculator(uint24(3000 + i * 100)));
        }
        MinimalObserver[8] memory recorders;
        address[] memory observers = new address[](8);
        for (uint256 i; i < 8; ++i) {
            recorders[i] = new MinimalObserver();
            observers[i] = address(recorders[i]);
        }
        IFactoryHook.HookConfigV2 memory config = _withObservers(
            _withChain(_emptyConfig(BASE_FEE), chain), observers, uint8(hook.CALL_AFTER_SWAP() | hook.CALL_FEE_CHANGE())
        );
        (MockBCToken deployed, PoolId poolId) = _deployGraduated(config, false);

        uint256 gasBefore = gasleft();
        uint256 amountOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("max-config swap gas (whole router call)", gasUsed);

        assertGt(amountOut, 0, "max-config pool must swap");
        assertEq(hook.getCurrentFee(poolId), 3300, "last chain stage priced the swap");
        // First swap of the pool: applied fee moves 4000 (seed) -> 3300, a regime change, so
        // both notifications fire on every observer (16 calls) under the shared 600k budget.
        for (uint256 i; i < 8; ++i) {
            assertEq(recorders[i].count(), 2, "every light observer served both notifications");
        }
    }
}
