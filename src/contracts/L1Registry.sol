// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract L1Registry is IL1Registry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private l1s;

    /// @inheritdoc IL1Registry
    function registerL1(address ACP99Manager) external {
        if (isRegistered(msg.sender)) {
            revert L1Registry__L1AlreadyRegistered();
        }

        // TODO: check if ACP99Manager is a valid ACP99Manager

        _addL1(msg.sender);

        emit RegisterL1(msg.sender);
    }

    /// @inheritdoc IL1Registry
    function isRegistered(address l1) public view returns (bool) {
        return l1s.contains(l1);
    }

    /// @inheritdoc IL1Registry
    function getL1At(uint256 index) public view returns (address) {
        return l1s.at(index);
    }

    /// @inheritdoc IL1Registry
    function totalL1s() public view returns (uint256) {
        return l1s.length();
    }

    /// @inheritdoc IL1Registry
    function getAllL1s() public view returns (address[] memory) {
        return l1s.values();
    }

    /**
     * @dev Add an address as an L1.
     * @param l1 The address to add.
     */
    function _addL1(address l1) internal {
        l1s.add(l1);
    }
}
