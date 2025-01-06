// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IAssetClassManager {
    error AssetClassManager__InvalidToken();
    error AssetClassManager__TokenNotFound();
    error AssetClassManager__TokenAlreadyRegistered();

    event TokenAdded(address indexed token);
    event TokenRemoved(address indexed token);

    /**
     * @notice Adds a token to the primary asset class.
     * @dev Reverts if the token address is zero.
     * @param _token The address of the token to add.
     */
    function addPrimaryToken(address _token) external;

    /**
     * @notice Removes a token from the primary asset class.
     * @param _token The address of the token to remove.
     */
    function removePrimaryToken(address _token) external;

    /**
     * @notice Adds a token to the secondary asset class.
     * @dev Reverts if the token address is zero.
     * @param _token The address of the token to add.
     */
    function addSecondaryToken(address _token) external;

    /**
     * @notice Removes a token from the secondary asset class.
     * @param _token The address of the token to remove.
     */
    function removeSecondaryToken(address _token) external;

    /**
     * @notice Returns an array of all the tokens in the primary asset class.
     * @return An array of token addresses in the primary asset class.
     */
    function getPrimaryTokens() external view returns (address[] memory);

    /**
     * @notice Returns an array of all the tokens in the secondary asset class.
     * @return An array of token addresses in the secondary asset class.
     */
    function getSecondaryTokens() external view returns (address[] memory);

    /**
     * @notice Returns the minimum validator stake for the primary asset class.
     * @return The minimum stake required to validate in the primary asset class.
     */
    function getPrimaryMinValidatorStake() external view returns (uint256);

    /**
     * @notice Returns the maximum validator stake for the primary asset class.
     * @return The maximum stake allowed in the primary asset class.
     */
    function getPrimaryMaxValidatorStake() external view returns (uint256);

    /**
     * @notice Returns the minimum validator stake for the secondary asset class.
     * @return The minimum stake required to validate in the secondary asset class.
     */
    function getSecondaryMinValidatorStake() external view returns (uint256);

    /**
     * @notice Returns the maximum validator stake for the secondary asset class.
     * @dev This value is set to 0, as secondary classes don't use max stake.
     * @return The maximum stake allowed in the secondary asset class (currently 0).
     */
    function getSecondaryMaxValidatorStake() external view returns (uint256);
}
