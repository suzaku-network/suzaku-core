// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import "../../src/contracts/middleware/AssetClassRegistry.sol";

error AssetClassRegistry__AssetIsPrimarytAssetClass(uint256 assetClassId);

contract MockAssetClassRegistry is AssetClassRegistry {
    address public primaryAsset;

    function setPrimaryAsset(
        address _primaryAsset
    ) external {
        primaryAsset = _primaryAsset;
    }

    function removeAssetFromClass(uint256 assetClassId, address asset) external override {
        if (assetClassId == 1 && asset == primaryAsset) {
            revert AssetClassRegistry__AssetIsPrimarytAssetClass(assetClassId);
        }
        super._removeAssetFromClass(assetClassId, asset);
    }
}
