// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAssetClassRegistry {
    error AssetClassRegistry__InvalidAsset();
    error AssetClassRegistry__AssetNotFound();
    error AssetClassRegistry__AssetAlreadyRegistered();
    error AssetClassRegistry__AssetClassAlreadyExists();
    error AssetClassRegistry__AssetClassNotFound();
    error AssetClassRegistry__AssetIsDefaultAsset();

    event AssetClassAdded(uint256 indexed classId, uint256 minStake, uint256 maxStake);
    event AssetAdded(uint256 indexed classId, address indexed asset);
    event AssetRemoved(uint256 indexed classId, address indexed asset);

    /**
     * @notice Returns all the assets in a specific asset class.
     * @param _classId The ID of the asset class.
     * @return An array of asset addresses in the asset class.
     */
    function getClassAssets(uint256 _classId) external view returns (address[] memory);

    /**
     * @notice Returns the minimum validator stake for a specific asset class.
     * @param _classId The ID of the asset class.
     * @return The minimum validator stake.
     */
    function getMinValidatorStake(uint256 _classId) external view returns (uint256);

    /**
     * @notice Returns the maximum validator stake for a specific asset class.
     * @param _classId The ID of the asset class.
     * @return The maximum validator stake.
     */
    function getMaxValidatorStake(uint256 _classId) external view returns (uint256);
}
