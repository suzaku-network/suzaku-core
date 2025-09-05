// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface ICollateralClassRegistry {
    error CollateralClassRegistry__InvalidAsset();
    error CollateralClassRegistry__AssetNotFound();
    error CollateralClassRegistry__AssetAlreadyRegistered();
    error CollateralClassRegistry__CollateralClassAlreadyExists();
    error CollateralClassRegistry__CollateralClassNotFound();
    error CollateralClassRegistry__AssetIsPrimaryCollateralClass(uint256 collateralClassId);
    error CollateralClassRegistry__AssetsStillExist();
    error CollateralClassRegistry__InvalidStakingRequirements();
    error CollateralClassRegistry__AssetDecimalsMismatch(uint8 expected, uint8 actual);

    event CollateralClassAdded(uint256 indexed collateralClassId, uint256 primaryCollateralMinStake, uint256 primaryCollateralMaxStake);
    event AssetAdded(uint256 indexed collateralClassId, address indexed asset);
    event AssetRemoved(uint256 indexed collateralClassId, address indexed asset);
    event CollateralClassRemoved(uint256 indexed collateralClassId);

    /**
     * @notice Adds a new asset class
     * @param collateralClassId New asset class ID
     * @param minValidatorStake Minimum validator stake
     * @param maxValidatorStake Maximum validator stake
     * @param initialAsset Initial asset to add to the asset class
     */
    function addCollateralClass(
        uint256 collateralClassId,
        uint256 minValidatorStake,
        uint256 maxValidatorStake,
        address initialAsset
    ) external;

    /**
     * @notice Adds a asset to an asset class.
     * @param collateralClassId The ID of the asset class.
     * @param asset The address of the asset to add.
     */
    function addAssetToClass(uint256 collateralClassId, address asset) external;

    /**
     * @notice Removes a asset from an asset class, except .
     * @param collateralClassId The ID of the asset class.
     * @param asset The address of the asset to remove.
     */
    function removeAssetFromClass(uint256 collateralClassId, address asset) external;

    /**
     * @notice Removes an asset class.
     * @param collateralClassId The ID of the asset class.
     */
    function removeCollateralClass(
        uint256 collateralClassId
    ) external;

    /**
     * @notice Returns all the assets in a specific asset class.
     * @param collateralClassId The ID of the asset class.
     * @return An array of asset addresses in the asset class.
     */
    function getClassAssets(
        uint256 collateralClassId
    ) external view returns (address[] memory);

    /**
     * @notice Returns the minimum validator stake for a specific asset class.
     * @param collateralClassId The ID of the asset class.
     * @return The minimum and maximum validator stake.
     */
    function getClassStakingRequirements(
        uint256 collateralClassId
    ) external view returns (uint256, uint256);

    /**
     * @notice Fetches the active asset class IDs
     * @return An array of asset class IDs
     */
    function getCollateralClassIds() external view returns (uint96[] memory);
}
