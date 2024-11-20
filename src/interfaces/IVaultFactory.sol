// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * @title IVaultFactory
 * @dev interface for the VaultFactory contract.
 */
interface IVaultFactory {
    error AlreadyBlacklisted();
    error AlreadyWhitelisted();
    error VersionBlacklisted();
    error InvalidImplementation();
    error InvalidVersion();
    error NotOwner();
    error OldVersion();
    error EntityNotExist();

    /**
     * @notice Emitted when a new entity is added to the registry.
     * @param entity The address of the newly added entity.
     */
    event AddEntity(address indexed entity);

    /**
     * @notice Emitted when a new implementation is whitelisted.
     * @param implementation The address of the whitelisted implementation.
     */
    event Whitelist(address indexed implementation);

    /**
     * @notice Emitted when a version is blacklisted.
     * @param version The version number that was blacklisted.
     */
    event Blacklist(uint64 indexed version);

    /**
     * @notice Emitted when an entity is migrated to a new version.
     * @param entity The address of the entity being migrated.
     * @param newVersion The new version number to which the entity was migrated.
     */
    event Migrate(address indexed entity, uint64 newVersion);

    /**
     * @notice Checks if a given address is a registered entity.
     * @param account The address to check.
     * @return True if the address is a registered entity, false otherwise.
     */
    function isEntity(address account) external view returns (bool);

    /**
     * @notice Retrieves the total number of registered entities.
     * @return The total count of entities.
     */
    function totalEntities() external view returns (uint256);

    /**
     * @notice Retrieves the address of an entity by its index.
     * @param index The index of the entity.
     * @return The address of the entity at the specified index.
     */
    function entity(uint256 index) external view returns (address);

    /**
     * @notice Retrieves the latest available version.
     * @return The version number of the latest implementation.
     * @dev Returns zero if no implementations are whitelisted.
     */
    function lastVersion() external view returns (uint64);

    /**
     * @notice Retrieves the implementation address for a specified version.
     * @param version The version number to query.
     * @return The address of the implementation corresponding to the given version.
     * @dev Reverts if the version is invalid.
     */
    function implementation(uint64 version) external view returns (address);

    /**
     * @notice Checks if a specific version is blacklisted.
     * @param version The version number to check.
     * @return True if the version is blacklisted, false otherwise.
     */
    function blacklisted(uint64 version) external view returns (bool);

    /**
     * @notice Adds a new implementation to the whitelist.
     * @param implementation The address of the implementation to whitelist.
     * @dev Only the contract owner can call this function.
     */
    function whitelist(address implementation) external;

    /**
     * @notice Adds a version to the blacklist.
     * @param version The version number to blacklist.
     * @dev Only the contract owner can call this function.
     *      The blacklisted version remains deployable.
     */
    function blacklist(uint64 version) external;

    /**
     * @notice Creates a new entity with the specified version and owner.
     * @param version The version number to use for the new entity.
     * @param owner The initial owner of the new entity.
     * @param data The initialization data for the entity.
     * @param delegatorFactory The address of the Delegator Factory.
     * @param slasherFactory The address of the Slasher Factory.
     * @return The address of the newly created entity.
     * @dev Utilizes CREATE2 with a salt derived from the provided parameters.
     */
    function create(
        uint64 version,
        address owner,
        bytes calldata data,
        address delegatorFactory,
        address slasherFactory        
    ) external returns (address);

    /**
     * @notice Migrates an existing entity to a new version.
     * @param entity The address of the entity to migrate.
     * @param newVersion The new version number to migrate to.
     * @param data The data required for reinitializing the entity post-migration.
     * @dev Only the owner of the entity can invoke this function.
     */
    function migrate(
        address entity,
        uint64 newVersion,
        bytes calldata data
    ) external;
}
