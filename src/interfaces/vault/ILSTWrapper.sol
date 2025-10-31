// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILSTWrapper is IERC4626 {
    // Errors
    error LSTWrapper__ZeroAddress(string param);
    error LSTWrapper__CannotSweepAsset();
    error LSTWrapper__CannotSweepCollateral();
    error LSTWrapper__CannotSweepNativeToken();
    error LSTWrapper__InvalidRecipient();
    error LSTWrapper__InvalidVaultCollateral();
    error LSTWrapper__InvalidRewardsToken();
    error LSTWrapper__InvalidVaultHelper();
    error LSTWrapper__DepositRestricted();
    error LSTWrapper__DepositLimitExceeded(uint256 headroom);
    error LSTWrapper__ZeroSharesMinted();
    error LSTWrapper__ExcessiveAmount();
    error LSTWrapper__AssetRescueNotAllowed();
    error LSTWrapper__SlippageProtection();
    error LSTWrapper__DepositsPaused();
    error LSTWrapper__OnlyOwnerFirstMint();

    // Events
    /**
     * @notice Emitted when rewards (native token) are harvested and reinvested.
     * @param caller address that triggered the harvest
     * @param claimedNative amount of native token claimed from rewards
     * @param mintedVaultShares amount of vault shares minted from reinvestment
     */
    event Harvest(address indexed caller, uint256 claimedNative, uint256 mintedVaultShares);

    /**
     * @notice Emitted when tokens are swept from the contract.
     * @param caller address that triggered the sweep
     * @param token address of the token being swept
     * @param recipient recipient of the swept tokens
     * @param amount amount of tokens swept
     */
    event Sweep(address indexed caller, address indexed token, address indexed recipient, uint256 amount);

    /**
     * @notice Emitted when rewards claim fails.
     * @param reason error reason for the failed claim
     */
    event RewardsClaimFailed(bytes reason);
    /**
     * @notice Emitted when the vault helper is updated.
     * @param helper new vault helper address
     */
    event VaultHelperUpdated(address indexed helper);
    
    /**
     * @notice Emitted when collateral dust is swept from the contract.
     * @param caller address that triggered the sweep
     * @param recipient recipient of the swept dust
     * @param amount amount of collateral dust swept
     */
    event CollateralDustSwept(address indexed caller, address indexed recipient, uint256 amount);
    
    /**
     * @notice Emitted when asset tokens are rescued from the contract.
     * @param recipient recipient of the rescued assets
     * @param amount amount of assets rescued
     */
    event AssetRescued(address indexed recipient, uint256 amount);
    
    /**
     * @notice Emitted when deposits are paused or unpaused.
     * @param paused true if deposits are paused, false if unpaused
     */
    event DepositsPaused(bool paused);

    // Functions
    /**
     * @notice Get the underlying VaultTokenized contract.
     * @return address of the VaultTokenized contract
     */
    function vault() external view returns (address);

    /**
     * @notice Get the Rewards contract associated with the vault.
     * @return address of the Rewards contract
     */
    function rewards() external view returns (address);

    /**
     * @notice Get the collateral token used by the vault.
     * @return address of the collateral token
     */
    function collateral() external view returns (address);

    /**
     * @notice Get the native token (underlying) paid by Rewards.
     * @return address of the native token
     */
    function nativeToken() external view returns (address);

    /**
     * @notice Get the vault helper used for conversion and staking.
     * @return address of the vault helper
     */
    function vaultHelper() external view returns (address);

    /**
     * @notice Initialize the LST Wrapper.
     * @param admin initial owner and admin of the wrapper
     * @param vault_ address of the VaultTokenized instance to wrap
     * @param rewards_ address of the associated Rewards contract
     * @param helper_ address of the VaultHelper to use
     * @param name_ ERC20 name for the LST wrapper token
     * @param symbol_ ERC20 symbol for the LST wrapper token
     */
    function initialize(
        address admin,
        address vault_,
        address rewards_,
        address helper_,
        string memory name_,
        string memory symbol_
    ) external;

    /**
     * @notice Harvest rewards and reinvest into the vault.
     * @dev Permissionless. If the underlying vault enforces a depositor whitelist,
     *      the caller must be whitelisted. The helper must also be whitelisted.
     * @return claimedNative amount of native token claimed from rewards
     * @return mintedVaultShares amount of vault shares minted from reinvestment
     */
    function harvest() external returns (uint256 claimedNative, uint256 mintedVaultShares);

    /**
     * @notice Sweep unexpected tokens from the contract.
     * @param token address of the token to sweep
     * @param recipient recipient address for the swept tokens
     * @param amount amount of tokens to sweep
     * @dev Only callable by owner. Cannot sweep the underlying asset or collateral.
     */
    function sweep(address token, address recipient, uint256 amount) external;

    // Admin
    function setVaultHelper(address helper_) external;
    function setDepositsPaused(bool paused) external;
    
    /**
     * @notice Check if deposits are currently paused.
     * @return true if deposits are paused, false otherwise
     */
    function paused() external view returns (bool);

    /**
     * @notice Recovers collateral dust that was accidentally sent to the wrapper.
     * @param recipient The address to send the dust to
     * @param amount The amount of collateral dust to recover
     * @dev Only callable by owner. Limited to small amounts for safety.
     */
    function sweepCollateralDust(address recipient, uint256 amount) external;

    /**
     * @notice Rescue underlying asset tokens if no wrapper shares exist.
     * @dev Prevents permanent lock after donation griefing. Only when totalSupply()==0.
     */
    function rescueAssetWhenNoSupply(address recipient, uint256 amount) external;

    /**
     * @notice Deposit assets with minimum shares protection.
     * @param assets amount of assets to deposit
     * @param minShares minimum shares to receive
     * @param receiver recipient of the shares
     * @return shares actual shares minted
     */
    function depositWithMinShares(uint256 assets, uint256 minShares, address receiver)
        external
        returns (uint256 shares);

    /**
     * @notice Mint shares with maximum assets protection.
     * @param shares amount of shares to mint
     * @param maxAssets maximum assets to spend
     * @param receiver recipient of the shares
     * @return assets actual assets spent
     */
    function mintWithMaxAssets(uint256 shares, uint256 maxAssets, address receiver)
        external
        returns (uint256 assets);

    /**
     * @notice Withdraw assets with maximum shares protection.
     * @param assets amount of assets to withdraw
     * @param maxShares maximum shares to burn
     * @param receiver recipient of the assets
     * @param owner owner of the shares
     * @return shares actual shares burned
     */
    function withdrawWithMaxShares(uint256 assets, uint256 maxShares, address receiver, address owner)
        external
        returns (uint256 shares);

    /**
     * @notice Redeem shares with minimum assets protection.
     * @param shares amount of shares to redeem
     * @param minAssets minimum assets to receive
     * @param receiver recipient of the assets
     * @param owner owner of the shares
     * @return assets actual assets received
     */
    function redeemWithMinAssets(uint256 shares, uint256 minAssets, address receiver, address owner)
        external
        returns (uint256 assets);
}
