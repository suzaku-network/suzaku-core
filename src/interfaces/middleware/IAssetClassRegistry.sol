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
     * @notice Adds a new asset class with specified parameters.
     * @param _classId The unique identifier for the asset class.
     * @param _minValidatorStake The minimum stake required for validators in this class.
     * @param _maxValidatorStake The maximum stake allowed for validators in this class.
     */
    function addAssetClass(
        uint256 _classId,
        uint256 _minValidatorStake,
        uint256 _maxValidatorStake
    ) external;

    /**
     * @notice Adds a asset to an asset class.
     * @param _classId The ID of the asset class.
     * @param _asset The address of the asset to add.
     */
    function addAsset(uint256 _classId, address _asset) external;

    /**
     * @notice Removes a asset from an asset class, except .
     * @param _classId The ID of the asset class.
     * @param _asset The address of the asset to remove.
     */
    function removeAsset(uint256 _classId, address _asset) external;

    /**
     * @notice Returns all the assets in a specific asset class.
     * @param _classId The ID of the asset class.
     * @return An array of asset addresses in the asset class.
     */
    function getAssets(uint256 _classId) external view returns (address[] memory);

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
