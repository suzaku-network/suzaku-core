// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IOperatorRegistry} from "../interfaces/IOperatorRegistry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract OperatorRegistry is IOperatorRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private operators;

    /// @inheritdoc IOperatorRegistry
    function registerOperator() external {
        if (isRegistered(msg.sender)) {
            revert OperatorRegistry__OperatorAlreadyRegistered();
        }

        _addOperator(msg.sender);

        emit RegisterOperator(msg.sender);
    }

    /// @inheritdoc IOperatorRegistry
    function isRegistered(address operator) public view returns (bool) {
        return operators.contains(operator);
    }

    /// @inheritdoc IOperatorRegistry
    function getOperatorAt(uint256 index) public view returns (address) {
        return operators.at(index);
    }

    /// @inheritdoc IOperatorRegistry
    function totalOperators() public view returns (uint256) {
        return operators.length();
    }

    /// @inheritdoc IOperatorRegistry
    function getAllOperators() public view returns (address[] memory) {
        return operators.values();
    }

    /**
     * @dev Add an address as an operator.
     * @param operator The address to add.
     */
    function _addOperator(address operator) internal {
        operators.add(operator);
    }
}
