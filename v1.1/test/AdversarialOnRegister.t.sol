// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {
    FixedQuoteCalculator,
    PorousExtension,
    RecordingObserver,
    ReentrantRegisterExtension
} from "test/helpers/ExtensionMocks.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title AdversarialOnRegisterTest
/// @notice The registration threat model: S2 (onRegister runs arbitrary code inside the deploy
/// transaction — reentering `registerPool` must die on the transient lock) and S1 (pool ids are
/// predictable pre-deploy — a non-gated extension can be poisoned ahead of the legitimate
/// call, which is exactly why the official extensions gate on the hook). The original suite's
/// `DynamicFeeExtension` cases (the gated official extension) are outside this hook-only package.
contract AdversarialOnRegisterTest is ExtensionCampaignBase {
    function _noStaking() internal pure returns (IBCTokenFactory.StakingConfig memory) {
        return IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)});
    }

    function test_S2_reentrantRegisterPool_failsTheWholeDeploy() public {
        address[] memory chain = new address[](1);
        chain[0] = address(new ReentrantRegisterExtension());
        IFactoryHook.HookConfigV2 memory config = _withChain(_emptyConfig(3000), chain);

        MockBCToken reentrant = _newCoin("Reentrant", "REENT");
        vm.expectRevert();
        _registerCoin(reentrant, 50, _noStaking(), _payload(config));
    }

    function test_S2_lockClears_nextDeploySucceeds() public {
        // The failed reentrant deploy reverts atomically, transient lock included: an honest
        // deploy right after must be unaffected.
        test_S2_reentrantRegisterPool_failsTheWholeDeploy();
        (MockBCToken deployed,) = _deployGraduated(_emptyConfig(3000), false);
        assertTrue(deployed.isLPd(), "the lock left no residue");
    }

    function test_S1_porousExtension_isPoisonableAheadOfTheDeploy() public {
        // The harm S1 warns about, demonstrated end to end on a NON-gated extension. Pool ids
        // are predictable pre-deploy (deterministic coin address): learn it, rewind, poison, redeploy.
        PorousExtension porous = new PorousExtension();
        address[] memory chain = new address[](1);
        chain[0] = address(porous);
        IFactoryHook.HookConfigV2 memory config = _withChain(_emptyConfig(3000), chain);

        uint256 snapshot = vm.snapshot();
        (, PoolId predictedPoolId) = _deployGraduated(config, false);
        vm.revertTo(snapshot);

        // The attacker registers the predicted id first — the porous extension lets anyone.
        address attacker = makeAddr("s1-attacker");
        vm.prank(attacker);
        porous.onRegisterCalculator(predictedPoolId, "");

        // The legitimate deploy now dies inside its own transaction: the extension's write-once
        // guard fires against the attacker's slot. A poisoned binding is a bricked deploy.
        MockBCToken legit = _newCoin(string.concat("Campaign ", vm.toString(campaignSaltNonce)), "CAMP");
        assertEq(PoolId.unwrap(_poolId(address(legit))), PoolId.unwrap(predictedPoolId), "same predicted pool");
        vm.expectRevert();
        _registerCoin(legit, 50, _noStaking(), _payload(config));
    }

    function test_roleSelectors_calculatorBoundAsObserver_failsTheDeploy() public {
        // A calculator listed in `observers`: it does not implement `onRegisterObserver`, so the
        // hook's registration call reverts and the deploy dies — a role mix-up (which would
        // otherwise ship a dead binding that burns observer budget every swap) cannot ship.
        FixedQuoteCalculator calculatorExt = new FixedQuoteCalculator(3000);
        address[] memory observers = new address[](1);
        observers[0] = address(calculatorExt);
        IFactoryHook.HookConfigV2 memory config =
            _withObservers(_emptyConfig(3000), observers, uint8(hook.CALL_FEE_CHANGE()));

        MockBCToken wrongRole = _newCoin("Wrong role", "ROLE");
        vm.expectRevert();
        _registerCoin(wrongRole, 50, _noStaking(), _payload(config));
    }

    function test_roleSelectors_observerBoundAsCalculator_failsTheDeploy() public {
        // The mirror image: an observer listed in `feeCalculators` lacks `onRegisterCalculator`
        // and dies the same way.
        address[] memory chain = new address[](1);
        chain[0] = address(new RecordingObserver());
        IFactoryHook.HookConfigV2 memory config = _withChain(_emptyConfig(3000), chain);

        MockBCToken wrongRole = _newCoin("Wrong role 2", "ROLE2");
        vm.expectRevert();
        _registerCoin(wrongRole, 50, _noStaking(), _payload(config));
    }
}
