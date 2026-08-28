// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title HookAddressMiner
 * @notice CREATE2 salt miner for Uniswap V4 hook addresses. Hashes the initcode ONCE and
 * iterates salts over the cached hash — the periphery test miner re-hashes the full initcode
 * per iteration, which is too slow to run inside Medusa harness constructors.
 * @dev ~16k iterations expected for a 14-bit flag match; deterministic (salts tried in order).
 */
library HookAddressMiner {
    /// @notice Mask of the 14 hook-permission bits (Hooks.ALL_HOOK_MASK).
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;

    /// @notice Upper bound on salts tried before giving up (~24x the expected iterations).
    uint256 internal constant MAX_ITERATIONS = 400_000;

    /**
     * @notice No valid salt found within MAX_ITERATIONS.
     */
    error SaltNotFound();

    /**
     * @notice Finds a CREATE2 salt so the deployed hook address encodes exactly `flags`.
     * @param deployer The CREATE2 deployer address (the contract executing `new{salt}` or the
     * canonical CREATE2 deployer proxy when broadcasting from a script).
     * @param flags The hook permission bits the address must encode.
     * @param creationCode The hook contract creation code.
     * @param constructorArgs The ABI-encoded constructor arguments (must be final — any change
     * invalidates the mined address).
     * @return hookAddress The address the hook will deploy to.
     * @return salt The salt to deploy with.
     */
    function find(address deployer, uint160 flags, bytes memory creationCode, bytes memory constructorArgs)
        internal
        view
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initcodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));
        flags = flags & FLAG_MASK;

        for (uint256 i; i < MAX_ITERATIONS; ++i) {
            salt = bytes32(i);
            hookAddress =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initcodeHash)))));
            if (uint160(hookAddress) & FLAG_MASK == flags && hookAddress.code.length == 0) {
                return (hookAddress, salt);
            }
        }
        revert SaltNotFound();
    }
}
