// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface ILSTWrapper is IERC4626 {
    // Errors
    error LSTWrapper__ZeroAddress(string param);
    error LSTWrapper__CannotSweepAsset();
    error LSTWrapper__CannotSweepCollateral();
    error LSTWrapper__InvalidRecipient();
    error LSTWrapper__InvalidVaultCollateral();

    // Events
    /**
     * @notice Emitted when rewards are harvested and reinvested.
     * @param caller address that triggered the harvest
     * @param claimedCollateral amount of collateral claimed from rewards
     * @param mintedVaultShares amount of vault shares minted from reinvestment
     */
    event Harvest(address indexed caller, uint256 claimedCollateral, uint256 mintedVaultShares);

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
     * @notice Initialize the LST Wrapper.
     * @param admin initial owner and admin of the wrapper
     * @param vault_ address of the VaultTokenized instance to wrap
     * @param rewards_ address of the associated Rewards contract
     * @param name_ ERC20 name for the LST wrapper token
     * @param symbol_ ERC20 symbol for the LST wrapper token
     */
    function initialize(
        address admin,
        address vault_,
        address rewards_,
        string memory name_,
        string memory symbol_
    ) external;

    /**
     * @notice Harvest rewards and reinvest them into the vault.
     * @return claimedCollateral amount of collateral claimed from rewards
     * @return mintedVaultShares amount of vault shares minted from reinvestment
     * @dev This function is permissionless and increases the value per share of the wrapper token.
     */
    function harvest() external returns (uint256 claimedCollateral, uint256 mintedVaultShares);

    /**
     * @notice Sweep unexpected tokens from the contract.
     * @param token address of the token to sweep
     * @param recipient recipient address for the swept tokens
     * @param amount amount of tokens to sweep
     * @dev Only callable by owner. Cannot sweep the underlying asset or collateral.
     */
    function sweep(address token, address recipient, uint256 amount) external;
}
