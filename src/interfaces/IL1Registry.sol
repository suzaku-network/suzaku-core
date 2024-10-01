// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface IL1Registry {
    event RegisterL1(address indexed l1);

    error L1Registry__L1AlreadyRegistered();
    error L1Registry__InvalidACP99Manager(address ACP99Manager);

    /**
     * @notice Register an Avalanche L1.
     * TODO: verify that the ACP99Manager is effectively the manager of an Avalanche L1 by
     * checking that the Subnet conversion message points to its address.
     * @dev The msg.sender must be the securityModule of the ACP99Manager
     * @param ACP99Manager The ACP99Manager of the Avalanche L1
     */
    function registerL1(address ACP99Manager /*, uint32 messageIndex, SubnetConversionData subnetConversionData*/ )
        external;

    /**
     * @notice Check if an address is registered as an L1.
     * @param l1 The address to check.
     * @return True if the address is registered as an L1, false otherwise.
     */
    function isRegistered(address l1) external view returns (bool);

    /**
     * @notice Get the L1 at a specific index.
     * @param index The index of the L1 to get.
     * @return The address of the L1 at the specified index.
     */
    function getL1At(uint256 index) external view returns (address);

    /**
     * @notice Get the total number of L1s.
     * @return Total number of L1s.
     */
    function totalL1s() external view returns (uint256);

    /**
     * @notice Get all L1s.
     * @return Array of all L1s.
     */
    function getAllL1s() external view returns (address[] memory);
}
