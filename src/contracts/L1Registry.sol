// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IL1Registry} from "../interfaces/IL1Registry.sol";
import {IAvalancheL1Middleware} from "../interfaces/middleware/IAvalancheL1Middleware.sol";

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract L1Registry is IL1Registry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private l1s;

    /// @notice The l1Middleware for each L1
    mapping(address => address) public l1Middleware;

    /// @notice The metadata URL for each L1
    mapping(address => string) public l1MetadataURL;

    modifier onlyValidatorManagerOwner(
        address l1
    ) {
        // Ensure caller owns the validator manager
        address vmOwner = Ownable(l1).owner();
        if (vmOwner != msg.sender) {
            revert L1Registry__NotValidatorManagerOwner(msg.sender, vmOwner);
        }
        _;
    }

    modifier isRegisteredL1(
        address l1
    ) {
        if (!isRegistered(l1)) {
            revert L1Registry__L1NotRegistered();
        }
        _;
    }

    modifier isZeroAddress(
        address l1
    ) {
        if (l1 == address(0)) {
            revert L1Registry__InvalidValidatorManager(l1);
        }
        _;
    }

    /// @inheritdoc IL1Registry
    function registerL1(
        address l1,
        address l1Middleware_,
        string calldata metadataURL
    ) external isZeroAddress(l1) onlyValidatorManagerOwner(l1) {
        if (isRegistered(l1)) {
            revert L1Registry__L1AlreadyRegistered();
        }
        if (l1 == address(0)) {
            revert L1Registry__InvalidValidatorManager(l1);
        }
        l1s.add(l1);
        l1Middleware[l1] = l1Middleware_;
        l1MetadataURL[l1] = metadataURL;

        emit RegisterL1(l1);
        emit SetL1Middleware(l1, l1Middleware_);
        emit SetMetadataURL(l1, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function setL1Middleware(
        address l1,
        address l1Middleware_
    ) external isZeroAddress(l1Middleware_) isRegisteredL1(l1) onlyValidatorManagerOwner(l1) {
        l1Middleware[l1] = l1Middleware_;

        emit SetL1Middleware(l1, l1Middleware_);
    }

    /// @inheritdoc IL1Registry
    function setMetadataURL(
        address l1,
        string calldata metadataURL
    ) external isRegisteredL1(l1) onlyValidatorManagerOwner(l1) {
        // TODO: check that msg.sender is a SecurityModule of the ValidatorManager

        l1MetadataURL[l1] = metadataURL;

        emit SetMetadataURL(l1, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function isRegistered(
        address l1
    ) public view returns (bool) {
        return l1s.contains(l1);
    }

    // @inheritdoc IL1Registry
    function isRegisteredWithMiddleware(address l1, address vaultManager_) external view returns (bool) {
        if (!isRegistered(l1)) {
            return false;
        }

        address middleware = l1Middleware[l1];
        if (middleware == address(0)) {
            return false;
        }

        address actualVaultManager = IAvalancheL1Middleware(middleware).getVaultManager();

        if (actualVaultManager != vaultManager_) {
            revert L1Registry__InvalidL1Middleware();
        }

        return true;
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
}
