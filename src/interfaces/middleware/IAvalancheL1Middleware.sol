// SPDX-License-Identifier: MIT
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
    error AvalancheL1Middleware__ActiveSecondaryAssetCLass();
    error AvalancheL1Middleware__AssetClassNotActive();
    error AvalancheL1Middleware__AssetIsPrimaryAsset();
    error AvalancheL1Middleware__AssetStillInUse();
    error AvalancheL1Middleware__AlreadyRebalanced();
    error AvalancheL1Middleware__WeightUpdateNotPending();
    error AvalancheL1Middleware__CollateralNotInAssetClass();
    error AvalancheL1Middleware__InvalidEpoch();
    error AvalancheL1Middleware__MaxL1LimitZero();
    error AvalancheL1Middleware__NoSlasher();
    error AvalancheL1Middleware__NotVault();
    error AvalancheL1Middleware__NotEnoughSecondaryAssetClasses();
    error AvalancheL1Middleware__NodeNotActive();
    error AvalancheL1Middleware__NotEnoughFreeStake();
    error AvalancheL1Middleware__WeightTooHigh();
    error AvalancheL1Middleware__WeightTooLow();
    error AvalancheL1Middleware__OperatorGracePeriodNotPassed();
    error AvalancheL1Middleware__OperatorAlreadyRegistered();
    error AvalancheL1Middleware__OperatorNotOptedIn();
    error AvalancheL1Middleware__OperatorNotRegistered();
    error AvalancheL1Middleware__SlashingWindowTooShort();
    error AvalancheL1Middleware__TooBigSlashAmount();
    error AvalancheL1Middleware__TooOldEpoch();
    error AvalancheL1Middleware__UnknownSlasherType();
    error AvalancheL1Middleware__VaultAlreadyRegistered();
    error AvalancheL1Middleware__VaultEpochTooShort();
    error AvalancheL1Middleware__VaultGracePeriodNotPassed();
    error AvalancheL1Middleware__WrongVaultAssetClass();
    error AvalancheL1Middleware__ZeroVaultMaxL1Limit();
    error AvalancheL1Middleware__NodeNotFound();
    error AvalancheL1Middleware__NodeWeightNotCached();
    error AvalancheL1Middleware__SecutiryModuleCapacityNotEnough();
    error AvalancheL1Middleware__WeightUpdatePending();
    error AvalancheL1Middleware__NodeStateNotUpdated();
    error AvalancheL1Middleware__NotInFinalWindowOfEpoch();

    // Events
    /**
     * @notice Emitted when a node is added
     * @param operator The operator who added the node
     * @param nodeId The ID of the node
     * @param blsKey The BLS key of the node
     * @param stake The stake assigned to the node
     * @param validationID The validation identifier from BalancerValidatorManager
     */
    event NodeAdded(
        address indexed operator,
        bytes32 indexed nodeId,
        bytes blsKey,
        uint256 stake,
        bytes32 validationID
    );

    /**
     * @notice Emitted when a node is removed
     * @param operator The operator who removed the node
     * @param nodeId The ID of the node
     */
    event NodeRemoved(address indexed operator, bytes32 indexed nodeId);

    /**
     * @notice Emitted when a single node's weight is updated
     * @param operator The operator who owns the node
     * @param nodeId The ID of the node
     * @param newStake The new weight/stake of the node
     */
    event NodeWeightUpdated(address indexed operator, bytes32 indexed nodeId, uint256 newStake);

    /**
     * @notice Emitted when the operator has leftover stake after rebalancing
     * @param operator The operator who has leftover stake
     * @param leftoverStake The amount of leftover stake
     */
    event OperatorHasLeftoverStake(address indexed operator, uint256 leftoverStake);

    /**
     * @notice Emitted when all node weights are updated for an operator
     * @param operator The operator
     * @param newStake The total new stake for the operator
     */
    event AllNodeWeightsUpdated(address indexed operator, uint256 newStake);
    
    /**
     * @dev Simple struct to return operator stake and key.
     */
    struct OperatorData {
        uint256 stake;
        bytes32 key;
    }

    // Public state variable getters
    function L1_VALIDATOR_MANAGER() external view returns (address);
    function OPERATOR_REGISTRY() external view returns (address);
    function VAULT_REGISTRY() external view returns (address);
    function OPERATOR_L1_OPTIN() external view returns (address);
    function OWNER() external view returns (address);
    function PRIMARY_ASSET() external view returns (address);
    function EPOCH_DURATION() external view returns (uint48);
    function SLASHING_WINDOW() external view returns (uint48);
    function START_TIME() external view returns (uint48);
    function UPDATE_WINDOW() external view returns (uint48);

    // External functions
    /**
     * @notice Activates a secondary asset class
     * @param assetClassId The asset class ID to activate
     */
    function activateSecondaryAssetClass(uint256 assetClassId) external;

    /**
     * @notice Deactivates a secondary asset class
     * @param assetClassId The asset class ID to deactivate
     */
    function deactivateSecondaryAssetClass(uint256 assetClassId) external;

    /**
     * @notice Registers a new operator and enables it
     * @param operator The operator address
     */
    function registerOperator(address operator) external;

    /**
     * @notice Disables an operator
     * @param operator The operator address
     */
    function disableOperator(address operator) external;

    /**
     * @notice Enables an operator
     * @param operator The operator address
     */
    function enableOperator(address operator) external;

    /**
     * @notice Removes an operator if grace period has passed
     * @param operator The operator address
     */
    function removeOperator(address operator) external;

    /**
     * @notice Add a new node => create a new validator.
     * Check the new node stake also ensure security module capacity.
     * @param nodeId The node ID
     * @param blsKey The BLS key
     * @param registrationExpiry The Unix timestamp after which the reigistration is no longer valid on the P-Chain
     * @param remainingBalanceOwner The owner of a validator's remaining balance
     * @param disableOwner The owner of a validator's disable owner on the P-Chain
     * @param initialWeight The initial weight of the node (optional)
     */
    function addNode(
        bytes32 nodeId,
        bytes calldata blsKey,
        uint64 registrationExpiry,
        PChainOwner calldata remainingBalanceOwner,
        PChainOwner calldata disableOwner,
        uint256 initialWeight
    ) external;

    /**
     * @notice Remove a node => remove a validator.
     * @param nodeId The node ID
     */
    function removeNode(bytes32 nodeId) external;

    /**
     * @notice Rebalance node weights once per epoch for an operator.
     * @param operator The operator address
     * @param limitWeight The maximum weight adjustment (add or remove) allowed per node per call.
     */
    function updateAllNodeWeights(address operator, uint256 limitWeight) external;

    /**
     * @notice Update the weight of a validator.
     * @param nodeId The node ID.
     * @param newWeight The new weight.
     */
    function initializeValidatorWeightUpdateAndLock(bytes32 nodeId, uint64 newWeight) external;

    /**
     * @notice Finalize a pending validator registration
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeValidatorRegistration(bytes32 nodeId, uint32 messageIndex) external;

    /**
     * @notice Finalize a pending weight update
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeNodeWeightUpdate(bytes32 nodeId, uint32 messageIndex) external;

    /**
     * @notice Finalize a pending validator removal
     * @param nodeId The node ID
     * @param messageIndex The message index
     */
    function completeValidatorRemoval(bytes32 nodeId, uint32 messageIndex) external;

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
     * @notice Caches manager-based weight for each node of `operator` in epoch `currentEpoch`.
     * @param operator The operator address
     */
    function calcAndCacheNodeWeightsForOperator(address operator) external;

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
    function isActiveAssetClass(uint96 assetClassId) external view returns (bool);

    /**
     * @notice Gets the start timestamp for a given epoch
     * @param epoch The epoch number
     * @return timestamp The start time of that epoch
     */
    function getEpochStartTs(uint48 epoch) external view returns (uint48);

    /**
     * @notice Gets the epoch number at a given timestamp
     * @param timestamp The timestamp
     * @return epoch The epoch at that time
     */
    function getEpochAtTs(uint48 timestamp) external view returns (uint48);

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
     * @notice Returns operator data (stake and key) for an epoch
     * @param epoch The epoch number
     * @param assetClassId The asset class ID
     * @return operatorsData An array of OperatorData (stake and key)
     */
    function getOperatorSet(uint48 epoch, uint96 assetClassId) external view returns (OperatorData[] memory);

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
    function getOperatorAvailableStake(address operator) external view returns (uint256);

    /**
     * @notice Summation of node stakes from the nodeWeightCache.
     * @param operator The operator address.
     * @return registeredStake The sum of node stakes.
     */
    function getOperatorUsedWeightCached(address operator) external view returns (uint256);

    /**
     * @notice Convert a full 256-bit stake amount into a 64-bit weight
     * @dev Anything < WEIGHT_SCALE_FACTOR becomes 0
     */
    function stakeToWeight(uint256 stakeAmount) external pure returns (uint64);

    /**
     * @notice Convert a 64-bit weight back into its 256-bit stake amount
     */
    function weightToStake(uint64 weight) external pure returns (uint256);
}
