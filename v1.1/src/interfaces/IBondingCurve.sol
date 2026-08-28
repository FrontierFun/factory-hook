// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/**
 * @title IBondingCurve
 * @author Frontier
 * @notice Buy and sell side of the bonding curve for factory-deployed BCTokens.
 */
interface IBondingCurve {
    /// @notice Failed to send ETH when minting or burning.
    error FailedToSendETH();

    /// @notice Amount must be non-zero, and a sell's `amountOut` cannot exceed the coin's `TVL()`.
    error InvalidAmount();

    /// @notice Only the `FACTORY` owner or the bonding curve may call.
    error InvalidCaller();

    /// @notice Token is not a factory-deployed BCToken.
    error InvalidToken();

    /**
     * @notice Fee exceeds the maximum.
     * @param maxFee The maximum fee allowed, in bps.
     */
    error MaxFeeExceeded(uint256 maxFee);

    /// @notice Amount out is below the caller's floor.
    error SlippageTooHigh();

    /// @notice Protocol is paused.
    error ProtocolPaused();

    /// @notice Address cannot be zero.
    error InvalidZeroAddress();

    /**
     * @notice `user` bought `token`; carries the coin's post-trade supply, market cap, price and reserves.
     * @param user Address of the user buying token.
     * @param token Address of the token purchased.
     * @param amount ETH spent, in wei.
     * @param amountOut Tokens received.
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
     * @notice `token` reached the LP stage; `pool` is what was created for it.
     * @param token Address of the token that reached LP stage.
     * @param pool Address of the pool created for the token.
     */
    event LPSeeded(address indexed token, address indexed pool);

    /**
     * @notice `user` sold `token`; carries the coin's post-trade supply, market cap, price and reserves.
     * @param user Address of the user selling token.
     * @param token Address of the token sold.
     * @param amount Tokens sold.
     * @param amountOut ETH received, in wei.
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
     * @notice Buy/sell fee changed; `fee` in bps.
     * @param fee The fee charged (in BPS).
     */
    event TxFeeUpdated(uint256 fee);

    /**
     * @notice Full split of a non-zero trade fee: `referralAmount + creatorAmount + protocolAmount == totalFee`.
     * @param token The token whose trade generated the fee.
     * @param totalFee Trade fee collected, in ETH wei.
     * @param referralAmount Share delivered to the referral manager, in WETH wei.
     * @param creatorAmount Share paid to the token's fee recipient, in WETH wei.
     * @param protocolAmount Residual held by the curve for the protocol, in ETH wei.
     * @param feeRecipient Recipient of `creatorAmount`, or address(0) when that share is zero.
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
     * @notice Referral manager changed.
     * @param referralManager The new referral manager address.
     */
    event ReferralManagerUpdated(address indexed referralManager);

    /**
     * @notice Residual ETH swept by the factory owner to the protocol treasury `to`; `amount` in wei.
     * @param to The recipient of the swept ETH (the protocol treasury).
     * @param amount The amount of ETH swept (in wei).
     */
    event Withdrawn(address indexed to, uint256 amount);

    /**
     * @notice The curve formula contract.
     * @return The address of the bonding curve formula contract.
     */
    function formula() external view returns (address);

    /**
     * @notice Buys `token` with `msg.value`; reverts with `SlippageTooHigh` below `expectedOut`.
     * @param token Address of the token to purchase. MUST be a valid BCToken.
     * @param affiliate Referrer; a non-zero address sets up the referral.
     * @param expectedOut Minimum tokens out (slippage floor).
     * @return Tokens acquired.
     */
    function buy(address token, address affiliate, uint256 expectedOut) external payable returns (uint256);

    /**
     * @notice Sells `amount` of `token`; reverts with `SlippageTooHigh` below `expectedOut`.
     * @param token Address of the token to sell. MUST be a valid BCToken.
     * @param affiliate Referrer; a non-zero address sets up the referral.
     * @param amount Amount of token to sell.
     * @param expectedOut Minimum ETH out, net of fee (slippage floor).
     * @return ETH received, net of fee.
     */
    function sell(address token, address affiliate, uint256 amount, uint256 expectedOut) external returns (uint256);

    /**
     * @notice Tokens received for `amount` of ETH, fee-inclusive: `txFee` is deducted from `amount` first, exactly
     * as `buy` does, so the result can be passed back as `buy`'s `expectedOut`. Raw curve output:
     * `getCurveAmountOutBuy`.
     * @param token Address of the token to buy.
     * @param amount ETH to spend, inclusive of `txFee`.
     * @return The amount of tokens to be received.
     */
    function getAmountOutBuy(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice `getAmountOutBuy` capped by the supply left (`MAX_SUPPLY - totalSupply`).
     * @param token Address of the token to buy.
     * @param amount ETH to spend, inclusive of `txFee`.
     * @return The amount of tokens to be received.
     */
    function getAmountOutBuySupplyCapped(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice ETH received for selling `amount` tokens, net of `txFee` exactly as `sell` deducts it, so the result
     * can be passed back as `sell`'s `expectedOut`. Gross curve output: `getCurveAmountOutSell`.
     * @param token Address of the token to sell.
     * @param amount Amount of tokens to sell of token.
     * @return The amount of ETH to be received, net of `txFee`.
     */
    function getAmountOutSell(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Raw curve output for `amount` of ETH with no `txFee` on either side: `amount` is taken as already net
     * of fee and nothing is deducted from the result. For spot-price reads and callers doing their own fee
     * accounting; a `buy` `expectedOut` wants `getAmountOutBuy`.
     * @param token Address of the token to buy.
     * @param amount ETH to spend on the curve, exclusive of `txFee`.
     * @return The amount of tokens the curve returns for `amount`.
     */
    function getCurveAmountOutBuy(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Gross ETH the curve returns for `amount` tokens, before the fee `sell` takes. For spot-price reads
     * and callers doing their own fee accounting; a `sell` `expectedOut` wants `getAmountOutSell`.
     * @param token Address of the token to sell.
     * @param amount Amount of tokens to sell of token.
     * @return The gross amount of ETH the curve returns for `amount`.
     */
    function getCurveAmountOutSell(address token, uint256 amount) external view returns (uint256);

    /**
     * @notice Sweeps `amount` of residual ETH to the protocol treasury; factory owner only. The protocol's fee
     * residual is pushed to the treasury on every trade, so this only moves incidental (e.g. force-sent) ETH.
     * @param amount Amount of ETH to sweep.
     */
    function withdraw(uint256 amount) external;

    /**
     * @notice Sets the buy/sell fee, in bps.
     * @param _fee The fee to be charged (in BPS).
     */
    function setTxFee(uint16 _fee) external;

    /**
     * @notice Sets the referral manager.
     * @param _referralManager The new referral manager address.
     */
    function setReferralManager(address _referralManager) external;

    /**
     * @notice The referral manager.
     * @return The address of the referral manager.
     */
    function referralManager() external view returns (address);

    /**
     * @notice Maximum buy/sell fee, in bps.
     * @return The maximum fee (in BPS).
     */
    function MAX_FEE() external view returns (uint256);

    /**
     * @notice The WETH contract.
     * @return The address of the WETH contract.
     */
    function weth() external view returns (address);

    /**
     * @notice Buy/sell fee charged by the protocol, in bps.
     * @return The fee charged (in BPS).
     */
    function txFee() external view returns (uint16);
}
