// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";
import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @title LpShareSplitTest
/// @notice The per-pool `lpShareBps` (schema v2) and the strict 3-bps minimum total fee. The non-LP
/// amount distributed to treasury + recipient after a swap equals `amountIn * protocolRate`, where
/// `protocolRate = max(fixedFee * (1 - lpShareBps), 3 bps)`. No vault, so treasury + recipient capture
/// the whole non-LP share; the LP share is what stays with the pool.
contract LpShareSplitTest is ExtensionCampaignBase {
    uint24 internal constant FIXED_FEE = 3000; // 0.30% = 30 bps
    uint256 internal constant FEE_DENOMINATOR = 1e6;
    uint256 internal constant PROTOCOL_FLOOR_PIPS = 300; // 3 bps

    function setUp() public override {
        super.setUp();
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);
    }

    /// @dev Graduated coin with `lpShareBps`, no vault (treasury + creator capture all non-LP).
    function _deploy(uint16 lpShareBps, bytes32 salt) internal returns (MockBCToken coin) {
        IFactoryHook.HookConfigV2 memory config = _emptyConfig(FIXED_FEE);
        config.lpShareBps = lpShareBps;
        coin = _deployCoin(
            string.concat("LpShare ", vm.toString(salt)),
            "LPS",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            _payload(config)
        );
        _graduate(coin);
    }

    /// @dev Swaps `amountIn` ETH into `coin` and returns the non-LP WETH captured (treasury + creator).
    function _nonLpTake(MockBCToken coin, uint256 amountIn) internal returns (uint256) {
        address recipient = coin.getFeeRecipient();
        uint256 treasuryBefore = weth.balanceOf(users.treasury);
        uint256 recipientBefore = weth.balanceOf(recipient);
        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);
        uint256 take = (weth.balanceOf(users.treasury) - treasuryBefore) + (weth.balanceOf(recipient) - recipientBefore);
        assertEq(weth.balanceOf(address(hook)), 0, "no WETH residue on the hook");
        return take;
    }

    function _expectedProtocolRate(uint16 lpShareBps) internal pure returns (uint256 rate) {
        rate = uint256(FIXED_FEE) * (10_000 - lpShareBps) / 10_000;
        if (rate < PROTOCOL_FLOOR_PIPS) rate = PROTOCOL_FLOOR_PIPS;
    }

    function test_default_70_30_split() public {
        MockBCToken coin = _deploy(7000, "lp-70");
        uint256 amountIn = 0.1 ether;
        // 30 bps fee, 70% LP -> non-LP = 9 bps.
        assertEq(_nonLpTake(coin, amountIn), amountIn * _expectedProtocolRate(7000) / FEE_DENOMINATOR, "9 bps non-LP");
    }

    /// @dev Every swap emits SwapFeeDistributed with the final non-LP breakdown: no vault here,
    /// so protocolAmount + recipientAmount equal the whole non-LP take and the vault leg is zero.
    function test_swapFeeDistributed_emitsNonLpBreakdown() public {
        MockBCToken coin = _deploy(7000, "lp-evt");
        uint256 amountIn = 0.1 ether;
        address recipient = coin.getFeeRecipient();
        PoolId poolId = _poolId(address(coin));

        vm.recordLogs();
        _swapEthForCoin(address(coin), users.buyerTwo, amountIn);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 topic0 =
            keccak256("SwapFeeDistributed(bytes32,address,uint256,uint256,uint256,address,address,address)");
        uint256 seen = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook) || logs[i].topics[0] != topic0) continue;
            seen++;
            assertEq(logs[i].topics[1], PoolId.unwrap(poolId), "poolId topic");
            _assertNonLpEvent(logs[i].data, recipient, amountIn * _expectedProtocolRate(7000) / FEE_DENOMINATOR);
        }
        assertEq(seen, 1, "exactly one SwapFeeDistributed on the ETH leg");
    }

    /// @dev Decodes a SwapFeeDistributed payload (no vault case) and asserts the breakdown.
    function _assertNonLpEvent(bytes memory data, address recipient, uint256 expectedSum) internal view {
        (
            address currency,
            uint256 protocolAmount,
            uint256 vaultAmount,
            uint256 recipientAmount,
            address protocolRecipient,
            address vault,
            address feeRecipient
        ) = abi.decode(data, (address, uint256, uint256, uint256, address, address, address));
        assertEq(currency, address(0), "ETH leg");
        assertEq(vaultAmount, 0, "no vault share");
        assertEq(vault, address(0), "no vault configured");
        assertEq(protocolRecipient, users.treasury, "treasury takes the protocol share");
        assertEq(feeRecipient, recipient, "coin fee recipient takes the rest");
        assertEq(protocolAmount + recipientAmount, expectedSum, "sum equals the non-LP take");
    }

    function test_customSplit_shiftsTheNonLpShare() public {
        // 60% LP -> non-LP = 40% of 30 bps = 12 bps (more to the non-LP side than the default).
        MockBCToken coin = _deploy(6000, "lp-60");
        uint256 amountIn = 0.1 ether;
        uint256 take = _nonLpTake(coin, amountIn);
        assertEq(take, amountIn * _expectedProtocolRate(6000) / FEE_DENOMINATOR, "12 bps non-LP");
        // Strictly more than the 70/30 default's 9 bps.
        assertGt(take, amountIn * _expectedProtocolRate(7000) / FEE_DENOMINATOR, "more non-LP than default");
    }

    function test_zeroLpShare_allToNonLp() public {
        // lpShareBps = 0 (literal): the whole 30-bps fee is the non-LP waterfall.
        MockBCToken coin = _deploy(0, "lp-0");
        uint256 amountIn = 0.1 ether;
        assertEq(_nonLpTake(coin, amountIn), amountIn * FIXED_FEE / FEE_DENOMINATOR, "the whole fee is non-LP");
    }

    function test_maxLpShare_noSurcharge_protocolKeepsTheFloor() public {
        // lpShareBps = 10000 (100% LP): non-LP natural = 0, floored to 3 bps — the protocol still
        // takes its floor from WITHIN the fee, no surcharge (total stays 30 bps).
        MockBCToken coin = _deploy(10_000, "lp-100");
        uint256 amountIn = 0.1 ether;
        uint256 take = _nonLpTake(coin, amountIn);
        assertEq(take, amountIn * PROTOCOL_FLOOR_PIPS / FEE_DENOMINATOR, "non-LP is exactly the 3-bps floor");
    }

    function test_strictMinTotalFee_zeroFeePoolCostsThreeBps() public {
        // A fixed-fee-0 pool: the total is floored at 3 bps, all of it non-LP (to the protocol),
        // never below — no surcharge, just the strict minimum.
        IFactoryHook.HookConfigV2 memory config = _emptyConfig(0); // fixedFee = 0
        config.lpShareBps = 7000;
        MockBCToken coin = _deployCoin(
            "LpShare",
            "LPS",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            _payload(config)
        );
        _graduate(coin);
        uint256 amountIn = 0.1 ether;
        assertEq(_nonLpTake(coin, amountIn), amountIn * PROTOCOL_FLOOR_PIPS / FEE_DENOMINATOR, "min 3 bps, all non-LP");
    }

    function test_invalidLpShare_aboveMax_revertsDeploy() public {
        IFactoryHook.HookConfigV2 memory config = _emptyConfig(FIXED_FEE);
        config.lpShareBps = 10_001; // > MAX_BPS
        // The coin is created first so expectRevert targets only the registration, where
        // registerPool validates the payload (the malformed lpShareBps reverts InvalidHookConfig).
        MockBCToken bad = _newCoin("LpShare bad-lpshare", "LPS");
        bytes memory payload = _payload(config);
        vm.expectRevert();
        _registerCoin(
            bad, 50, IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}), payload
        );
    }

    function _exactInParams(uint256 amountIn) internal pure returns (SwapParams memory) {
        return SwapParams({
            zeroForOne: true, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });
    }

    function test_previewFee_decomposesAndMatchesTheCharge() public {
        MockBCToken coin = _deploy(7000, "lp-preview");
        PoolId pid = _poolId(address(coin));
        (uint24 totalFee, uint24 lpFee, uint24 nonLpFee) = hook.previewFee(pid, _exactInParams(0.1 ether));

        assertEq(totalFee, lpFee + nonLpFee, "total decomposes into lp + non-lp");
        assertGe(totalFee, 300, "never below 3 bps");
        assertEq(totalFee, FIXED_FEE, "fixed-fee pool: total is the fixed fee");
        assertEq(nonLpFee, uint24(_expectedProtocolRate(7000)), "non-LP is 30% of the fee");

        // Executing the swap charges exactly the previewed total (lastAppliedFee).
        _swapEthForCoin(address(coin), users.buyerTwo, 0.1 ether);
        assertEq(hook.getCurrentFee(pid), totalFee, "preview matches the charged total");
    }

    function test_previewFee_reflectsLpShareBps() public {
        MockBCToken low = _deploy(2000, "lp-preview-low"); // 20% LP -> 80% non-LP
        MockBCToken high = _deploy(9000, "lp-preview-high"); // 90% LP -> non-LP floored at 3 bps
        (,, uint24 nonLpLow) = hook.previewFee(_poolId(address(low)), _exactInParams(0.1 ether));
        (,, uint24 nonLpHigh) = hook.previewFee(_poolId(address(high)), _exactInParams(0.1 ether));
        assertGt(nonLpLow, nonLpHigh, "lower LP share -> larger non-LP fee");
        assertEq(nonLpLow, uint24(_expectedProtocolRate(2000)));
        assertEq(nonLpHigh, uint24(_expectedProtocolRate(9000)));
    }

    function test_emptyPayload_usesDefaultLpShare() public {
        MockBCToken coin = _deployCoin(
            "LpShare",
            "LPS",
            50,
            IBCTokenFactory.StakingConfig({deployStaking: false, alternativeFeeRecipient: address(0)}),
            bytes("")
        );
        _graduate(coin);
        assertEq(hook.getPoolState(_poolId(address(coin))).lpShareBps, 7000, "empty payload -> DEFAULT_LP_SHARE_BPS");
    }
}
