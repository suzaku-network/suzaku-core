// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract L1Registry is IL1Registry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private l1s;

    /// @notice The l1Middleware for each L1
    mapping(address => address) public l1Middleware;

    /// @notice The metadata URL for each L1
    mapping(address => string) public l1MetadataURL;

    /// @inheritdoc IL1Registry
    function registerL1(address validatorManager, address l1Middleware_, string calldata metadataURL) external {
        if (isRegistered(validatorManager)) {
            revert L1Registry__L1AlreadyRegistered();
        }

        // TODO: check that validatorManager is a valid ValidatorManager
        // TODO: check that msg.sender is a SecurityModule of the ValidatorManager
        // TODO: check that l1Middleware_ is a valid SecurityModule of the ValidatorManager

        l1s.add(validatorManager);
        l1Middleware[validatorManager] = l1Middleware_;
        l1MetadataURL[validatorManager] = metadataURL;

        emit RegisterL1(validatorManager);
        emit SetL1Middleware(validatorManager, l1Middleware_);
        emit SetMetadataURL(validatorManager, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function isRegistered(
        address l1
    ) public view returns (bool) {
        return l1s.contains(l1);
    }

    // @inheritdoc IL1Registry
    function isRegisteredWithMiddleware(address l1, address l1Middleware_) external view returns (bool) {
        isRegistered(l1);
        if (l1Middleware[l1] != l1Middleware_) {
            revert L1Registry__InvalidL1Middleware();
        }
        return l1s.contains(l1);
    }

    /// @inheritdoc IL1Registry
    function getL1At(
        uint256 index
    ) public view returns (address, address, string memory) {
        address l1 = l1s.at(index);
        return (l1, l1Middleware[l1], l1MetadataURL[l1]);
    }

    /// @inheritdoc IL1Registry
    function totalL1s() public view returns (uint256) {
        return l1s.length();
    }

    /// @inheritdoc IL1Registry
    function getAllL1s() public view returns (address[] memory, address[] memory, string[] memory) {
        address[] memory l1sList = l1s.values();
        address[] memory l1Middlewares = new address[](l1sList.length);
        string[] memory metadataURLs = new string[](l1sList.length);
        for (uint256 i = 0; i < l1sList.length; i++) {
            l1Middlewares[i] = l1Middleware[l1sList[i]];
            metadataURLs[i] = l1MetadataURL[l1sList[i]];
        }
        return (l1sList, l1Middlewares, metadataURLs);
    }

    /// @inheritdoc IL1Registry
    function setL1Middleware(address validatorManager, address l1Middleware_) external {
        if (!isRegistered(validatorManager)) {
            revert L1Registry__L1NotRegistered();
        }

        l1Middleware[validatorManager] = l1Middleware_;

        emit SetL1Middleware(validatorManager, l1Middleware_);
    }

    /// @inheritdoc IL1Registry
    function setMetadataURL(address validatorManager, string calldata metadataURL) external {
        if (!isRegistered(validatorManager)) {
            revert L1Registry__L1NotRegistered();
        }

        // TODO: check that msg.sender is a SecurityModule of the ValidatorManager

        l1MetadataURL[validatorManager] = metadataURL;

        emit SetMetadataURL(validatorManager, metadataURL);
    }
}
