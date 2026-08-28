// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title ProtocolMocks
 * @notice Stand-ins for the protocol contracts `FactoryHook` talks to, so the hook can be
 * exercised on a real in-process Uniswap V4 stack without the rest of the protocol. Each mock
 * implements exactly the surface the hook (and the hook suites) read on the real contract:
 *
 *   - `MockBCTokenFactory`   ← `BCTokenFactory`: `owner()`, `treasury()`, `liquidityManager()`
 *   - `MockBCToken`          ← `BCToken`: ERC20 + `isLPd()`, `lpdAt()`, `getFeeRecipient()`
 *   - `MockStakingVault`     ← `StakingVault`: ERC20 shares + `asset()`, `hook()`, `deposit()`,
 *                              `notifyWethReward()`, `pendingWeth()`, `wethRewardPerShare()`
 *   - `MockStakingVaultFactory` ← `StakingVaultFactory`: `hook()`, `setHook()`, `deployVault()`
 *
 * The accounting in `MockStakingVault.notifyWethReward` is the real vault's, verbatim.
 */

/// @notice Minimal BCTokenFactory stand-in: the three auth/routing views the hook reads.
contract MockBCTokenFactory {
    address public owner;
    address public treasury;
    address public liquidityManager;

    constructor(address owner_, address treasury_, address liquidityManager_) {
        owner = owner_;
        treasury = treasury_;
        liquidityManager = liquidityManager_;
    }

    function setOwner(address owner_) external {
        owner = owner_;
    }

    function setTreasury(address treasury_) external {
        treasury = treasury_;
    }

    function setLiquidityManager(address liquidityManager_) external {
        liquidityManager = liquidityManager_;
    }
}

/// @notice Minimal BCToken stand-in: a mintable ERC20 carrying the graduation flag, the
/// graduation timestamp and the fee-recipient resolution the hook reads.
contract MockBCToken is ERC20 {
    address public immutable creator;
    address public alternativeFeeRecipient;
    bool public isLPd;
    uint256 public lpdAt;

    constructor(string memory name_, string memory symbol_, address creator_) ERC20(name_, symbol_) {
        creator = creator_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Flags the coin as graduated, as `BCToken._seedLP` does once the curve sells out.
    function graduate() external {
        isLPd = true;
        lpdAt = block.timestamp;
    }

    function setAlternativeFeeRecipient(address recipient) external {
        alternativeFeeRecipient = recipient;
    }

    /// @dev Mirrors `BCToken.getFeeRecipient`: the alternative recipient when set, else the creator.
    function getFeeRecipient() external view returns (address) {
        return alternativeFeeRecipient == address(0) ? creator : alternativeFeeRecipient;
    }
}

/// @notice Minimal StakingVault stand-in: 1:1 share minting plus the WETH-reward accounting the
/// hook drives through `notifyWethReward`.
contract MockStakingVault is ERC20 {
    uint256 private constant REWARD_PRECISION = 1e18;

    IERC20 public immutable ASSET;
    address public immutable hook;
    address public immutable WETH;

    uint256 public wethRewardPerShare;
    uint256 public pendingWeth;

    error UnauthorizedNotifier();

    event WethRewardNotified(uint256 amount);

    constructor(IERC20 asset_, address hook_, address weth_) ERC20("Staked Coin", "sCOIN") {
        ASSET = asset_;
        hook = hook_;
        WETH = weth_;
    }

    function asset() external view returns (address) {
        return address(ASSET);
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        ASSET.transferFrom(msg.sender, address(this), assets);
        _mint(receiver, assets);
        return assets;
    }

    /// @dev Verbatim `StakingVault.notifyWethReward` accounting, gated on the bound hook only.
    function notifyWethReward(uint256 amount) external {
        if (msg.sender != hook) revert UnauthorizedNotifier();

        uint256 supply = totalSupply();
        uint256 total = amount + pendingWeth;
        if (supply == 0) {
            pendingWeth = total;
        } else {
            wethRewardPerShare += total * REWARD_PRECISION / supply;
            pendingWeth = 0;
        }

        emit WethRewardNotified(amount);
    }
}

/// @notice Minimal StakingVaultFactory stand-in: owner-set hook pointer and a hook-only
/// `deployVault`, as the real factory gates it.
contract MockStakingVaultFactory {
    address public owner;
    address public hook;
    address public immutable WETH;

    error OnlyOwner();
    error OnlyHook();

    event VaultDeployed(IERC20 indexed asset, address indexed vault);
    event HookUpdated(address indexed previousHook, address indexed newHook);

    constructor(address owner_, address hook_, address weth_) {
        owner = owner_;
        hook = hook_;
        WETH = weth_;
    }

    function setHook(address newHook) external {
        if (msg.sender != owner) revert OnlyOwner();
        emit HookUpdated(hook, newHook);
        hook = newHook;
    }

    function deployVault(IERC20 asset) external returns (address vault) {
        if (msg.sender != hook) revert OnlyHook();
        vault = address(new MockStakingVault(asset, hook, WETH));
        emit VaultDeployed(asset, vault);
    }
}
