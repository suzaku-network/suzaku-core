// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {MigratableEntityProxy} from "./common/MigratableEntityProxy.sol";

import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IMigratablesFactory} from "../interfaces/common/IMigratablesFactory.sol";
import {IRegistry} from "../interfaces/common/IRegistry.sol";
import {IVaultTokenized} from "../interfaces/vault/IVaultTokenized.sol";
import {IMigratableEntityProxy} from "../interfaces/common/IMigratableEntityProxy.sol";

import {ISlasherFactory} from "../interfaces/ISlasherFactory.sol";
import {IDelegatorFactory} from "../interfaces/IDelegatorFactory.sol";

contract VaultFactory is Ownable, IMigratablesFactory {
    using EnumerableSet for EnumerableSet.AddressSet;
    using Address for address;
    using ERC165Checker for address;

    EnumerableSet.AddressSet private _whitelistedImplementations;
    EnumerableSet.AddressSet private _entities;

    bytes4 private constant INTERFACE_ID_ISLASHER_FACTORY = type(ISlasherFactory).interfaceId;
    bytes4 private constant INTERFACE_ID_IDELEGATOR_FACTORY = type(IDelegatorFactory).interfaceId;

    /**
     * @inheritdoc IMigratablesFactory
     */
    mapping(uint64 version => bool value) public blacklisted;

    modifier checkEntity(
        address account
    ) {
        _checkEntity(account);
        _;
    }

    modifier checkVersion(
        uint64 version
    ) {
        if (version == 0 || version > lastVersion()) {
            revert MigratableFactory__InvalidVersion();
        }
        _;
    }

    constructor(
        address owner_
    ) Ownable(owner_) {}

    /**
     * @inheritdoc IMigratablesFactory
     */
    function lastVersion() public view returns (uint64) {
        return uint64(_whitelistedImplementations.length());
    }

    /**
     * @inheritdoc IMigratablesFactory
     */
    function implementation(
        uint64 version
    ) public view checkVersion(version) returns (address) {
        unchecked {
            return _whitelistedImplementations.at(version - 1);
        }
    }

    /**
     * @inheritdoc IMigratablesFactory
     */
    function whitelist(
        address implementation_
    ) external onlyOwner {
        if (IVaultTokenized(implementation_).FACTORY() != address(this)) {
            revert MigratableFactory__InvalidImplementation();
        }
        if (!_whitelistedImplementations.add(implementation_)) {
            revert MigratableFactory__AlreadyWhitelisted();
        }

        emit Whitelist(implementation_);
    }

    /**
     * @inheritdoc IMigratablesFactory
     */
    function blacklist(
        uint64 version
    ) external onlyOwner checkVersion(version) {
        if (blacklisted[version]) {
            revert MigratableFactory__AlreadyBlacklisted();
        }

        blacklisted[version] = true;

        emit Blacklist(version);
    }

    /**
     * @inheritdoc IMigratablesFactory
     */
    function create(
        uint64 version,
        address owner_,
        bytes calldata data,
        address delegatorFactory,
        address slasherFactory
    ) external returns (address entity_) {
        // Ensure the version is not blacklisted
        if (blacklisted[version]) {
            revert MigratableFactory__VersionBlacklisted();
        }

        // Validate factory addresses using ERC165.
        if (!delegatorFactory.supportsInterface(INTERFACE_ID_IDELEGATOR_FACTORY)) {
            revert MigratableFactory__InvalidImplementation();
        }
        if (!slasherFactory.supportsInterface(INTERFACE_ID_ISLASHER_FACTORY)) {
            revert MigratableFactory__InvalidImplementation();
        }

        // Deploy a new MigratableEntityProxy using CREATE2 for deterministic address
        entity_ = address(
            new MigratableEntityProxy{
                salt: keccak256(abi.encode(totalEntities(), version, owner_, data, delegatorFactory, slasherFactory))
            }(
                implementation(version),
                abi.encodeCall(IVaultTokenized.initialize, (version, owner_, data, delegatorFactory, slasherFactory))
            )
        );

        _addEntity(entity_);
    }

    /**
     * @inheritdoc IMigratablesFactory
     */
    function migrate(address entity_, uint64 newVersion, bytes calldata data) external checkEntity(entity_) {
        if (msg.sender != Ownable(entity_).owner()) {
            revert MigratableFactory__NotOwner();
        }

        if (newVersion <= IVaultTokenized(entity_).version()) {
            revert MigratableFactory__OldVersion();
        }

        if (blacklisted[newVersion]) {
            revert MigratableFactory__VersionBlacklisted();
        }

        IMigratableEntityProxy(entity_).upgradeToAndCall(
            implementation(newVersion), abi.encodeCall(IVaultTokenized.migrate, (newVersion, data))
        );

        emit Migrate(entity_, newVersion);
    }

    /**
     * @inheritdoc IRegistry
     */
    function isEntity(
        address entity_
    ) public view returns (bool) {
        return _entities.contains(entity_);
    }

    /**
     * @inheritdoc IRegistry
     */
    function totalEntities() public view returns (uint256) {
        return _entities.length();
    }

    /**
     * @inheritdoc IRegistry
     */
    function entity(
        uint256 index
    ) public view returns (address) {
        return _entities.at(index);
    }

    function _addEntity(
        address entity_
    ) internal {
        _entities.add(entity_);

        emit AddEntity(entity_);
    }

    function _checkEntity(
        address account
    ) internal view {
        if (!isEntity(account)) {
            revert EntityNotExist();
        }
    }
}
