// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {
    IValidatorManager,
    Validator,
    ValidatorStatus,
    ValidatorRegistrationInput,
    PChainOwner
} from "@avalabs/teleporter/validator-manager/interfaces/IValidatorManager.sol";

/**
 * @title IAvalancheL1Middleware
 * @notice Manages operator registration, asset classes, stake accounting, and slashing for Avalanche L1
 */
interface IAvalancheL1Middleware {
    // Errors
    error AvalancheL1Middleware__ActiveSecondaryAssetCLass(uint256 assetClassId);
    error AvalancheL1Middleware__AssetClassNotActive(uint256 assetClassId);
    error AvalancheL1Middleware__AssetStillInUse(uint256 assetClassId);
    error AvalancheL1Middleware__AlreadyRebalanced(address operator, uint48 epoch);
    error AvalancheL1Middleware__WeightUpdateNotPending(bytes32 validationId);
    error AvalancheL1Middleware__CollateralNotInAssetClass(address collateral, uint96 assetClassId);
    error AvalancheL1Middleware__EpochError(uint48 epochStartTs);
    error AvalancheL1Middleware__MaxL1LimitZero();
    error AvalancheL1Middleware__NoSlasher();
    error AvalancheL1Middleware__NotEnoughFreeStakeSecondaryAssetClasses();
    error AvalancheL1Middleware__NodeNotActive();
    error AvalancheL1Middleware__NotEnoughFreeStake(uint256 newStake);
    error AvalancheL1Middleware__StakeTooHigh(uint256 newStake, uint256 maxStake);
    error AvalancheL1Middleware__StakeTooLow(uint256 newStake, uint256 minStake);
    error AvalancheL1Middleware__OperatorGracePeriodNotPassed(uint48 disabledTime, uint48 slashingWindow);
    error AvalancheL1Middleware__OperatorAlreadyRegistered(address operator);
    error AvalancheL1Middleware__OperatorNotOptedIn(address operator, address l1ValidatorManager);
    error AvalancheL1Middleware__OperatorNotRegistered(address operator);
    error AvalancheL1Middleware__SlashingWindowTooShort(uint48 slashingWindow, uint48 epochDuration);
    error AvalancheL1Middleware__TooBigSlashAmount();
    error AvalancheL1Middleware__NodeNotFound(bytes32 nodeId);
    error AvalancheL1Middleware__SecurityModuleCapacityNotEnough(uint256 securityModuleCapacity, uint256 minStake);
    error AvalancheL1Middleware__WeightUpdatePending(bytes32 validationID);
    error AvalancheL1Middleware__NodeStateNotUpdated(bytes32 validationID);
    error AvalancheL1Middleware__NotEpochUpdatePeriod(uint48 timeNow, uint48 epochUpdatePeriod);
    error AvalancheL1Middleware__NotImplemented();
    error AvalancheL1Middleware__NodePendingRemoval(bytes32 nodeId);
    error AvalancheL1Middleware__NodePendingUpdate(bytes32 nodeId);
    // Events
    /**
     * @notice Emitted when a node is added
     * @param operator The operator who added the node
     * @param nodeId The ID of the node
     * @param stake The stake assigned to the node
     * @param validationID The validation identifier from BalancerValidatorManager
     */
    event NodeAdded(address indexed operator, bytes32 indexed nodeId, uint256 stake, bytes32 indexed validationID);

    /**
     * @notice Emitted when a node is removed
     * @param operator The operator who removed the node
     * @param nodeId The ID of the node
     * @param validationID The validation identifier from BalancerValidatorManager
     */
    event NodeRemoved(address indexed operator, bytes32 indexed nodeId, bytes32 indexed validationID);

    /**
     * @notice Emitted when a single node's stake is updated
     * @param operator The operator who owns the node
     * @param nodeId The ID of the node
     * @param newStake The new stake of the node
     * @param validationID The validation identifier from BalancerValidatorManager
     */
    event NodeStakeUpdated(
        address indexed operator, bytes32 indexed nodeId, uint256 newStake, bytes32 indexed validationID
    );

    /**
     * @notice Emitted when the operator has leftover stake after rebalancing
     * @param operator The operator who has leftover stake
     * @param leftoverStake The amount of leftover stake
     */
    event OperatorHasLeftoverStake(address indexed operator, uint256 leftoverStake);

    /**
     * @notice Emitted when all node stakes are updated for an operator
     * @param operator The operator
     * @param newStake The total new stake for the operator
     */
    event AllNodeStakesUpdated(address indexed operator, uint256 newStake);

    /**
     * @notice Emitted when the Vault Manager is updated
     * @param oldVaultManager The old Vault Manager address
     * @param newVaultManager The new Vault Manager address
     */
    event VaultManagerUpdated(address indexed oldVaultManager, address indexed newVaultManager);

    /**
     * @dev Simple struct to return operator stake and key.
     */
    struct OperatorData {
        uint256 stake;
        bytes32 key;
    }
    // External functions
    /**
     * @notice Activates a secondary asset class
     * @param assetClassId The asset class ID to activate
     */

    function activateSecondaryAssetClass(
        uint256 assetClassId
    ) external;

    /**
     * @notice Deactivates a secondary asset class
     * @param assetClassId The asset class ID to deactivate
     */
    function deactivateSecondaryAssetClass(
        uint256 assetClassId
    ) external;

    /**
     * @notice Registers a new operator and enables it
     * @param operator The operator address
     */
    function registerOperator(
        address operator
    ) external;

    /**
     * @notice Disables an operator
     * @param operator The operator address
     */
    function disableOperator(
        address operator
    ) external;

    /**
     * @notice Enables an operator
     * @param operator The operator address
     */
    function enableOperator(
        address operator
    ) external;

    /**
     * @notice Removes an operator if grace period has passed
     * @param operator The operator address
     */
    function removeOperator(
        address operator
    ) external;

    /**
     * @notice Add a new node => create a new validator.
     * Check the new node stake also ensure security module capacity.
     * @param nodeId The node ID
     * @param blsKey The BLS key
     * @param registrationExpiry The Unix timestamp after which the reigistration is no longer valid on the P-Chain
     * @param remainingBalanceOwner The owner of a validator's remaining balance
     * @param disableOwner The owner of a validator's disable owner on the P-Chain
     * @param stakeAmount The initial stake of the node to be added(optional)
     */
    function addNode(
        bytes32 nodeId,
        bytes calldata blsKey,
        uint64 registrationExpiry,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner,
        uint256 stakeAmount
    ) external;

    /**
     * @notice Remove a node => remove a validator.
     * @param nodeId The node ID
     */
    function removeNode(
        bytes32 nodeId
    ) external;

    /**
     * @notice Rebalance node stakes once per epoch for an operator.
     * @param operator The operator address
     * @param limitStake The maximum stake adjustment (add or remove) allowed per node per call.
     */
    function forceUpdateNodes(address operator, uint256 limitStake) external;

    /**
     * @notice Update the stake of a validator.
     * @param nodeId The node ID.
     * @param stakeAmount The new stake.
     */
    function initializeValidatorStakeUpdate(bytes32 nodeId, uint256 stakeAmount) external;

    /**
     * @notice Finalize a pending validator registration
     * @param operator The operator address
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeValidatorRegistration(address operator, bytes32 nodeId, uint32 messageIndex) external;

    /**
     * @notice Finalize a pending stake update
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeStakeUpdate(bytes32 nodeId, uint32 messageIndex) external;

    /**
     * @notice Finalize a pending validator removal
     * @param messageIndex The message index
     */
    function completeValidatorRemoval(
        uint32 messageIndex
    ) external;

    /**
     * @notice Slashes an operator's stake
     * @param epoch The epoch of the slash
     * @param operator The operator being slashed
     * @param amount The slash amount
     * @param assetClassId The asset class ID
     */
    function slash(uint48 epoch, address operator, uint256 amount, uint96 assetClassId) external;

    /**
     * @notice Calculates and caches total stake for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return totalStake The total stake calculated and cached
     */
    function calcAndCacheStakes(uint48 epoch, uint96 assetClassId) external returns (uint256);

    /**
     * @notice Calculates and caches node stakes for all operators retroactively for all epochs
     */
    function calcAndCacheNodeStakeForAllOperators() external;

    /**
     * @notice Fetches the primary and secondary asset classes
     * @return primary The primary asset class
     * @return secondaries An array of secondary asset classes
     */
    function getActiveAssetClasses() external view returns (uint256 primary, uint256[] memory secondaries);

    /**
     * @notice Checks if the classId is active
     * @param assetClassId The asset class ID
     * @return bool True if active
     */
    function isActiveAssetClass(
        uint96 assetClassId
    ) external view returns (bool);

    /**
     * @notice Gets the start timestamp for a given epoch
     * @param epoch The epoch number
     * @return timestamp The start time of that epoch
     */
    function getEpochStartTs(
        uint48 epoch
    ) external view returns (uint48);

    /**
     * @notice Gets the epoch number at a given timestamp
     * @param timestamp The timestamp
     * @return epoch The epoch at that time
     */
    function getEpochAtTs(
        uint48 timestamp
    ) external view returns (uint48);

    /**
     * @notice Gets the current epoch based on the current block time
     * @return epoch The current epoch
     */
    function getCurrentEpoch() external view returns (uint48);

    /**
     * @notice Returns an operator's stake at a given epoch for a specific asset class
     * @param operator The operator address
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return stake The operator's stake
     */
    function getOperatorStake(address operator, uint48 epoch, uint96 assetClassId) external view returns (uint256);

    /**
     * @notice Returns total stake across all operators in a specific epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return The total stake in that epoch
     */
    function getTotalStake(uint48 epoch, uint96 assetClassId) external view returns (uint256);

    /**
     * @notice Returns all operators
     */
    function getAllOperators() external view returns (address[] memory);

    /**
     * @notice Returns the cached stake for a given node in the specified epoch, based on its Validation ID.
     * @param epoch The target Not enough free stake to add nodeepoch.
     * @param validationId The node ID.
     * @return The node stake from the cache.
     */
    function getNodeStake(uint48 epoch, bytes32 validationId) external view returns (uint256);

    /**
     * @notice Returns the current epoch number
     * @param operator The operator address
     * @param epoch The epoch number
     * @return activeNodeIds The list of nodes
     */
    function getActiveNodesForEpoch(address operator, uint48 epoch) external view returns (bytes32[] memory);

    /**
     * @notice Returns the available stake for an operator
     * @param operator The operator address
     * @return The available stake
     */
    function getOperatorAvailableStake(
        address operator
    ) external view returns (uint256);

    /**
     * @notice Summation of node stakes from the nodeStakeCache.
     * @param operator The operator address.
     * @return registeredStake The sum of node stakes.
     */
    function getOperatorUsedStakeCached(
        address operator
    ) external view returns (uint256);

    /**
     * @notice Returns the Vault Manager address associated to this middleware
     * @return Address Vault Manager
     */
    function getVaultManager() external view returns (address);
}
