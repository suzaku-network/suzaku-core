// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import "../../src/contracts/middleware/AssetClassRegistry.sol";

error AssetClassRegistry__AssetIsPrimaryAssetClass(uint256 assetClassId);

contract MockAssetClassRegistry is AssetClassRegistry {
    address public primaryAsset;

    constructor(
        address initialOwner
    ) AssetClassRegistry(initialOwner) {}

    function setPrimaryAsset(
        address _primaryAsset
    ) external {
        primaryAsset = _primaryAsset;
    }

    function removeAssetFromClass(uint256 assetClassId, address asset) public override {
        if (assetClassId == 1 && asset == primaryAsset) {
            revert AssetClassRegistry__AssetIsPrimaryAssetClass(assetClassId);
        }
        _removeAssetFromClass(assetClassId, asset);
    }
}
