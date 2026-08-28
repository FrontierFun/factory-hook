// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

/// @notice Adversarial and instrumentation doubles for the gen-2 extension campaigns. All of
/// them accept any registration (they are not S1-conformant on purpose — the campaigns test the
/// HOOK's cage, not extension hygiene; `DynamicFeeExtension` is the S1 reference).

/// @notice Fee calculator quoting a constant, whatever the chain state.
contract FixedQuoteCalculator {
    uint24 public immutable quote;

    constructor(uint24 _quote) {
        quote = _quote;
    }

    function onRegisterCalculator(PoolId, bytes calldata) external {}

    function quoteFee(PoolId, uint24, uint24, uint88, int24, SwapParams calldata) external view returns (uint24) {
        return quote;
    }
}

/// @notice Fee calculator that always reverts — the stage must be skipped.
contract RevertingCalculator {
    error Broken();

    function onRegisterCalculator(PoolId, bytes calldata) external {}

    function quoteFee(PoolId, uint24, uint24, uint88, int24, SwapParams calldata) external pure returns (uint24) {
        revert Broken();
    }
}

/// @notice Fee calculator that burns every forwarded gas unit — the stipend must cut it off.
contract GasGuzzlerCalculator {
    function onRegisterCalculator(PoolId, bytes calldata) external {}

    fallback() external {
        while (true) {}
    }
}

/// @notice Fee calculator answering with a 1MB returndata bomb — must be rejected uncopied.
contract ReturndataBombCalculator {
    function onRegisterCalculator(PoolId, bytes calldata) external {}

    fallback() external {
        assembly {
            return(0, 1048576)
        }
    }
}

/// @notice Fee calculator returning a well-formed 32-byte value that overflows uint24.
contract OverflowCalculator {
    function onRegisterCalculator(PoolId, bytes calldata) external {}

    function quoteFee(PoolId, uint24, uint24, uint88, int24, SwapParams calldata) external pure returns (uint24) {
        assembly {
            mstore(0, 0x1000000)
            return(0, 32)
        }
    }
}

/// @notice Observer recording every notification it receives (raw calls may write state).
contract RecordingObserver {
    uint256 public afterSwapCount;
    uint256 public feeChangeCount;
    PoolId public lastPoolId;
    uint24 public lastFeeRate;
    uint256 public lastFeeAmount;
    bytes public lastHookData;
    uint24 public lastPreviousFee;
    uint24 public lastNewFee;

    function onRegisterObserver(PoolId, bytes calldata) external {}

    function onAfterSwap(PoolId poolId, BalanceDelta, uint24 feeRate, uint256 feeAmount, bytes calldata hookData)
        external
    {
        afterSwapCount++;
        lastPoolId = poolId;
        lastFeeRate = feeRate;
        lastFeeAmount = feeAmount;
        lastHookData = hookData;
    }

    function onFeeChange(PoolId poolId, uint24 previousFee, uint24 newFee) external {
        feeChangeCount++;
        lastPoolId = poolId;
        lastPreviousFee = previousFee;
        lastNewFee = newFee;
    }
}

/// @notice Minimal observer: one warm-path SSTORE per notification — the "light" observer the
/// shared-budget envelope is sized for.
contract MinimalObserver {
    uint256 public count;

    function onRegisterObserver(PoolId, bytes calldata) external {}

    function onAfterSwap(PoolId, BalanceDelta, uint24, uint256, bytes calldata) external {
        count++;
    }

    function onFeeChange(PoolId, uint24, uint24) external {
        count++;
    }
}

/// @notice Observer that burns everything forwarded to it — later best-effort observers must
/// starve, the swap itself must not.
contract GreedyObserver {
    function onRegisterObserver(PoolId, bytes calldata) external {}

    fallback() external {
        while (true) {}
    }
}

/// @notice Observer that always reverts — must be ignored.
contract RevertingObserver {
    error Grumpy();

    function onRegisterObserver(PoolId, bytes calldata) external {}

    fallback() external {
        revert Grumpy();
    }
}

/// @notice Observer that reenters `PoolManager.unlock` from inside the notification. A nested
/// `unlock` reverts (`AlreadyUnlocked`) since the notification runs inside the swap's unlock, so
/// the flag never sets; the hook ignores the revert. This pins the ONE reentrancy fact that is
/// actually blocked — a nested `swap` is NOT (see {NestedSwapObserver}).
interface IUnlockTarget {
    function unlock(bytes calldata data) external returns (bytes memory);
}

contract NestedUnlockObserver {
    IUnlockTarget public immutable poolManager;
    bool public reentered;

    constructor(address _poolManager) {
        poolManager = IUnlockTarget(_poolManager);
    }

    function onRegisterObserver(PoolId, bytes calldata) external {}

    function onAfterSwap(PoolId, BalanceDelta, uint24, uint256, bytes calldata) external {
        poolManager.unlock("");
        reentered = true;
    }

    function onFeeChange(PoolId, uint24, uint24) external {}
}

/// @notice Observer that runs a REAL nested swap on its own pool from inside the notification —
/// the vector V4 actually permits (`swap` is `onlyWhenUnlocked`, and the notification runs while
/// unlocked). It funds itself with ETH and does a tiny exact-input ETH->coin swap; when
/// `settleDebt` is true it fully settles (pays ETH, takes coin), otherwise it leaves the delta
/// unsettled to force the outer unlock to revert (`CurrencyNotSettled`). A guard stops the nested
/// swap's own notification from recursing.
contract NestedSwapObserver {
    IPoolManager public immutable poolManager;
    uint256 public immutable amountIn;
    bool public immutable settleDebt;
    PoolKey internal key;
    bool internal armed;
    bool internal entered;
    uint256 public swaps;

    constructor(address _poolManager, uint256 _amountIn, bool _settleDebt) {
        poolManager = IPoolManager(_poolManager);
        amountIn = _amountIn;
        settleDebt = _settleDebt;
    }

    receive() external payable {}

    /// @dev Bound in the deploy payload before its pool exists; armed with the pool key once the
    /// coin has graduated.
    function arm(PoolKey calldata k) external {
        key = k;
        armed = true;
    }

    function onRegisterObserver(PoolId, bytes calldata) external {}

    function onAfterSwap(PoolId, BalanceDelta, uint24, uint256, bytes calldata) external {
        if (!armed || entered) return; // run exactly once, and only once its key is known
        entered = true;
        swaps++;

        BalanceDelta delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            ""
        );

        if (settleDebt) {
            // Exact-in zeroForOne: amount0 < 0 (ETH we owe), amount1 > 0 (coin owed to us).
            poolManager.settle{value: uint256(uint128(-delta.amount0()))}();
            poolManager.take(key.currency1, address(this), uint256(uint128(delta.amount1())));
        }
    }

    function onFeeChange(PoolId, uint24, uint24) external {}
}

/// @notice Extension whose `onRegisterCalculator` tries to reenter `registerPool` on the calling hook —
/// the S2 transient lock must kill the whole deploy.
contract ReentrantRegisterExtension {
    function onRegisterCalculator(PoolId poolId, bytes calldata) external {
        PoolKey memory junk;
        IFactoryHook(msg.sender)
            .registerPool(
                junk,
                address(0),
                0,
                IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
                ""
            );
        poolId; // silence
    }

    function quoteFee(PoolId, uint24, uint24, uint88, int24, SwapParams calldata) external pure returns (uint24) {
        return 0;
    }
}

/// @notice Deliberately NON-S1-conformant extension: `onRegisterCalculator` is open to anyone but
/// write-once — the shape a poisoning attack needs.
contract PorousExtension {
    error AlreadyRegistered();

    mapping(PoolId => bool) public registered;

    function onRegisterCalculator(PoolId poolId, bytes calldata) external {
        if (registered[poolId]) revert AlreadyRegistered();
        registered[poolId] = true;
    }

    function quoteFee(PoolId, uint24 previousFee, uint24, uint88, int24, SwapParams calldata)
        external
        pure
        returns (uint24)
    {
        return previousFee;
    }
}
