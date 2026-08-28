// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBCTokenDeployer} from "src/interfaces/IBCTokenDeployer.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

/**
 * @title IBCTokenFactory
 * @author Frontier
 * @notice Factory that deploys bonding-curve-backed BCTokens, with optional staking vaults and a creator buy.
 */
interface IBCTokenFactory {
    /**
     * @notice Address configuration of the factory.
     * @param owner Address owner of the contract.
     * @param treasury Address of the protocol treasury receiving protocol fees.
     * @param harvester Address of the contract that can harvest LP positions.
     * @param positionManager Address of liquidity NFT Position Manager contract.
     * @param weth Address of WETH token.
     * @param tokenDeployer Address of the BCTokenDeployer contract.
     * @param tokenVesting Address of the token vesting contract.
     */
    struct FactoryAddresses {
        address owner;
        address treasury;
        address harvester;
        address positionManager;
        address weth;
        address tokenDeployer;
        address tokenVesting;
    }

    /**
     * @notice Curve and fee parameters of the factory. `protocolFee`, `creatorFee` and `refundFee` are in bps and
     * charged at LP seeding; `creationFee` is a flat ETH amount in wei charged at deploy.
     * @param virtualReserves Initial virtual reserves of the bonding curve.
     * @param initialSupply Initial supply of coin allocated to the bonding curve for seeding LP.
     * @param maxSupply Maximum coin supply allowed.
     * @param protocolFee Fee charged by the protocol when bonding curve LPs.
     * @param creatorFee Fee earned by the creator when bonding curve LPs.
     * @param refundFee Fee paid to the caller who triggers LP seeding.
     * @param creationFee Fee earned by the protocol when coin is created.
     * @param curveBounds Protocol bounds every curve launch's params must satisfy.
     * @param seedFdvBounds FDV window every direct-seed launch must open inside.
     */
    struct FactoryParams {
        uint256 virtualReserves;
        uint256 initialSupply;
        uint256 maxSupply;
        uint80 protocolFee;
        uint80 creatorFee;
        uint80 refundFee;
        uint80 creationFee;
        CurveBounds curveBounds;
        SeedFdvBounds seedFdvBounds;
    }

    /**
     * @notice Creator-supplied launch configuration. `directSeed` selects the mode: curve mode runs the bonding
     * curve with explicit, bounds-checked `virtualReserves` (ETH wei) and `initialSupply`, and `seedTick` must be
     * zero; direct mode skips the curve, seeds the full supply one-sided at `seedTick`, and the curve fields must
     * be zero.
     *
     * `maxSupply` is deliberately absent: it is protocol-defined and read from factory storage on every deploy.
     * @dev No contract-level defaults: the curve fields are never filled from `initialParams()`. In direct mode, ETH
     * beyond the creation fee becomes an atomic first-fill dev buy.
     * @param directSeed Whether the coin seeds its pool directly instead of running a curve.
     * @param virtualReserves Initial virtual ETH reserves of the bonding curve (curve mode only; must be zero in direct
     * mode).
     * @param initialSupply Initial supply of coin allocated to the bonding curve for seeding LP (curve mode only; must
     * be zero in direct mode).
     * @param seedTick The pool opening tick for a direct seed — must fall exactly on a tick-spacing multiple and price
     * the coin inside the protocol's seed FDV window (direct mode only; must be zero in curve mode).
     */
    struct LaunchConfig {
        bool directSeed;
        uint256 virtualReserves;
        uint256 initialSupply;
        int24 seedTick;
    }

    /**
     * @notice FDV window in ETH wei every direct-seed launch must open inside:
     * `minFdv <= maxSupply * seedPrice <= maxFdv`, with `seedPrice` the ETH-per-coin price at the seed tick.
     * `minFdv` must be non-zero. Owner-tunable so it can track the ETH price without a redeploy.
     * @dev Enforced by the LiquidityManager alongside its tick checks; the USD → ETH translation is offchain policy.
     * @param minFdv Lower FDV bound in wei (must be non-zero).
     * @param maxFdv Upper FDV bound in wei.
     */
    struct SeedFdvBounds {
        uint256 minFdv;
        uint256 maxFdv;
    }

    /**
     * @notice Protocol bounds every curve-mode launch must satisfy. `minRaise` is the minimum ETH raised at
     * graduation (`targetETH - virtualReserves`), in wei; the two `supplyRatio*Wad` fields bound
     * `maxSupply / initialSupply`, WAD-scaled; the two `*InitialFdv` fields bound the launch FDV, which equals
     * `virtualReserves`, in wei.
     *
     * `minRaise` also implies a `virtualReserves` floor of `minRaise / (ratio - 1)`; whichever floor is higher binds.
     * `maxSupply` has no window here: it is owner-set, and only the uint128 ceiling applies.
     * @dev Without these bounds a degenerate curve is a disguised skip of the curve phase; the USD → ETH translation is
     * offchain policy.
     * @param minRaise Minimum ETH raised at graduation (`targetETH − virtualReserves`), in wei.
     * @param supplyRatioFloorWad Lower bound of the `maxSupply / initialSupply` ratio, WAD-scaled.
     * @param supplyRatioCapWad Upper bound of the `maxSupply / initialSupply` ratio, WAD-scaled.
     * @param minInitialFdv Lower bound of the launch FDV (`virtualReserves`), in wei (non-zero).
     * @param maxInitialFdv Upper bound of the launch FDV (`virtualReserves`), in wei.
     */
    struct CurveBounds {
        uint256 minRaise;
        uint256 supplyRatioFloorWad;
        uint256 supplyRatioCapWad;
        uint256 minInitialFdv;
        uint256 maxInitialFdv;
    }

    /**
     * @notice Staking configuration for pool creation. `alternativeFeeRecipient` redirects WETH and coin fees and
     * may be set with or without a staking vault.
     * @param deployStaking Whether to deploy a staking vault for the pool.
     * @param alternativeFeeRecipient Alternative fee recipient for WETH and coin fees. Can be used with or without a
     * staking vault.
     */
    struct StakingConfig {
        bool deployStaking;
        address alternativeFeeRecipient;
    }

    /// @notice Provided address cannot be the zero address.
    error InvalidZeroAddress();

    /// @notice Ownership renouncement is disabled: `owner()` gates admin and recovery across the protocol.
    error RenounceDisabled();

    /// @notice Sent value does not cover the creation fee.
    error InsufficientCreationFee();

    /// @notice ETH transfer failed on withdraw.
    error FailedToSendETH();

    /// @notice `initialSupply` and `virtualReserves` must be non-zero and `initialSupply` below `maxSupply`.
    error InvalidInitialParams();

    /**
     * @notice The launch config carries the other mode's fields: `seedTick` in curve mode, curve params in direct
     * mode. They must be zero rather than be silently ignored.
     */
    error InvalidLaunchConfig();

    /// @notice `minFdv` must be non-zero and must not exceed `maxFdv`.
    error InvalidSeedFdvBounds();

    /**
     * @notice A direct-seed launch sent a dev buy while no DirectSeeder is set; the ETH cannot be honoured and
     * must not sit in the factory.
     */
    error DirectSeederUnset();

    /**
     * @notice `maxSupply` is at or above 2^128: the LiquidityManager's seeding math is uint128-bound, so the coin
     * would trade but brick at the graduation mint. This is the only bound on the owner-set `maxSupply`.
     * @param maxSupply The rejected max supply.
     */
    error MaxSupplyOutOfBounds(uint256 maxSupply);

    /**
     * @notice `maxSupply / initialSupply` falls outside `supplyRatioFloorWad..supplyRatioCapWad`.
     * @param ratioWad The rejected ratio, WAD-scaled.
     */
    error SupplyRatioOutOfBounds(uint256 ratioWad);

    /**
     * @notice The ETH raised at graduation (`targetETH - virtualReserves`) is below `minRaise`.
     * @param raise The rejected raise, in wei.
     */
    error RaiseBelowMinimum(uint256 raise);

    /**
     * @notice The launch FDV (`virtualReserves`) falls outside `minInitialFdv..maxInitialFdv`.
     * @param initialFdv The rejected launch FDV, in wei.
     */
    error InitialFdvOutOfBounds(uint256 initialFdv);

    /**
     * @notice Curve bounds are inconsistent: `minRaise` and `minInitialFdv` must be non-zero, the ratio floor must
     * exceed 1 WAD and not exceed the cap, the FDV floor must not exceed its cap, and `maxInitialFdv` must admit
     * the `virtualReserves` floor `minRaise` implies at the ratio cap.
     */
    error InvalidCurveBounds();

    /// @notice A fee exceeds `MAX_FEE`.
    error InvalidFees();

    /// @notice The protocol is paused.
    error ProtocolPaused();

    /**
     * @notice Token params are invalid, or the caller already deployed a coin with this exact name, symbol,
     * description and image.
     */
    error InvalidParams();

    /// @notice Community fee ratio cannot exceed 100.
    error InvalidCommunityFeeRatio();

    /// @notice The hook config payload exceeds `maxHookConfigBytes`.
    error HookConfigTooLarge();

    /**
     * @notice The cap on the hook config payload changed; both values in bytes.
     * @param previousMax The previous cap in bytes.
     * @param newMax The new cap in bytes.
     */
    event MaxHookConfigBytesUpdated(uint256 previousMax, uint256 newMax);

    /// @notice Deploying a staking vault requires a non-zero community fee ratio.
    error StakingRequiresCommunityFee();

    /// @notice Salt already used for a deployment.
    error SaltAlreadyUsed();

    /// @notice Creator buy exceeds `maxCreatorBuyBps` of total supply.
    error CreatorBuyExceedsCap();

    /// @notice Value exceeds the 2500 bps (25%) hard cap on the max creator buy.
    error ExceedsHardCap();

    /**
     * @notice Creator share exceeds the maximum.
     * @param maxCreatorShareBps The maximum creator share in bps that is allowed.
     */
    error MaxCreatorShareExceeded(uint256 maxCreatorShareBps);

    /**
     * @notice Fees changed: `protocolFee`, `creatorFee` and `refundFee` in bps, charged at LP seeding;
     * `creationFee` a flat ETH amount in wei.
     * @param protocolFee New protocol fee in bps charged upon LP seeding.
     * @param creatorFee New creator fee in bps paid upon LP seeding.
     * @param refundFee New fee in bps paid to the caller who triggers LP seeding.
     * @param creationFee New flat ETH fee charged to create a new coin.
     */
    event FeesUpdated(uint80 protocolFee, uint80 creatorFee, uint80 refundFee, uint80 creationFee);

    /**
     * @notice The bonding curve contract changed.
     * @param bondingCurve The new bonding curve contract address.
     */
    event BondingCurveUpdated(address indexed bondingCurve);

    /**
     * @notice The creator's share of the curve trade fee changed.
     * @param creatorShareBps In bps of the fee net of referral.
     */
    event CreatorShareUpdated(uint256 creatorShareBps);

    /**
     * @notice The LiquidityManager contract changed.
     * @param liquidityManager The new liquidity manager contract address.
     */
    event LiquidityManagerUpdated(address indexed liquidityManager);

    /**
     * @notice A new BCToken was deployed. For direct-seed coins this event is the seed signal (they never emit
     * `LPSeeded`) and every curve-only field (`initialSupply`, `initialETHReserves`, `initialPrice`,
     * `initialMarketCap`, `targetETH`) is zero.
     * @param creator The address that deployed the BCToken.
     * @param token The address of the newly deployed BCToken.
     * @param factory The address of the BCTokenFactory that deployed the token.
     * @param lp The hook governing the coin's V4 pool.
     * @param name The human-readable name of the token.
     * @param symbol The ticker symbol of the token.
     * @param description The human-readable description of the token.
     * @param image The on-chain image URI of the token.
     * @param initialSupply The initial token supply minted to the BCToken for LP seeding.
     * @param maxSupply The supply at which LP is seeded.
     * @param initialETHReserves The curve's initial virtual ETH reserves.
     * @param initialPrice The curve's initial spot price, in ETH per token.
     * @param initialMarketCap `initialPrice * initialSupply`.
     * @param targetETH The ETH, including virtual reserves, required to reach LP seeding.
     * @param directSeed Whether the coin was born seeded (direct mode). Indexed so consumers can filter launches by
     * mode. For direct coins this event IS the seed signal — they never emit `LPSeeded` — and every curve-only field
     * above (`initialSupply`, `initialETHReserves`, `initialPrice`, `initialMarketCap`, `targetETH`) is zero; launch
     * pricing comes from the pool itself from birth.
     */
    event CoinDeployed(
        address indexed creator,
        address indexed token,
        address factory,
        address lp,
        string name,
        string symbol,
        string description,
        string image,
        uint256 initialSupply,
        uint256 maxSupply,
        uint256 initialETHReserves,
        uint256 initialPrice,
        uint256 initialMarketCap,
        uint256 targetETH,
        bool indexed directSeed
    );

    /**
     * @notice Emitted on every deploy right after `CoinDeployed` with the alternative fee recipient set at
     * construction; `address(0)` means fees go to the creator. Later changes emit the token's own
     * `AlternativeFeeRecipientUpdated`.
     * @param token The deployed coin.
     * @param recipient The alternative fee recipient set at construction, or address(0).
     */
    event FeeRecipientAssigned(address indexed token, address indexed recipient);

    /**
     * @notice The harvester contract changed.
     * @param newHarvester The new harvester contract address.
     */
    event UpdatedHarvester(address indexed newHarvester);

    /**
     * @notice The token vesting contract changed.
     * @param tokenVesting The new token vesting contract address.
     */
    event TokenVestingUpdated(address indexed tokenVesting);

    /**
     * @notice The default initial params for new coins changed; `virtualReserves` in ETH wei.
     * @param virtualReserves The new initial virtual ETH reserves for the bonding curve.
     * @param initialSupply The new initial token supply minted to the bonding curve.
     * @param maxSupply The new maximum token supply at which LP is seeded.
     */
    event UpdatedInitialParams(uint256 virtualReserves, uint256 initialSupply, uint256 maxSupply);

    /**
     * @notice The direct-seed FDV window changed; bounds in ETH wei.
     * @param minFdv The new lower FDV bound in wei.
     * @param maxFdv The new upper FDV bound in wei.
     */
    event SeedFdvBoundsUpdated(uint256 minFdv, uint256 maxFdv);

    /**
     * @notice The DirectSeeder pointer changed; `newSeeder == address(0)` unplugs the dev buy.
     * @param previousSeeder The previous DirectSeeder address.
     * @param newSeeder The new DirectSeeder address (address(0) unplugs the dev buy).
     */
    event DirectSeederUpdated(address indexed previousSeeder, address indexed newSeeder);

    /**
     * @notice The protocol curve bounds changed; see `CurveBounds` for units.
     * @param minRaise The new minimum ETH raised at graduation, in wei.
     * @param supplyRatioFloorWad The new lower bound of the supply ratio, WAD-scaled.
     * @param supplyRatioCapWad The new upper bound of the supply ratio, WAD-scaled.
     * @param minInitialFdv The new lower bound of the launch FDV (`virtualReserves`), in wei.
     * @param maxInitialFdv The new upper bound of the launch FDV (`virtualReserves`), in wei.
     */
    event CurveBoundsUpdated(
        uint256 minRaise,
        uint256 supplyRatioFloorWad,
        uint256 supplyRatioCapWad,
        uint256 minInitialFdv,
        uint256 maxInitialFdv
    );

    /**
     * @notice The cap on the creator buy, in bps of total supply, changed.
     * @param newMaxBps The new maximum creator buy percentage in basis points.
     */
    event MaxCreatorBuyBpsUpdated(uint256 newMaxBps);

    /**
     * @notice The creator bought tokens in the deploy transaction: a curve buy in curve mode, a pool dev buy via
     * the DirectSeeder in direct mode.
     * @param creator Address of the token creator performing the buy.
     * @param token Address of the newly deployed BCToken.
     * @param ethAmount Amount of ETH spent on the creator buy.
     * @param tokenAmount Amount of tokens received by the creator.
     */
    event CreatorBuy(address indexed creator, address indexed token, uint256 ethAmount, uint256 tokenAmount);

    /**
     * @notice The protocol pause state changed.
     * @param paused Whether the protocol is paused.
     */
    event ProtocolPausedUpdated(bool paused);

    /**
     * @notice Residual ETH was swept to the protocol treasury; `amount` in wei.
     * @param to The recipient of the swept ETH (the protocol treasury).
     * @param amount The amount of ETH swept (in wei).
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice The protocol treasury changed.
     * @param treasury The new treasury address.
     */
    event TreasurySet(address indexed treasury);

    /**
     * @notice The protocol owner (Ownable).
     * @return The address of the factory owner.
     */
    function owner() external view returns (address);

    /**
     * @notice The protocol treasury receiving protocol fees.
     * @dev Resolved through the factory at pay time by the curve, the BCToken and the hook, so one update here
     * re-routes protocol fees across every deployed coin, curve and hook generation.
     * @return The address of the protocol treasury.
     */
    function treasury() external view returns (address);

    /**
     * @notice Sets the protocol treasury. Owner only; cannot be the zero address.
     * @dev Deliberately distinct from `owner()`: operations and revenue custody are separate roles.
     * @param _treasury The new treasury address.
     */
    function setTreasury(address _treasury) external;

    /**
     * @notice The NFT position manager.
     * @return The address of the NFT Position Manager contract.
     */
    function POSITION_MANAGER() external view returns (address);

    /**
     * @notice The WETH token.
     * @return The address of the WETH token.
     */
    function WETH() external view returns (address);

    /**
     * @notice Whether the protocol is paused.
     * @return Whether the protocol is paused.
     */
    function PROTOCOL_PAUSED() external view returns (bool);

    /**
     * @notice The BCTokenDeployer that deploys coins via CREATE3.
     * @return The BCTokenDeployer contract.
     */
    function TOKEN_DEPLOYER() external view returns (IBCTokenDeployer);

    /**
     * @notice Maximum protocol, creator or refund fee, in bps.
     * @return The maximum fee in basis points.
     */
    function MAX_FEE() external view returns (uint256);

    /**
     * @notice Whether `token` was deployed by this factory.
     * @param token The address to check.
     * @return Whether the address is a valid BCToken.
     */
    function bcTokens(address token) external view returns (bool);

    /**
     * @notice The coin deployed with a given params hash, `keccak256(abi.encode(creator, name, symbol, description,
     * image))`; the metadata reservation is per creator, not global.
     * @param paramsHash The hash of the coin's creator and initial parameters.
     * @return The address of the coin.
     */
    function bcTokensParams(bytes32 paramsHash) external view returns (address);

    /**
     * @notice The contract allowed to harvest LP positions.
     * @return The address of the harvester contract.
     */
    function harvester() external view returns (address);

    /**
     * @notice The current bonding curve contract.
     * @return The address of the bonding curve contract.
     */
    function bondingCurve() external returns (IBondingCurve);

    /**
     * @notice The current liquidity manager.
     * @return The address of the liquidity manager contract.
     */
    function liquidityManager() external view returns (address);

    /**
     * @notice The token vesting contract.
     * @return The address of the token vesting contract.
     */
    function tokenVesting() external view returns (address);

    /**
     * @notice Deploys a new coin via CREATE3 at `keccak256(abi.encodePacked(msg.sender, salt))`, independent of the
     * metadata. Reverts `InvalidParams` if this caller already deployed a coin with the same name, symbol,
     * description and image. ETH sent beyond the creation fee becomes the creator buy of the chosen mode.
     * @param name The name of the new coin.
     * @param symbol The symbol of the new coin.
     * @param description The description of the new coin.
     * @param image The image source code to store.
     * @param communityFeeRatio At most 100.
     * @param salt The salt for the CREATE3 deployment.
     * @param launchConfig Mode and mode params; curve params are checked against `curveBounds()` together with the
     * `maxSupply` from `initialParams()`, never defaulted.
     * @param stakingConfig Staking vault configuration.
     * @param hookConfig Opaque creator hook payload, empty for defaults; only length-capped here, validated by the
     * hook in `registerPool`.
     * @return The address of the newly deployed coin.
     */
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata description,
        string calldata image,
        uint8 communityFeeRatio,
        bytes32 salt,
        LaunchConfig calldata launchConfig,
        StakingConfig calldata stakingConfig,
        bytes calldata hookConfig
    ) external payable returns (address);

    /**
     * @notice Sweeps residual ETH to the protocol treasury. Owner only.
     * @dev Protocol fees are pushed at source in `deploy`; the balance holds only incidental ETH such as
     * supply-capped creator-buy refunds.
     * @param amount Amount of ETH to sweep.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Sets the bonding curve contract.
     * @param _bondingCurve Address of the bonding curve contract.
     */
    function setBondingCurve(address _bondingCurve) external;

    /**
     * @notice Sets the creator's share of the curve trade fee net of referral; read by the curve on every trade.
     * @param _creatorShareBps In bps, at most 10_000.
     */
    function setCreatorShareBps(uint16 _creatorShareBps) external;

    /**
     * @notice The creator's share of the curve trade fee net of referral, in bps.
     * @return The creator share (in BPS of 10 000).
     */
    function creatorShareBps() external view returns (uint16);

    /**
     * @notice Sets the liquidity manager contract.
     * @param _liquidityManager Address of the liquidity manager contract.
     */
    function setLiquidityManager(address _liquidityManager) external;

    /**
     * @notice Updates the default initial params for new coins; `_maxSupply` is authoritative for every launch,
     * the other two are a frontend prefill.
     * @param _virtualReserves New initial virtual reserves.
     * @param _initialSupply New coin initial supply.
     * @param _maxSupply New coin `MAX_SUPPLY`.
     */
    function updateInitialParams(uint256 _virtualReserves, uint256 _initialSupply, uint256 _maxSupply) external;

    /**
     * @notice Updates the fees: `_protocolFee`, `_creatorFee` and `_refundFee` in bps charged at LP seeding,
     * `_creationFee` a flat ETH amount in wei.
     * @param _protocolFee Fee earned by the protocol when bonding curve LPs in bps.
     * @param _creatorFee Fee earned by the creator when bonding curve LPs in bps.
     * @param _refundFee Fee paid to the caller who triggers LP seeding in bps.
     * @param _creationFee The fee charged to create a new coin.
     */
    function updateFees(uint80 _protocolFee, uint80 _creatorFee, uint80 _refundFee, uint80 _creationFee) external;

    /**
     * @notice Sets the harvester contract.
     * @param _harvester The new address to set as harvester.
     */
    function setHarvester(address _harvester) external;

    /**
     * @notice Sets the token vesting contract.
     * @param _tokenVesting The new address to set as token vesting.
     */
    function setTokenVesting(address _tokenVesting) external;

    /**
     * @notice Sets the protocol pause state.
     * @param _state Whether the protocol is paused or not.
     */
    function setProtocolPaused(bool _state) external;

    /**
     * @notice The default curve initialisation params. `virtualReserves` (ETH wei) and `initialSupply` are a
     * frontend prefill only, while `maxSupply` is authoritative: `deploy` reads it from storage for every launch
     * and creators cannot override it.
     * @return virtualReserves The virtual ETH reserves seeded into the bonding curve.
     * @return initialSupply The initial token supply minted to the bonding curve.
     * @return maxSupply The maximum token supply; LP is seeded when reached.
     */
    function initialParams() external view returns (uint256 virtualReserves, uint256 initialSupply, uint256 maxSupply);

    /**
     * @notice The FDV window in ETH wei every direct-seed launch must open inside.
     * @return The current seed FDV bounds.
     */
    function seedFdvBounds() external view returns (SeedFdvBounds memory);

    /**
     * @notice Updates the direct-seed FDV window, in ETH wei. Owner only; retune it as the ETH price moves.
     * @param bounds The new seed FDV bounds.
     */
    function updateSeedFdvBounds(SeedFdvBounds calldata bounds) external;

    /**
     * @notice The DirectSeeder executing direct-launch dev buys; `address(0)` when unplugged.
     * @return The DirectSeeder address (address(0) when unplugged).
     */
    function directSeeder() external view returns (address);

    /**
     * @notice Sets the DirectSeeder. Owner only; `address(0)` is allowed and unplugs the dev buy while direct
     * launches without one keep working.
     * @param _directSeeder The new DirectSeeder address (address(0) to unplug).
     */
    function setDirectSeeder(address _directSeeder) external;

    /**
     * @notice The protocol bounds enforced on every curve launch's params.
     * @return The current curve bounds.
     */
    function curveBounds() external view returns (CurveBounds memory);

    /**
     * @notice Updates the curve bounds. Owner only.
     * @dev The stored default params are not re-validated: narrowing the bounds past them makes prefilled deploys
     * revert until `updateInitialParams` re-tunes them.
     * @param bounds The new curve bounds.
     */
    function updateCurveBounds(CurveBounds calldata bounds) external;

    /**
     * @notice The current fee configuration: the three fees in bps charged at LP seeding, `creationFee` in wei.
     * @return protocolFee Fee earned by the protocol when bonding curve LPs in bps.
     * @return creatorFee Fee earned by the creator when bonding curve LPs in bps.
     * @return refundFee Fee paid to the caller who triggers LP seeding in bps.
     * @return creationFee Fee charged to create a new coin in wei.
     */
    function feeConfig()
        external
        view
        returns (uint80 protocolFee, uint80 creatorFee, uint80 refundFee, uint80 creationFee);

    /**
     * @notice Hard cap on the max creator buy: 2500 bps (25%).
     * @return The hard cap in basis points.
     */
    function MAX_CREATOR_BUY_BPS_HARD_CAP() external view returns (uint256);

    /**
     * @notice Cap on the creator buy at deployment, in bps of total supply.
     * @return The max creator buy cap in basis points (e.g., 2500 = 25%).
     */
    function maxCreatorBuyBps() external view returns (uint16);

    /**
     * @notice Sets the creator buy cap, in bps of total supply; cannot exceed the 2500 bps hard cap. Owner only.
     * @param _newMaxBps The new max creator buy percentage in basis points.
     */
    function setMaxCreatorBuyBps(uint16 _newMaxBps) external;

    /**
     * @notice Custody-side cap on the opaque hook config payload, in bytes; the per-schema bound lives in each hook
     * generation's `registerPool`.
     * @return The cap in bytes.
     */
    function maxHookConfigBytes() external view returns (uint256);

    /**
     * @notice Sets the hook config payload cap, in bytes. Owner only; raise it alongside a hook generation switch
     * whose schema needs more room.
     * @param _maxHookConfigBytes The new cap in bytes.
     */
    function setMaxHookConfigBytes(uint256 _maxHookConfigBytes) external;
}
