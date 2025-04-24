// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {IMiddlewareVaultManager} from "../../interfaces/middleware/IMiddlewareVaultManager.sol";
import {IAvalancheL1Middleware} from "../../interfaces/middleware/IAvalancheL1Middleware.sol";
import {IRegistry} from "../../interfaces/common/IRegistry.sol";
import {IEntity} from "../../interfaces/common/IEntity.sol";
import {IVaultTokenized} from "../../interfaces/vault/IVaultTokenized.sol";
import {BaseDelegator} from "../../contracts/delegator/BaseDelegator.sol";
import {ISlasher} from "../../interfaces/slasher/ISlasher.sol";
import {IVetoSlasher} from "../../interfaces/slasher/IVetoSlasher.sol";

import {MapWithTimeData} from "./libraries/MapWithTimeData.sol";
import {AvalancheL1Middleware} from "./AvalancheL1Middleware.sol";

contract MiddlewareVaultManager is IMiddlewareVaultManager, Ownable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;

    mapping(address => uint96) public vaultToAssetClass;
    EnumerableMap.AddressToUintMap private vaults;

    address public immutable VAULT_REGISTRY;
    AvalancheL1Middleware public immutable middleware;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;

    constructor(address vaultRegistry, address owner, address middlewareAddress) Ownable(owner) {
        if (vaultRegistry == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("vaultRegistry");
        }
        if (middlewareAddress == address(0)) {
            revert AvalancheL1Middleware__ZeroAddress("middlewareAddress");
        }
        VAULT_REGISTRY = vaultRegistry;
        middleware = AvalancheL1Middleware(payable(middlewareAddress));
    }

    /**
     * @notice Registers a vault to a specific asset class, sets the max stake.
     * @param vault The vault address
     * @param assetClassId The asset class ID for that vault
     * @param vaultMaxL1Limit The maximum stake allowed for this vault
     */
    function registerVault(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external onlyOwner {
        if (vaultMaxL1Limit == 0) {
            revert AvalancheL1Middleware__ZeroVaultMaxL1Limit();
        }
        if (vaults.contains(vault)) {
            revert AvalancheL1Middleware__VaultAlreadyRegistered();
        }

        uint48 vaultEpoch = IVaultTokenized(vault).epochDuration();
        address slasher = IVaultTokenized(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }
        if (vaultEpoch < middleware.SLASHING_WINDOW()) {
            revert AvalancheL1Middleware__VaultEpochTooShort();
        }

        vaultToAssetClass[vault] = assetClassId;
        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        vaults.add(vault);
        vaults.enable(vault);
    }

    /**
     * @notice Updates a vault's max L1 stake limit. Disables or enables the vault based on the new limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param vaultMaxL1Limit The new maximum stake
     */
    function updateVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external onlyOwner {
        if (!vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }
        if (vaultToAssetClass[vault] != assetClassId) {
            revert AvalancheL1Middleware__WrongVaultAssetClass();
        }

        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        if (vaultMaxL1Limit == 0) {
            vaults.disable(vault);
        } else {
            vaults.enable(vault);
        }
    }

    /**
     * @notice Removes a vault if the grace period has passed
     * @param vault The vault address
     */
    function removeVault(
        address vault
    ) external onlyOwner {
        if (!vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }

        (, uint48 disabledTime) = vaults.getTimes(vault);
        if (disabledTime == 0) {
            revert AvalancheL1Middleware__VaultNotDisabled();
        }

        if (disabledTime + middleware.SLASHING_WINDOW() > Time.timestamp()) {
            revert AvalancheL1Middleware__VaultGracePeriodNotPassed();
        }

        // Remove from vaults and clear mapping
        vaults.remove(vault);
        delete vaultToAssetClass[vault];
    }

    /**
     * @notice Sets a vault's max L1 stake limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param amount The new maximum stake
     */
    function _setVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 amount) internal onlyOwner {
        if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }
        if (!middleware.isActiveAssetClass(assetClassId)) {
            revert IAvalancheL1Middleware.AvalancheL1Middleware__AssetClassNotActive(assetClassId);
        }
        address vaultCollateral = IVaultTokenized(vault).collateral();
        if (!middleware.isAssetInClass(assetClassId, vaultCollateral)) {
            revert IAvalancheL1Middleware.AvalancheL1Middleware__CollateralNotInAssetClass(
                vaultCollateral, assetClassId
            );
        }
        address delegator = IVaultTokenized(vault).delegator();
        BaseDelegator(delegator).setMaxL1Limit(middleware.L1_VALIDATOR_MANAGER(), assetClassId, amount);
    }

    function slashVault() external pure {
        revert AvalancheL1Middleware__SlasherNotImplemented();
    }

    function getVaultCount() external view returns (uint256) {
        return vaults.length();
    }

    function getVaultAtWithTimes(
        uint256 index
    ) external view returns (address vault, uint48 enabledTime, uint48 disabledTime) {
        return vaults.atWithTimes(index);
    }

    function getVaultAssetClass(
        address vault
    ) external view returns (uint96) {
        return vaultToAssetClass[vault];
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime >= timestamp);
    }
}
