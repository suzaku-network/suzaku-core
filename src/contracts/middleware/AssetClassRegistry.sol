// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {IAssetClassRegistry} from "../../interfaces/middleware/IAssetClassRegistry.sol";

abstract contract AssetClassRegistry is IAssetClassRegistry, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    struct AssetClass {
        EnumerableSet.AddressSet assets;
        uint256 minValidatorStake;
        uint256 maxValidatorStake;
    }

    EnumerableSet.UintSet internal assetClassIds;
    mapping(uint256 => AssetClass) internal assetClasses;

    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}

    /// @inheritdoc IAssetClassRegistry
    function addAssetClass(
        uint256 assetClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) external onlyOwner {
        _addAssetClass(assetClassId, minValidatorStake, maxValidatorStake, initialAsset);
    }

    /// @inheritdoc IAssetClassRegistry
    function addAssetToClass(uint256 assetClassId, address asset) external onlyOwner {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (asset == address(0)) {
            revert AssetClassRegistry__InvalidAsset();
        }

        _addAssetToClass(assetClassId, asset);
    }

    /// @inheritdoc IAssetClassRegistry
    function removeAssetFromClass(uint256 assetClassId, address asset) public virtual onlyOwner {
        _removeAssetFromClass(assetClassId, asset);
    }

    /// @inheritdoc IAssetClassRegistry
    function removeAssetClass(
        uint256 assetClassId
    ) public virtual onlyOwner {
        _removeAssetClass(assetClassId);
    }

    /// @inheritdoc IAssetClassRegistry
    function getClassAssets(
        uint256 assetClassId
    ) external view returns (address[] memory) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[assetClassId].assets.values();
    }

    /// @inheritdoc IAssetClassRegistry
    function getClassStakingRequirements(
        uint256 assetClassId
    ) external view returns (uint256 minStake, uint256 maxStake) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        AssetClass storage cls = assetClasses[assetClassId];
        return (cls.minValidatorStake, cls.maxValidatorStake);
    }

    function _addAssetClass(
        uint256 assetClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) internal {
        if (initialAsset == address(0)) {
            revert AssetClassRegistry__InvalidAsset();
        }
        if (assetClassId == 1 && minValidatorStake > maxValidatorStake) {
            revert AssetClassRegistry__InvalidStakingRequirements();
        }

        bool added = assetClassIds.add(assetClassId);
        if (!added) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }

        AssetClass storage cls = assetClasses[assetClassId];
        cls.minValidatorStake = minValidatorStake;
        cls.maxValidatorStake = maxValidatorStake;

        emit AssetClassAdded(assetClassId, minValidatorStake, maxValidatorStake);

        _addAssetToClass(assetClassId, initialAsset);
    }

    function _addAssetToClass(uint256 assetClassId, address asset) internal {
        AssetClass storage cls = assetClasses[assetClassId];

        bool added = cls.assets.add(asset);
        if (!added) {
            revert AssetClassRegistry__AssetAlreadyRegistered();
        }

        emit AssetAdded(assetClassId, asset);
    }

    function _removeAssetFromClass(uint256 assetClassId, address asset) internal {
        AssetClass storage cls = assetClasses[assetClassId];
        bool assetFound = cls.assets.remove(asset);
        
        if (!assetFound) {
            if (!assetClassIds.contains(assetClassId)) {
                revert AssetClassRegistry__AssetClassNotFound();
            }
            revert AssetClassRegistry__AssetNotFound();
        }

        emit AssetRemoved(assetClassId, asset);
    }

    function _removeAssetClass(
        uint256 assetClassId
    ) internal {
        if (assetClassId == 1) {
            revert AssetClassRegistry__AssetIsPrimaryAssetClass(assetClassId);
        }

        if (assetClasses[assetClassId].assets.length() != 0) {
            revert AssetClassRegistry__AssetsStillExist();
        }

        bool removed = assetClassIds.remove(assetClassId);
        if (!removed) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        delete assetClasses[assetClassId];

        emit AssetClassRemoved(assetClassId);
    }

    function isAssetInClass(uint256 assetClassId, address asset) external view returns (bool) {
        if (!assetClassIds.contains(assetClassId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[assetClassId].assets.contains(asset);
    }

    function getAssetClassIds() external view returns (uint96[] memory) {
        uint256[] memory ids = assetClassIds.values();
        uint96[] memory assetClassIDs = new uint96[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            assetClassIDs[i] = uint96(ids[i]);
        }
        return assetClassIDs;
    }

    receive() external payable {}
}
