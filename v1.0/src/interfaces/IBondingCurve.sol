// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IBondingCurve
 * @author Frontier
 * @notice Interface for the bonding curve contract managing buy and sell operations for BCTokens.
 */
interface IBondingCurve {
    /**
     * @notice Failed to send ETH when minting or burning tokens.
     */
    error FailedToSendETH();

    /**
     * @notice Amount of tokens must be greater than zero or sell `amountOut` cannot exceed coin `TVL()`.
     */
    error InvalidAmount();

    /**
     * @notice Only `FACTORY` owner or bonding curve can call.
     */
    error InvalidCaller();

    /**
     * @notice Token address of buy or sell functions does not belong to a factory deployed BCToken.
     */
    error InvalidToken();

    /**
     * @notice The fee cannot exceed max value.
     * @param maxFee The maximum fee in bps that is allowed.
     */
    error MaxFeeExceeded(uint256 maxFee);

    /**
     * @notice Amount of tokens to be received is not enough.
     */
    error SlippageTooHigh();

    /**
     * @notice Protocol is paused and action cannot be performed.
     */
    error ProtocolPaused();

    /**
     * @notice Provided address cannot be the zero-address.
     */
    error InvalidZeroAddress();

    /**
     * @notice Emitted when a given token is purchased.
     * @param user Address of the user buying token.
     * @param token Address of the token purchased.
     * @param amount Amount of ETH spent to purchase tokens.
     * @param amountOut Amount of tokens received.
     * @param totalSupply Current total supply of coin.
     * @param marketCap Current market cap of coin.
     * @param price Current price of coin.
     * @param reserveBalance Amount of ETH as reserves in coin.
     */
    event Buy(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 amountOut,
        uint256 totalSupply,
        uint256 marketCap,
        uint256 price,
        uint256 reserveBalance
    );

    /**
     * @notice Emitted when a given token reaches the LP stage.
     * @param token Address of the token that reached LP stage.
     * @param pool Address of the pool created for the token.
     */
    event LPSeeded(address indexed token, address indexed pool);

    /**
     * @notice Emitted when a given token is sold.
     * @param user Address of the user selling token.
     * @param token Address of the token sold.
     * @param amount Amount of tokens sold.
     * @param amountOut Amount of ETH received by selling tokens.
     * @param totalSupply Current total supply of coin.
     * @param marketCap Current market cap of coin.
     * @param price Current price of coin.
     * @param reserveBalance Amount of ETH as reserves in coin.
     */
    event Sell(
        address indexed user,
        address indexed token,
        uint256 amount,
        uint256 amountOut,
        uint256 totalSupply,
        uint256 marketCap,
        uint256 price,
        uint256 reserveBalance
    );

    /**
     * @notice Emitted when the fee charged on buy/sell orders is updated.
     * @param fee The fee charged (in BPS).
     */
    event TxFeeUpdated(uint256 fee);

    /**
     * @notice Emitted on every trade whose fee is non-zero, with the fee's full split.
     * `referralAmount + creatorAmount + protocolAmount == totalFee`.
     * @param token The token whose trade generated the fee.
     * @param totalFee The total trade fee collected, in ETH wei.
     * @param referralAmount The share delivered to the referral manager, in WETH wei.
     * @param creatorAmount The share paid to the token's fee recipient, in WETH wei.
     * @param protocolAmount The residual held by the curve for the protocol, in ETH wei.
     * @param feeRecipient The recipient of `creatorAmount`, or address(0) when that share is zero.
     */
    event CurveFeeDistributed(
        address indexed token,
        uint256 totalFee,
        uint256 referralAmount,
        uint256 creatorAmount,
        uint256 protocolAmount,
        address feeRecipient
    );

    /**
     * @notice Emitted when the referral manager is updated.
     * @param referralManager The new referral manager address.
     */
    event ReferralManagerUpdated(address indexed referralManager);

    /**
     * @notice Emitted when the factory owner sweeps residual ETH from the bonding curve to the
     * protocol treasury.
     * @param to The recipient of the swept ETH (the protocol treasury).
     * @param amount The amount of ETH swept (in wei).
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice Returns the bonding curve's formula address.
     * @return The address of the bonding curve formula contract.
     */
    function formula() external view returns (address);

    /**
     * @notice Lets user buy a specific token.
     *
     * @param token Address of the token to purchase. MUST be a valid BCToken.
     * @param affiliate Address of the affiliate (referrer). If not address(0), sets up referral.
     * @param expectedOut Minimum acceptable amount of tokens out (slippage floor); the call
     *        reverts with `SlippageTooHigh` if the actual amount out is below this value.
     *
     * @return The amount of tokens acquired.
     */
    function buy(address token, address affiliate, uint256 expectedOut) external payable returns (uint256);

    /**
     * @notice Lets user sell a specific token.
     *
     * @param token Address of the token to sell. MUST be a valid BCToken.
     * @param affiliate Address of the affiliate (referrer). If not address(0), sets up referral.
     * @param amount Amount of token to sell.
     * @param expectedOut Minimum acceptable ETH amount out (net of fee); the call reverts
     *        with `SlippageTooHigh` if the actual amount out is below this value.
     *
     * @return The amount of ETH received.
     */
    function sell(address token, address affiliate, uint256 amount, uint256 expectedOut) external returns (uint256);

    /**
     * @notice Returns the amount of tokens to be received by spending amount of ETH.
     * @dev Fee-inclusive: `txFee` is deducted from `amount` before the curve is applied, exactly
     * as `buy` does, so the result is what `buy` would deliver for `msg.value == amount` and can
     * be passed straight back as its `expectedOut`. For the raw curve output on a fee-exclusive
     * input, see `getCurveAmountOutBuy`.
     *
     * @param token Address of the token to buy.
     * @param amount Amount of ETH to spend buying token, inclusive of `txFee`.
     *
     * @return The amount of tokens to be received.
     */
    function getAmountOutBuy(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice View utility function that returns the amount of tokens to be received by
     * spending amount of ETH capped by the supply left (`MAX_SUPPLY - totalSupply`).
     * @dev Fee-inclusive, on the same terms as `getAmountOutBuy`.
     *
     * @param token Address of the token to buy.
     * @param amount Amount of ETH to spend buying token, inclusive of `txFee`.
     *
     * @return The amount of tokens to be received.
     */
    function getAmountOutBuySupplyCapped(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Returns the amount of ETH to be received by selling amount of tokens.
     * @dev Fee-inclusive: `txFee` is already deducted, exactly as `sell` deducts it, so the
     * result is the ETH the caller actually receives and can be passed straight back as `sell`'s
     * `expectedOut`. For the gross curve output, see `getCurveAmountOutSell`.
     *
     * @param token Address of the token to sell.
     * @param amount Amount of tokens to sell of token.
     *
     * @return The amount of ETH to be received, net of `txFee`.
     */
    function getAmountOutSell(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Returns the raw curve output for an amount of ETH, WITHOUT applying `txFee`.
     * @dev Fee-exclusive on both sides: `amount` is treated as ETH that has already had the fee
     * removed, and no fee is deducted from the result. Intended for spot-price reads and callers
     * doing their own fee accounting; users constructing `buy`'s `expectedOut` want
     * `getAmountOutBuy`.
     *
     * @param token Address of the token to buy.
     * @param amount Amount of ETH to spend on the curve, exclusive of `txFee`.
     *
     * @return The amount of tokens the curve returns for `amount`.
     */
    function getCurveAmountOutBuy(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Returns the raw curve output for an amount of tokens, WITHOUT deducting `txFee`.
     * @dev Fee-exclusive: the gross ETH the curve returns, before the fee `sell` takes. Intended
     * for spot-price reads and callers doing their own fee accounting; users constructing
     * `sell`'s `expectedOut` want `getAmountOutSell`.
     *
     * @param token Address of the token to sell.
     * @param amount Amount of tokens to sell of token.
     *
     * @return The gross amount of ETH the curve returns for `amount`.
     */
    function getCurveAmountOutSell(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Sweeps residual ETH to the protocol treasury. Only callable by the factory owner.
     * @dev The protocol's trade-fee residual is pushed to the treasury on every trade, so the
     * contract balance is zero between trades by construction — this sweeps only incidental
     * ETH (e.g. force-sent).
     *
     * @param amount Amount of ETH to sweep.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Updates the buy/sell fee charged on orders by the protocol.
     *
     * @param _fee The fee to be charged (in BPS).
     */
    function setTxFee(uint16 _fee) external;

    /**
     * @notice Sets the referral manager address.
     *
     * @param _referralManager The new referral manager address.
     */
    function setReferralManager(address _referralManager) external;

    /**
     * @notice Returns the referral manager address.
     * @return The address of the referral manager.
     */
    function referralManager() external view returns (address);

    /**
     * @notice Returns the maximum fee that can be charged on transactions.
     * @return The maximum fee (in BPS).
     */
    function MAX_FEE() external view returns (uint256);

    /**
     * @notice Returns the WETH contract address.
     * @return The address of the WETH contract.
     */
    function weth() external view returns (address);

    /**
     * @notice Returns the buy/sell fee charged by the protocol.
     * @return The fee charged (in BPS).
     */
    function txFee() external view returns (uint16);
}
