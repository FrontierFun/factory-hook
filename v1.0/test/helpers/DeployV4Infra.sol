// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {MockWETH} from "test/helpers/MockWETH.sol";
import {Permit2Artifact} from "test/helpers/Permit2Artifact.sol";

/**
 * @title DeployV4Infra
 * @notice Bootstraps a REAL in-process Uniswap V4 stack for tests: PoolManager and
 * PositionManager compiled from source, canonical Permit2 etched at its canonical address,
 * a PoolSwapTest router, and a local WETH9. No fork, no secrets.
 * @dev Medusa-safe: `_etch` defaults to calling the cheatcode contract address shared by
 * forge and Medusa; override if a harness needs different plumbing.
 */
abstract contract DeployV4Infra {
    /// @notice The in-process Uniswap V4 pool manager.
    IPoolManager internal poolManager;

    /// @notice The in-process Uniswap V4 position manager (posm).
    PositionManager internal positionManager;

    /// @notice Canonical Permit2, etched at 0x000000000022D473030F116dDEE9F6B43aC78BA3.
    IAllowanceTransfer internal permit2;

    /// @notice Swap router for driving pool swaps in tests.
    PoolSwapTest internal swapRouter;

    /// @notice Local WETH9-compatible wrapped ETH.
    MockWETH internal weth;

    /**
     * @notice Deploys the full V4 stack in-process.
     * @dev Permit2 is DEPLOYED via CREATE (not `vm.etch`) so it works identically under Foundry
     * and Medusa. Medusa's EVM does not reliably execute cheatcode-etched runtime bytecode
     * (calls into an etched contract stack-underflow), whereas normally-deployed contracts run
     * fine — so etching Permit2 broke the graduation path (LiquidityManager -> Permit2.approve)
     * under Medusa only. Deploying the canonical runtime removes that discrepancy. We only use
     * Permit2's `approve` (AllowanceTransfer), which does not touch the constructor-baked EIP-712
     * domain separator, so deploying the runtime alone (skipping the constructor) is sound.
     * Consumers reference `address(permit2)`, so the non-canonical address is transparent.
     */
    function deployV4Infra() internal {
        poolManager = new PoolManager(address(0));

        permit2 = IAllowanceTransfer(_deployRuntime(Permit2Artifact.code()));

        weth = new MockWETH();

        positionManager =
            new PositionManager(poolManager, permit2, 300_000, IPositionDescriptor(address(0)), IWETH9(address(weth)));

        swapRouter = new PoolSwapTest(poolManager);
    }

    /**
     * @notice Deploys a contract whose runtime code is exactly `runtime` via CREATE.
     * @dev Wraps `runtime` in a minimal initcode that returns it verbatim:
     *   PUSH2 len; DUP1; PUSH1 10; RETURNDATASIZE; CODECOPY; RETURNDATASIZE; RETURN; <runtime>.
     * The constructor is not run — fine for code (like Permit2's AllowanceTransfer surface) that
     * does not depend on constructor-set immutables in the paths we exercise.
     * @param runtime The runtime bytecode to deploy.
     * @return deployed The address of the deployed contract.
     */
    function _deployRuntime(bytes memory runtime) internal returns (address deployed) {
        require(runtime.length <= type(uint16).max, "runtime too large");
        bytes memory initcode = abi.encodePacked(hex"61", uint16(runtime.length), hex"80600a3d393df3", runtime);
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        require(deployed != address(0), "DeployV4Infra: permit2 create failed");
    }
}
