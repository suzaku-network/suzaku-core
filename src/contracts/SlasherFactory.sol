// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {IEntity} from "../interfaces/common/IEntity.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {ISlasherFactory} from "../interfaces/ISlasherFactory.sol";

contract SlasherFactory is ISlasherFactory, Ownable, ERC165 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Clones for address;
    using ERC165Checker for address;

    /**
     * @inheritdoc ISlasherFactory
     */
    mapping(uint64 => bool) public blacklisted;

    EnumerableSet.AddressSet private _whitelistedImplementations;
    EnumerableSet.AddressSet private _entities;

    modifier checkType(
        uint64 type_
    ) {
        if (type_ >= totalTypes()) {
            revert SlasherFactory__InvalidType();
        }
        _;
    }

    constructor(
        address owner_
    ) Ownable(owner_) {}

    /**
     * @inheritdoc ISlasherFactory
     */
    function totalTypes() public view returns (uint64) {
        return uint64(_whitelistedImplementations.length());
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function implementation(
        uint64 type_
    ) public view returns (address) {
        return _whitelistedImplementations.at(type_);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function whitelist(
        address implementation_
    ) external onlyOwner {
        // Check if the implementation supports the IEntity interface via ERC165
        if (!implementation_.supportsInterface(type(IEntity).interfaceId)) {
            revert SlasherFactory__InvalidImplementation();
        }

        if (IEntity(implementation_).FACTORY() != address(this) || IEntity(implementation_).TYPE() != totalTypes()) {
            revert SlasherFactory__InvalidImplementation();
        }
        if (!_whitelistedImplementations.add(implementation_)) {
            revert SlasherFactory__AlreadyWhitelisted();
        }

        emit Whitelist(implementation_);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function blacklist(
        uint64 type_
    ) external onlyOwner checkType(type_) {
        if (blacklisted[type_]) {
            revert SlasherFactory__AlreadyBlacklisted();
        }

        blacklisted[type_] = true;

        emit Blacklist(type_);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function create(uint64 type_, bytes calldata data) external returns (address entity_) {
        entity_ = implementation(type_).cloneDeterministic(keccak256(abi.encode(totalEntities(), type_, data)));

        _addSlasherEntity(entity_);

        IEntity(entity_).initialize(data);
    }

    function _addSlasherEntity(
        address entity_
    ) internal {
        _entities.add(entity_);

        emit AddEntity(entity_);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function entity(
        uint256 index
    ) public view returns (address) {
        return _entities.at(index);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function isEntity(
        address entity_
    ) public view returns (bool) {
        return _entities.contains(entity_);
    }

    /**
     * @inheritdoc ISlasherFactory
     */
    function totalEntities() public view returns (uint256) {
        return _entities.length();
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view override(ERC165, ISlasherFactory) returns (bool) {
        return interfaceId == type(ISlasherFactory).interfaceId || super.supportsInterface(interfaceId);
    }
}
