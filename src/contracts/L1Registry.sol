// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

// Compatible with OpenZeppelin Contracts ^5.0.0

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract L1Registry is IL1Registry {
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    EnumerableSet.AddressSet private l1s;

    /// @notice The l1Middleware for each L1
    mapping(address => address) public l1Middleware;

    /// @notice The metadata URL for each L1
    mapping(address => string) public l1MetadataURL;

    struct Subnetwork {
        address validatorManager;
        uint256 identifier;
    }

    /// @notice Set of all registered subnetwork IDs
    EnumerableSet.Bytes32Set private subnetworkIdentifiers;

    /// @notice Mapping of subnetwork ID to its details
    mapping(bytes32 => Subnetwork) public subnetworks;

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
    function isRegistered(address l1) public view returns (bool) {
        return l1s.contains(l1);
    }

    /// @inheritdoc IL1Registry
    function getL1At(uint256 index) public view returns (address, address, string memory) {
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

    /// @inheritdoc IL1Registry
    function registerSubnetwork(address validatorManager, uint256 identifier) external returns (bytes32 subnetwork) {

        if (!isRegistered(validatorManager)) {
            revert L1Registry__L1NotRegistered();
        }

        // Generate the unique identifier for the subnetwork
        subnetwork = keccak256(abi.encodePacked(validatorManager, identifier));

        if (isRegisteredSubnetwork(subnetwork)) {
            revert L1Registry__SubnetworkAlreadyRegistered(subnetwork);
        }

        subnetworks[subnetwork] = Subnetwork({ validatorManager: validatorManager, identifier: identifier });

        subnetworkIdentifiers.add(subnetwork);

        emit RegisterSubnetwork(validatorManager, identifier);
    }

    /// @inheritdoc IL1Registry
    function isRegisteredSubnetwork(bytes32 subnetwork) public view returns (bool exists) {
        return subnetworkIdentifiers.contains(subnetwork);
    }

    /// @inheritdoc IL1Registry
    function getSubnetwork(bytes32 subnetwork) external view returns (address validatorManager, uint256 identifier) {
        if (!isRegisteredSubnetwork(subnetwork)) {
            revert L1Registry__SubnetworkNotRegistered(subnetwork);
        }

        return (subnetworks[subnetwork].validatorManager, subnetworks[subnetwork].identifier);
    }

    /// @inheritdoc IL1Registry
    function getSubnetworkByParams(address validatorManager, uint256 identifier) public view returns (bytes32 subnetwork) {
        subnetwork = keccak256(abi.encodePacked(validatorManager, identifier));

        if (!isRegisteredSubnetwork(subnetwork)) {
            revert L1Registry__SubnetworkNotRegistered(subnetwork);
        }
        return (subnetwork);
    }

    /// @inheritdoc IL1Registry
    function getAllSubnetworks() external view returns (bytes32[] memory _subnetworks, address[] memory _validatorManagers, uint256[] memory _identifiers) {
        uint256 count = subnetworkIdentifiers.length();
        _subnetworks = new bytes32[](count);
        _validatorManagers = new address[](count);
        _identifiers = new uint256[](count);

        for (uint256 i = 0; i < count; i++) {
            bytes32 subnetwork = subnetworkIdentifiers.at(i);

            _subnetworks[i] = subnetwork;
            _validatorManagers[i] = subnetworks[subnetwork].validatorManager;
            _identifiers[i] = subnetworks[subnetwork].identifier;
        }
    }

    function removeSubnetwork(bytes32 subnetwork) external {
        if (isRegisteredSubnetwork(subnetwork)) {
            revert L1Registry__SubnetworkAlreadyRegistered(subnetwork);
        }

        subnetworkIdentifiers.remove(subnetwork);
        delete subnetworks[subnetwork];
    }
}

