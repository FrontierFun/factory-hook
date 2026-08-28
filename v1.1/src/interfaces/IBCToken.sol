// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBCTokenFactory} from "src/interfaces/IBCTokenFactory.sol";

/**
 * @title IBCToken
 * @author Frontier
 * @notice ERC-20 with an integrated bonding curve that seeds a liquidity pool once `MAX_SUPPLY` is reached.
 */
interface IBCToken {
    /**
     * @notice Creation parameters of a coin. `_protocolFee`, `_creatorFee` and `_refundFee` are bps of the raised
     * ETH paid at LP seeding, the refund to whoever triggers it; `_communityFeeRatio` is 0-100.
     *
     * With `_directSeed` the coin is born graduated: the curve fields are ignored and zeroed, and `_seedTick` is the
     * tick-spacing-aligned opening tick (upper bound of the one-sided coin position); zero in curve mode.
     * @param _name Token name.
     * @param _symbol Token ticker symbol.
     * @param _img On-chain image URI metadata.
     * @param _description Human-readable description of the token.
     * @param _creator Address of the token creator.
     * @param _initialOwner Address that receives ownership of the token contract.
     * @param _factory Address of the BCTokenFactory that deployed this token.
     * @param _bondingCurve Address of the BondingCurve contract for buy/sell logic.
     * @param _positionManager Address of the Uniswap NFT Position Manager.
     * @param _weth Address of the canonical WETH contract.
     * @param _virtualReserves Initial virtual ETH reserves for the bonding curve.
     * @param _initialSupply Initial token supply minted to the contract.
     * @param _maxSupply Maximum token supply; LP is seeded when this is reached.
     * @param _protocolFee Protocol fee in bps charged upon LP seeding.
     * @param _creatorFee Creator fee in bps paid upon LP seeding.
     * @param _refundFee Fee in bps paid to the caller who triggers LP seeding.
     * @param _communityFeeRatio Community fee ratio (0-100) for staking vault distributions.
     * @param _directSeed Whether the coin is born graduated with its supply seeded directly into the pool. In direct
     * mode the curve fields above are ignored and their immutables zeroed: there is no bonding curve phase at all.
     * @param _seedTick The pool opening tick for a direct seed (tick-spacing aligned; the upper bound of the one-sided
     * coin position). Zero in curve mode.
     * @param _stakingConfig Staking vault deployment and fee recipient configuration.
     * @param _hookConfig Opaque creator hook payload forwarded to the hook at pool registration; empty for defaults.
     */
    struct InitParams {
        string _name;
        string _symbol;
        string _img;
        string _description;
        address _creator;
        address _initialOwner;
        address _factory;
        address _bondingCurve;
        address _positionManager;
        address _weth;
        uint256 _virtualReserves;
        uint256 _initialSupply;
        uint256 _maxSupply;
        uint80 _protocolFee;
        uint80 _creatorFee;
        uint80 _refundFee;
        uint8 _communityFeeRatio;
        bool _directSeed;
        int24 _seedTick;
        IBCTokenFactory.StakingConfig _stakingConfig;
        bytes _hookConfig;
    }

    /// @notice Amount would exceed `MAX_SUPPLY` or the ETH held by the coin.
    error AmountExceeded();

    /// @notice Curve burns are no longer allowed once the coin has LPd.
    error CurveCannotBurnTokens();

    /// @notice Not allowed while the coin is in its bonding-curve stage.
    error CannotPerformUntilLP();

    /// @notice Mints are no longer allowed once the coin has LPd.
    error CannotMintTokens();

    /// @notice Only the `FACTORY` owner or the bonding curve may call.
    error InvalidCaller();

    /// @notice Liquidity pool already exists or the sqrtPriceX96 is invalid.
    error InvalidLiquidityPool();

    /// @notice Failed to send ETH when minting or burning.
    error FailedToSendETH();

    /// @notice Address cannot be zero.
    error AddressZero();

    /// @notice Only the creator may set an alternative fee recipient while none is assigned.
    error OnlyCreator();

    /// @notice Only the current alternative fee recipient may delegate to a new address.
    error OnlyCurrentFeeRecipient();

    /**
     * @notice Tokens minted to `to` by a bonding-curve buy.
     * @param to Address receiving minted tokens.
     * @param amount Amount of tokens minted.
     */
    event Mint(address indexed to, uint256 amount);

    /**
     * @notice Tokens burned by `from`, on a curve sell or a post-LP holder burn.
     * @param from Address burning tokens.
     * @param amount Amount of tokens burned.
     */
    event Burn(address indexed from, uint256 amount);

    /**
     * @notice Alternative fee recipient changed; `newRecipient` is address(0) when cleared.
     * @param newRecipient The new alternative fee recipient address (address(0) clears it).
     */
    event AlternativeFeeRecipientUpdated(address indexed newRecipient);

    /**
     * @notice Graduation fees paid out of the raised ETH at LP seeding, once per coin. Amounts are in WETH wei
     * and zero when the corresponding fee is zero.
     * @param feeRecipient Recipient of `creatorAmount`: the creator, or the alternative fee recipient.
     * @param caller Caller who triggered the seeding, paid `refundAmount`.
     * @param creatorAmount The creator fee paid to `feeRecipient`.
     * @param protocolAmount Protocol fee paid to the factory's protocol treasury.
     * @param refundAmount The refund fee paid to `caller`.
     */
    event GraduationFeesPaid(
        address indexed feeRecipient,
        address indexed caller,
        uint256 creatorAmount,
        uint256 protocolAmount,
        uint256 refundAmount
    );

    /**
     * @notice The BCTokenFactory that deployed this coin.
     * @return The address of the Token Factory.
     */
    function FACTORY() external view returns (address);

    /**
     * @notice The NFT position manager used to create LP positions.
     * @return The address of the NFT Position Manager.
     */
    function POSITION_MANAGER() external view returns (address);

    /**
     * @notice The LiquidityManager responsible for pool creation and seeding.
     * @return The address of the LiquidityManager contract.
     */
    function LIQUIDITY_MANAGER() external view returns (address);

    /**
     * @notice The canonical WETH contract.
     * @return The address of the WETH contract.
     */
    function WETH() external view returns (address);

    /**
     * @notice ETH, in wei, needed to seed the liquidity pool.
     * @return The amount of ETH needed to seed the liquidity pool.
     */
    function TARGET_ETH() external view returns (uint256);

    /**
     * @notice Initial virtual ETH reserves of the bonding-curve pricing formula.
     * @return The initial virtual balance of the coin.
     */
    function VIRTUAL_BALANCE() external view returns (uint256);

    /**
     * @notice Supply minted to the contract at deployment for bonding-curve operations.
     * @return The initial supply of the coin.
     */
    function INITIAL_SUPPLY() external view returns (uint256);

    /**
     * @notice Maximum supply; the liquidity pool is seeded when `totalSupply()` reaches it.
     * @return The maximum token supply allowed.
     */
    function MAX_SUPPLY() external view returns (uint256);

    /**
     * @notice Protocol fee in bps charged on the raised ETH at LP seeding.
     * @return The fee charged in bps by the protocol when the bonding curve is completed.
     */
    function PROTOCOL_FEE() external view returns (uint80);

    /**
     * @notice Creator fee in bps paid from the raised ETH at LP seeding.
     * @return The fee paid in bps to the coin creator when the bonding curve is completed.
     */
    function CREATOR_FEE() external view returns (uint80);

    /**
     * @notice Fee in bps paid to the caller who triggers LP seeding.
     * @return The refund fee in basis points.
     */
    function REFUND_FEE() external view returns (uint80);

    /**
     * @notice Share (0-100) of the pool's swap fees directed to the community staking vault.
     * @return The community fee ratio (0-100).
     */
    function COMMUNITY_FEE_RATIO() external view returns (uint8);

    /**
     * @notice The coin creator, set at deployment.
     * @return The creator address set at deployment.
     */
    function creator() external view returns (address);

    /**
     * @notice The BondingCurve contract handling buys and sells of this coin.
     * @return The address of the BondingCurve contract.
     */
    function bondingCurve() external view returns (address);

    /**
     * @notice The hook governing this coin's pool.
     * @dev V4 pools are PoolManager records, not contracts; discover the pool through
     * `LiquidityManager.getPoolKey(token)` / `getPoolId(token)`.
     * @return The address of the hook governing the created pool.
     */
    function lp() external view returns (address);

    /**
     * @notice The harvester of the factory's LP positions.
     * @return The address of the factory LP positions harvester.
     */
    function harvester() external view returns (address);

    /**
     * @notice Whether the coin has reached the LP stage: from graduation for curve coins, from birth for
     * direct-seed coins. A lifecycle flag, distinct from the immutable `DIRECT_SEED`.
     * @return The status of LP.
     */
    function isLPd() external view returns (bool);

    /**
     * @notice Whether the coin launched in direct-seed mode: no bonding curve, born graduated with its full
     * supply seeded as one-sided pool liquidity.
     * @dev Immutable birth property and the onchain source of truth for the launch mode, resolvable by
     * `eth_call` on resync; `isLPd` is the lifecycle flag, which happens to be true from birth here.
     * @return Whether the coin is a direct-seed launch.
     */
    function DIRECT_SEED() external view returns (bool);

    /**
     * @notice Graduation (LP seeding) timestamp in seconds, zero until the coin graduates; the record of when
     * trading opened, used by time-window fee extensions.
     * @return The graduation timestamp.
     */
    function lpdAt() external view returns (uint256);

    /**
     * @notice Mints `amount` tokens to `to` against `amountETH` paid on the curve; only the bonding curve may call.
     * @param to Address of user to receive tokens.
     * @param amount Amount of tokens minted.
     * @param amountETH Amount of ETH used to mint tokens.
     */
    function mint(address to, uint256 amount, uint256 amountETH) external payable;

    /**
     * @notice Burns `amount` of `owner`'s tokens on a curve sell, returning `amountETH`; only the bonding curve
     * may call.
     * @param owner Address of user burning tokens.
     * @param amount Amount of tokens burned.
     * @param amountETH Amount of ETH returned to burner user.
     */
    function burnCurve(address owner, uint256 amount, uint256 amountETH) external;

    /**
     * @notice Burns `amount` of the caller's own tokens; not allowed until the coin has LPd.
     * @dev Post-LP burns are intentional: the LP positions seeded at graduation are not adjusted, so circulating
     * supply may drift below the post-graduation supply over time.
     * @param amount Amount of tokens to burn.
     */
    function burn(uint256 amount) external;

    /**
     * @notice ETH received, in wei, if one whole coin is sold to the bonding curve.
     * @return The amount of ETH per coin.
     */
    function price() external view returns (uint256);

    /**
     * @notice The coin's image URI metadata.
     * @return The image URI of the coin.
     */
    function tokenURI() external returns (string memory);

    /**
     * @notice ETH accumulated through curve buys and sells, including the virtual reserves.
     * @return The amount of ETH.
     */
    function reserveBalance() external view returns (uint256);

    /**
     * @notice ETH accumulated through curve buys and sells, excluding the virtual reserves.
     * @return The amount of ETH.
     */
    function TVL() external view returns (uint256);

    /**
     * @notice Human-readable description of the coin.
     * @return The human-readable description of the token.
     */
    function description() external view returns (string memory);

    /**
     * @notice Vesting contract exempt from the pre-LP transfer restriction, frozen at construction; address(0)
     * when none was set.
     * @return The vesting contract frozen at construction, or address(0) when none was set.
     */
    function TOKEN_VESTING() external view returns (address);

    /**
     * @notice Alternative fee recipient, or address(0) when none is set.
     * @return The alternative fee recipient, or address(0) if not set.
     */
    function alternativeFeeRecipient() external view returns (address);

    /**
     * @notice Sets or clears the alternative recipient of creator/community fees. Only the creator may assign
     * one while none is set; once set, only the current recipient may delegate onward. address(0) clears it.
     * @param _recipient The new alternative fee recipient (address(0) to clear).
     */
    function setAlternativeFeeRecipient(address _recipient) external;

    /**
     * @notice Effective recipient of creator/community fees: the alternative fee recipient if set, else the
     * creator.
     * @return The address that currently receives creator/community fee distributions.
     */
    function getFeeRecipient() external view returns (address);
}
