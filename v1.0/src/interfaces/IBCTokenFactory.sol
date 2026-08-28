// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBCTokenDeployer} from "src/interfaces/IBCTokenDeployer.sol";
import {IBondingCurve} from "src/interfaces/IBondingCurve.sol";

/**
 * @title IBCTokenFactory
 * @author Frontier
 * @notice Interface for the factory contract that deploys bonding-curve-backed BCTokens with optional
 * staking vaults and creator buy functionality.
 */
interface IBCTokenFactory {
    /**
     * @notice Struct containing address configurations for the factory.
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
     * @notice Struct containing curve and fee parameters for the factory.
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
     * @notice Creator-supplied launch configuration for a new coin.
     * @dev Two launch modes share one deploy path, discriminated by `directSeed`. CURVE MODE
     * (`directSeed = false`): the coin trades on the bonding curve and its pool goes live at
     * graduation. Curve params are always explicit and always bounds-checked — there is no
     * defaults fallback at the contract level. A "standard" launch is a frontend concern: the
     * UI prefills `virtualReserves`/`initialSupply` from `initialParams()` and the factory
     * treats them like any other curve params. `seedTick` must be zero. DIRECT MODE
     * (`directSeed = true`): the curve is skipped entirely — the coin is born graduated, its
     * full supply is placed as one-sided pool liquidity at `seedTick` in the deploy
     * transaction, and any ETH sent beyond the creation fee becomes an atomic first-fill dev
     * buy through the pool. The curve fields must be zero. In BOTH modes `maxSupply` is
     * deliberately NOT part of the config: it is protocol-defined (owner-set via
     * `updateInitialParams`) and read from factory storage on every deploy — creators shape
     * the launch, never the coin's total supply.
     * @param directSeed Whether the coin seeds its pool directly instead of running a curve.
     * @param virtualReserves Initial virtual ETH reserves of the bonding curve (curve mode
     * only; must be zero in direct mode).
     * @param initialSupply Initial supply of coin allocated to the bonding curve for seeding
     * LP (curve mode only; must be zero in direct mode).
     * @param seedTick The pool opening tick for a direct seed — must fall exactly on a
     * tick-spacing multiple and price the coin inside the protocol's seed FDV window (direct
     * mode only; must be zero in curve mode).
     */
    struct LaunchConfig {
        bool directSeed;
        uint256 virtualReserves;
        uint256 initialSupply;
        int24 seedTick;
    }

    /**
     * @notice FDV window (in ETH wei) every direct-seed launch must open inside.
     * @dev `minFdv ≤ maxSupply × seedPrice ≤ maxFdv`, where `seedPrice` is the ETH-per-coin
     * price at the seed tick. On-chain contracts know no dollars: the USD → ETH translation is
     * off-chain policy, and the window is owner-tunable so it can track the ETH price without
     * redeploying. Enforced by the LiquidityManager next to its tick checks.
     * @param minFdv Lower FDV bound in wei (must be non-zero).
     * @param maxFdv Upper FDV bound in wei.
     */
    struct SeedFdvBounds {
        uint256 minFdv;
        uint256 maxFdv;
    }

    /**
     * @notice Protocol bounds enforced on the curve params of every curve-mode launch.
     * @dev The generating set: without it, a degenerate curve is a disguised skip of the curve
     * phase (and of the direct-seed rules). The ratio window, min raise and initial-FDV window
     * gate the creator-supplied `LaunchConfig` on every curve deploy. `maxSupply` carries no
     * window here: it is owner-set via `updateInitialParams` (creators cannot supply it at
     * all), and these bounds are set by that same owner — a window would only gate its own
     * author. Only the structural uint128 ceiling on `maxSupply` is enforced, directly at
     * validation. The initial-FDV window is the curve-mode twin of `SeedFdvBounds`: at deploy
     * the curve holds the full `maxSupply` against `virtualReserves`, so the spot price is
     * `virtualReserves / maxSupply` and the launch FDV is exactly `virtualReserves` — the
     * window binds `virtualReserves` directly, in ETH wei (the USD → ETH translation is
     * off-chain policy, owner-tunable as ETH moves). `minRaise` still implies its own
     * ratio-dependent `virtualReserves` floor (`minRaise / (ratio − 1)`, since the raised ETH
     * at graduation equals `virtualReserves × (maxSupply/initialSupply − 1)`); the two floors
     * compose — whichever is higher binds.
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
     * @notice Struct containing staking configuration for pool creation.
     * @param deployStaking Whether to deploy a staking vault for the pool.
     * @param alternativeFeeRecipient Alternative fee recipient for WETH and coin fees. Can be
     * used with or without a staking vault.
     */
    struct StakingConfig {
        bool deployStaking;
        address alternativeFeeRecipient;
    }

    /**
     * @notice Provided address cannot be the zero-address.
     */
    error InvalidZeroAddress();

    /**
     * @notice Ownership renouncement is disabled: `owner()` is load-bearing for admin gating
     * and recovery across the protocol (hook setters, curve setters, treasury rotation), so
     * renouncing would freeze protocol configuration forever.
     */
    error RenounceDisabled();

    /**
     * @notice The sent value is not enough to cover the creation fee.
     */
    error InsufficientCreationFee();

    /**
     * @notice Failed to send ETH when withdrawing from factory.
     */
    error FailedToSendETH();

    /**
     * @notice BCToken factory initial params are invalid.
     * initialSupply and virtualReserves must be higher than 0.
     * initialSupply must be lower than maxSupply.
     */
    error InvalidInitialParams();

    /**
     * @notice The launch config is internally inconsistent for its mode: a curve-mode launch
     * carries a non-zero `seedTick`, or a direct-mode launch carries non-zero curve params.
     * The other mode's fields must be zero — a frontend sending them is confused and must fail
     * loud rather than have the fields silently ignored.
     */
    error InvalidLaunchConfig();

    /**
     * @notice The seed FDV bounds are invalid: `minFdv` must be non-zero and must not exceed
     * `maxFdv`.
     */
    error InvalidSeedFdvBounds();

    /**
     * @notice A direct-seed launch requested a dev buy while no DirectSeeder is configured.
     * The dev buy is optional plumbing behind an owner-settable pointer: with the seeder
     * unplugged, direct launches without a dev buy keep working, but ETH beyond the creation
     * fee cannot be honoured and must revert rather than sit in the factory.
     */
    error DirectSeederUnset();

    /**
     * @notice The `maxSupply` exceeds the structural uint128 ceiling: the LiquidityManager's
     * seeding math is uint128-bound, so a supply at or above 2^128 would deploy and trade but
     * brick forever on the graduation mint (H-354). This is the only bound on `maxSupply` —
     * it is owner-set via `updateInitialParams`, so a policy window would only gate the same
     * admin who would set the window.
     * @param maxSupply The rejected max supply.
     */
    error MaxSupplyOutOfBounds(uint256 maxSupply);

    /**
     * @notice The launch's `maxSupply / initialSupply` ratio falls outside the protocol window
     * (`supplyRatioFloorWad`..`supplyRatioCapWad`).
     * @param ratioWad The rejected ratio, WAD-scaled.
     */
    error SupplyRatioOutOfBounds(uint256 ratioWad);

    /**
     * @notice The ETH the launch would raise at graduation (`targetETH − virtualReserves`) is
     * below the protocol minimum (`minRaise`).
     * @param raise The rejected raise, in wei.
     */
    error RaiseBelowMinimum(uint256 raise);

    /**
     * @notice The launch's initial FDV (`virtualReserves` — the curve prices the full supply
     * at `virtualReserves / maxSupply` from birth) falls outside the protocol window
     * (`minInitialFdv`..`maxInitialFdv`).
     * @param initialFdv The rejected launch FDV, in wei.
     */
    error InitialFdvOutOfBounds(uint256 initialFdv);

    /**
     * @notice The curve bounds are internally inconsistent: `minRaise` and `minInitialFdv`
     * must be non-zero, the ratio floor must exceed 1 (WAD) and cannot exceed the ratio cap,
     * the initial-FDV floor cannot exceed its cap, and the box must not be empty —
     * `maxInitialFdv` must admit the `virtualReserves` floor `minRaise` implies at the ratio
     * cap.
     */
    error InvalidCurveBounds();

    /**
     * @notice Fees cannot be higher than `MAX_FEE`.
     */
    error InvalidFees();

    /**
     * @notice Protocol is paused and action cannot be performed.
     */
    error ProtocolPaused();

    /**
     * @notice BCToken params are invalid, or the caller has already deployed a coin with this
     * exact name, symbol, description and image.
     */
    error InvalidParams();

    /**
     * @notice Community fee ratio cannot be higher than 100.
     */
    error InvalidCommunityFeeRatio();

    /**
     * @notice The hook config payload exceeds the custody-side length cap
     * (`maxHookConfigBytes`).
     */
    error HookConfigTooLarge();

    /**
     * @notice Emitted when the hook config payload length cap is updated.
     * @param previousMax The previous cap in bytes.
     * @param newMax The new cap in bytes.
     */
    event MaxHookConfigBytesUpdated(uint256 previousMax, uint256 newMax);

    /**
     * @notice Community fee ratio must be greater than 0 when deploying a staking vault.
     */
    error StakingRequiresCommunityFee();

    /**
     * @notice Salt has already been used for deployment.
     */
    error SaltAlreadyUsed();

    /**
     * @notice Creator buy amount exceeds the maximum allowed percentage of total supply,
     * as defined by `maxCreatorBuyBps`.
     */
    error CreatorBuyExceedsCap();

    /**
     * @notice The provided max creator buy bps value exceeds the protocol hard cap of 25% (2500 bps).
     */
    error ExceedsHardCap();

    /**
     * @notice The creator share cannot exceed max value.
     * @param maxCreatorShareBps The maximum creator share in bps that is allowed.
     */
    error MaxCreatorShareExceeded(uint256 maxCreatorShareBps);

    /**
     * @notice Emitted when fees are updated.
     * @param protocolFee New protocol fee in bps charged upon LP seeding.
     * @param creatorFee New creator fee in bps paid upon LP seeding.
     * @param refundFee New fee in bps paid to the caller who triggers LP seeding.
     * @param creationFee New flat ETH fee charged to create a new coin.
     */
    event FeesUpdated(uint80 protocolFee, uint80 creatorFee, uint80 refundFee, uint80 creationFee);

    /**
     * @notice Emitted when the BondingCurve contract changes.
     * @param bondingCurve The new bonding curve contract address.
     */
    event BondingCurveUpdated(address indexed bondingCurve);

    /**
     * @notice Emitted when the creator's share of the curve trade fee is updated.
     * @param creatorShareBps The new creator share (in BPS of the fee net of referral).
     */
    event CreatorShareUpdated(uint256 creatorShareBps);

    /**
     * @notice Emitted when the LiquidityManager contract changes.
     * @param liquidityManager The new liquidity manager contract address.
     */
    event LiquidityManagerUpdated(address indexed liquidityManager);

    /**
     * @notice Emitted when a new BCToken is deployed.
     * @param creator The address that deployed the BCToken.
     * @param token The address of the newly deployed BCToken.
     * @param factory The address of the BCTokenFactory that deployed the token.
     * @param lp The address of the hook governing the V4 pool created for this token.
     * @param name The human-readable name of the token.
     * @param symbol The ticker symbol of the token.
     * @param description The human-readable description of the token.
     * @param image The on-chain image URI of the token.
     * @param initialSupply The initial token supply minted to the BCToken for LP seeding.
     * @param maxSupply The maximum token supply; LP is seeded when this is reached.
     * @param initialETHReserves The initial virtual ETH reserves used by the bonding curve.
     * @param initialPrice The initial spot price of the bonding curve (ETH per token).
     * @param initialMarketCap The initial market cap implied by `initialPrice * initialSupply`.
     * @param targetETH The amount of ETH (incl. virtual reserves) required to reach LP seeding.
     * @param directSeed Whether the coin was born seeded (direct mode). Indexed so consumers
     * can filter launches by mode. For direct coins this event IS the seed signal — they never
     * emit `LPSeeded` — and every curve-only field above (`initialSupply`,
     * `initialETHReserves`, `initialPrice`, `initialMarketCap`, `targetETH`) is zero; launch
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
     * @notice Emitted on every deploy, right after `CoinDeployed`, with the coin's alternative
     * fee recipient as set at construction. `address(0)` means none is set: fees go to the
     * creator (`getFeeRecipient()`). Later changes emit the token's own
     * `AlternativeFeeRecipientUpdated`.
     * @param token The deployed coin.
     * @param recipient The alternative fee recipient set at construction, or address(0).
     */
    event FeeRecipientAssigned(address indexed token, address indexed recipient);

    /**
     * @notice Emitted when the harvester contract is updated.
     * @param newHarvester The new harvester contract address.
     */
    event UpdatedHarvester(address indexed newHarvester);

    /**
     * @notice Emitted when the token vesting contract is updated.
     * @param tokenVesting The new token vesting contract address.
     */
    event TokenVestingUpdated(address indexed tokenVesting);

    /**
     * @notice Emitted when the initial params for a new coin are updated.
     * @param virtualReserves The new initial virtual ETH reserves for the bonding curve.
     * @param initialSupply The new initial token supply minted to the bonding curve.
     * @param maxSupply The new maximum token supply at which LP is seeded.
     */
    event UpdatedInitialParams(uint256 virtualReserves, uint256 initialSupply, uint256 maxSupply);

    /**
     * @notice Emitted when the direct-seed FDV window is updated.
     * @param minFdv The new lower FDV bound in wei.
     * @param maxFdv The new upper FDV bound in wei.
     */
    event SeedFdvBoundsUpdated(uint256 minFdv, uint256 maxFdv);

    /**
     * @notice Emitted when the DirectSeeder pointer is updated.
     * @param previousSeeder The previous DirectSeeder address.
     * @param newSeeder The new DirectSeeder address (address(0) unplugs the dev buy).
     */
    event DirectSeederUpdated(address indexed previousSeeder, address indexed newSeeder);

    /**
     * @notice Emitted when the protocol curve bounds are updated.
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
     * @notice Emitted when the maximum percentage of total supply a creator can buy on deployment
     * is updated.
     * @param newMaxBps The new maximum creator buy percentage in basis points.
     */
    event MaxCreatorBuyBpsUpdated(uint256 newMaxBps);

    /**
     * @notice Emitted when a creator purchases tokens as part of the deployment transaction —
     * a curve buy for curve launches, a pool dev buy (via the DirectSeeder) for direct-seed
     * launches. Both modes share one creator-buy rule and one event.
     * @param creator Address of the token creator performing the buy.
     * @param token Address of the newly deployed BCToken.
     * @param ethAmount Amount of ETH spent on the creator buy.
     * @param tokenAmount Amount of tokens received by the creator.
     */
    event CreatorBuy(address indexed creator, address indexed token, uint256 ethAmount, uint256 tokenAmount);

    /**
     * @notice Emitted when the protocol pause state is updated.
     * @param paused Whether the protocol is paused.
     */
    event ProtocolPausedUpdated(bool paused);

    /**
     * @notice Emitted when the factory owner sweeps residual ETH to the protocol treasury.
     * @param to The recipient of the swept ETH (the protocol treasury).
     * @param amount The amount of ETH swept (in wei).
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice Emitted when the protocol treasury address is updated.
     * @param treasury The new treasury address.
     */
    event TreasurySet(address indexed treasury);

    /**
     * @notice Returns the current protocol owner (inherited from Ownable).
     * @return The address of the factory owner.
     */
    function owner() external view returns (address);

    /**
     * @notice Returns the protocol treasury receiving protocol fees.
     * @dev Resolved through the factory at pay time by the bonding curve (trade-fee residual),
     * BCToken (graduation protocol fee) and the hook (swap-fee protocol share), so one update
     * here re-routes protocol fees across every deployed coin, curve and hook generation.
     * @return The address of the protocol treasury.
     */
    function treasury() external view returns (address);

    /**
     * @notice Sets the protocol treasury receiving protocol fees.
     * @dev Only callable by the owner. The treasury is deliberately separate from `owner()` —
     * operations (owner multisig) and revenue custody (treasury multisig) are distinct roles.
     * Cannot be the zero address.
     * @param _treasury The new treasury address.
     */
    function setTreasury(address _treasury) external;

    /**
     * @notice Returns the position manager address.
     * @return The address of the NFT Position Manager contract.
     */
    function POSITION_MANAGER() external view returns (address);

    /**
     * @notice Returns the WETH token address.
     * @return The address of the WETH token.
     */
    function WETH() external view returns (address);

    /**
     * @notice Returns whether the protocol is paused or not.
     * @return Whether the protocol is paused.
     */
    function PROTOCOL_PAUSED() external view returns (bool);

    /**
     * @notice Returns the token deployer contract that handles BCToken deployment via CREATE3.
     * @return The BCTokenDeployer contract.
     */
    function TOKEN_DEPLOYER() external view returns (IBCTokenDeployer);

    /**
     * @notice Returns the maximum fee that can be charged by protocol, creator, or refund (bps).
     * @return The maximum fee in basis points.
     */
    function MAX_FEE() external view returns (uint256);

    /**
     * @notice Returns whether an address is a coin created by the Token Factory.
     * @param token The address to check.
     * @return Whether the address is a valid BCToken.
     */
    function bcTokens(address token) external view returns (bool);

    /**
     * @notice Given a bytes32 hash returns the coin address that has been created with that configuration.
     * @dev The hash is `keccak256(abi.encode(creator, name, symbol, description, image))`: the
     * metadata reservation is per creator, not global, so two creators may use the same metadata
     * and neither can block the other.
     * @param paramsHash The hash of the coin's creator and initial parameters.
     * @return The address of the coin.
     */
    function bcTokensParams(bytes32 paramsHash) external view returns (address);

    /**
     * @notice Returns the contract that can harvest LP positions.
     * @return The address of the harvester contract.
     */
    function harvester() external view returns (address);

    /**
     * @notice Returns the contract's bonding curve address.
     * @return The address of the bonding curve contract.
     */
    function bondingCurve() external returns (IBondingCurve);

    /**
     * @notice Returns the contract's liquidity manager address.
     * @return The address of the liquidity manager contract.
     */
    function liquidityManager() external view returns (address);

    /**
     * @notice Returns the token vesting contract address.
     * @return The address of the token vesting contract.
     */
    function tokenVesting() external view returns (address);

    /**
     * @notice Deploys a new coin using CREATE3.
     * @dev Reverts `InvalidParams` if THIS caller has already deployed a coin with the same
     * name, symbol, description and image; another creator using the same metadata is not a
     * conflict. The deployment address is `keccak256(abi.encodePacked(msg.sender, salt))` through
     * CREATE3, so it depends only on the caller and the salt — never on the metadata.
     * @param name The name of the new coin.
     * @param symbol The symbol of the new coin.
     * @param description The description of the new coin.
     * @param image The image source code to store.
     * @param communityFeeRatio The community fee ratio for the new coin. Cannot be higher than 100.
     * @param salt The salt for the CREATE3 deployment.
     * @param launchConfig The launch mode selection plus its mode's params. Curve mode: the
     * creator-supplied curve params (`virtualReserves`, `initialSupply`) — always explicit,
     * always checked against `curveBounds()` together with the protocol-defined `maxSupply`
     * read from `initialParams()`; prefill from `initialParams()` for a standard launch — a
     * zeroed config reverts on the bounds, it never falls back to defaults. Direct mode: the
     * `seedTick` the pool opens at (born graduated, full supply seeded one-sided in this
     * transaction). ETH sent beyond the creation fee becomes the creator buy of the chosen
     * mode — a curve buy, or a real pool swap through the DirectSeeder.
     * @param stakingConfig Staking vault configuration.
     * @param hookConfig The opaque creator hook payload — empty for protocol defaults. The
     * factory only length-caps it (`maxHookConfigBytes`) and forwards it unread; the hook
     * validates it in `registerPool`, inside this same transaction.
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
     * @notice Sweeps residual ETH from the contract to the protocol treasury.
     * @dev Only callable by the owner. Protocol fees are pushed at source (the creation fee to
     * the treasury inside `deploy`), so the factory balance holds only incidental ETH — e.g.
     * supply-capped creator-buy refunds — swept here rather than accrued by design.
     * @param amount Amount of ETH to sweep.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Sets the address of the bonding curve.
     * @param _bondingCurve Address of the bonding curve contract.
     */
    function setBondingCurve(address _bondingCurve) external;

    /**
     * @notice Updates the creator's share of the curve trade fee net of referral. Read by the
     * bonding curve on every trade, so one update covers every active curve generation.
     * @param _creatorShareBps The share to pay the token's fee recipient (in BPS, ≤ 10 000).
     */
    function setCreatorShareBps(uint16 _creatorShareBps) external;

    /**
     * @notice Returns the creator's share of the curve trade fee net of referral.
     * @return The creator share (in BPS of 10 000).
     */
    function creatorShareBps() external view returns (uint16);

    /**
     * @notice Sets the address of the liquidity manager.
     * @param _liquidityManager Address of the liquidity manager contract.
     */
    function setLiquidityManager(address _liquidityManager) external;

    /**
     * @notice Updates new coin's initial params.
     * @param _virtualReserves New initial virtual reserves.
     * @param _initialSupply New coin initial supply.
     * @param _maxSupply New coin `MAX_SUPPLY`.
     */
    function updateInitialParams(uint256 _virtualReserves, uint256 _initialSupply, uint256 _maxSupply) external;

    /**
     * @notice Updates fees for protocol and creator.
     * @param _protocolFee Fee earned by the protocol when bonding curve LPs in bps.
     * @param _creatorFee Fee earned by the creator when bonding curve LPs in bps.
     * @param _refundFee Fee paid to the caller who triggers LP seeding in bps.
     * @param _creationFee The fee charged to create a new coin.
     */
    function updateFees(uint80 _protocolFee, uint80 _creatorFee, uint80 _refundFee, uint80 _creationFee) external;

    /**
     * @notice Sets the address of the harvester contract.
     * @param _harvester The new address to set as harvester.
     */
    function setHarvester(address _harvester) external;

    /**
     * @notice Sets the address of the token vesting contract.
     * @param _tokenVesting The new address to set as token vesting.
     */
    function setTokenVesting(address _tokenVesting) external;

    /**
     * @notice Sets the current paused state of the protocol.
     * @param _state Whether the protocol is paused or not.
     */
    function setProtocolPaused(bool _state) external;

    /**
     * @notice Returns the default curve initialisation parameters.
     * @dev Two roles: `virtualReserves` / `initialSupply` are a frontend prefill only (`deploy`
     * never reads them — the launch config is always explicit), while `maxSupply` is
     * AUTHORITATIVE — `deploy` reads it from storage for every launch; creators cannot override
     * it. Owner-tunable via `updateInitialParams` so both the default curve and the protocol
     * supply can change without a frontend release.
     * @return virtualReserves The virtual ETH reserves seeded into the bonding curve.
     * @return initialSupply The initial token supply minted to the bonding curve.
     * @return maxSupply The maximum token supply; LP is seeded when reached.
     */
    function initialParams() external view returns (uint256 virtualReserves, uint256 initialSupply, uint256 maxSupply);

    /**
     * @notice Returns the FDV window (in ETH wei) every direct-seed launch must open inside.
     * @return The current seed FDV bounds.
     */
    function seedFdvBounds() external view returns (SeedFdvBounds memory);

    /**
     * @notice Updates the FDV window for direct-seed launches.
     * @dev Only callable by the owner. In ETH wei — retune it as the ETH price moves; the
     * USD → ETH translation is off-chain policy.
     * @param bounds The new seed FDV bounds.
     */
    function updateSeedFdvBounds(SeedFdvBounds calldata bounds) external;

    /**
     * @notice Returns the DirectSeeder executing dev buys for direct-seed launches.
     * @return The DirectSeeder address (address(0) when unplugged).
     */
    function directSeeder() external view returns (address);

    /**
     * @notice Sets the DirectSeeder used for direct-launch dev buys.
     * @dev Only callable by the owner. The seeder is stateless, hot-swappable plumbing —
     * address(0) is deliberately allowed and unplugs the dev buy: direct launches without a
     * dev buy keep working while a faulty seeder is out of rotation.
     * @param _directSeeder The new DirectSeeder address (address(0) to unplug).
     */
    function setDirectSeeder(address _directSeeder) external;

    /**
     * @notice Returns the protocol bounds enforced on every curve launch's params.
     * @return The current curve bounds.
     */
    function curveBounds() external view returns (CurveBounds memory);

    /**
     * @notice Updates the protocol bounds enforced on every launch's curve params.
     * @dev Only callable by the owner. The stored default params are NOT re-validated here:
     * narrowing the bounds past the defaults only makes default-prefilled deploys revert until
     * `updateInitialParams` re-tunes them — update both together when moving the windows.
     * @param bounds The new curve bounds.
     */
    function updateCurveBounds(CurveBounds calldata bounds) external;

    /**
     * @notice Returns the current fee configuration for the factory.
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
     * @notice Returns the hard cap for the max creator buy percentage — 25% (2500 bps).
     * @return The hard cap in basis points.
     */
    function MAX_CREATOR_BUY_BPS_HARD_CAP() external view returns (uint256);

    /**
     * @notice Returns the maximum percentage of total supply a creator can buy on deployment.
     * @return The max creator buy cap in basis points (e.g., 2500 = 25%).
     */
    function maxCreatorBuyBps() external view returns (uint16);

    /**
     * @notice Sets the maximum percentage of total supply a creator can buy on deployment.
     * @notice Cannot exceed the hard cap of 25% (2500 bps). Only callable by the factory owner.
     * @param _newMaxBps The new max creator buy percentage in basis points.
     */
    function setMaxCreatorBuyBps(uint16 _newMaxBps) external;

    /**
     * @notice Returns the custody-side cap on the opaque hook config payload, in bytes.
     * @dev The per-schema structural bound lives in each hook generation's `registerPool`;
     * this is the outer envelope the factory enforces at `deploy`.
     * @return The cap in bytes.
     */
    function maxHookConfigBytes() external view returns (uint256);

    /**
     * @notice Sets the custody-side cap on the opaque hook config payload.
     * @dev Only callable by the owner. Owner-settable so the cap can follow hook generations
     * (the factory never redeploys after v1.2): raise it in the same multicall as a generation
     * switch whose schema needs more room.
     * @param _maxHookConfigBytes The new cap in bytes.
     */
    function setMaxHookConfigBytes(uint256 _maxHookConfigBytes) external;
}
