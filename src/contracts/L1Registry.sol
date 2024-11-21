// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract L1Registry is IL1Registry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private l1s;

    /// @notice The metadata URL for each L1
    mapping(address => string) public l1MetadataURL;

    /// @inheritdoc IL1Registry
    function registerL1(
        address ACP99Manager,
        string memory metadataURL
    ) external {
        if (isRegistered(msg.sender)) {
            revert L1Registry__L1AlreadyRegistered();
        }

        // TODO: check if ACP99Manager is a valid ACP99Manager

        l1s.add(msg.sender);
        l1MetadataURL[msg.sender] = metadataURL;

        emit RegisterL1(msg.sender, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function isRegistered(address l1) public view returns (bool) {
        return l1s.contains(l1);
    }

    /// @inheritdoc IL1Registry
    function getL1At(
        uint256 index
    ) public view returns (address, string memory) {
        address l1 = l1s.at(index);
        return (l1, l1MetadataURL[l1]);
    }

    /// @inheritdoc IL1Registry
    function totalL1s() public view returns (uint256) {
        return l1s.length();
    }

    /// @inheritdoc IL1Registry
    function getAllL1s()
        public
        view
        returns (address[] memory, string[] memory)
    {
        address[] memory l1sList = l1s.values();
        string[] memory metadataURLs = new string[](l1sList.length);
        for (uint256 i = 0; i < l1sList.length; i++) {
            metadataURLs[i] = l1MetadataURL[l1sList[i]];
        }
        return (l1sList, metadataURLs);
    }
}
