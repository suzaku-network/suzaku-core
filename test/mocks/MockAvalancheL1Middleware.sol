// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

contract MockAvalancheL1Middleware {
    uint48 public constant EPOCH_DURATION = 4 hours;
    address public immutable BALANCER_VALIDATOR_MANAGER;
    address public constant L1_VALIDATOR_MANAGER = address(0x123);
    address public immutable VAULT_MANAGER;

    mapping(uint48 => mapping(bytes32 => uint256)) public nodeStake;
    mapping(uint48 => mapping(uint96 => uint256)) public totalStakeCache;
    mapping(uint48 => mapping(address => mapping(uint96 => uint256))) public operatorStake;
    mapping(address asset => uint96 assetClass) public assetClassAsset;

    // Replace constant arrays with state variables
    address[] private OPERATORS;
    bytes32[] private VALIDATION_ID_ARRAY;

    // Add mapping from operator to their node IDs
    mapping(address => bytes32[]) private operatorToNodes;

    uint96 primaryAssetClass = 1;
    uint96[] secondaryAssetClasses = [2, 3];

    constructor(
        uint256 operatorCount,
        uint256[] memory nodesPerOperator,
        address balancerValidatorManager,
        address vaultManager
    ) {
        require(operatorCount > 0, "At least one operator required");
        require(operatorCount == nodesPerOperator.length, "Arrays length mismatch");

        BALANCER_VALIDATOR_MANAGER = balancerValidatorManager;
        VAULT_MANAGER = vaultManager;

        // Generate operators
        for (uint256 i = 0; i < operatorCount; i++) {
            // Generate a deterministic but different address for each operator
            // Using a base address and incrementing it for each operator
            address operator = address(uint160(0x1000 + i));
            OPERATORS.push(operator);

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

    function setTotalStakeCache(uint48 epoch, uint96 assetClass, uint256 stake) external {
        totalStakeCache[epoch][assetClass] = stake;
    }

    function setOperatorStake(uint48 epoch, address operator, uint96 assetClass, uint256 stake) external {
        operatorStake[epoch][operator][assetClass] = stake;
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

    function getOperatorTrueStake(uint48 epoch, address operator, uint96 assetClass) external view returns (uint256) {
        if (assetClass == 1) {
            bytes32[] storage nodesArr = operatorToNodes[operator];
            uint256 stake = 0;

            for (uint256 i = 0; i < nodesArr.length; i++) {
                bytes32 nodeId = nodesArr[i];
                stake += this.getNodeStake(epoch, nodeId);
            }
            return stake;
        } else {
            return this.getOperatorStake(operator, epoch, assetClass);
        }
    }

    function getOperatorStake(address operator, uint48 epoch, uint96 assetClass) external view returns (uint256) {
        return operatorStake[epoch][operator][assetClass];
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

    function getActiveAssetClasses() external view returns (uint96, uint96[] memory) {
        return (primaryAssetClass, secondaryAssetClasses);
    }

    function getAssetClassIds() external view returns (uint96[] memory) {
        uint96[] memory assetClasses = new uint96[](3);
        assetClasses[0] = primaryAssetClass;
        assetClasses[1] = secondaryAssetClasses[0];
        assetClasses[2] = secondaryAssetClasses[1];
        return assetClasses;
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

    function isAssetInClass(uint256 assetClass, address asset) external view returns (bool) {
        uint96 assetClassRegistered = assetClassAsset[asset];
        if (assetClassRegistered == assetClass) {
            return true;
        }
        return false;
    }

    function setAssetInAssetClass(uint96 assetClass, address asset) external {
        assetClassAsset[asset] = assetClass;
    }

    function getVaultManager() external view returns (address) {
        return VAULT_MANAGER;
    }
}
