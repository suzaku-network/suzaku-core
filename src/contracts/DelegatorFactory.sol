// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.25;

import { IEntity } from "../interfaces/common/IEntity.sol";
import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";
import { EnumerableSet } from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ERC165Checker } from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import { ERC165 } from "@openzeppelin/contracts/utils/introspection/ERC165.sol";


import { IDelegatorFactory } from "../interfaces/IDelegatorFactory.sol";

contract DelegatorFactory is IDelegatorFactory, Ownable, ERC165 {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Clones for address;
    using ERC165Checker for address;

    /**
     * @inheritdoc IDelegatorFactory
     */
    mapping(uint64 => bool) public blacklisted;

    EnumerableSet.AddressSet private _whitelistedImplementations;
    EnumerableSet.AddressSet private _entities;
    
    modifier checkType(uint64 type_) {
        if (type_ >= totalTypes()) {
            revert DelegatorFactory__InvalidType();
        }
        _;
    }

    constructor(
        address owner_
    ) Ownable(owner_) {}

    /**
     * @inheritdoc IDelegatorFactory
     */
    function totalTypes() public view returns (uint64) {
        return uint64(_whitelistedImplementations.length());
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function implementation(uint64 type_) public view returns (address) {
        return _whitelistedImplementations.at(type_);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function whitelist(address implementation_) external onlyOwner {
        // Check if the implementation supports the IEntity interface via ERC165
        if (!implementation_.supportsInterface(type(IEntity).interfaceId)) {
            revert DelegatorFactory__InvalidImplementation();
        }

        if (IEntity(implementation_).FACTORY() != address(this) || IEntity(implementation_).TYPE() != totalTypes()) {
            revert DelegatorFactory__InvalidImplementation();
        }
        if (!_whitelistedImplementations.add(implementation_)) {
            revert DelegatorFactory__AlreadyWhitelisted();
        }

        emit Whitelist(implementation_);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function blacklist(uint64 type_) external onlyOwner checkType(type_) {
        if (blacklisted[type_]) {
            revert DelegatorFactory__AlreadyBlacklisted();
        }

        blacklisted[type_] = true;

        emit Blacklist(type_);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function create(uint64 type_, bytes calldata data) external returns (address entity_) {
        entity_ = implementation(type_).cloneDeterministic(keccak256(abi.encode(totalEntities(), type_, data)));

        _addDelegatorEntity(entity_);

        IEntity(entity_).initialize(data);
    }

    function _addDelegatorEntity(
        address entity_
    ) internal {
        _entities.add(entity_);

        emit AddEntity(entity_);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function entity(
        uint256 index
    ) public view returns (address) {
        return _entities.at(index);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function isEntity(
        address entity_
    ) public view returns (bool) {
        return _entities.contains(entity_);
    }

    /**
     * @inheritdoc IDelegatorFactory
     */
    function totalEntities() public view returns (uint256) {
        return _entities.length();
    }

    function _checkEntity(
        address account
    ) internal view {
        if (!isEntity(account)) {
            revert DelegatorFactory__EntityNotExist();
        }
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC165, IDelegatorFactory) returns (bool) {
        return interfaceId == type(IDelegatorFactory).interfaceId || super.supportsInterface(interfaceId);
    }
}
