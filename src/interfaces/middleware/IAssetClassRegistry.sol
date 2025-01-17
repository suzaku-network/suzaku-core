// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAssetClassRegistry {
    error AssetClassRegistry__InvalidAsset();
    error AssetClassRegistry__AssetNotFound();
    error AssetClassRegistry__AssetAlreadyRegistered();
    error AssetClassRegistry__AssetClassAlreadyExists();
    error AssetClassRegistry__AssetClassNotFound();
    error AssetClassRegistry__AssetIsPrimaryAsset();
    error AssetClassRegistry__AssetIsPrimarytAssetClass();
    error AssetClassRegistry__AssetsStillExist();

    event AssetClassAdded(uint256 indexed assetClassId, uint256 primaryAssetMinStake, uint256 primaryAssetMaxStake);
    event AssetAdded(uint256 indexed assetClassId, address indexed asset);
    event AssetRemoved(uint256 indexed assetClassId, address indexed asset);
    event AssetClassRemoved(uint256 indexed assetClassId);

    /**
     * @notice Adds a new asset class
     * @param assetClassId New asset class ID
     * @param minValidatorStake Minimum validator stake
     * @param maxValidatorStake Maximum validator stake
     * @param initialAsset Initial asset to add to the asset class
     */
    function addAssetClass(
        uint256 assetClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) external;

    /**
     * @notice Adds a asset to an asset class.
     * @param assetClassId The ID of the asset class.
     * @param asset The address of the asset to add.
     */
    function addAssetToClass(uint256 assetClassId, address asset) external;

    /**
     * @notice Removes a asset from an asset class, except .
     * @param assetClassId The ID of the asset class.
     * @param asset The address of the asset to remove.
     */
    function removeAssetFromClass(uint256 assetClassId, address asset) external;

    /**
     * @notice Removes an asset class.
     * @param assetClassId The ID of the asset class.
     */
    function removeAssetClass(uint256 assetClassId) external;

    /**
     * @notice Returns all the assets in a specific asset class.
     * @param assetClassId The ID of the asset class.
     * @return An array of asset addresses in the asset class.
     */
    function getClassAssets(uint256 assetClassId) external view returns (address[] memory);

    /**
     * @notice Returns the minimum validator stake for a specific asset class.
     * @param assetClassId The ID of the asset class.
     * @return The minimum validator stake.
     */
    function getMinValidatorStake(uint256 assetClassId) external view returns (uint256);

    /**
     * @notice Returns the maximum validator stake for a specific asset class.
     * @param assetClassId The ID of the asset class.
     * @return The maximum validator stake.
     */
    function getMaxValidatorStake(uint256 assetClassId) external view returns (uint256);
}
