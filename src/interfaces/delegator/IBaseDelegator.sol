// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity ^0.8.0;

interface IBaseDelegator {
    error BaseDelegator__AlreadySet();
    error BaseDelegator__InsufficientHookGas();
    error BaseDelegator__NotL1();
    error BaseDelegator__NotSlasher();
    error BaseDelegator__NotVault();
    error BaseDelegator__NotInitialized();
    error BaseDelegator__ZeroAddress(string name);
    error BaseDelegator__NotAuthorizedMiddleware();
    /**
     * @notice Base parameters needed for delegators' deployment.
     * @param defaultAdminRoleHolder address of the initial DEFAULT_ADMIN_ROLE holder
     * @param hook address of the hook contract
     * @param hookSetRoleHolder address of the initial HOOK_SET_ROLE holder
     */
    struct BaseParams {
        address defaultAdminRoleHolder;
        address hook;
        address hookSetRoleHolder;
    }

    /**
     * @notice Base hints for a stake.
     * @param operatorVaultOptInHint hint for the operator-vault opt-in
     * @param operatorL1OptInHint hint for the operator-l1 opt-in
     */
    struct StakeBaseHints {
        bytes operatorVaultOptInHint;
        bytes operatorL1OptInHint;
    }

    /**
     * @notice Emitted when a asset class maximum limit is set.
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @param amount new maximum asset class limit (how much stake the asset class is ready to get)
     */
    event SetMaxL1Limit(address indexed l1, uint96 indexed assetClass, uint256 amount);

    /**
     * @notice Emitted when a slash happens.
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @param operator address of the operator
     * @param amount amount of the collateral to be slashed
     * @param captureTimestamp time point when the stake was captured
     */
    event OnSlash(
        address indexed l1, uint96 indexed assetClass, address indexed operator, uint256 amount, uint48 captureTimestamp
    );

    /**
     * @notice Emitted when a hook is set.
     * @param hook address of the hook
     */
    event SetHook(address indexed hook);

    /**
     * @notice Get a version of the delegator (different versions mean different interfaces).
     * @return version of the delegator
     * @dev Must return 1 for this one.
     */

    /**
     * @notice Get the factory's address.
     * @return address of the factory
     */
    function FACTORY() external view returns (address);

    /**
     * @notice Get the entity's type.
     * @return type of the entity
     */
    function TYPE() external view returns (uint64);

    /**
     * @notice Initialize this entity contract by using a given data.
     * @param data some data to use
     */
    function initialize(
        bytes calldata data
    ) external;

    function VERSION() external view returns (uint64);

    /**
     * @notice Get the l1 registry's address.
     * @return address of the l1 registry
     */
    function L1_REGISTRY() external view returns (address);

    /**
     * @notice Get the vault factory's address.
     * @return address of the vault factory
     */
    function VAULT_FACTORY() external view returns (address);

    /**
     * @notice Get the operator-vault opt-in service's address.
     * @return address of the operator-vault opt-in service
     */
    function OPERATOR_VAULT_OPT_IN_SERVICE() external view returns (address);

    /**
     * @notice Get the operator-l1 opt-in service's address.
     * @return address of the operator-l1 opt-in service
     */
    function OPERATOR_L1_OPT_IN_SERVICE() external view returns (address);

    /**
     * @notice Get a gas limit for the hook.
     * @return value of the hook gas limit
     */
    function HOOK_GAS_LIMIT() external view returns (uint256);

    /**
     * @notice Get a reserve gas between the gas limit check and the hook's execution.
     * @return value of the reserve gas
     */
    function HOOK_RESERVE() external view returns (uint256);

    /**
     * @notice Get a hook setter's role.
     * @return assetClass of the hook setter role
     */
    function HOOK_SET_ROLE() external view returns (bytes32);

    /**
     * @notice Get the vault's address.
     * @return address of the vault
     */
    function vault() external view returns (address);

    /**
     * @notice Get the hook's address.
     * @return address of the hook
     * @dev The hook can have arbitrary logic under certain functions, however, it doesn't affect the stake guarantees.
     */
    function hook() external view returns (address);

    /**
     * @notice Get a particular asset class maximum limit
     *         (meaning the asset class is not ready to get more as a stake).
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @return maximum limit of the asset class
     */
    function maxL1Limit(address l1, uint96 assetClass) external view returns (uint256);

    /**
     * @notice Get a stake that a given asset class could be able to slash for a certain operator at a given timestamp
     *         until the end of the consequent epoch using hints (if no cross-slashing and no slashings by the asset class).
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @param operator address of the operator
     * @param timestamp time point to capture the stake at
     * @param hints hints for the checkpoints' indexes
     * @return slashable stake at the given timestamp until the end of the consequent epoch
     * @dev Warning: it is not safe to use timestamp >= current one for the stake capturing, as it can change later.
     */
    function stakeAt(
        address l1,
        uint96 assetClass,
        address operator,
        uint48 timestamp,
        bytes memory hints
    ) external view returns (uint256);

    /**
     * @notice Get a stake that a given asset class will be able to slash
     *         for a certain operator until the end of the next epoch (if no cross-slashing and no slashings by the asset class).
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @param operator address of the operator
     * @return slashable stake until the end of the next epoch
     * @dev Warning: this function is not safe to use for stake capturing, as it can change by the end of the block.
     */
    function stake(address l1, uint96 assetClass, address operator) external view returns (uint256);

    /**
     * @notice Set a maximum limit for a asset class (how much stake the asset class is ready to get).
     * assetClass assetClass of the asset class
     * @param l1 address of the l1
     * @param amount new maximum asset class limit
     * @dev Only a l1 can call this function.
     */
    function setMaxL1Limit(address l1, uint96 assetClass, uint256 amount) external;

    /**
     * @notice Set a new hook.
     * @param hook address of the hook
     * @dev Only a HOOK_SET_ROLE holder can call this function.
     *      The hook can have arbitrary logic under certain functions, however, it doesn't affect the stake guarantees.
     */
    function setHook(
        address hook
    ) external;

    /**
     * @notice Called when a slash happens.
     * @param l1 address of the l1.
     * @param assetClass the uint96 assetClass.
     * @param operator address of the operator
     * @param amount amount of the collateral slashed
     * @param captureTimestamp time point when the stake was captured
     * @param data some additional data
     * @dev Only the vault's slasher can call this function.
     */
    function onSlash(
        address l1,
        uint96 assetClass,
        address operator,
        uint256 amount,
        uint48 captureTimestamp,
        bytes calldata data
    ) external;
}
