// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IRegistry} from "../../interfaces/common/IRegistry.sol";
import {ILSTWrapper} from "../../interfaces/vault/ILSTWrapper.sol";

/**
 * @title LSTWrapperFactory
 * @notice Factory for permissionless deployment of LSTWrapper contracts from whitelisted implementations
 * @dev Follows VaultFactory pattern but uses TransparentUpgradeableProxy instead of MigratableEntityProxy
 */
contract LSTWrapperFactory is Ownable, IRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;

    EnumerableSet.AddressSet private _whitelistedImplementations;
    EnumerableSet.AddressSet private _entities;

    // Errors
    error LSTWrapperFactory__InvalidImplementation();
    error LSTWrapperFactory__AlreadyWhitelisted();
    error LSTWrapperFactory__InvalidVersion();
    error LSTWrapperFactory__AlreadyBlacklisted();
    error LSTWrapperFactory__VersionBlacklisted();

    /**
     * @notice Mapping of blacklisted versions
     */
    mapping(uint64 version => bool value) public blacklisted;

    /**
     * @notice Emitted when a new implementation is whitelisted
     * @param implementation address of the new implementation
     */
    event Whitelist(address indexed implementation);

    /**
     * @notice Emitted when a version is blacklisted
     * @param version version that was blacklisted
     */
    event Blacklist(uint64 indexed version);

    modifier checkVersion(uint64 version) {
        if (version == 0 || version > lastVersion()) {
            revert LSTWrapperFactory__InvalidVersion();
        }
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    /**
     * @notice Get the last available version
     * @return version of the last implementation
     */
    function lastVersion() public view returns (uint64) {
        return uint64(_whitelistedImplementations.length());
    }

    /**
     * @notice Get the implementation for a given version
     * @param version version to get the implementation for
     * @return address of the implementation
     */
    function implementation(uint64 version) public view checkVersion(version) returns (address) {
        unchecked {
            return _whitelistedImplementations.at(version - 1);
        }
    }

    /**
     * @notice Whitelist a new implementation for wrappers
     * @param implementation_ address of the new implementation
     * @dev Only owner can whitelist implementations
     */
    function whitelist(address implementation_) external onlyOwner {
        if (implementation_.code.length == 0) {
            revert LSTWrapperFactory__InvalidImplementation();
        }
        if (!_whitelistedImplementations.add(implementation_)) {
            revert LSTWrapperFactory__AlreadyWhitelisted();
        }

        emit Whitelist(implementation_);
    }

    /**
     * @notice Blacklist a version of wrappers
     * @param version version to blacklist
     */
    function blacklist(uint64 version) external onlyOwner checkVersion(version) {
        if (blacklisted[version]) {
            revert LSTWrapperFactory__AlreadyBlacklisted();
        }

        blacklisted[version] = true;

        emit Blacklist(version);
    }

    /**
     * @notice Create a new LSTWrapper from a whitelisted implementation
     * @param version implementation version to use
     * @param admin admin address for the wrapper (owner and ProxyAdmin)
     * @param vault VaultTokenized address to wrap
     * @param rewards Rewards contract address
     * @param name ERC20 name for the wrapper token
     * @param symbol ERC20 symbol for the wrapper token
     * @return entity_ address of the deployed wrapper
     * @dev Permissionless - anyone can deploy from whitelisted implementations
     */
    function create(
        uint64 version,
        address admin,
        address vault,
        address rewards,
        string memory name,
        string memory symbol
    ) external returns (address entity_) {
        // Ensure the version is not blacklisted
        if (blacklisted[version]) {
            revert LSTWrapperFactory__VersionBlacklisted();
        }

        // Prepare initialization data
        bytes memory initData = abi.encodeWithSelector(
            ILSTWrapper.initialize.selector,
            admin,
            vault,
            rewards,
            name,
            symbol
        );

        // Deploy proxy using CREATE2 for deterministic addresses
        entity_ = address(
            new TransparentUpgradeableProxy{
                salt: keccak256(abi.encode(totalEntities(), version, admin, vault, rewards, name, symbol))
            }(implementation(version), admin, initData)
        );

        _addEntity(entity_);
    }

    /**
     * @inheritdoc IRegistry
     */
    function isEntity(address entity_) public view returns (bool) {
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
    function entity(uint256 index) public view returns (address) {
        return _entities.at(index);
    }

    function _addEntity(address entity_) internal {
        _entities.add(entity_);

        emit AddEntity(entity_);
    }
}
