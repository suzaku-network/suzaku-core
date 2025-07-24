// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

contract MockAvalancheL1Middleware {
    uint48 public constant EPOCH_DURATION = 4 hours;
    uint48 public constant SLASHING_WINDOW = 5 hours;
    uint48 public constant REMOVAL_DELAY_EPOCHS = 6;
    address public immutable L1_VALIDATOR_MANAGER;
    address public immutable VAULT_MANAGER;

    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStake;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(address => mapping(uint96 => uint256))) public operatorStake;
    mapping(address asset => uint96 collateralClass) public collateralClassAsset;

    // Replace constant arrays with state variables
    address[] private OPERATORS;
    bytes32[] private VALIDATION_ID_ARRAY;

    // Add mapping from operator to their node IDs
    mapping(address => bytes32[]) private operatorToNodes;

    // Track operator status
    mapping(address => bool) public isEnabled;
    mapping(address => uint256) public disabledTime;

    uint96 primaryCollateralClass = 1;
    uint96[] secondaryCollateralClasses = [2, 3];
    uint96[] private collateralClassIds = [1, 2, 3]; // Initialize with default asset classes

    constructor(
        uint256 operatorCount,
        uint256[] memory nodesPerOperator,
        address balancerValidatorManager,
        address vaultManager
    ) {
        require(operatorCount > 0, "At least one operator required");
        require(operatorCount == nodesPerOperator.length, "Arrays length mismatch");

        L1_VALIDATOR_MANAGER = balancerValidatorManager;
        VAULT_MANAGER = vaultManager;

        // Generate operators
        for (uint256 i = 0; i < operatorCount; i++) {
            // Generate a deterministic but different address for each operator
            // Using a base address and incrementing it for each operator
            address operator = address(uint160(0x1000 + i));
            OPERATORS.push(operator);
            isEnabled[operator] = true; // Initialize as enabled

            uint256 nodeCount = nodesPerOperator[i];
            require(nodeCount > 0, "Each operator must have at least one node");

            bytes32[] memory operatorNodes = new bytes32[](nodeCount);

            for (uint256 j = 0; j < nodeCount; j++) {
                // Create a unique node ID for each operator and node index
                bytes32 nodeId = keccak256(abi.encode(operator, j));
                operatorNodes[j] = nodeId;
                VALIDATION_ID_ARRAY.push(nodeId);
            }

            // Store the operator's nodes in the mapping
            operatorToNodes[operator] = operatorNodes;
        }
    }

    function disableOperator(address operator) external {
        require(isEnabled[operator], "Operator not enabled");
        disabledTime[operator] = block.timestamp;
        isEnabled[operator] = false;
    }

    function removeOperator(address operator) external {
        require(!isEnabled[operator], "Operator is still enabled");
        require(this.getCurrentEpoch() >= getEpochAtTs(uint48(disabledTime[operator])) + REMOVAL_DELAY_EPOCHS, "Removal delay not passed");
        require(block.timestamp >= disabledTime[operator] + SLASHING_WINDOW, "Slashing window not passed");
        // Remove operator from OPERATORS array
        for (uint256 i = 0; i < OPERATORS.length; i++) {
            if (OPERATORS[i] == operator) {
                OPERATORS[i] = OPERATORS[OPERATORS.length - 1];
                OPERATORS.pop();
                break;
            }
        }
    }

    function setTotalStakeCache(uint48 epoch, uint96 collateralClass, uint256 stake) external {
        totalStakeCache[epoch][collateralClass] = stake;
    }

    function setOperatorStake(uint48 epoch, address operator, uint96 collateralClass, uint256 stake) external {
        operatorStake[epoch][operator][collateralClass] = stake;
    }

    function setNodeStake(uint48 epoch, bytes32 nodeId, uint256 stake) external {
        nodeStake[epoch][nodeId] = stake;
    }

    function getNodeStake(uint48 epoch, bytes32 nodeId) external view returns (uint256) {
        return nodeStake[epoch][nodeId]; // Return stored stake instead of reverting
    }

    function getCurrentEpoch() external view returns (uint48) {
        return getEpochAtTs(uint48(block.timestamp));
    }

    function getAllOperators() external view returns (address[] memory) {
        return OPERATORS;
    }

    function getOperatorUsedStakeCachedPerEpoch(
        uint48 epoch,
        address operator,
        uint96 collateralClass
    ) external view returns (uint256) {
        if (collateralClass == 1) {
            bytes32[] storage nodesArr = operatorToNodes[operator];
            uint256 stake = 0;

            for (uint256 i = 0; i < nodesArr.length; i++) {
                bytes32 nodeId = nodesArr[i];
                stake += this.getNodeStake(epoch, nodeId);
            }
            return stake;
        } else {
            return this.getOperatorStake(operator, epoch, collateralClass);
        }
    }

    function getOperatorStake(address operator, uint48 epoch, uint96 collateralClass) external view returns (uint256) {
        return operatorStake[epoch][operator][collateralClass];
    }

    /// @notice Returns the mock epoch at a given timestamp.
    function getEpochAtTs(
        uint48 timestamp
    ) public pure returns (uint48) {
        return timestamp / EPOCH_DURATION;
    }

    /// @notice Returns the mock epoch start timestamp.
    function getEpochStartTs(
        uint48 epoch
    ) external pure returns (uint256) {
        return epoch * EPOCH_DURATION + 1;
    }

    function getActiveCollateralClasses() external view returns (uint96, uint96[] memory) {
        return (primaryCollateralClass, secondaryCollateralClasses);
    }

    function setCollateralClassIds(uint96[] memory newCollateralClassIds) external {
        // Clear existing array
        delete collateralClassIds;
        
        // Copy new asset class IDs
        for (uint256 i = 0; i < newCollateralClassIds.length; i++) {
            collateralClassIds.push(newCollateralClassIds[i]);
        }
    }

    function getCollateralClassIds() external view returns (uint96[] memory) {
        uint96[] memory collateralClasses = new uint96[](3);
        collateralClasses[0] = primaryCollateralClass;
        collateralClasses[1] = secondaryCollateralClasses[0];
        collateralClasses[2] = secondaryCollateralClasses[1];
        return collateralClasses;
    }

    /// @notice Returns the active nodes for an operator in a given epoch.
    function getActiveNodesForEpoch(address operator, uint48) external view returns (bytes32[] memory) {
        return operatorToNodes[operator];
    }

    /// @notice Get all nodes for a specific operator
    function getOperatorNodes(
        address operator
    ) external view returns (bytes32[] memory) {
        return operatorToNodes[operator];
    }

    /// @notice Get all validation node IDs
    function getAllValidationIds() external view returns (bytes32[] memory) {
        return VALIDATION_ID_ARRAY;
    }

    function isAssetInClass(uint256 collateralClass, address asset) external view returns (bool) {
        uint96 collateralClassRegistered = collateralClassAsset[asset];
        if (collateralClassRegistered == collateralClass) {
            return true;
        }
        return false;
    }

    function setAssetInCollateralClass(uint96 collateralClass, address asset) external {
        collateralClassAsset[asset] = collateralClass;
    }

    function getVaultManager() external view returns (address) {
        return VAULT_MANAGER;
    }

    /**
     * @notice Simulates the real contract's stake calculation and caching.
     * @dev This now has the correct signature `public returns (uint256)` to match the interface.
     */
    function calcAndCacheStakes(uint48 epoch, uint96 collateralClassId) public returns (uint256 totalStake) {
        // This logic mimics the real contract by summing the individual operator stakes
        // that were configured during the test's setup phase.
        for (uint256 i = 0; i < OPERATORS.length; i++) {
            totalStake += operatorStake[epoch][OPERATORS[i]][collateralClassId];
        }

        // Cache the calculated total stake so the Rewards contract can read it.
        totalStakeCache[epoch][collateralClassId] = totalStake;

        // Return the calculated value as per the real interface.
        return totalStake;
    }
}
