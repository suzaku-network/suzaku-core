// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";

struct LastUptimeCheckpoint {
    uint256 remainingUptime;
    uint256 uptime;
    uint256 timestamp;
}

error UptimeTracker__ValidatorUptimeNotRecorded(uint48 epoch, bytes32 validator);

/**
 * @title UptimeTracker
 * @dev Tracks validator uptime and calculates uptime percentages per epoch.
 * Used to monitor validator activity and operator performance.
 */
contract UptimeTracker {
    /**
     * @notice Emitted when a validator's uptime is recorded.
     * @param validationID Unique ID of the validator's validation period.
     * @param uptime Recorded uptime (in seconds) since the last proof.
     * @param numberOfEpochs Number of epochs covered by this uptime.
     * @param firstEpoch First epoch included in this uptime calculation.
     */
    event ValidatorUptimeComputed(
        bytes32 indexed validationID, uint256 indexed uptime, uint256 indexed numberOfEpochs, uint48 firstEpoch
    );

    /**
     * @notice Emitted when an operator's uptime is calculated.
     * @param operator Operator's address.
     * @param uptime Average uptime (in seconds) of the operator's validators.
     * @param epoch Epoch for which uptime was recorded.
     */
    event OperatorUptimeComputed(address indexed operator, uint256 indexed uptime, uint48 indexed epoch);

    uint48 private epochDuration;
    AvalancheL1Middleware private l1Middleware;

    /// @notice Mapping of validation ID to the last recorded uptime checkpoint.
    mapping(bytes32 => LastUptimeCheckpoint) public validatorLastUptimeCheckpoint;

    /// @notice Mapping of epoch to validator uptime (in seconds).
    mapping(uint48 => mapping(bytes32 => uint256)) public validatorUptimePerEpoch;

    /// @notice Mapping of epoch to validator uptime recorded.
    mapping(uint48 => mapping(bytes32 => bool)) public isUptimeSet;

    /// @notice Mapping of epoch to operator uptime (in seconds).
    mapping(uint48 => mapping(address => uint256)) public operatorUptimePerEpoch;

    constructor(
        address _l1Middleware
    ) {
        l1Middleware = AvalancheL1Middleware(_l1Middleware);
        epochDuration = l1Middleware.EPOCH_DURATION();
    }

    /**
     * @notice Sets the initial uptime checkpoint for a validator.
     * @param validationID ID of the validation period of a validator.
     * @param timestamp Timestamp at which the validator has activated its validation period.
     */
    function setInitialCheckpoint(bytes32 validationID, uint256 timestamp) external {
        validatorLastUptimeCheckpoint[validationID] =
            LastUptimeCheckpoint({remainingUptime: 0, uptime: 0, timestamp: timestamp});
    }

    /**
     * @notice Computes and records the validator's uptime for each epoch.
     * @param validationID ID of the validation period of a validator.
     * @param uptime Current uptime recorded.
     * @param timestamp Current timestamp at which uptime is measured.
     */
    function calculateValidatorUptimeCoverage(bytes32 validationID, uint256 uptime, uint256 timestamp) external {
        LastUptimeCheckpoint storage lastUptimeCheckpoint = validatorLastUptimeCheckpoint[validationID];

        uint48 lastUptimeEpoch = l1Middleware.getEpochAtTs(uint48(lastUptimeCheckpoint.timestamp));
        uint256 lastUptimeEpochStart = l1Middleware.getEpochStartTs(lastUptimeEpoch);

        uint48 currentEpoch = l1Middleware.getEpochAtTs(uint48(timestamp));
        uint256 currentEpochStart = l1Middleware.getEpochStartTs(currentEpoch);

        uint256 totalUptime = lastUptimeCheckpoint.remainingUptime + (uptime - lastUptimeCheckpoint.uptime);
        uint256 timeBetweenUptime = currentEpochStart - lastUptimeEpochStart;
        uint256 numberOfEpochs = timeBetweenUptime / epochDuration;

        uint256 uptimeToDistribute = totalUptime;

        if (uptimeToDistribute > timeBetweenUptime) {
            validatorLastUptimeCheckpoint[validationID] = LastUptimeCheckpoint({
                remainingUptime: uptimeToDistribute - timeBetweenUptime,
                uptime: uptime,
                timestamp: currentEpochStart
            });
        } else {
            validatorLastUptimeCheckpoint[validationID] =
                LastUptimeCheckpoint({remainingUptime: 0, uptime: uptime, timestamp: currentEpochStart});
        }

        if (numberOfEpochs > 1) {
            uint256 uptimePerEpoch = uptimeToDistribute / numberOfEpochs;
            for (uint48 i = 0; i < numberOfEpochs; i++) {
                uint48 epoch = lastUptimeEpoch + i;
                validatorUptimePerEpoch[epoch][validationID] = uptimePerEpoch;
                isUptimeSet[epoch][validationID] = true;
            }
        } else if (numberOfEpochs == 1) {
            validatorUptimePerEpoch[lastUptimeEpoch][validationID] = uptimeToDistribute;
            isUptimeSet[lastUptimeEpoch][validationID] = true;
        }

        emit ValidatorUptimeComputed(validationID, uptimeToDistribute, numberOfEpochs, lastUptimeEpoch);
    }

    /**
     * @notice Computes and records an operator’s uptime for a given epoch.
     * @dev Aggregates uptime from all validators operated by the given operator for a given epoch.
     * @param operator Address of the operator.
     * @param epoch Epoch for which uptime is calculated.
     */
    function calculateOperatorUptimeCoverageAt(address operator, uint48 epoch) external {
        bytes32[] memory operatorNodes = l1Middleware.getActiveNodesForEpoch(operator, epoch);
        uint256 numberOfValidators = operatorNodes.length;
        uint256 sumValidatorsUptime = 0;

        for (uint256 i = 0; i < numberOfValidators; i++) {
            if (isUptimeSet[epoch][operatorNodes[i]] == false) {
                revert UptimeTracker__ValidatorUptimeNotRecorded(epoch, operatorNodes[i]);
            }
            uint256 uptimeValidator = validatorUptimePerEpoch[epoch][operatorNodes[i]];
            sumValidatorsUptime += uptimeValidator;
        }

        operatorUptimePerEpoch[epoch][operator] = sumValidatorsUptime / numberOfValidators;

        emit OperatorUptimeComputed(operator, sumValidatorsUptime / numberOfValidators, epoch);
    }

    /**
     * @notice Returns the last uptime checkpoint for a validator.
     * @param validationID The validator's unique validation ID.
     * @return Last recorded uptime checkpoint.
     */
    function getLastUptimeCheckpoint(
        bytes32 validationID
    ) external view returns (LastUptimeCheckpoint memory) {
        return validatorLastUptimeCheckpoint[validationID];
    }
}
