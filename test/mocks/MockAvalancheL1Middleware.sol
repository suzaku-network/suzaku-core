// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO
pragma solidity 0.8.25;

contract MockAvalancheL1Middleware {
    uint48 public constant EPOCH_DURATION = 4 hours;
    address public immutable BALANCER_VALIDATOR_MANAGER;

    bytes32[] VALIDATION_ID_ARRAY = [
        keccak256(abi.encode("Validator1")),
        keccak256(abi.encode("Validator2")),
        keccak256(abi.encode("Validator3")),
        keccak256(abi.encode("Validator4")),
        keccak256(abi.encode("Validator5"))
    ];

    constructor(
        address validatorManager_
    ) {
        BALANCER_VALIDATOR_MANAGER = validatorManager_;
    }

    /// @notice Returns the mock epoch at a given timestamp.
    function getEpochAtTs(
        uint48 timestamp
    ) external pure returns (uint48) {
        return timestamp / EPOCH_DURATION;
    }

    /// @notice Returns the mock epoch start timestamp.
    function getEpochStartTs(
        uint48 epoch
    ) external pure returns (uint256) {
        return epoch * EPOCH_DURATION + 1;
    }

    /// @notice Returns the active nodes for an operator in a given epoch.
    function getActiveNodesForEpoch(address, uint48) external view returns (bytes32[] memory) {
        return VALIDATION_ID_ARRAY;
    }
}
