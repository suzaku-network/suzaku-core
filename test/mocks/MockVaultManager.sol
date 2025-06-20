// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {MockDelegator} from "./MockDelegator.sol";
import {MockVault} from "./MockVault.sol";
import {MockAvalancheL1Middleware} from "./MockAvalancheL1Middleware.sol";
import {MapWithTimeData} from "../../src/contracts/middleware/libraries/MapWithTimeData.sol";

contract MockVaultManager is Ownable {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using MapWithTimeData for EnumerableMap.AddressToUintMap;

    mapping(address => uint96) public vaultToAssetClass;
    EnumerableMap.AddressToUintMap private _vaults;

    address[] public vaults; // Keep for backward compatibility with existing tests
    address public immutable VAULT_REGISTRY;
    MockAvalancheL1Middleware public middleware;

    // ADD THIS LINE:
    uint48 public immutable VAULT_REMOVAL_EPOCH_DELAY;

    uint48 private constant INSTANT_SLASHER_TYPE = 0;
    uint48 private constant VETO_SLASHER_TYPE = 1;

    // Use exact same error names as MiddlewareVaultManager
    error AvalancheL1Middleware__ZeroAddress(string param);
    error AvalancheL1Middleware__ZeroVaultMaxL1Limit();
    error AvalancheL1Middleware__VaultAlreadyRegistered();
    error AvalancheL1Middleware__VaultEpochTooShort();
    error AvalancheL1Middleware__NotVault(address vault);
    error AvalancheL1Middleware__WrongVaultAssetClass();
    error AvalancheL1Middleware__VaultNotDisabled();
    error AvalancheL1Middleware__VaultGracePeriodNotPassed();
    error AvalancheL1Middleware__SlasherNotImplemented();
    error AvalancheL1Middleware__AssetClassNotActive(uint96 assetClass);
    error AvalancheL1Middleware__CollateralNotInAssetClass(address collateral, uint96 assetClass);

    constructor() Ownable(msg.sender) {
        VAULT_REGISTRY = address(0); // Mock doesn't need real registry
        // middleware will be zero address - tests can set it later if needed
        VAULT_REMOVAL_EPOCH_DELAY = 1; // Default to 1 epoch for testing
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
        if (_vaults.contains(vault)) {
            revert AvalancheL1Middleware__VaultAlreadyRegistered();
        }

        // Mock vault epoch validation (simplified)
        // uint48 vaultEpoch = IVaultTokenized(vault).epochDuration();
        // address slasher = IVaultTokenized(vault).slasher();
        // if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
        //     vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        // }
        // if (vaultEpoch < middleware.SLASHING_WINDOW()) {
        //     revert AvalancheL1Middleware__VaultEpochTooShort();
        // }

        vaultToAssetClass[vault] = assetClassId;
        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        _vaults.add(vault);
        _vaults.enable(vault);
        vaults.push(vault); // Keep for backward compatibility
    }

    /**
     * @notice Updates a vault's max L1 stake limit. Disables or enables the vault based on the new limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param vaultMaxL1Limit The new maximum stake
     */
    function updateVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 vaultMaxL1Limit) external onlyOwner {
        if (!_vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }
        if (vaultToAssetClass[vault] != assetClassId) {
            revert AvalancheL1Middleware__WrongVaultAssetClass();
        }

        _setVaultMaxL1Limit(vault, assetClassId, vaultMaxL1Limit);

        if (vaultMaxL1Limit == 0) {
            _vaults.disable(vault);
        } else {
            _vaults.enable(vault);
        }
    }

    /**
     * @notice Removes a vault if the grace period has passed
     * @param vault The vault address
     */
    function removeVault(address vault) external onlyOwner {
        if (!_vaults.contains(vault)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }

        (, uint48 disabledTime) = _vaults.getTimes(vault);
        if (disabledTime == 0) {
            revert AvalancheL1Middleware__VaultNotDisabled();
        }

        uint48 epochDuration = middleware.EPOCH_DURATION();
        uint48 disabledEpoch = disabledTime / epochDuration;
        uint48 currentEpoch = uint48(Time.timestamp() / epochDuration);
        if (currentEpoch < disabledEpoch + VAULT_REMOVAL_EPOCH_DELAY) {
            revert AvalancheL1Middleware__VaultGracePeriodNotPassed();
        }

        // Remove from vaults and clear mapping
        _vaults.remove(vault);
        delete vaultToAssetClass[vault];

        // Remove from array for backward compatibility
        for (uint256 i = 0; i < vaults.length; i++) {
            if (vaults[i] == vault) {
                vaults[i] = vaults[vaults.length - 1];
                vaults.pop();
                break;
            }
        }
    }

    /**
     * @notice Sets a vault's max L1 stake limit
     * @param vault The vault address
     * @param assetClassId The asset class ID
     * @param amount The new maximum stake
     */
    function _setVaultMaxL1Limit(address vault, uint96 assetClassId, uint256 amount) internal {
        // Mock implementation - basic validation
        if (vault == address(0)) {
            revert AvalancheL1Middleware__NotVault(vault);
        }
        
        // In real implementation, this would check registry and call delegator
        // if (!IRegistry(VAULT_REGISTRY).isEntity(vault)) {
        //     revert AvalancheL1Middleware__NotVault(vault);
        // }
        // if (!middleware.isActiveAssetClass(assetClassId)) {
        //     revert IAvalancheL1Middleware.AvalancheL1Middleware__AssetClassNotActive(assetClassId);
        // }
        // address vaultCollateral = IVaultTokenized(vault).collateral();
        // if (!middleware.isAssetInClass(assetClassId, vaultCollateral)) {
        //     revert IAvalancheL1Middleware.AvalancheL1Middleware__CollateralNotInAssetClass(
        //         vaultCollateral, assetClassId
        //     );
        // }
        // address delegator = IVaultTokenized(vault).delegator();
        // BaseDelegator(delegator).setMaxL1Limit(middleware.L1_VALIDATOR_MANAGER(), assetClassId, amount);
    }

    function slashVault() external pure {
        revert AvalancheL1Middleware__SlasherNotImplemented();
    }

    // Existing functions for backward compatibility
    function addVault(address vault) external {
        vaults.push(vault);
        if (!_vaults.contains(vault)) {
            _vaults.add(vault);
            _vaults.enable(vault);
        }
    }

    function deployAndAddVault(
        address collateralAddress,
        address owner
    ) external returns (address vaultAddress, address delegatorAddress) {
        // First deploy the delegator
        MockDelegator delegator = new MockDelegator();
        delegatorAddress = address(delegator);

        // Then deploy the vault with reference to the delegator
        MockVault newVault = new MockVault(collateralAddress, delegatorAddress, owner);
        vaultAddress = address(newVault);

        vaults.push(vaultAddress);
        if (!_vaults.contains(vaultAddress)) {
            _vaults.add(vaultAddress);
            _vaults.enable(vaultAddress);
        }
    }

    function getVaultCount() external view returns (uint256) {
        return _vaults.length();
    }

    function getVaultAtWithTimes(
        uint256 index
    ) external view returns (address vault, uint48 enabledTime, uint48 disabledTime) {
        return _vaults.atWithTimes(index);
    }

    function getVaultAssetClass(address vault) external view returns (uint96) {
        return vaultToAssetClass[vault];
    }

    function setVaultAssetClass(address vault, uint96 assetClass) external {
        vaultToAssetClass[vault] = assetClass;
    }

    // Allow setting the middleware after construction for testing
    function setMiddleware(address middlewareAddress) external {
        middleware = MockAvalancheL1Middleware(payable(middlewareAddress));
    }

    function getVaults(uint48 epoch) external view returns (address[] memory) {
        uint256 vaultCount = _vaults.length();
        uint48 epochStart;
        if (address(middleware) != address(0)) {
            epochStart = uint48(middleware.getEpochStartTs(epoch));
        } else {
            // Simplified mock - just use the epoch as timestamp for testing
            epochStart = uint48(Time.timestamp());
        }

        uint256 activeCount = 0;
        for (uint256 i = 0; i < vaultCount; i++) {
            (, uint48 enabledTime, uint48 disabledTime) = _vaults.atWithTimes(i);
            if (_wasActiveAt(enabledTime, disabledTime, epochStart)) {
                activeCount++;
            }
        }

        address[] memory activeVaults = new address[](activeCount);
        uint256 activeIndex = 0;
        for (uint256 i = 0; i < vaultCount; i++) {
            (address vault, uint48 enabledTime, uint48 disabledTime) = _vaults.atWithTimes(i);
            if (_wasActiveAt(enabledTime, disabledTime, epochStart)) {
                activeVaults[activeIndex] = vault;
                activeIndex++;
            }
        }

        return activeVaults;
    }

    function _wasActiveAt(uint48 enabledTime, uint48 disabledTime, uint48 timestamp) private pure returns (bool) {
        return enabledTime != 0 && enabledTime <= timestamp && (disabledTime == 0 || disabledTime > timestamp);
    }
}
