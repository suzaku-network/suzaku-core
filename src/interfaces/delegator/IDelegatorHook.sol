// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IDelegatorHook {
    /**
     * @notice Called when a slash happens.
     * @param l1 address of the l1 (part of the subnetwork full  stakableAsset)
     * @param stakableAsset the uint96  stakableAsset (part of the subnetwork full  stakableAsset)
     * @param operator address of the operator
     * @param amount amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     * @param data some additional data
     */
    function onSlash(
        address l1,
        uint96  stakableAsset,
        address operator,
        uint256 amount,
        uint48 captureTimestamp,
        bytes calldata data
    ) external;
}
