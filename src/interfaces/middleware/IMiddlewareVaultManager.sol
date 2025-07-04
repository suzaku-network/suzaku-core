// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IAvalancheL1Middleware} from "../../interfaces/middleware/IAvalancheL1Middleware.sol";

/**
 * @title IMiddlewareVaultManager
 * @notice Manages vault registration, maximum L1 stake limits, and slash routing.
 */
interface IMiddlewareVaultManager {
    // -----------------------------------------------------------------------
    // Errors
    // -----------------------------------------------------------------------
    error AvalancheL1Middleware__VaultAlreadyRegistered();
    error AvalancheL1Middleware__VaultEpochTooShort();
    error AvalancheL1Middleware__NotVault(address vault);
    error AvalancheL1Middleware__WrongVaultAssetClass();
    error AvalancheL1Middleware__ZeroVaultMaxL1Limit();
    error AvalancheL1Middleware__VaultGracePeriodNotPassed();
    error AvalancheL1Middleware__VaultNotDisabled();
    error AvalancheL1Middleware__ZeroAddress(string name);
    error AvalancheL1Middleware__SlasherNotImplemented();

    // -----------------------------------------------------------------------
    // Public state variable getters
    // -----------------------------------------------------------------------
    /**
     * @notice Returns the VAULT_REGISTRY address.
     */
    function VAULT_REGISTRY() external view returns (address);

    //
    // Functions
    //
    /**
     * @notice Registers a vault to a specific asset class with a given maximum L1 stake limit.
     * @param vault The vault address
     * @param assetClassId The asset class ID for the vault
     * @param vaultMaxL1Limit The maximum stake allowed for this vault
     */
    function registerVault(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external;

    /**
     * @notice Updates a vault's max L1 stake limit.
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param vaultMaxL1Limit The new maximum stake
     */
    function updateVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external;

    /**
     * @notice Removes a vault if the grace period has passed.
     * @param vault The vault address
     */
    function removeVault(
        address vault
    ) external;

    /**
     * @notice Slashes a vault based on the operator’s share of stake.
     */
    function slashVault() external;

    /**
     * @notice Returns the number of vaults registered.
     * @return The count of vaults
     */
    function getVaultCount() external view returns (uint256);

    /**
     * @notice Returns the vault and its enable/disable times at the given index.
     * @param index The vault index
     * @return vault The vault address
     * @return enabledTime The time the vault was enabled
     * @return disabledTime The time the vault was disabled
     */
    function getVaultAtWithTimes(
        uint256 index
    ) external view returns (address vault, uint48 enabledTime, uint48 disabledTime);

    /**
     * @notice Returns the asset class ID for a given vault.
     * @param vault The vault address
     * @return The asset class ID
     */
    function getVaultAssetClass(
        address vault
    ) external view returns (uint96);

    /**
     * @notice Fetches the active vaults for a given epoch
     * @param epoch The epoch for which vaults are fetched
     * @return An array of active vault addresses
     */
    function getVaults(
        uint48 epoch
    ) external view returns (address[] memory);
}
