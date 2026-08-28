// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IFactoryHook} from "src/interfaces/IFactoryHook.sol";

import {ExtensionCampaignBase} from "test/helpers/ExtensionCampaignBase.sol";
import {MockBCToken} from "test/helpers/ProtocolMocks.sol";

/// @notice A staking vault that passes the hook's `setStakingVault` checks (right asset + hook)
/// but reverts on `notifyWethReward` — the misbehaving-vault case the guard must survive.
contract RevertingVault {
    address public asset;
    address public hook;

    constructor(address _asset, address _hook) {
        asset = _asset;
        hook = _hook;
    }

    function totalSupply() external pure returns (uint256) {
        return 1; // non-zero so the vault stays active on both legs
    }

    function notifyWethReward(uint256) external pure {
        revert("vault down");
    }
}

/// @title VaultNotifyGuardTest
/// @notice The ETH-leg fee distribution must not be brickable by a misbehaving staking vault:
/// `_distributeFee` notifies the vault under try/catch and, on revert, redirects the vault's WETH
/// share to the fee recipient so the swap completes.
contract VaultNotifyGuardTest is ExtensionCampaignBase {
    uint24 internal constant BASE_FEE = 4000;

    MockBCToken internal lottoCoin;
    PoolId internal poolId;
    RevertingVault internal badVault;

    function setUp() public override {
        super.setUp();
        vm.prank(users.owner);
        hook.setProtocolFeeRatio(25);

        // A graduated coin with communityFeeRatio 50 (from the campaign deploy) and no vault yet.
        (lottoCoin, poolId) = _deployGraduated(_emptyConfig(BASE_FEE), false);

        // Install a vault that reverts on notify.
        badVault = new RevertingVault(address(lottoCoin), address(hook));
        vm.prank(users.owner);
        hook.setStakingVault(poolId, address(badVault));
    }

    function test_revertingVault_doesNotBrickTheSwap_shareRedirected() public {
        // The fee recipient is the creator (this test contract), since no alternative was set.
        address recipient = lottoCoin.getFeeRecipient();
        assertEq(recipient, address(this), "recipient is the creator");
        uint256 recipientBefore = weth.balanceOf(recipient);

        // The guard fires: VaultNotifyFailed(coin, vault, amount) — topics checked, amount not.
        vm.expectEmit(true, true, false, false, address(hook));
        emit IFactoryHook.VaultNotifyFailed(address(lottoCoin), address(badVault), 0);

        uint256 amountOut = _swapEthForCoin(address(lottoCoin), users.buyerTwo, 0.1 ether);

        assertGt(amountOut, 0, "the swap must complete despite the reverting vault");
        assertEq(weth.balanceOf(address(badVault)), 0, "no WETH sent to the failing vault");
        assertGt(weth.balanceOf(recipient) - recipientBefore, 0, "the recipient absorbed the vault's share");
        assertEq(address(hook).balance, 0, "no native residue on the hook");
        assertEq(weth.balanceOf(address(hook)), 0, "no WETH residue on the hook");
    }

    function test_healthyVaultStillPaid_asControl() public {
        // Swap on a SEPARATE coin whose vault is a real, working StakingVault: the vault leg is
        // paid normally (no redirect, no VaultNotifyFailed).
        (MockBCToken healthy, PoolId healthyId) = _deployGraduated(_emptyConfig(BASE_FEE), true);
        address vault = hook.getPoolState(healthyId).stakingVault;
        assertTrue(vault != address(0), "healthy vault deployed");

        uint256 vaultBefore = weth.balanceOf(vault);
        _swapEthForCoin(address(healthy), users.buyerTwo, 0.1 ether);
        assertGt(weth.balanceOf(vault) - vaultBefore, 0, "healthy vault paid its WETH share");
    }
}
