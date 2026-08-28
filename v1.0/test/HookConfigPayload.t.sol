// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {HookTestBase} from "test/helpers/HookTestBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @notice Extension stub accepting any binding in either role; records the registration call
/// so tests can assert the hook called the role-specific registration inside the deploy
/// transaction (a normal call, so the stub may write state — unlike `quoteFee`, which runs
/// under staticcall).
contract ExtensionStub {
    uint256 public registerCount;
    PoolId public lastPoolId;
    bytes public lastConfig;

    function onRegisterCalculator(PoolId poolId, bytes calldata config) external {
        _record(poolId, config);
    }

    function onRegisterObserver(PoolId poolId, bytes calldata config) external {
        _record(poolId, config);
    }

    function _record(PoolId poolId, bytes calldata config) internal {
        registerCount++;
        lastPoolId = poolId;
        lastConfig = config;
    }

    function quoteFee(PoolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        pure
        returns (uint24)
    {
        return previousFee;
    }

    function onAfterSwap(PoolId, int256, uint24, uint256, bytes calldata) external {}
    function onFeeChange(PoolId, uint24, uint24) external {}
}

/// @notice An extension whose registration reverts — binding it must fail the whole deploy.
contract RevertingOnRegisterStub {
    error Rejected();

    function onRegisterCalculator(PoolId, bytes calldata) external pure {
        revert Rejected();
    }
}

/// @title HookConfigPayloadTest
/// @notice Step-2 coverage of the creator hook payload (schema v2): strict validation in the
/// deploy transaction, the applied per-pool fee pipeline (base fee, calculator chain, sniper
/// window, observers), extension registration, the unconditional protocol floor on a zero-fee
/// pool, and the `lpdAt` graduation anchor (Q16). The payload travels
/// `deploy -> BCToken -> LiquidityManager -> registerPool` and is interpreted only by the hook, so
/// every case here drives the real `registerPool` + `initialize` step through `_deployCoin`.
contract HookConfigPayloadTest is HookTestBase {
    using StateLibrary for IPoolManager;

    uint256 internal saltNonce;

    /// @dev Encodes a schema-v2 payload: version byte + one abi-encoded HookConfigV2.
    function _payload(IFactoryHook.HookConfigV2 memory config) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(2), abi.encode(config));
    }

    /// @dev A pipeline-free config carrying only a base fee.
    function _bareConfig(uint24 fixedFee) internal pure returns (IFactoryHook.HookConfigV2 memory) {
        return IFactoryHook.HookConfigV2({
            fixedFee: fixedFee,
            lpShareBps: 7000,
            feeCalculators: new address[](0),
            calculatorConfigs: new bytes[](0),
            sniperWindow: 0,
            observers: new IFactoryHook.ObserverConfig[](0)
        });
    }

    function _fixedTier(uint24 tier) internal pure returns (bytes memory) {
        return _payload(_bareConfig(tier));
    }

    function _deployWith(bytes memory hookConfig) internal returns (MockBCToken) {
        string memory name = string.concat("Payload ", vm.toString(saltNonce++));
        return _deployCoin(
            name,
            "PAY",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: true, alternativeFeeRecipient: address(0)}),
            hookConfig
        );
    }

    /// @dev `registerPool` rejects the payload inside the atomic registration step, so only
    /// revert-happens is assertable; the coin is created first because a CREATE would consume
    /// the armed `expectRevert`.
    function _expectDeployReverts(bytes memory hookConfig) internal {
        MockBCToken rejected = _newCoin(string.concat("Payload ", vm.toString(saltNonce++)), "PAY");
        vm.expectRevert();
        _registerCoin(
            rejected,
            50,
            IBCTokenFactory.StakingConfig({deployStaking: true, alternativeFeeRecipient: address(0)}),
            hookConfig
        );
    }
}

contract PayloadValidationTest is HookConfigPayloadTest {
    event FixedFeeChanged(PoolId indexed poolId, uint24 fixedFee);

    function test_emptyPayload_appliesProtocolDefaults() public {
        MockBCToken freshCoin = _deployWith(bytes(""));
        IFactoryHook.PoolState memory state = hook.getPoolState(_poolId(address(freshCoin)));

        assertEq(state.fixedFee, hook.DEFAULT_FIXED_FEE(), "base fee default");
        assertEq(state.lastAppliedFee, hook.DEFAULT_FIXED_FEE(), "applied fee seeded with default");
        assertEq(state.sniperWindow, 0, "no sniper window");
        assertEq(state.feeCalculators.length, 0, "no fee chain");
        assertEq(state.observers.length, 0, "no observers");
        assertEq(hook.getCurrentFee(_poolId(address(freshCoin))), hook.DEFAULT_FIXED_FEE(), "current fee default");
    }

    function test_fixedTier_appliesAndEmits() public {
        uint24 tier = 10_000; // 1%
        // Topic-only check on poolId: it is unknown before the deploy computes it.
        vm.expectEmit(false, false, false, true, address(hook));
        emit FixedFeeChanged(PoolId.wrap(bytes32(0)), tier);
        MockBCToken freshCoin = _deployWith(_fixedTier(tier));

        IFactoryHook.PoolState memory state = hook.getPoolState(_poolId(address(freshCoin)));
        assertEq(state.fixedFee, tier, "base fee applied");
        assertEq(state.lastAppliedFee, tier, "applied fee seeded with the tier");
        assertEq(hook.getCurrentFee(_poolId(address(freshCoin))), tier, "current fee is the tier");
    }

    function test_pipelineBinding_storesChainAndObservers_andRegistersExtensions() public {
        ExtensionStub calculator = new ExtensionStub();
        ExtensionStub observer = new ExtensionStub();

        IFactoryHook.HookConfigV2 memory config = _bareConfig(5000);
        config.feeCalculators = new address[](1);
        config.feeCalculators[0] = address(calculator);
        config.calculatorConfigs = new bytes[](1);
        config.calculatorConfigs[0] = hex"c0ffee";
        config.sniperWindow = 1800;
        config.observers = new IFactoryHook.ObserverConfig[](1);
        config.observers[0] = IFactoryHook.ObserverConfig({
            observer: address(observer),
            calls: uint8(hook.CALL_AFTER_SWAP() | hook.CALL_FEE_CHANGE()),
            config: hex"beef"
        });

        MockBCToken freshCoin = _deployWith(_payload(config));
        PoolId freshPoolId = _poolId(address(freshCoin));
        IFactoryHook.PoolState memory state = hook.getPoolState(freshPoolId);

        assertEq(state.fixedFee, 5000);
        assertEq(state.sniperWindow, 1800);
        assertEq(state.feeCalculators.length, 1);
        assertEq(state.feeCalculators[0], address(calculator));
        assertEq(state.observers.length, 1);
        assertEq(state.observers[0].observer, address(observer));
        assertEq(state.observers[0].calls, hook.CALL_AFTER_SWAP() | hook.CALL_FEE_CHANGE());

        // Both extensions were registered in the deploy transaction, with their sub-payloads.
        assertEq(calculator.registerCount(), 1, "calculator registration called once");
        assertEq(PoolId.unwrap(calculator.lastPoolId()), PoolId.unwrap(freshPoolId));
        assertEq(calculator.lastConfig(), hex"c0ffee");
        assertEq(observer.registerCount(), 1, "observer registration called once");
        assertEq(observer.lastConfig(), hex"beef");
    }

    function test_revertingOnRegister_failsTheDeploy() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(5000);
        config.feeCalculators = new address[](1);
        config.feeCalculators[0] = address(new RevertingOnRegisterStub());
        config.calculatorConfigs = new bytes[](1);
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_unknownVersion() public {
        bytes memory body = abi.encode(_bareConfig(3000));
        _expectDeployReverts(abi.encodePacked(uint8(0), body));
        _expectDeployReverts(abi.encodePacked(uint8(1), body));
        _expectDeployReverts(abi.encodePacked(uint8(3), body));
    }

    function test_revertsIf_wrongLength() public {
        _expectDeployReverts(abi.encodePacked(uint8(2)));
        _expectDeployReverts(abi.encodePacked(uint8(2), uint256(0)));
        bytes memory valid = _fixedTier(3000);
        _expectDeployReverts(abi.encodePacked(valid, uint8(0)));
    }

    function test_revertsIf_fixedTierAboveCap() public {
        _expectDeployReverts(_fixedTier(uint24(hook.MAX_HOOK_FEE()) + 1));
    }

    function test_revertsIf_tooManyCalculators() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        uint256 tooMany = hook.MAX_FEE_CALCULATORS() + 1;
        config.feeCalculators = new address[](tooMany);
        config.calculatorConfigs = new bytes[](tooMany);
        for (uint256 i; i < tooMany; ++i) {
            config.feeCalculators[i] = address(new ExtensionStub());
        }
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_calculatorConfigArityMismatch() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        config.feeCalculators = new address[](1);
        config.feeCalculators[0] = address(new ExtensionStub());
        config.calculatorConfigs = new bytes[](2);
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_zeroCalculatorAddress() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        config.feeCalculators = new address[](1);
        config.calculatorConfigs = new bytes[](1);
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_tooManyObservers() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        uint256 tooMany = hook.MAX_OBSERVERS() + 1;
        config.observers = new IFactoryHook.ObserverConfig[](tooMany);
        for (uint256 i; i < tooMany; ++i) {
            config.observers[i] =
                IFactoryHook.ObserverConfig({observer: address(new ExtensionStub()), calls: 1, config: ""});
        }
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_observerBitsInvalid() public {
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        config.observers = new IFactoryHook.ObserverConfig[](1);

        // No call bits: a bound observer that would never be notified is a payload mistake.
        config.observers[0] =
            IFactoryHook.ObserverConfig({observer: address(new ExtensionStub()), calls: 0, config: ""});
        _expectDeployReverts(_payload(config));

        // Unknown bit outside CALL_AFTER_SWAP | CALL_FEE_CHANGE.
        config.observers[0].calls = 4;
        _expectDeployReverts(_payload(config));

        // Zero observer address.
        config.observers[0] = IFactoryHook.ObserverConfig({observer: address(0), calls: 1, config: ""});
        _expectDeployReverts(_payload(config));
    }

    function test_revertsIf_sniperWindowInvalid() public {
        // A sniper window with no calculator chain: nothing could ever use the raised ceiling.
        IFactoryHook.HookConfigV2 memory config = _bareConfig(3000);
        config.sniperWindow = 600;
        _expectDeployReverts(_payload(config));

        // Above the global bound, even with a chain.
        config.feeCalculators = new address[](1);
        config.feeCalculators[0] = address(new ExtensionStub());
        config.calculatorConfigs = new bytes[](1);
        config.sniperWindow = hook.MAX_SNIPER_WINDOW() + 1;
        _expectDeployReverts(_payload(config));
    }

    function test_fixedTierAtCap_andZero_areValid() public {
        MockBCToken atCap = _deployWith(_fixedTier(uint24(hook.MAX_HOOK_FEE())));
        assertEq(hook.getCurrentFee(_poolId(address(atCap))), hook.MAX_HOOK_FEE(), "cap tier applies");

        MockBCToken zeroFee = _deployWith(_fixedTier(0));
        assertEq(hook.getCurrentFee(_poolId(address(zeroFee))), 0, "zero tier applies");
    }
}

contract PayloadFuzzTest is HookConfigPayloadTest {
    /// @notice Any non-empty payload either reverts the deploy or leaves the pool with a fee
    /// pipeline inside the hook's own bounds — no payload can smuggle an out-of-band fee.
    function testFuzz_arbitraryPayload_rejectedOrBounded(bytes calldata raw) public {
        vm.assume(raw.length > 0 && raw.length <= 512);

        MockBCToken fuzzed = _newCoin("Fuzzed", "FUZ");
        try this.registerAndInitialize(
            _poolKey(address(fuzzed)),
            address(fuzzed),
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            raw
        ) {
            IFactoryHook.PoolState memory state = hook.getPoolState(_poolId(address(fuzzed)));
            assertLe(state.fixedFee, hook.MAX_HOOK_FEE(), "base fee <= MAX_HOOK_FEE");
            assertLe(state.feeCalculators.length, hook.MAX_FEE_CALCULATORS(), "chain bounded");
            assertLe(state.observers.length, hook.MAX_OBSERVERS(), "observers bounded");
            assertLe(state.sniperWindow, hook.MAX_SNIPER_WINDOW(), "sniper window bounded");
            if (state.sniperWindow != 0) {
                assertGt(state.feeCalculators.length, 0, "sniper window requires a chain");
            }
        } catch {
            // Rejected payload: the deploy reverted atomically, nothing registered.
        }
    }
}

contract ZeroFeePoolFloorTest is HookConfigPayloadTest {
    MockBCToken internal zeroCoin;
    PoolId internal zeroPoolId;

    function setUp() public override {
        super.setUp();
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);

        zeroCoin = _deployWith(_fixedTier(0));
        zeroPoolId = _poolId(address(zeroCoin));
        _graduate(zeroCoin);
    }

    /// @notice Q18 end to end on the payload path: a creator-configured zero-fee pool still
    /// costs the trader exactly the protocol floor, all of it to the protocol treasury — LPs,
    /// vault and creator get nothing.
    function test_zeroFeePool_exactIn_paysExactlyTheFloorToTheProtocol() public {
        uint256 amountIn = 0.1 ether;
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 creatorBefore = weth.balanceOf(zeroCoin.getFeeRecipient());
        address vault = hook.getPoolState(zeroPoolId).stakingVault;
        uint256 vaultBefore = weth.balanceOf(vault);

        uint256 amountOut = _swapEthForCoin(address(zeroCoin), users.buyerTwo, amountIn);
        assertGt(amountOut, 0, "swap settles");

        assertEq(
            weth.balanceOf(users.treasury) - treasuryBefore,
            amountIn * uint256(hook.PROTOCOL_FLOOR_PIPS()) / 1e6,
            "protocol gets exactly the floor"
        );
        assertEq(weth.balanceOf(zeroCoin.getFeeRecipient()), creatorBefore, "creator gets nothing");
        assertEq(weth.balanceOf(vault), vaultBefore, "vault gets nothing");
        assertEq(address(hook).balance, 0, "no native residue");
        assertEq(weth.balanceOf(address(hook)), 0, "no WETH residue");
    }

    /// @notice The same floor guarantee on the exact-output path, via the fee-inclusive
    /// identity `fee = totalPaid * floor / 1e6`.
    function test_zeroFeePool_exactOut_paysExactlyTheFloorToTheProtocol() public {
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 buyerBefore = users.buyerTwo.balance;

        PoolKey memory key = _poolKey(address(zeroCoin));
        vm.prank(users.buyerTwo);
        swapRouter.swap{value: 1 ether}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: int256(1_000_000e18), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 totalPaid = buyerBefore - users.buyerTwo.balance;
        assertApproxEqAbs(
            weth.balanceOf(users.treasury) - treasuryBefore,
            totalPaid * uint256(hook.PROTOCOL_FLOOR_PIPS()) / 1e6,
            1,
            "protocol gets exactly the floor share of the total paid"
        );
    }
}
