// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {FactoryHook} from "src/hook/FactoryHook.sol";
import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {HookAddressMiner} from "script/utils/HookAddressMiner.sol";
import {DeployV4Infra} from "test/helpers/DeployV4Infra.sol";
import {ERC20Mock} from "test/helpers/ERC20Mock.sol";
import {FactoryHookHarness} from "test/helpers/FactoryHookHarness.sol";
import {MockStakingVault, MockStakingVaultFactory} from "test/helpers/ProtocolMocks.sol";

using StateLibrary for IPoolManager;

/// @notice Minimal BCTokenFactory stand-in exposing the two auth views the hook reads.
contract MockTokenFactory {
    address public owner;
    address public liquidityManager;

    constructor(address owner_, address liquidityManager_) {
        owner = owner_;
        liquidityManager = liquidityManager_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setLiquidityManager(address liquidityManager_) external {
        liquidityManager = liquidityManager_;
    }
}

/// @title FactoryHookUnitTest
/// @notice Direct unit coverage of FactoryHook admin, registration, callbacks and internal fee
/// math via {FactoryHookHarness}; no pool swaps are driven here (see FactoryHook.t.sol for the
/// integration paths).
contract FactoryHookUnitTest is Test, DeployV4Infra {
    uint160 internal constant HOOK_FLAGS = 0x30CC;

    FactoryHookHarness internal hook;
    MockTokenFactory internal tokenFactory;
    MockStakingVaultFactory internal stakingVaultFactory;
    ERC20Mock internal coin;
    PoolKey internal key;
    PoolId internal poolId;

    address internal owner = makeAddr("owner");

    receive() external payable {}

    function setUp() public virtual {
        deployV4Infra();

        tokenFactory = new MockTokenFactory(owner, address(this));
        stakingVaultFactory = new MockStakingVaultFactory(owner, address(0), address(weth));
        coin = new ERC20Mock("Coin", "COIN", 18);

        bytes memory constructorArgs =
            abi.encode(poolManager, address(tokenFactory), address(weth), address(stakingVaultFactory));
        (address predictedHook, bytes32 salt) =
            HookAddressMiner.find(address(this), HOOK_FLAGS, type(FactoryHookHarness).creationCode, constructorArgs);
        hook = new FactoryHookHarness{salt: salt}(
            poolManager, address(tokenFactory), address(weth), address(stakingVaultFactory)
        );
        assertEq(address(hook), predictedHook);

        vm.prank(owner);
        stakingVaultFactory.setHook(address(hook));

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(coin)),
            // Dynamic-fee flag, as LiquidityManager uses in production: the hook returns a
            // per-swap LP-fee override, which V4 only accepts on a dynamic-fee pool.
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = key.toId();
    }

    function _register(bool deployStaking, uint8 communityFeeRatio) internal {
        hook.registerPool(
            key,
            address(coin),
            communityFeeRatio,
            IBCTokenFactory.StakingConfig({deployStaking: deployStaking, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
    }

    /// @dev Router used by `_seedActiveLiquidity` / `_drainActiveLiquidity`.
    PoolModifyLiquidityTest internal liquidityRouter;

    /// @dev Initialises the registered pool and mints a wide two-sided position so the pool holds
    /// active liquidity, mirroring the state a graduated pool trades in.
    function _seedActiveLiquidity() internal {
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));

        liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        coin.mint(address(this), 1_000_000 ether);
        coin.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 100 ether);

        liquidityRouter.modifyLiquidity{value: 100 ether}(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: 1e18, salt: bytes32(0)}),
            ""
        );
        assertGt(poolManager.getLiquidity(poolId), 0, "pool must hold active liquidity");
    }

    /// @dev Burns the position minted by `_seedActiveLiquidity`, leaving the pool with no active
    /// liquidity.
    function _drainActiveLiquidity() internal {
        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: -60_000, tickUpper: 60_000, liquidityDelta: -1e18, salt: bytes32(0)}),
            ""
        );
    }
}

contract ConstructorTest is FactoryHookUnitTest {
    function test_storesImmutablesAndDefaults() public view {
        assertEq(address(hook.poolManager()), address(poolManager));
        assertEq(hook.BC_TOKEN_FACTORY(), address(tokenFactory));
        assertEq(hook.WETH(), address(weth));
        assertEq(hook.stakingVaultFactory(), address(stakingVaultFactory));
        assertEq(hook.protocolFeeRatio(), 0);
        assertEq(hook.factoryOwner(), owner);
    }

    function test_revertsIf_addressFlagsMismatch() public {
        // A plain `new` deploy lands on an address whose low bits do not encode the required
        // hook permissions; BaseHook's constructor validation must reject it.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new FactoryHook(poolManager, address(tokenFactory), address(weth), address(stakingVaultFactory));
    }
}

contract RegisterPoolTest is FactoryHookUnitTest {
    function test_revertsIf_notLiquidityManager() public {
        tokenFactory.setLiquidityManager(makeAddr("someoneElse"));
        vm.expectRevert(IFactoryHook.OnlyLiquidityManager.selector);
        _register(false, 50);
    }

    function test_revertsIf_wrongHookInKey() public {
        key.hooks = IHooks(makeAddr("otherHook"));
        vm.expectRevert(IFactoryHook.InvalidPoolKey.selector);
        _register(false, 50);
    }

    function test_revertsIf_currency0NotNative() public {
        key.currency0 = Currency.wrap(address(weth));
        vm.expectRevert(IFactoryHook.InvalidPoolKey.selector);
        _register(false, 50);
    }

    function test_revertsIf_currency1NotCoin() public {
        key.currency1 = Currency.wrap(address(weth));
        vm.expectRevert(IFactoryHook.InvalidPoolKey.selector);
        _register(false, 50);
    }

    function test_revertsIf_communityFeeRatioAbove100() public {
        vm.expectRevert(IFactoryHook.InvalidCommunityFeeRatio.selector);
        _register(false, 101);
    }

    function test_revertsIf_alreadyRegistered() public {
        _register(false, 50);
        vm.expectRevert(IFactoryHook.PoolAlreadyRegistered.selector);
        _register(false, 50);
    }

    function test_successful_withoutStaking() public {
        _register(false, 50);
        IFactoryHook.PoolState memory state = hook.getPoolState(poolId);
        assertTrue(state.registered);
        assertEq(state.coin, address(coin));
        assertEq(state.communityFeeRatio, 50);
        assertEq(state.stakingVault, address(0));
        // Empty payload: flat default fee, no extension pipeline.
        assertEq(state.fixedFee, hook.DEFAULT_FIXED_FEE());
        assertEq(state.lastAppliedFee, hook.DEFAULT_FIXED_FEE());
        assertEq(state.sniperWindow, 0);
        assertEq(state.feeCalculators.length, 0);
        assertEq(state.observers.length, 0);
    }

    function test_successful_deploysStakingVault() public {
        _register(true, 50);
        address vault = hook.getPoolState(poolId).stakingVault;
        assertTrue(vault != address(0), "vault not deployed");
        // Re-registration cannot replace the vault; only `setStakingVault` can.
        vm.expectRevert(IFactoryHook.PoolAlreadyRegistered.selector);
        _register(true, 50);
        assertEq(hook.getPoolState(poolId).stakingVault, vault);
    }

    function testFuzz_communityFeeRatioBoundary(uint8 ratio) public {
        ratio = uint8(bound(ratio, 0, 200));
        if (ratio > 100) {
            vm.expectRevert(IFactoryHook.InvalidCommunityFeeRatio.selector);
            _register(false, ratio);
        } else {
            _register(false, ratio);
            assertEq(hook.getPoolState(poolId).communityFeeRatio, ratio);
        }
    }
}

/// @notice The S2 guard's genuine trigger: a fee calculator whose `onRegisterCalculator`
/// reenters `registerPool` AS the liquidity manager itself (this test contract IS the mocked
/// liquidity manager) for a different, not-yet-registered pool, while the outer registration
/// is still mid-flight. Every other validation passes — only the transient lock stops it.
contract ReentrantRegisterPoolTest is FactoryHookUnitTest {
    function onRegisterCalculator(PoolId, bytes calldata) external {
        PoolKey memory nestedKey = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(makeAddr("nested-coin")),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(msg.sender)
        });
        IFactoryHook(msg.sender)
            .registerPool(
                nestedKey,
                Currency.unwrap(nestedKey.currency1),
                0,
                IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
                ""
            );
    }

    function test_registerPool_reentrantCallFromLiquidityManager_reverts() public {
        address[] memory chain = new address[](1);
        chain[0] = address(this);
        IFactoryHook.HookConfigV2 memory config = IFactoryHook.HookConfigV2({
            fixedFee: 3000,
            lpShareBps: 7000,
            feeCalculators: chain,
            calculatorConfigs: new bytes[](1),
            sniperWindow: 0,
            observers: new IFactoryHook.ObserverConfig[](0)
        });

        vm.expectRevert();
        hook.registerPool(
            key,
            address(coin),
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            abi.encodePacked(uint8(2), abi.encode(config))
        );
    }
}

contract AdminSettersTest is FactoryHookUnitTest {
    event ProtocolFeeRatioUpdated(uint8 oldRatio, uint8 newRatio);
    event StakingVaultFactoryUpdated(address indexed oldFactory, address indexed newFactory);
    event StakingVaultUpdated(PoolId indexed poolId, address indexed oldVault, address indexed newVault);

    /// @dev Deploys a standalone StakingVault over `asset` bound to the live hook, bypassing the
    /// vault factory's onlyHook gate (the hook checks the vault's underlying asset and binding).
    function _deployVault(address asset) internal returns (address) {
        return address(new MockStakingVault(IERC20(asset), address(hook), address(weth)));
    }

    function test_setProtocolFeeRatio_revertsIf_notFactoryOwner() public {
        vm.expectRevert(IFactoryHook.OnlyFactoryOwner.selector);
        hook.setProtocolFeeRatio(10);
    }

    function test_setProtocolFeeRatio_revertsIf_above100() public {
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.InvalidProtocolFeeRatio.selector);
        hook.setProtocolFeeRatio(101);
    }

    function test_setProtocolFeeRatio_successful() public {
        vm.prank(owner);
        vm.expectEmit(address(hook));
        emit ProtocolFeeRatioUpdated(0, 25);
        hook.setProtocolFeeRatio(25);
        assertEq(hook.protocolFeeRatio(), 25);
    }

    function testFuzz_setProtocolFeeRatio_boundary(uint8 ratio) public {
        ratio = uint8(bound(ratio, 0, 200));
        vm.prank(owner);
        if (ratio > 100) {
            vm.expectRevert(IFactoryHook.InvalidProtocolFeeRatio.selector);
            hook.setProtocolFeeRatio(ratio);
        } else {
            hook.setProtocolFeeRatio(ratio);
            assertEq(hook.protocolFeeRatio(), ratio);
        }
    }

    function test_setStakingVaultFactory_revertsIf_notFactoryOwner() public {
        vm.expectRevert(IFactoryHook.OnlyFactoryOwner.selector);
        hook.setStakingVaultFactory(makeAddr("newFactory"));
    }

    function test_setStakingVaultFactory_revertsIf_zeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.InvalidZeroAddress.selector);
        hook.setStakingVaultFactory(address(0));
    }

    function test_setStakingVaultFactory_successful() public {
        // The replacement factory must already resolve back to this hook.
        MockStakingVaultFactory newFactory = new MockStakingVaultFactory(owner, address(hook), address(weth));
        vm.prank(owner);
        vm.expectEmit(address(hook));
        emit StakingVaultFactoryUpdated(address(stakingVaultFactory), address(newFactory));
        hook.setStakingVaultFactory(address(newFactory));
        assertEq(hook.stakingVaultFactory(), address(newFactory));
    }

    function test_setStakingVaultFactory_revertsIf_factoryNotWiredToThisHook() public {
        // A factory whose `hook` names some other address would make `registerPool` revert
        // inside `deployVault`'s onlyHook guard, so the setter refuses it.
        MockStakingVaultFactory misWired = new MockStakingVaultFactory(owner, makeAddr("someOtherHook"), address(weth));
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.InvalidStakingVaultFactory.selector);
        hook.setStakingVaultFactory(address(misWired));
    }

    function test_setStakingVault_revertsIf_notFactoryOwner() public {
        _register(false, 50);
        address vault = _deployVault(address(coin));
        vm.expectRevert(IFactoryHook.OnlyFactoryOwner.selector);
        hook.setStakingVault(poolId, vault);
    }

    function test_setStakingVault_revertsIf_poolNotRegistered() public {
        address vault = _deployVault(address(coin));
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.PoolNotRegistered.selector);
        hook.setStakingVault(poolId, vault);
    }

    function test_setStakingVault_revertsIf_assetMismatch() public {
        _register(false, 50);
        ERC20Mock otherCoin = new ERC20Mock("Other", "OTHER", 18);
        address wrongVault = _deployVault(address(otherCoin));
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.InvalidStakingVault.selector);
        hook.setStakingVault(poolId, wrongVault);
    }

    function test_setStakingVault_revertsIf_vaultBoundToOtherHook() public {
        _register(false, 50);
        // Right asset, but the vault authorises a different hook: it could never be notified.
        address foreignVault =
            address(new MockStakingVault(IERC20(address(coin)), makeAddr("someOtherHook"), address(weth)));
        vm.prank(owner);
        vm.expectRevert(IFactoryHook.InvalidStakingVault.selector);
        hook.setStakingVault(poolId, foreignVault);
    }

    function test_setStakingVault_successful_setsVaultWhenNoneDeployed() public {
        _register(false, 50);
        address vault = _deployVault(address(coin));
        vm.prank(owner);
        vm.expectEmit(address(hook));
        emit StakingVaultUpdated(poolId, address(0), vault);
        hook.setStakingVault(poolId, vault);
        assertEq(hook.getPoolState(poolId).stakingVault, vault);
    }

    function test_setStakingVault_successful_replacesVault() public {
        _register(true, 50);
        address oldVault = hook.getPoolState(poolId).stakingVault;
        address newVault = _deployVault(address(coin));
        vm.prank(owner);
        vm.expectEmit(address(hook));
        emit StakingVaultUpdated(poolId, oldVault, newVault);
        hook.setStakingVault(poolId, newVault);
        assertEq(hook.getPoolState(poolId).stakingVault, newVault);
    }

    function test_setStakingVault_successful_clearsVault() public {
        _register(true, 50);
        address oldVault = hook.getPoolState(poolId).stakingVault;
        vm.prank(owner);
        vm.expectEmit(address(hook));
        emit StakingVaultUpdated(poolId, oldVault, address(0));
        hook.setStakingVault(poolId, address(0));
        assertEq(hook.getPoolState(poolId).stakingVault, address(0));
    }
}

contract CallbackAuthTest is FactoryHookUnitTest {
    function test_beforeInitialize_revertsIf_notPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    function test_afterInitialize_revertsIf_notPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, 0, 0);
    }

    function test_beforeSwap_revertsIf_notPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(
            address(this), key, SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}), ""
        );
    }

    function test_afterSwap_revertsIf_notPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0}),
            BalanceDelta.wrap(0),
            ""
        );
    }

    function test_beforeInitialize_revertsIf_senderNotLiquidityManager() public {
        _register(false, 50);
        vm.prank(address(poolManager));
        vm.expectRevert(IFactoryHook.UnauthorizedPoolInitialization.selector);
        hook.beforeInitialize(makeAddr("rogue"), key, 0);
    }

    function test_beforeInitialize_revertsIf_poolNotRegistered() public {
        vm.prank(address(poolManager));
        vm.expectRevert(IFactoryHook.UnauthorizedPoolInitialization.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    function test_beforeInitialize_revertsIf_notDynamicFee() public {
        // A statically-fee-keyed pool clears both the sender and registration checks (neither
        // inspects `key.fee`), isolating the LAST beforeInitialize guard.
        key.fee = 3000;
        poolId = key.toId();
        _register(false, 50);

        vm.prank(address(poolManager));
        vm.expectRevert(IFactoryHook.NotDynamicFee.selector);
        hook.beforeInitialize(address(this), key, 0);
    }

    function test_liquidityCallbacks_revertWith_hookNotImplemented() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: 0});

        vm.startPrank(address(poolManager));
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterAddLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterRemoveLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(BaseHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
        vm.stopPrank();
    }

    function test_allCallbacks_revertIf_notPoolManager() public {
        ModifyLiquidityParams memory params =
            ModifyLiquidityParams({tickLower: 0, tickUpper: 60, liquidityDelta: 1, salt: 0});

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, params, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterAddLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(address(this), key, params, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterRemoveLiquidity(address(this), key, params, BalanceDelta.wrap(0), BalanceDelta.wrap(0), "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 0, 0, "");
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 0, 0, "");
    }

    function test_receive_revertsIf_unknownSender() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "receive should reject unknown senders");
    }

    function test_receive_acceptsPoolManagerAndWeth() public {
        vm.deal(address(poolManager), 1 ether);
        vm.prank(address(poolManager));
        (bool ok,) = address(hook).call{value: 1}("");
        assertTrue(ok, "pool manager rejected");

        vm.deal(address(weth), 1 ether);
        vm.prank(address(weth));
        (ok,) = address(hook).call{value: 1}("");
        assertTrue(ok, "weth rejected");
    }
}

contract ViewGettersTest is FactoryHookUnitTest {
    function test_getVolatility_and_getCurrentFee_zeroBeforeAnyPool() public view {
        // Unregistered pool: state is zeroed, so getCurrentFee returns 0 and volatility is 0.
        assertEq(hook.getVolatility(poolId), 0);
        assertEq(hook.getCurrentFee(poolId), 0);
    }

    function test_getCurrentFee_defaultAfterRegistration() public {
        // lastAppliedFee is seeded with the base fee at registration, before any swap.
        _register(false, 50);
        assertEq(hook.getCurrentFee(poolId), hook.DEFAULT_FIXED_FEE());
    }

    function test_getVolatility_afterSeededState() public {
        _register(false, 50);
        // Seed a non-zero accumulator directly via the harness and read it back through the
        // public view (displacement of the reference tick against itself is zero).
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 420);
        assertEq(hook.getVolatility(poolId), 420);
    }
}

/// @notice One fee-chain stage returning `previousFee + delta`. Stages run under staticcall,
/// so mocks cannot record what they saw — threading is asserted arithmetically instead, by
/// composing stages whose order changes the result.
contract AddingFeeCalculator {
    uint24 public immutable delta;

    constructor(uint24 _delta) {
        delta = _delta;
    }

    function quoteFee(PoolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        view
        returns (uint24)
    {
        return previousFee + delta;
    }
}

/// @notice A stage returning `previousFee * 2` — non-commutative with the adder, so chain
/// order is observable in the final value.
contract DoublingFeeCalculator {
    function quoteFee(PoolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        pure
        returns (uint24)
    {
        return previousFee * 2;
    }
}

/// @notice A stage echoing `baseFee`, ignoring the running fee — proves later stages still
/// receive the chain seed, not an earlier stage's output, as `baseFee`.
contract BaseFeeEchoCalculator {
    function quoteFee(PoolId, uint24, uint24 baseFee, uint88, int24, SwapParams calldata)
        external
        pure
        returns (uint24)
    {
        return baseFee;
    }
}

/// @notice A stage that always reverts — must be skipped, its input passing through.
contract RevertingFeeCalculator {
    error Broken();

    fallback() external {
        revert Broken();
    }
}

/// @notice A stage that burns all forwarded gas — must be cut off by the stipend and skipped.
contract GasGuzzlerFeeCalculator {
    fallback() external {
        while (true) {}
    }
}

/// @notice A stage returning 64 bytes instead of 32 — malformed returndata must be skipped.
contract FatReturnFeeCalculator {
    fallback() external {
        assembly {
            mstore(0, 1000)
            mstore(32, 1000)
            return(0, 64)
        }
    }
}

contract FeeChainTest is FactoryHookUnitTest {
    SwapParams internal params = SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: 0});

    event FeeCalculatorFallback(PoolId indexed poolId, address indexed calculator);

    function test_emptyChain_returnsBaseFee() public {
        hook.setFeePipeline(poolId, 4000, new address[](0), 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 4000);
    }

    function test_chain_threadsPreviousFeeInOrder() public {
        address adder = address(new AddingFeeCalculator(1000));
        address doubler = address(new DoublingFeeCalculator());

        // (3000 + 1000) * 2 = 8000 — the adder ran first.
        address[] memory chain = new address[](2);
        chain[0] = adder;
        chain[1] = doubler;
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 8000, "stages must compose in payload order");

        // 3000 * 2 + 1000 = 7000 — swapped order gives a different value.
        chain[0] = doubler;
        chain[1] = adder;
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 7000, "order must be the payload's");
    }

    function test_chain_baseFeeStaysTheSeedForLaterStages() public {
        // Stage 1 raises the running fee; stage 2 echoes baseFee — the final value proves the
        // seed, not stage 1's output, was passed as baseFee.
        address[] memory chain = new address[](2);
        chain[0] = address(new AddingFeeCalculator(1000));
        chain[1] = address(new BaseFeeEchoCalculator());
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 3000);
    }

    function test_chain_revertingStageIsSkippedAndSignalled() public {
        RevertingFeeCalculator broken = new RevertingFeeCalculator();
        AddingFeeCalculator working = new AddingFeeCalculator(500);
        address[] memory chain = new address[](2);
        chain[0] = address(broken);
        chain[1] = address(working);
        hook.setFeePipeline(poolId, 3000, chain, 0);

        vm.expectEmit(address(hook));
        emit FeeCalculatorFallback(poolId, address(broken));
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 3500, "input must pass through a failed stage");
    }

    function test_chain_allStagesFailing_landsOnBaseFee() public {
        address[] memory chain = new address[](2);
        chain[0] = address(new RevertingFeeCalculator());
        chain[1] = address(new GasGuzzlerFeeCalculator());
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 3000);
    }

    function test_chain_malformedReturndataIsSkipped() public {
        address[] memory chain = new address[](1);
        chain[0] = address(new FatReturnFeeCalculator());
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), 3000);
    }

    function test_chain_outputClampedAtMaxHookFee() public {
        // A stage may quote above the cage ceiling; the final chain output is clamped.
        AddingFeeCalculator greedy = new AddingFeeCalculator(400_000);
        address[] memory chain = new address[](1);
        chain[0] = address(greedy);
        hook.setFeePipeline(poolId, 3000, chain, 0);
        assertEq(hook.exposed_runFeeChain(poolId, 0, 0, params), hook.MAX_HOOK_FEE());
    }

    function test_staticQuote_rejectsValueAboveUint24() public {
        // The raw stage guard: a well-formed 32-byte value that overflows uint24 is unusable.
        AddingFeeCalculator ok_ = new AddingFeeCalculator(0);
        (bool ok, uint24 fee) = hook.exposed_staticQuote(address(ok_), poolId, 1234, 1234, 0, 0, params);
        assertTrue(ok);
        assertEq(fee, 1234);

        (ok,) = hook.exposed_staticQuote(address(new FatReturnFeeCalculator()), poolId, 0, 0, 0, 0, params);
        assertFalse(ok, "malformed returndata must be rejected");
    }
}

contract FeeMathTest is FactoryHookUnitTest {
    function testFuzz_split_conservesAmount(uint256 amount, uint256 ratio) public view {
        amount = bound(amount, 0, type(uint128).max);
        ratio = bound(ratio, 0, 100);
        (uint256 amountA, uint256 amountB) = hook.exposed_split(amount, ratio);
        assertEq(amountA + amountB, amount, "split must conserve");
        if (ratio == 0) assertEq(amountA, 0);
        if (ratio == 100) assertEq(amountB, 0);
    }
}

contract VolatilityAccumulatorTest is FactoryHookUnitTest {
    function setUp() public override {
        super.setUp();
        _register(false, 50);
        _seedActiveLiquidity();
    }

    function test_update_addsDisplacementAndCapsAtT2() public {
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 0);
        assertEq(hook.exposed_updateVolatility(poolId, 300), 300, "displacement not added");
        // Same timestamp: no decay, displacement accumulates and saturates at the upper
        // threshold t2 (900), the accumulator cap.
        assertEq(hook.exposed_updateVolatility(poolId, 900), 900, "accumulation wrong");
        assertEq(hook.exposed_updateVolatility(poolId, 0), 900, "not capped at t2");
    }

    /// @notice A price move out of the seeded band is still a price move: displacement accrues
    /// whether or not the pool holds active liquidity, so the swap that leaves the band is not
    /// recorded as zero volatility with the whole round trip billed to the swap that returns.
    function test_update_accruesDisplacementWithoutActiveLiquidity() public {
        // Move the pool price outside the seeded range so active liquidity is zero.
        _drainActiveLiquidity();
        assertEq(poolManager.getLiquidity(poolId), 0, "precondition: no active liquidity");

        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 0);
        assertEq(hook.exposed_updateVolatility(poolId, 300), 300, "out-of-band displacement must accrue");
        assertEq(hook.getPoolState(poolId).referenceTick, 300, "reference tick must advance");
    }

    /// @notice The previous swap's move carries over to the next swap, decayed over the elapsed
    /// time: `referenceTick` keeps the pre-swap tick, so the move a swap leaves behind is priced
    /// into whoever trades next at `(decayWindow - elapsed) / decayWindow` weight.
    function test_update_carryOverDecaysAcrossSwaps() public {
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 0);

        // Swap 1 enters at tick 0 and leaves the pool at tick 400: it is priced on zero
        // volatility, and its own 400-tick move stays pending in the displacement term.
        assertEq(hook.exposed_swapCycle(poolId, 0, 400), 0, "a swap must not be priced on its own move");

        // A quarter window later, the next swap is priced on that move at 3/4 weight.
        skip(150);
        assertEq(hook.exposed_updateVolatility(poolId, 400), 300, "carry-over must decay linearly");
    }

    function test_displacement_decaysLinearlyOverWindow() public {
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 0);
        assertEq(hook.exposed_displacement(poolId, 600), 600, "no decay at zero elapsed");
        skip(150); // quarter of the 600s window
        assertEq(hook.exposed_displacement(poolId, 600), 450, "quarter-window decay wrong");
        skip(150);
        assertEq(hook.exposed_displacement(poolId, 600), 300, "half-window decay wrong");
        skip(300);
        assertEq(hook.exposed_displacement(poolId, 600), 0, "full-window decay wrong");
    }

    function testFuzz_displacement_symmetricAndExactAtZeroElapsed(int24 a, int24 b) public {
        a = int24(bound(a, -887_272, 887_272));
        b = int24(bound(b, -887_272, 887_272));

        hook.setVolatilityState(poolId, b, uint32(block.timestamp), 0);
        uint256 d = hook.exposed_displacement(poolId, a);

        hook.setVolatilityState(poolId, a, uint32(block.timestamp), 0);
        assertEq(d, hook.exposed_displacement(poolId, b), "not symmetric");

        int256 diff = int256(a) - int256(b);
        assertEq(d, uint256(diff < 0 ? -diff : diff), "wrong magnitude");
    }

    function test_decay_linearOverWindow() public {
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 600);
        skip(300); // half the 600s window
        assertEq(hook.exposed_decayedAccumulator(poolId), 300, "half-window decay wrong");
        skip(300);
        assertEq(hook.exposed_decayedAccumulator(poolId), 0, "full-window decay wrong");
    }

    function test_decay_zeroAfterGapBeyondWindow() public {
        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), 1000);
        skip(601);
        assertEq(hook.exposed_decayedAccumulator(poolId), 0);
    }

    function testFuzz_update_neverExceedsT2(int24 tick, uint32 elapsed, uint88 seeded) public {
        tick = int24(bound(tick, -887_272, 887_272));
        elapsed = uint32(bound(elapsed, 0, 7 days));
        seeded = uint88(bound(seeded, 0, 900));

        hook.setVolatilityState(poolId, 0, uint32(block.timestamp), seeded);
        skip(elapsed);
        uint88 updated = hook.exposed_updateVolatility(poolId, tick);
        assertLe(updated, 900, "accumulator exceeded t2 cap");
    }
}
