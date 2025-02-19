// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";

/**
 * Calculate the uptime for each validator DONE
 * Aggregate uptime for the operators
 * Define rewards given for each asset class
 * Claimable rewards in one token (but can issue another erc20 if wanted)
 *
 */
struct LastUptimeCheckpoint {
    uint256 remainingUptime;
    uint256 uptime;
    uint256 timestamp;
}

struct ValidatorUptimeInfos {
    string validationID;
    string nodeID;
    uint256 weight;
    uint256 startTimestamp;
    bool isActive;
    bool isL1Validator;
    bool isConnected;
    uint256 uptimePercentage;
    uint256 uptimeSeconds;
}

/**
 * @title UptimeTracker
 * @dev Tracks validator uptime and calculates uptime percentages per epoch.
 * Used to monitor validator activity and operator performance.
 */
contract UptimeTracker {
    // need to fetch this value from wherever
    uint48 public immutable EPOCH_DURATION = 4 hours;

    AvalancheL1Middleware private l1Middleware;

    // move these to another contract
    uint256 private rewardsPerEpoch;
    uint256 private partOfRewardsForPrimaryAssetClass;
    uint256 private partOfRewardsForSecondaryAssetClass;

    /// @notice Mapping of validation ID to the last recorded uptime checkpoint.
    mapping(string => LastUptimeCheckpoint) public validatorLastUptimeCheckpoint;

    /// @notice Mapping of epoch to validator uptime percentage.
    mapping(uint48 => mapping(string => uint256)) public validatorUptimePerEpoch;

    /// @notice Mapping of epoch to operator uptime percentage.
    mapping(uint48 => mapping(address => uint256)) public operatorUptimePerEpoch;

    constructor(
        address _l1Middleware
    ) {
        l1Middleware = AvalancheL1Middleware(_l1Middleware);
    }

    /**
     * @notice Sets the initial uptime checkpoint for a validator.
     * @param validatorUptimeInfos Struct containing validator uptime data.
     */
    function setInitialCheckpoint(
        ValidatorUptimeInfos memory validatorUptimeInfos
    ) external {
        validatorLastUptimeCheckpoint[validatorUptimeInfos.validationID] =
            LastUptimeCheckpoint({remainingUptime: 0, uptime: 0, timestamp: validatorUptimeInfos.startTimestamp});
    }

    /**
     * @notice Computes and records the validator's uptime for each epoch.
     * @param validatorUptimeInfos Struct containing validator uptime data.
     * @param timestamp Current timestamp at which uptime is measured.
     */
    function calculateValidatorUptimeCoverage(
        ValidatorUptimeInfos memory validatorUptimeInfos,
        uint256 timestamp
    ) external {
        LastUptimeCheckpoint storage lastUptimeCheckpoint =
            validatorLastUptimeCheckpoint[validatorUptimeInfos.validationID];

        uint48 lastUptimeEpoch = l1Middleware.getEpochAtTs(uint48(lastUptimeCheckpoint.timestamp));
        uint256 lastUptimeEpochStart = l1Middleware.getEpochStartTs(lastUptimeEpoch);

        uint48 currentEpoch = l1Middleware.getEpochAtTs(uint48(timestamp));
        uint256 currentEpochStart = l1Middleware.getEpochStartTs(currentEpoch);

        uint256 totalUptime =
            lastUptimeCheckpoint.remainingUptime + (validatorUptimeInfos.uptimeSeconds - lastUptimeCheckpoint.uptime);
        uint256 timeBetweenUptime = currentEpochStart - lastUptimeEpochStart;
        uint256 numberOfEpochs = timeBetweenUptime / EPOCH_DURATION;

        uint256 uptimePercentage;

        if (totalUptime > timeBetweenUptime) {
            validatorLastUptimeCheckpoint[validatorUptimeInfos.validationID] = LastUptimeCheckpoint({
                remainingUptime: totalUptime - timeBetweenUptime,
                uptime: validatorUptimeInfos.uptimeSeconds,
                timestamp: currentEpochStart
            });
            uptimePercentage = 100;
        } else {
            validatorLastUptimeCheckpoint[validatorUptimeInfos.validationID] = LastUptimeCheckpoint({
                remainingUptime: 0,
                uptime: validatorUptimeInfos.uptimeSeconds,
                timestamp: currentEpochStart
            });
            uptimePercentage = (totalUptime * 100) / timeBetweenUptime;
        }

        if (numberOfEpochs > 1) {
            for (uint48 i = 0; i < numberOfEpochs; i++) {
                uint48 epoch = lastUptimeEpoch + i;
                validatorUptimePerEpoch[epoch][validatorUptimeInfos.validationID] = uptimePercentage;
            }
        } else if (numberOfEpochs == 1) {
            validatorUptimePerEpoch[lastUptimeEpoch][validatorUptimeInfos.validationID] = uptimePercentage;
        }
    }

    /**
     * @notice Computes and records an operator’s uptime for a given epoch.
     * @dev Aggregates uptime from all validators operated by the given operator for a given epoch.
     * @param operator Address of the operator.
     * @param epoch Epoch for which uptime is calculated.
     */
    function calculateOperatorUptimeCoverageAt(address operator, uint48 epoch) external {
        /**
         * Fetch operator's validators.
         * Sum the uptime percentages from `validatorUptimePerEpoch`.
         * If any validator uptime is missing, revert.
         * Store aggregated uptime in `operatorUptimePerEpoch`.
         */
    }

    /**
     * @notice Returns the last uptime checkpoint for a validator.
     * @param validationID The validator's unique validation ID.
     * @return Last recorded uptime checkpoint.
     */
    function getLastUptimeCheckpoint(
        string memory validationID
    ) external view returns (LastUptimeCheckpoint memory) {
        return validatorLastUptimeCheckpoint[validationID];
    }

    /**
     * @notice Returns a validator's uptime percentage for a specific epoch.
     * @param validationID The validator's unique validation ID.
     * @param epoch The epoch number.
     * @return Uptime percentage for the validator.
     */
    function getValidatorUptimeAt(string memory validationID, uint48 epoch) external view returns (uint256) {
        return validatorUptimePerEpoch[epoch][validationID];
    }

    /**
     * @notice Returns an operator's aggregated uptime percentage for a specific epoch.
     * @param operator The address of the operator.
     * @param epoch The epoch number.
     * @return Uptime percentage for the operator.
     */
    function getOperatorUptimeAt(address operator, uint48 epoch) external view returns (uint256) {
        return operatorUptimePerEpoch[epoch][operator];
    }
}
