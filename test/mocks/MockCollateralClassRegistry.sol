// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import "../../src/contracts/middleware/CollateralClassRegistry.sol";

error CollateralClassRegistry__AssetIsPrimaryCollateralClass(uint256 collateralClassId);

contract MockCollateralClassRegistry is CollateralClassRegistry {
    address public primaryAsset;

    constructor(
        address initialOwner
    ) CollateralClassRegistry(initialOwner) {}

    function setPrimaryAsset(
        address _primaryAsset
    ) external {
        primaryAsset = _primaryAsset;
    }

    function removeAssetFromClass(uint256 collateralClassId, address asset) public override {
        if (collateralClassId == 1 && asset == primaryAsset) {
            revert CollateralClassRegistry__AssetIsPrimaryCollateralClass(collateralClassId);
        }
        _removeAssetFromClass(collateralClassId, asset);
    }
}
