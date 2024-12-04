// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title IDelegatorFactory
 * @dev Combined interface integrating IDelegatorFactory, IFactory, IRegistry, and IERC165.
 */
interface IDelegatorFactory is IERC165 {
    error DelegatorFactory__EntityNotExist();
    error DelegatorFactory__AlreadyBlacklisted();
    error DelegatorFactory__AlreadyWhitelisted();
    error DelegatorFactory__InvalidImplementation();
    error DelegatorFactory__InvalidType();

    /**
     * @notice Emitted when an entity is added.
     * @param entity address of the added entity
     */
    event AddEntity(address indexed entity);

    /**
     * @notice Emitted when a new type is whitelisted.
     * @param implementation address of the new implementation
     */
    event Whitelist(address indexed implementation);

    /**
     * @notice Emitted when a type is blacklisted (e.g., in case of invalid implementation).
     * @param type_ type that was blacklisted
     * @dev The given type is still deployable.
     */
    event Blacklist(uint64 indexed type_);

    /**
     * @notice Query if a contract implements an interface
     * @param interfaceId The interface identifier, as specified in ERC-165
     * @return `true` if the contract implements `interfaceId` and
     *  `interfaceId` is not 0xffffffff, `false` otherwise
     */
    function supportsInterface(bytes4 interfaceId) external view returns (bool);

    /**
     * @notice Get if a given address is an entity.
     * @param account address to check
     * @return if the given address is an entity
     */
    function isEntity(address account) external view returns (bool);

    /**
     * @notice Get a total number of entities.
     * @return total number of entities added
     */
    function totalEntities() external view returns (uint256);

    /**
     * @notice Get an entity given its index.
     * @param index index of the entity to get
     * @return address of the entity
     */
    function entity(uint256 index) external view returns (address);

    /**
     * @notice Get the total number of whitelisted types.
     * @return total number of types
     */
    function totalTypes() external view returns (uint64);

    /**
     * @notice Get the implementation for a given type.
     * @param type_ position to get the implementation at
     * @return address of the implementation
     */
    function implementation(uint64 type_) external view returns (address);

    /**
     * @notice Get if a type is blacklisted (e.g., in case of invalid implementation).
     * @param type_ type to check
     * @return whether the type is blacklisted
     * @dev The given type is still deployable.
     */
    function blacklisted(uint64 type_) external view returns (bool);

    /**
     * @notice Whitelist a new type of entity.
     * @param implementation address of the new implementation
     */
    function whitelist(address implementation) external;

    /**
     * @notice Blacklist a type of entity.
     * @param type_ type to blacklist
     * @dev The given type will still be deployable.
     */
    function blacklist(uint64 type_) external;

    /**
     * @notice Create a new entity at the factory.
     * @param type_ type's implementation to use
     * @param data initial data for the entity creation
     * @return address of the entity
     * @dev CREATE2 salt is constructed from the given parameters.
     */
    function create(uint64 type_, bytes calldata data) external returns (address);
}
