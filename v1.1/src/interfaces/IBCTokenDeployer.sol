// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBCToken} from "src/interfaces/IBCToken.sol";

/**
 * @title IBCTokenDeployer
 * @author Frontier
 * @notice Interface for deploying BCTokens via CREATE3, separated from the factory to reduce bytecode size.
 */
interface IBCTokenDeployer {
    /// @notice Caller is not the factory.
    error Unauthorized();

    /// @notice The CREATE3 salt has already been used.
    error SaltAlreadyUsed();

    /**
     * @notice Deploys a new BCToken via CREATE3.
     * @param salt Expected to be `keccak256(abi.encodePacked(buyer, originalSalt))`.
     * @param params The initialization parameters for the BCToken.
     * @return token The address of the deployed token.
     */
    function deploy(bytes32 salt, IBCToken.InitParams calldata params) external returns (address token);

    /**
     * @notice The address CREATE3 deploys to for `salt`.
     * @param salt The salt that will be used for deployment.
     * @return The predicted address.
     */
    function getDeployed(bytes32 salt) external view returns (address);

    /**
     * @notice The CREATE3 factory.
     * @return The CREATE3 factory address.
     */
    function CREATE_DEPLOYER() external view returns (address);

    /**
     * @notice The BCTokenFactory authorised to call `deploy`.
     * @return The address of the BCTokenFactory.
     */
    function FACTORY() external view returns (address);
}
