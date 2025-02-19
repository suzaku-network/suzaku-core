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

contract UptimeTracker {
    // need to fetch this value from wherever
    uint48 public immutable EPOCH_DURATION = 4 hours;

    AvalancheL1Middleware private l1Middleware;
    uint256 private rewardsPerEpoch;
    uint256 private partOfRewardsForPrimaryAssetClass;
    uint256 private partOfRewardsForSecondaryAssetClass;

    /// @notice validation ID => last uptime checkpoint
    mapping(string => LastUptimeCheckpoint) public validatorLastUptimeCheckpoint;

    /// @notice epoch => validation ID => uptime
    mapping(uint48 => mapping(string => uint256)) public validatorUptimePerEpoch;

    /// @notice epoch => operator address => uptime
    mapping(uint48 => mapping(address => uint256)) public operatorUptimePerEpoch;

    constructor(
        address _l1Middleware
    ) {
        l1Middleware = AvalancheL1Middleware(_l1Middleware);
    }

    function setInitialCheckpoint(
        ValidatorUptimeInfos memory validatorUptimeInfos
    ) external {
        validatorLastUptimeCheckpoint[validatorUptimeInfos.validationID] =
            LastUptimeCheckpoint({remainingUptime: 0, uptime: 0, timestamp: validatorUptimeInfos.startTimestamp});
    }

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

    function calculateOperatorUptimeCoverageAt(address operator, uint48 epoch) external {
        /**
         * Get operator list of validator
         * For each validator:
         *  - get validationID
         *  - get uptime from validatorUptimePerEpoch mapping
         * Sum all uptimes
         * If an uptime is missing revert
         * Add the uptime sum to the operatorUptimePerEpoch mapping
         */
    }

    function getLastUptimeCheckpoint(
        string memory validationID
    ) external view returns (LastUptimeCheckpoint memory) {
        return validatorLastUptimeCheckpoint[validationID];
    }

    function getValidatorUptimeAt(string memory validationID, uint48 epoch) external view returns (uint256) {
        return validatorUptimePerEpoch[epoch][validationID];
    }
}
