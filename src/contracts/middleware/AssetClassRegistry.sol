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

    address immutable defaultAsset;

    EnumerableSet.UintSet internal assetClassIds;
    mapping(uint256 => AssetClass) internal assetClasses;

    function _addAssetClass(
        uint256 _classId,
        uint256 _minValidatorStake,
        uint256 _maxValidatorStake
    ) internal {
        if (assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassAlreadyExists();
        }

        assetClassIds.add(_classId);

        AssetClass storage cls = assetClasses[_classId];
        cls.minValidatorStake = _minValidatorStake;
        cls.maxValidatorStake = _maxValidatorStake;

        emit AssetClassAdded(_classId, _minValidatorStake, _maxValidatorStake);
    }
    
    function _addAssetToClass(uint256 _classId, address _asset) internal {
        if (!assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        if (_asset == address(0)) {
            revert AssetClassRegistry__InvalidAsset();
        }

        AssetClass storage cls = assetClasses[_classId];
        if (cls.assets.contains(_asset)) {
            revert AssetClassRegistry__AssetAlreadyRegistered();
        }
        cls.assets.add(_asset);

        emit AssetAdded(_classId, _asset);
    }

    function _removeAssetFromClass(uint256 _classId, address _asset) internal {
        if (!assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }

        if (_classId == 1 && _asset == defaultAsset) {
            revert AssetClassRegistry__AssetIsDefaultAsset();
        }

        AssetClass storage cls = assetClasses[_classId];
        if (!cls.assets.contains(_asset)) {
            revert AssetClassRegistry__AssetNotFound();
        }
        cls.assets.remove(_asset);

        emit AssetRemoved(_classId, _asset);
    }

    /// @inheritdoc IAssetClassRegistry
    function getClassAssets(uint256 _classId) external view returns (address[] memory) {
        if (!assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[_classId].assets.values();
    }

    /// @inheritdoc IAssetClassRegistry
    function getMinValidatorStake(uint256 _classId) external view returns (uint256) {
        if (!assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[_classId].minValidatorStake;
    }

    /// @inheritdoc IAssetClassRegistry
    function getMaxValidatorStake(uint256 _classId) external view returns (uint256) {
        if (!assetClassIds.contains(_classId)) {
            revert AssetClassRegistry__AssetClassNotFound();
        }
        return assetClasses[_classId].maxValidatorStake;
    }
}
