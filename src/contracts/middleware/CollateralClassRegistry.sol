// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import {ICollateralClassRegistry} from "../../interfaces/middleware/ICollateralClassRegistry.sol";

abstract contract CollateralClassRegistry is ICollateralClassRegistry, Ownable {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    struct CollateralClass {
        EnumerableSet.AddressSet assets;
        uint256 minValidatorStake;
        uint256 maxValidatorStake;
    }

    EnumerableSet.UintSet internal collateralClassIds;
    mapping(uint256 => CollateralClass) internal collateralClasses;

    constructor(
        address initialOwner
    ) Ownable(initialOwner) {}

    /// @inheritdoc ICollateralClassRegistry
    function addCollateralClass(
        uint256 collateralClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) external onlyOwner {
        _addCollateralClass(collateralClassId, minValidatorStake, maxValidatorStake, initialAsset);
    }

    /// @inheritdoc ICollateralClassRegistry
    function addAssetToClass(uint256 collateralClassId, address asset) external onlyOwner {
        if (!collateralClassIds.contains(collateralClassId)) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
        if (asset == address(0)) {
            revert CollateralClassRegistry__InvalidAsset();
        }

        _addAssetToClass(collateralClassId, asset);
    }

    /// @inheritdoc ICollateralClassRegistry
    function removeAssetFromClass(uint256 collateralClassId, address asset) public virtual onlyOwner {
        _removeAssetFromClass(collateralClassId, asset);
    }

    /// @inheritdoc ICollateralClassRegistry
    function removeCollateralClass(
        uint256 collateralClassId
    ) public virtual onlyOwner {
        _removeCollateralClass(collateralClassId);
    }

    /// @inheritdoc ICollateralClassRegistry
    function getClassAssets(
        uint256 collateralClassId
    ) external view returns (address[] memory) {
        if (!collateralClassIds.contains(collateralClassId)) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
        return collateralClasses[collateralClassId].assets.values();
    }

    /// @inheritdoc ICollateralClassRegistry
    function getClassStakingRequirements(
        uint256 collateralClassId
    ) external view returns (uint256 minStake, uint256 maxStake) {
        if (!collateralClassIds.contains(collateralClassId)) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
        CollateralClass storage cls = collateralClasses[collateralClassId];
        return (cls.minValidatorStake, cls.maxValidatorStake);
    }

    function _addCollateralClass(
        uint256 collateralClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) internal {
        if (initialAsset == address(0)) {
            revert CollateralClassRegistry__InvalidAsset();
        }
        if (collateralClassId == 1 && minValidatorStake > maxValidatorStake) {
            revert CollateralClassRegistry__InvalidStakingRequirements();
        }

        bool added = collateralClassIds.add(collateralClassId);
        if (!added) {
            revert CollateralClassRegistry__CollateralClassAlreadyExists();
        }

        CollateralClass storage cls = collateralClasses[collateralClassId];
        cls.minValidatorStake = minValidatorStake;
        cls.maxValidatorStake = maxValidatorStake;

        emit CollateralClassAdded(collateralClassId, minValidatorStake, maxValidatorStake);

        _addAssetToClass(collateralClassId, initialAsset);
    }

    function _addAssetToClass(uint256 collateralClassId, address asset) internal {
        CollateralClass storage cls = collateralClasses[collateralClassId];

        bool added = cls.assets.add(asset);
        if (!added) {
            revert CollateralClassRegistry__AssetAlreadyRegistered();
        }

        emit AssetAdded(collateralClassId, asset);
    }

    function _removeAssetFromClass(uint256 collateralClassId, address asset) internal {
        CollateralClass storage cls = collateralClasses[collateralClassId];
        bool assetFound = cls.assets.remove(asset);
        
        if (!assetFound) {
            if (!collateralClassIds.contains(collateralClassId)) {
                revert CollateralClassRegistry__CollateralClassNotFound();
            }
            revert CollateralClassRegistry__AssetNotFound();
        }

        emit AssetRemoved(collateralClassId, asset);
    }

    function _removeCollateralClass(
        uint256 collateralClassId
    ) internal {
        if (collateralClassId == 1) {
            revert CollateralClassRegistry__AssetIsPrimaryCollateralClass(collateralClassId);
        }

        if (collateralClasses[collateralClassId].assets.length() != 0) {
            revert CollateralClassRegistry__AssetsStillExist();
        }

        bool removed = collateralClassIds.remove(collateralClassId);
        if (!removed) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }

        delete collateralClasses[collateralClassId];

        emit CollateralClassRemoved(collateralClassId);
    }

    function isAssetInClass(uint256 collateralClassId, address asset) external view returns (bool) {
        if (!collateralClassIds.contains(collateralClassId)) {
            revert CollateralClassRegistry__CollateralClassNotFound();
        }
        return collateralClasses[collateralClassId].assets.contains(asset);
    }

    function getCollateralClassIds() external view returns (uint96[] memory) {
        uint256[] memory ids = collateralClassIds.values();
        uint96[] memory collateralClassIDs = new uint96[](ids.length);
        for (uint256 i = 0; i < ids.length; i++) {
            collateralClassIDs[i] = uint96(ids[i]);
        }
        return collateralClassIDs;
    }

    receive() external payable {}
}
