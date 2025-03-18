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

    modifier onlyValidatorAndMiddlewareOwner(address validatorManager, address middleware) {
        // Ensure caller owns the validator manager
        address vmOwner = Ownable(validatorManager).owner();
        if (vmOwner != msg.sender) {
            revert L1Registry__NotValidatorManagerOwner(msg.sender, vmOwner);
        }

        // Ensure caller owns the middleware (if non-zero)
        if (middleware != address(0)) {
            address middlewareOwner = Ownable(middleware).owner();
            if (middlewareOwner != msg.sender) {
                revert L1Registry__NotMiddlewareOwner(msg.sender, middlewareOwner);
            }
        }

        _;
    }

    modifier isRegisteredL1(
        address validatorManager
    ) {
        if (!isRegistered(validatorManager)) {
            revert L1Registry__L1NotRegistered();
        }
        _;
    }

    modifier isZeroAddress(
        address validatorManager
    ) {
        if (validatorManager == address(0)) {
            revert L1Registry__InvalidValidatorManager(validatorManager);
        }
        _;
    }

    /// @inheritdoc IL1Registry
    function registerL1(
        address validatorManager,
        address l1Middleware_,
        string calldata metadataURL
    ) external isZeroAddress(validatorManager) onlyValidatorAndMiddlewareOwner(validatorManager, l1Middleware_) {
        if (isRegistered(validatorManager)) {
            revert L1Registry__L1AlreadyRegistered();
        }
        if (validatorManager == address(0)) {
            revert L1Registry__InvalidValidatorManager(validatorManager);
        }
        l1s.add(validatorManager);
        l1Middleware[validatorManager] = l1Middleware_;
        l1MetadataURL[validatorManager] = metadataURL;

        emit RegisterL1(validatorManager);
        emit SetL1Middleware(validatorManager, l1Middleware_);
        emit SetMetadataURL(validatorManager, metadataURL);
    }

    /// @inheritdoc IL1Registry
    function setL1Middleware(
        address validatorManager,
        address l1Middleware_
    ) external isRegisteredL1(validatorManager) onlyValidatorAndMiddlewareOwner(validatorManager, l1Middleware_) {
        l1Middleware[validatorManager] = l1Middleware_;

        emit SetL1Middleware(validatorManager, l1Middleware_);
    }

    /// @inheritdoc IL1Registry
    function setMetadataURL(
        address validatorManager,
        address l1Middleware_,
        string calldata metadataURL
    ) external isRegisteredL1(validatorManager) onlyValidatorAndMiddlewareOwner(validatorManager, l1Middleware_) {
        // TODO: check that msg.sender is a SecurityModule of the ValidatorManager

        l1MetadataURL[validatorManager] = metadataURL;

        emit SetMetadataURL(validatorManager, metadataURL);
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
