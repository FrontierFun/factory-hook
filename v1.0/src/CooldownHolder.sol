// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICooldownHolder} from "src/interfaces/ICooldownHolder.sol";

/**
 * @title CooldownHolder
 * @author Frontier
 * @notice Holds tokens during the stake cooldown process.
 */
contract CooldownHolder is ICooldownHolder {
    /// @notice Semantic version of this contract.
    string public constant VERSION = "1.1.0";

    /// @notice The token being held.
    IERC20 public immutable bcToken;

    /// @notice Address of the staking vault authorized to call withdraw.
    address public immutable stakingVault;

    /**
     * @notice Modifier to restrict function access to only the staking vault.
     */
    modifier onlyStakingVault() {
        if (msg.sender != stakingVault) revert OnlyStakingVault();
        _;
    }

    /**
     * @notice Constructor to set the staking vault and token addresses.
     * @param _stakingVault Address of the staking vault contract.
     * @param _bcToken Address of the token contract.
     */
    constructor(address _stakingVault, address _bcToken) {
        stakingVault = _stakingVault;
        bcToken = IERC20(_bcToken);
    }

    /**
     * @inheritdoc ICooldownHolder
     */
    function withdraw(address to, uint256 amount) external onlyStakingVault {
        bcToken.transfer(to, amount);
    }
}
