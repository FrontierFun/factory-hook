// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {FactoryHook} from "src/hook/FactoryHook.sol";
import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IStakingVault} from "src/interfaces/IStakingVault.sol";

import {HookAddressMiner} from "script/utils/HookAddressMiner.sol";
import {DeployV4Infra} from "test/helpers/DeployV4Infra.sol";
import {MockBCToken, MockBCTokenFactory, MockStakingVaultFactory} from "test/helpers/ProtocolMocks.sol";
import {Users} from "test/helpers/Users.sol";

/**
 * @title HookTestBase
 * @notice Integration-test base for the hook suites: boots the REAL in-process Uniswap V4 stack,
 * deploys `FactoryHook` at a mined address, and stands in for the rest of the protocol with the
 * mocks in {ProtocolMocks}. This contract plays the `LiquidityManager` (it registers pools with
 * the hook and initializes them) and the coin creator (it is every coin's fee recipient).
 * @dev A port of the protocol repo's `BaseTest` for the hook alone: the variable names, users,
 * fixture coin (`coin`, communityFeeRatio 50, staking vault deployed) and the graduation shape
 * (150M coins + 4 ETH seed the pool, the 850M curve-sold coins land on `buyerOne`) mirror the
 * original so the hook test bodies port near-verbatim.
 */
abstract contract HookTestBase is Test, DeployV4Infra {
    using StateLibrary for IPoolManager;

    /// @dev The hook's permission bits (before/afterInitialize, before/afterSwap, both swap return deltas).
    uint160 internal constant HOOK_FLAGS = 0x30CC;

    /// @dev `LiquidityManager.TICK_SPACING`.
    int24 internal constant TICK_SPACING = 60;

    // Graduation fixture, mirroring the protocol's default launch in the original suite.
    uint256 public constant INITIAL_SUPPLY = 150_000_000 ether;
    uint256 public constant MAX_SUPPLY = 1_000_000_000 ether;
    uint256 public constant TARGET_MCAP = 4 ether;

    /// @dev Opening tick of every fixture pool (coin per ETH ≈ 3.75e7, i.e. 150M coins ≈ 4 ETH), spacing-aligned.
    int24 public constant SEED_TICK = 174_420;

    Users internal users;

    MockBCTokenFactory public factory;
    MockStakingVaultFactory public stakingVaultFactory;
    FactoryHook public hook;
    MockBCToken public coin;

    /// @dev Router used to seed graduation liquidity (liquidity hook flags are off, so any caller may LP).
    PoolModifyLiquidityTest internal liquidityRouter;

    mapping(address token => PoolKey key) internal _poolKeys;

    receive() external payable {}

    /// @notice Deploys the V4 infra, the hook and one default coin with a staking vault.
    function setUp() public virtual {
        deployV4Infra();

        users = Users({
            owner: _createUser("Owner"),
            treasury: _createUser("Treasury"),
            creator: _createUser("Creator"),
            buyerOne: _createUser("Buyer One"),
            buyerTwo: _createUser("Buyer Two"),
            buyerThree: _createUser("Buyer Three")
        });

        // This contract is the liquidity manager the hook authorises for registration/initialization.
        factory = new MockBCTokenFactory(users.owner, users.treasury, address(this));
        stakingVaultFactory = new MockStakingVaultFactory(users.owner, address(0), address(weth));

        bytes memory constructorArgs =
            abi.encode(poolManager, address(factory), address(weth), address(stakingVaultFactory));
        (address predictedHook, bytes32 salt) =
            HookAddressMiner.find(address(this), HOOK_FLAGS, type(FactoryHook).creationCode, constructorArgs);
        hook = new FactoryHook{salt: salt}(poolManager, address(factory), address(weth), address(stakingVaultFactory));
        assertEq(address(hook), predictedHook, "hook address mismatch");

        vm.prank(users.owner);
        stakingVaultFactory.setHook(address(hook));

        liquidityRouter = new PoolModifyLiquidityTest(poolManager);

        coin = _deployCoin(
            "Init Token",
            "INIT",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: true, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
    }

    /*//////////////////////////////////////////////////////////////
                      INTERNAL STATE-CHANGING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Generates a user, labels its address, and funds it with test assets.
    function _createUser(string memory name) internal returns (address payable) {
        address payable user = payable(makeAddr(name));
        vm.deal({account: user, newBalance: 100 ether});
        return user;
    }

    /// @dev Stands in for `BCTokenFactory.deploy`: deploys a coin, registers its ETH/coin pool with
    /// the hook and initializes the pool at `SEED_TICK` — the pre-graduation state a curve coin sits in.
    /// This contract is the coin's creator, hence its fee recipient.
    function _deployCoin(
        string memory name,
        string memory symbol,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig memory stakingConfig,
        bytes memory hookConfig
    ) internal returns (MockBCToken token) {
        token = _newCoin(name, symbol);
        _registerCoin(token, communityFeeRatio, stakingConfig, hookConfig);
    }

    /// @dev The coin half of `_deployCoin`: deploys the coin and records its pool key. Split out so a
    /// test can arm `vm.expectRevert` on the registration alone (a CREATE would consume it).
    function _newCoin(string memory name, string memory symbol) internal returns (MockBCToken token) {
        token = new MockBCToken(name, symbol, address(this));
        _poolKeys[address(token)] = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    /// @dev The registration half of `_deployCoin`: one external self-call so `registerPool` and the
    /// pool initialization are atomic, as they are inside `BCTokenFactory.deploy` — a payload the hook
    /// rejects reverts the whole step and leaves nothing registered.
    function _registerCoin(
        MockBCToken token,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig memory stakingConfig,
        bytes memory hookConfig
    ) internal {
        this.registerAndInitialize(
            _poolKeys[address(token)], address(token), communityFeeRatio, stakingConfig, hookConfig
        );
    }

    /// @dev External target of `_registerCoin`; callable by this contract only. `msg.sender` on both
    /// calls is this contract, the liquidity manager the hook authorises.
    function registerAndInitialize(
        PoolKey calldata key,
        address token,
        uint8 communityFeeRatio,
        IBCTokenFactory.StakingConfig calldata stakingConfig,
        bytes calldata hookConfig
    ) external {
        require(msg.sender == address(this), "self-call only");
        hook.registerPool(key, token, communityFeeRatio, stakingConfig, hookConfig);
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(SEED_TICK));
    }

    /// @dev Graduates `token` the way the curve does: the curve-sold supply lands on `buyerOne`, the
    /// LP seed (150M coins below the seed tick, 4 ETH above it — `LiquidityManager`'s two graduation
    /// ranges) is minted into the pool, and the coin is flagged LP'd.
    function _graduate(MockBCToken token) internal {
        PoolKey memory key = _poolKeys[address(token)];

        token.mint(users.buyerOne, MAX_SUPPLY - INITIAL_SUPPLY);

        // One coin of slack absorbs the pool's round-up on the coin-only range.
        token.mint(address(this), INITIAL_SUPPLY + 1 ether);
        token.approve(address(liquidityRouter), type(uint256).max);
        vm.deal(address(this), address(this).balance + TARGET_MCAP + 1 ether);

        int24 coinLowTick = _modulateTick(TickMath.MIN_TICK);
        int24 coinHighTick = SEED_TICK;
        int24 ethHighTick = _modulateTick(TickMath.MAX_TICK);

        uint128 coinLiquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(coinLowTick), TickMath.getSqrtPriceAtTick(coinHighTick), INITIAL_SUPPLY
        );
        uint128 ethLiquidity = LiquidityAmounts.getLiquidityForAmount0(
            TickMath.getSqrtPriceAtTick(coinHighTick), TickMath.getSqrtPriceAtTick(ethHighTick), TARGET_MCAP
        );

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: coinLowTick,
                tickUpper: coinHighTick,
                liquidityDelta: int256(uint256(coinLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );
        liquidityRouter.modifyLiquidity{value: TARGET_MCAP + 1 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: coinHighTick,
                tickUpper: ethHighTick,
                liquidityDelta: int256(uint256(ethLiquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        token.graduate();
        assertTrue(token.isLPd(), "graduation failed");
    }

    /// @dev Stakes `amount` of `token` into its pool's staking vault from `who`, giving the vault
    /// real shares. Coin-side vault fees are only routed to the vault while it holds shares —
    /// with zero supply there is no share price to appreciate, so the hook pays the fee recipient
    /// instead. Tests that expect a coin-leg vault share must stake first.
    function _stakeIntoVault(address token, address who, uint256 amount) internal returns (address vault) {
        vault = hook.getPoolState(_poolId(token)).stakingVault;
        require(vault != address(0), "token has no staking vault");

        vm.startPrank(who);
        IERC20(token).approve(vault, amount);
        IStakingVault(vault).deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev Swaps native ETH for `token` through the hooked pool (exact input).
    function _swapEthForCoin(address token, address who, uint256 amountIn) internal returns (uint256 amountOut) {
        PoolKey memory key = _poolKey(token);
        uint256 before = IERC20(token).balanceOf(who);
        vm.prank(who);
        swapRouter.swap{value: amountIn}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        amountOut = IERC20(token).balanceOf(who) - before;
    }

    /// @dev Swaps `token` for native ETH through the hooked pool (exact input).
    function _swapCoinForEth(address token, address who, uint256 amountIn) internal returns (uint256 amountOut) {
        PoolKey memory key = _poolKey(token);
        uint256 before = who.balance;
        vm.startPrank(who);
        IERC20(token).approve(address(swapRouter), amountIn);
        swapRouter.swap(
            key,
            SwapParams({
                zeroForOne: false, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
        amountOut = who.balance - before;
    }

    /*//////////////////////////////////////////////////////////////
                       INTERNAL READ-ONLY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev The V4 pool key of a token's hooked pool (`LiquidityManager.getPoolKey`).
    function _poolKey(address token) internal view returns (PoolKey memory) {
        return _poolKeys[token];
    }

    /// @dev The V4 pool id of a token's hooked pool (`LiquidityManager.getPoolId`).
    function _poolId(address token) internal view returns (PoolId) {
        return _poolKeys[token].toId();
    }

    /// @dev Rounds a tick toward zero to a `TICK_SPACING` multiple (`LiquidityManager._modulateTick`).
    function _modulateTick(int24 tick) internal pure returns (int24) {
        return tick / TICK_SPACING * TICK_SPACING;
    }
}
