// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface IL1Registry {
    event RegisterL1(address indexed l1);
    event SetL1Middleware(address indexed l1, address indexed l1Middleware);
    event SetMetadataURL(address indexed l1, string metadataURL);

    error L1Registry__L1AlreadyRegistered();
    error L1Registry__L1NotRegistered();
    error L1Registry__InvalidValidatorManager(address l1);
    error L1Registry__InvalidL1Middleware();
    error L1Registry__NotValidatorManagerOwner(address caller, address expectedOwner);
    error L1Registry__NotMiddlewareOwner(address caller, address expectedOwner);

    /**
     * @notice Register an Avalanche L1
     * @dev l1 must be the manager of the Avalanche L1
     * @dev msg.sender must be a SecurityModule of the l1
     * @dev l1Middleware must be a SecurityModule of the Avalanche L1
     * @param l1 The l1 of the Avalanche L1. Should be The ValidatorManager.
     * @param l1Middleware The l1Middleware of the Avalanche L1
     * @param metadataURL The metadata URL of the Avalanche L1
     */
    function registerL1(
        address l1,
        address l1Middleware,
        string calldata metadataURL
    )
        /*, uint32 messageIndex, SubnetConversionData subnetConversionData*/
        external;

    /**
     * @notice Check if an address is registered as an L1
     * @param l1 The l1 of the Avalanche L1. Should be The ValidatorManager.
     * @return True if the address is registered as an L1, false otherwise
     */
    function isRegistered(
        address l1
    ) external view returns (bool);

    /**
     * @notice Check if an address is registered as an L1 and if the Middleware is correct
     * @param l1 The l1 of the Avalanche L1. Should be The ValidatorManager.
     * @param l1middleware_ The l1Middleware to check
     * @return True if the address is registered as an L1 and the middleware is correct, false otherwise
     */
    function isRegisteredWithMiddleware(address l1, address l1middleware_) external view returns (bool);

    /**
     * @notice Get the L1 at a specific index
     * @param index The index of the L1 to get
     * @return The address of the L1 at the specified index
     * @return The l1Middleware of the L1 at the specified index
     * @return The metadata URL of the L1 at the specified index
     */
    function getL1At(
        uint256 index
    ) external view returns (address, address, string memory);

    /**
     * @notice Get the total number of L1s
     * @return Total number of L1s
     */
    function totalL1s() external view returns (uint256);

    /**
     * @notice Get all L1s
     * @return Array of all L1s
     * @return Array of all L1s' l1Middlewares
     * @return Array of all L1s' metadata URLs
     */
    function getAllL1s() external view returns (address[] memory, address[] memory, string[] memory);

    /**
     * @notice Set the l1Middleware of an L1
     * @param l1 The l1 of the Avalanche L1. Should be The ValidatorManager.
     * @param l1Middleware_ The new l1Middleware
     */
    function setL1Middleware(address l1, address l1Middleware_) external;

    /**
     * @notice Set the metadata URL of an L1
     * @param l1 The l1 of the Avalanche L1. Should be The ValidatorManager.
     * @param metadataURL The new metadata URL
     */
    function setMetadataURL(address l1, string calldata metadataURL) external;
}
