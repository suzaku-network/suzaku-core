// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {IAssetClassRegistry} from "../../interfaces/middleware/IAssetClassRegistry.sol";

abstract contract AssetClassRegistry is IAssetClassRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    struct AssetClass {
        EnumerableSet.AddressSet assets;
        uint256 minValidatorStake;
        uint256 maxValidatorStake;
    }

    EnumerableSet.UintSet internal assetClassIds;
    mapping(uint256 => AssetClass) internal assetClasses;

    /// @inheritdoc IAssetClassRegistry
    function addAssetClass(
        uint256 assetClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) external {
        _addAssetClass(assetClassId, minValidatorStake, maxValidatorStake, initialAsset);
    }

    /// @inheritdoc IAssetClassRegistry
    function addAssetToClass(uint256 assetClassId, address asset) external {
        _addAssetToClass(assetClassId, asset);
    }

    /// @inheritdoc IAssetClassRegistry
    function removeAssetFromClass(uint256 assetClassId, address asset) external virtual {
        _removeAssetFromClass(assetClassId, asset);
    }

    /// @inheritdoc IAssetClassRegistry
    function removeAssetClass(uint256 assetClassId) external virtual {
        _removeAssetClass(assetClassId);
    }

    /// @inheritdoc IAssetClassRegistry
    function getClassAssets(uint256 assetClassId) external view returns (address[] memory) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[assetClassId].assets.values();
    }

    /// @inheritdoc IAssetClassRegistry
    function getMinValidatorStake(uint256 assetClassId) external view returns (uint256) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[assetClassId].minValidatorStake;
    }

    /// @inheritdoc IAssetClassRegistry
    function getMaxValidatorStake(uint256 assetClassId) external view returns (uint256) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[assetClassId].maxValidatorStake;
    }

    function _addAssetClass(
        uint256 assetClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) internal {
        if (assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }
        if (initialAsset == address(0)) {
            revert AssetClassRegistry__InvalidAsset();
        }

        assetClassIds.add(assetClassId);

        AssetClass storage cls = assetClasses[assetClassId];
        cls.minValidatorStake = minValidatorStake;
        cls.maxValidatorStake = maxValidatorStake;

        emit AssetClassAdded(assetClassId, minValidatorStake, maxValidatorStake);

        _addAssetToClass(assetClassId, initialAsset);
    }

    function _addAssetToClass(uint256 assetClassId, address asset) internal {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (asset == address(0)) {
            revert AssetClassRegistry__InvalidAsset();
        }

        AssetClass storage cls = assetClasses[assetClassId];
        if (cls.assets.contains(asset)) {
            revert AssetClassRegistry__AssetAlreadyRegistered();
        }
        cls.assets.add(asset);

        emit AssetAdded(assetClassId, asset);
    }

    function _removeAssetFromClass(uint256 assetClassId, address asset) internal {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        AssetClass storage cls = assetClasses[assetClassId];
        if (!cls.assets.contains(asset)) {
            revert AssetClassRegistry__AssetNotFound();
        }
        cls.assets.remove(asset);

        emit AssetRemoved(assetClassId, asset);
    }

    function _removeAssetClass(uint256 assetClassId) internal {
        if (assetClassId == 1) {
            revert AssetClassRegistry__AssetIsPrimarytAssetClass();
        }

        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        if (assetClasses[assetClassId].assets.length() != 0) {
            revert AssetClassRegistry__AssetsStillExist();
        }

        assetClassIds.remove(assetClassId);
        delete assetClasses[assetClassId];

        emit AssetClassRemoved(assetClassId);
    }
}
