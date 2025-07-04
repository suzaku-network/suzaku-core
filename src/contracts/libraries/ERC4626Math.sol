// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @dev This library adds helper functions for ERC4626 math operations.
 */
library ERC4626Math {
    using Math for uint256;

    /// @dev Offset used in calculations to prevent division by zero and improve precision
    uint256 private constant DECIMALS_OFFSET = 0;

    function previewDeposit(uint256 assets, uint256 totalShares, uint256 totalAssets) internal pure returns (uint256) {
        return convertToShares(assets, totalShares, totalAssets, Math.Rounding.Floor);
    }

    function previewMint(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return convertToAssets(shares, totalAssets, totalShares, Math.Rounding.Ceil);
    }

    function previewWithdraw(
        uint256 assets,
        uint256 totalShares,
        uint256 totalAssets
    ) internal pure returns (uint256) {
        return convertToShares(assets, totalShares, totalAssets, Math.Rounding.Ceil);
    }

    function previewRedeem(uint256 shares, uint256 totalAssets, uint256 totalShares) internal pure returns (uint256) {
        return convertToAssets(shares, totalAssets, totalShares, Math.Rounding.Floor);
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     */
    function convertToShares(
        uint256 assets,
        uint256 totalShares,
        uint256 totalAssets,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return assets.mulDiv(totalShares + 10 ** DECIMALS_OFFSET, totalAssets + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     */
    function convertToAssets(
        uint256 shares,
        uint256 totalAssets,
        uint256 totalShares,
        Math.Rounding rounding
    ) internal pure returns (uint256) {
        return shares.mulDiv(totalAssets + 1, totalShares + 10 **DECIMALS_OFFSET, rounding);
    }
}
