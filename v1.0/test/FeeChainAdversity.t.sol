// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {
    FixedQuoteCalculator,
    GasGuzzlerCalculator,
    OverflowCalculator,
    ReturndataBombCalculator,
    RevertingCalculator
} from "test/helpers/ExtensionMocks.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title FeeChainAdversityTest
/// @notice The cage under fire, through REAL swaps: whatever a bound calculator does — revert,
/// burn gas, bomb returndata, overflow the value — the swap settles, the broken stage is
/// skipped with an S7 signal, and the applied fee stays inside the clamp (base fee when the
/// whole chain is dead, sniper ceiling only inside a declared window).
contract FeeChainAdversityTest is ExtensionCampaignBase {
    uint24 internal constant BASE_FEE = 4000;

    event FeeCalculatorFallback(PoolId indexed poolId, address indexed calculator);

    function _deployWithChain(address[] memory chain) internal returns (MockBCToken deployed, PoolId poolId) {
        return _deployGraduated(_withChain(_emptyConfig(BASE_FEE), chain), false);
    }

    function _singleStage(address stage) internal returns (MockBCToken deployed, PoolId poolId) {
        address[] memory chain = new address[](1);
        chain[0] = stage;
        return _deployWithChain(chain);
    }

    function _assertSwapLandsOnBase(MockBCToken deployed, PoolId poolId, address brokenStage) internal {
        vm.expectEmit(address(hook));
        emit FeeCalculatorFallback(poolId, brokenStage);
        uint256 amountOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertGt(amountOut, 0, "the swap must always settle");
        assertEq(hook.getCurrentFee(poolId), BASE_FEE, "a dead chain lands on the pool's base fee");
    }

    function test_revertingStage_isSkippedAndSignalled() public {
        address broken = address(new RevertingCalculator());
        (MockBCToken deployed, PoolId poolId) = _singleStage(broken);
        _assertSwapLandsOnBase(deployed, poolId, broken);
    }

    function test_gasGuzzlerStage_isCutOffByTheStipend() public {
        address broken = address(new GasGuzzlerCalculator());
        (MockBCToken deployed, PoolId poolId) = _singleStage(broken);
        _assertSwapLandsOnBase(deployed, poolId, broken);
    }

    function test_returndataBombStage_isRejectedUncopied() public {
        address broken = address(new ReturndataBombCalculator());
        (MockBCToken deployed, PoolId poolId) = _singleStage(broken);
        _assertSwapLandsOnBase(deployed, poolId, broken);
    }

    function test_overflowingStage_isRejected() public {
        // A well-formed 32-byte value that does not fit uint24 must be unusable, not truncated.
        address broken = address(new OverflowCalculator());
        (MockBCToken deployed, PoolId poolId) = _singleStage(broken);
        _assertSwapLandsOnBase(deployed, poolId, broken);
    }

    function test_brokenStage_passesItsInputToTheNextStage() public {
        // [broken, fixed 8000]: the broken stage is skipped, the working stage still prices.
        address broken = address(new RevertingCalculator());
        address[] memory chain = new address[](2);
        chain[0] = broken;
        chain[1] = address(new FixedQuoteCalculator(8000));
        (MockBCToken deployed, PoolId poolId) = _deployWithChain(chain);

        vm.expectEmit(address(hook));
        emit FeeCalculatorFallback(poolId, broken);
        _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertEq(hook.getCurrentFee(poolId), 8000, "the surviving stage must still price the swap");
    }

    function test_allFourStagesBroken_everySkipSignalled_baseFeeApplies() public {
        address[] memory chain = new address[](4);
        chain[0] = address(new RevertingCalculator());
        chain[1] = address(new GasGuzzlerCalculator());
        chain[2] = address(new ReturndataBombCalculator());
        chain[3] = address(new OverflowCalculator());
        (MockBCToken deployed, PoolId poolId) = _deployWithChain(chain);

        for (uint256 i; i < 4; ++i) {
            vm.expectEmit(address(hook));
            emit FeeCalculatorFallback(poolId, chain[i]);
        }
        uint256 amountOut = _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertGt(amountOut, 0, "four dead stages cannot block the swap");
        assertEq(hook.getCurrentFee(poolId), BASE_FEE);
    }

    function test_quoteAboveTheCeiling_isClampedOutsideAnyWindow() public {
        // 20% quoted, no sniper window declared: the cage clamps at MAX_HOOK_FEE.
        (MockBCToken deployed, PoolId poolId) = _singleStage(address(new FixedQuoteCalculator(200_000)));
        _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertEq(hook.getCurrentFee(poolId), hook.MAX_HOOK_FEE(), "clamped at the 10% ceiling");
    }

    function test_sniperWindow_raisesTheCeilingThenExpiresForever() public {
        // A declared 1800s window: 40% is chargeable inside it, never after.
        address[] memory chain = new address[](1);
        chain[0] = address(new FixedQuoteCalculator(400_000));
        IFactoryHook.HookConfigV2 memory config = _withChain(_emptyConfig(BASE_FEE), chain);
        config.sniperWindow = 1800;
        (MockBCToken deployed, PoolId poolId) = _deployGraduated(config, false);

        // Inside the window (graduation just happened): the raised ceiling admits the quote.
        _swapEthForCoin(address(deployed), users.buyerTwo, 0.05 ether);
        assertEq(hook.getCurrentFee(poolId), 400_000, "sniper ceiling admits 40% inside the window");

        // One second past the window: the quote is clamped back to the 10% cap, forever.
        skip(1801);
        _swapEthForCoin(address(deployed), users.buyerThree, 0.05 ether);
        assertEq(hook.getCurrentFee(poolId), hook.MAX_HOOK_FEE(), "past the window, never above 10% again");
    }
}
