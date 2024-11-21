// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract OperatorRegistry is IOperatorRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    /// @notice The set of registered operators
    EnumerableSet.AddressSet private operators;

    /// @notice The metadata URL for each operator
    mapping(address => string) public operatorMetadataURL;

    /// @inheritdoc IOperatorRegistry
    function registerOperator(string memory metadataURL) external {
        if (isRegistered(msg.sender)) {
            revert OperatorRegistry__OperatorAlreadyRegistered();
        }

        operators.add(msg.sender);
        operatorMetadataURL[msg.sender] = metadataURL;

        emit RegisterOperator(msg.sender, metadataURL);
    }

    /// @inheritdoc IOperatorRegistry
    function isRegistered(address operator) public view returns (bool) {
        return operators.contains(operator);
    }

    /// @inheritdoc IOperatorRegistry
    function getOperatorAt(
        uint256 index
    ) public view returns (address, string memory) {
        address operator = operators.at(index);
        return (operator, operatorMetadataURL[operator]);
    }

    /// @inheritdoc IOperatorRegistry
    function totalOperators() public view returns (uint256) {
        return operators.length();
    }

    /// @inheritdoc IOperatorRegistry
    function getAllOperators()
        public
        view
        returns (address[] memory, string[] memory)
    {
        address[] memory operatorsList = operators.values();
        string[] memory metadataURLs = new string[](operatorsList.length);
        for (uint256 i = 0; i < operatorsList.length; i++) {
            metadataURLs[i] = operatorMetadataURL[operatorsList[i]];
        }
        return (operatorsList, metadataURLs);
    }
}
