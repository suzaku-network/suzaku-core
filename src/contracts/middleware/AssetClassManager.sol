// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAssetClassManager} from "../../interfaces/middleware/IAssetClassManager.sol";

/**
 * @title AssetClassManager
 * @notice Implementation of IAssetClassManager for managing primary and secondary asset classes,
 *         their tokens, and validator stake requirements.
 */
contract AssetClassManager is IAssetClassManager {
    using EnumerableSet for EnumerableSet.AddressSet;

    struct AssetClass {
        bool isPrimary;
        EnumerableSet.AddressSet tokens;
        uint256 minValidatorStake;
        uint256 maxValidatorStake;
    }

    AssetClass private primaryAssetClass;
    AssetClass private secondaryAssetClass;

    constructor(
        uint256 _maxStake,
        uint256 _primaryMinStake,
        uint256 _secondaryMinStake
    ) {
        primaryAssetClass.isPrimary = true;
        primaryAssetClass.minValidatorStake = _primaryMinStake;
        primaryAssetClass.maxValidatorStake = _maxStake;

        secondaryAssetClass.isPrimary = false;
        secondaryAssetClass.minValidatorStake = _secondaryMinStake;
        secondaryAssetClass.maxValidatorStake = 0; // Not used for secondary
    }
    
    /// @inheritdoc IAssetClassManager
    function addPrimaryToken(address _token) external override {
        if (_token == address(0)) {
            revert AssetClassManager__InvalidToken();
        }
        if (primaryAssetClass.tokens.contains(_token)) {
            revert AssetClassManager__TokenAlreadyRegistered();
        }
        primaryAssetClass.tokens.add(_token);

        emit TokenAdded(_token);
    }

    /// @inheritdoc IAssetClassManager
    function removePrimaryToken(address _token) external override {
        if (!primaryAssetClass.tokens.contains(_token)) {
            revert AssetClassManager__TokenNotFound();
        }

        primaryAssetClass.tokens.remove(_token);

        emit TokenRemoved(_token);
    }


    /// @inheritdoc IAssetClassManager
    function addSecondaryToken(address _token) external override {
        if (_token == address(0)) {
            revert AssetClassManager__InvalidToken();
        }
        if (secondaryAssetClass.tokens.contains(_token)) {
            revert AssetClassManager__TokenAlreadyRegistered();
        }
        secondaryAssetClass.tokens.add(_token);

        emit TokenAdded(_token);
    }

    /// @inheritdoc IAssetClassManager
    function removeSecondaryToken(address _token) external override {
        if (!secondaryAssetClass.tokens.contains(_token)) {
            revert AssetClassManager__TokenNotFound();
        }

        secondaryAssetClass.tokens.remove(_token);

        emit TokenRemoved(_token);
    }

    /// @inheritdoc IAssetClassManager
    function getPrimaryTokens() external view override returns (address[] memory) {
        return primaryAssetClass.tokens.values();
    }

    /// @inheritdoc IAssetClassManager
    function getSecondaryTokens() external view override returns (address[] memory) {
        return secondaryAssetClass.tokens.values();
    }

    /// @inheritdoc IAssetClassManager
    function getPrimaryMinValidatorStake() external view override returns (uint256) {
        return primaryAssetClass.minValidatorStake;
    }

    /// @inheritdoc IAssetClassManager
    function getPrimaryMaxValidatorStake() external view override returns (uint256) {
        return primaryAssetClass.maxValidatorStake;
    }

    /// @inheritdoc IAssetClassManager
    function getSecondaryMinValidatorStake() external view override returns (uint256) {
        return secondaryAssetClass.minValidatorStake;
    }

    /// @inheritdoc IAssetClassManager
    function getSecondaryMaxValidatorStake() external view override returns (uint256) {
        return secondaryAssetClass.maxValidatorStake;
    }
}
