// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface IOperatorRegistry {
    event RegisterOperator(address indexed operator, string metadataURL);

    error OperatorRegistry__OperatorAlreadyRegistered();

    /// @notice Register an operator with its metadata URL
    function registerOperator(string memory metadataURL) external;

    /**
     * @notice Check if an address is registered as an operator
     * @param operator The address to check
     * @return True if the address is registered as an operator, false otherwise
     */
    function isRegistered(address operator) external view returns (bool);

    /**
     * @notice Get the operator at a specific index
     * @param index The index of the operator to get
     * @return The address of the operator at the specified index
     * @return The metadata URL of the operator at the specified index
     */
    function getOperatorAt(
        uint256 index
    ) external view returns (address, string memory);

    /**
     * @notice Get the total number of operators
     * @return Total number of operators
     */
    function totalOperators() external view returns (uint256);

    /**
     * @notice Get all operators
     * @return Array of all operators
     * @return Array of all operators' metadata URLs
     */
    function getAllOperators()
        external
        view
        returns (address[] memory, string[] memory);
}
