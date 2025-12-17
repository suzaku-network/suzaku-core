// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../interfaces/rewards/IUptimeTracker.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IACP99Manager.sol";
import {ValidatorMessages} from "@avalabs/icm-contracts/validator-manager/ValidatorMessages.sol";
import {
    IWarpMessenger, WarpMessage
} from "@avalabs/subnet-evm-contracts@1.2.0/contracts/interfaces/IWarpMessenger.sol";

/**
 * @title UptimeTracker
 * @dev Tracks validator uptime and calculates uptime percentages per epoch.
 * Used to monitor validator and operator performance.
 */
contract UptimeTracker is IUptimeTracker {
    uint48 private immutable epochDuration;
    AvalancheL1Middleware private immutable middleware;
    BalancerValidatorManager private immutable validatorManager;
    bytes32 private immutable uptimeBlockchainID; // blockchainID of the L1

    IWarpMessenger public constant WARP_MESSENGER = IWarpMessenger(0x0200000000000000000000000000000000000005);

    /// @notice Mapping of validation ID to the last recorded uptime checkpoint.
    mapping(bytes32 validationID => LastUptimeCheckpoint lastUptimeCheckpoint) public validatorLastUptimeCheckpoint;

    /// @notice Mapping of epoch to validator uptime (in seconds).
    mapping(uint48 epoch => mapping(bytes32 validationID => uint256 uptime)) public validatorUptimePerEpoch;

    /// @notice Mapping of epoch to validator uptime set.
    mapping(uint48 epoch => mapping(bytes32 validationID => bool isSet)) public isValidatorUptimeSet;

    /// @notice Mapping of epoch to operator uptime (in seconds).
    mapping(uint48 epoch => mapping(address operator => uint256 uptime)) public operatorUptimePerEpoch;

    /// @notice Mapping of epoch to operator uptime set.
    mapping(uint48 epoch => mapping(address operator => bool isSet)) public isOperatorUptimeSet;

    /// @notice Tracks the epoch in which operator uptime was computed (epoch+1 sentinel)..
    mapping(uint48 epoch => mapping(address operator => uint48 epochPlusOne)) private operatorUptimeComputedAtEpochPlusOne;

    /// @notice Mapping of validation ID to highest uptime seen (monotonicity guard).
    mapping(bytes32 validationID => uint256 highestUptime) public validatorHighestUptime;

    /// @notice Snapshot of checkpoint state at the start of the current epoch.
    mapping(bytes32 validationID => EpochBaseline baseline) private validatorEpochBaseline;

    /// @notice Epoch baseline struct.
    struct EpochBaseline {
        uint48 epoch;
        LastUptimeCheckpoint checkpoint;
    }

    constructor(
        address payable middleware_,
        bytes32 uptimeBlockchainID_
    ) {
        middleware = AvalancheL1Middleware(middleware_);
        epochDuration = middleware.EPOCH_DURATION();
        validatorManager = BalancerValidatorManager(middleware.BALANCER());
        uptimeBlockchainID = uptimeBlockchainID_;
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function computeValidatorUptime(
        uint32 messageIndex
    ) external {
        // Get warp message directly
        (WarpMessage memory warpMessage, bool valid) = WARP_MESSENGER.getVerifiedWarpMessage(messageIndex);
        if (!valid) {
            revert InvalidWarpMessage();
        }
        // Must match to P-Chain blockchain id
        if (warpMessage.sourceChainID != uptimeBlockchainID) {
            revert InvalidWarpSourceChainID(warpMessage.sourceChainID);
        }
        if (warpMessage.originSenderAddress != address(0)) {
            revert InvalidWarpOriginSenderAddress(warpMessage.originSenderAddress);
        }

        // Unpack the uptime message
        (bytes32 validationID, uint256 uptime) = ValidatorMessages.unpackValidationUptimeMessage(warpMessage.payload);

        uint256 stored = validatorHighestUptime[validationID];
        if (stored > 0 && uptime <= stored) {
            return;
        }
        validatorHighestUptime[validationID] = uptime;

        LastUptimeCheckpoint storage lastUptimeCheckpoint = validatorLastUptimeCheckpoint[validationID];

        // No timestamp means no initial checkpoint
        if (lastUptimeCheckpoint.timestamp == 0) {
            // Get validator details
            Validator memory validator = validatorManager.getValidator(validationID);
            validatorLastUptimeCheckpoint[validationID] =
                LastUptimeCheckpoint({remainingUptime: 0, attributedUptime: 0, timestamp: validator.startTime});

            // Refresh the reference to the updated struct
            lastUptimeCheckpoint = validatorLastUptimeCheckpoint[validationID];
        }

        // Get current epoch start
        uint48 currentEpoch = middleware.getEpochAtTs(uint48(block.timestamp));
        uint256 currentEpochStart = middleware.getEpochStartTs(currentEpoch);

        // Snapshot checkpoint state for this epoch so later calls in the same epoch can reprocess with higher uptime.
        EpochBaseline storage baseline = validatorEpochBaseline[validationID];
        if (baseline.epoch != currentEpoch) {
            baseline.epoch = currentEpoch;
            baseline.checkpoint = lastUptimeCheckpoint;
        }
        LastUptimeCheckpoint memory base = baseline.checkpoint;

        // Always compute from `base` (the checkpoint as of the first call in this epoch)
        uint48 lastUptimeEpoch = middleware.getEpochAtTs(uint48(base.timestamp));
        uint256 lastUptimeEpochStart = middleware.getEpochStartTs(lastUptimeEpoch);

        // Calculate the recorded uptime since the last checkpoint (from the epoch baseline)
        uint256 recordedUptime = base.remainingUptime + (uptime - base.attributedUptime);

        // Check if current epoch is before the validator's start epoch
        if (currentEpoch < lastUptimeEpoch) {
            revert UptimeBeforeStart(validationID, lastUptimeEpoch, currentEpoch);
        }

        // Determine how many full epochs have passed - optimized calculation
        uint256 elapsedEpochs = currentEpoch - lastUptimeEpoch;

        // Calculate the elapsed time between the last recorded epoch and the current epoch
        uint256 elapsedTime = currentEpochStart - lastUptimeEpochStart;

        uint256 remainingUptime = recordedUptime > elapsedTime ? recordedUptime - elapsedTime : 0;

        // The uptime to distribute across the elapsed epochs
        uint256 uptimeToDistribute = recordedUptime - remainingUptime;

        // If the recorded uptime is greater than the elapsed time, carry over the excess uptime else reset it
        validatorLastUptimeCheckpoint[validationID] = LastUptimeCheckpoint({
            remainingUptime: remainingUptime, // Store the leftover uptime for future epochs if any
            attributedUptime: uptime, // Update the last recorded uptime
            timestamp: currentEpochStart // Move the checkpoint forward
        });

        // Advance the real checkpoint to currentEpochStart on every call.
        // This ensures that next epoch processing remains correct.

        // Distribute the recorded uptime across multiple epochs
        if (elapsedEpochs >= 1) {
            uint256 uptimePerEpoch = uptimeToDistribute / elapsedEpochs;
            uint256 remainder = uptimeToDistribute % elapsedEpochs;

            for (uint48 i = 0; i < elapsedEpochs;) {
                uint48 epoch;
                unchecked {
                    epoch = lastUptimeEpoch + i;
                    i++;
                }

                uint256 epochUptime = uptimePerEpoch;
                // Distribute the leftover seconds one by one to the earliest available epochs
                if (remainder > 0) {
                    epochUptime += 1;
                    remainder -= 1;
                }

                // Allow in-epoch reprocessing to correct earlier (stale) distributions.
                // Values only ever increase due to validatorHighestUptime monotonicity.
                if (isValidatorUptimeSet[epoch][validationID] == true) {
                    if (epochUptime <= validatorUptimePerEpoch[epoch][validationID]) {
                        continue;
                    }
                }

                validatorUptimePerEpoch[epoch][validationID] = epochUptime;
                isValidatorUptimeSet[epoch][validationID] = true;
            }
        }

        emit ValidatorUptimeComputed(validationID, lastUptimeEpoch, uptimeToDistribute, elapsedEpochs);
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function computeOperatorUptimeAt(address operator, uint48 epoch) external {
        uint48 currentEpoch = middleware.getEpochAtTs(uint48(block.timestamp));
        uint48 currentEpochPlusOne = currentEpoch + 1;

        // Allow reprocessing only within the same current epoch, otherwise keep write-once revert.
        if (isOperatorUptimeSet[epoch][operator]) {
            if (operatorUptimeComputedAtEpochPlusOne[epoch][operator] != currentEpochPlusOne) {
                revert UptimeTracker__OperatorUptimeAlreadySet(epoch, operator);
            }
        }

        bytes32[] memory operatorValidationIDs = middleware.getOperatorValidationIDs(operator);
        uint48 epochStartTs = middleware.getEpochStartTs(epoch);
        uint256 numberOfValidators = 0;
        uint256 sumValidatorsUptime = 0;

        for (uint256 i = 0; i < operatorValidationIDs.length; i++) {
            bytes32 validationID = operatorValidationIDs[i];

            Validator memory v = validatorManager.getValidator(validationID);
            uint48 start = uint48(v.startTime);
            uint48 end = uint48(v.endTime);
            if (start == 0 || start > epochStartTs || (end != 0 && end <= epochStartTs)) {
                continue;
            }

            if (isValidatorUptimeSet[epoch][validationID] == false) {
                revert UptimeTracker__ValidatorUptimeNotRecorded(epoch, validationID);
            }
            sumValidatorsUptime += validatorUptimePerEpoch[epoch][validationID];
            numberOfValidators += 1;
        }

        if (numberOfValidators == 0) revert UptimeTracker__NoValidators(operator, epoch);

        uint256 computed = sumValidatorsUptime / numberOfValidators;

        if (isOperatorUptimeSet[epoch][operator]) {
            uint256 prev = operatorUptimePerEpoch[epoch][operator];
            if (computed <= prev) {
                return;
            }
        }

        operatorUptimePerEpoch[epoch][operator] = computed;
        isOperatorUptimeSet[epoch][operator] = true;
        operatorUptimeComputedAtEpochPlusOne[epoch][operator] = currentEpochPlusOne;

        emit OperatorUptimeComputed(operator, epoch, computed);
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function getLastUptimeCheckpoint(
        bytes32 validationID
    ) external view returns (LastUptimeCheckpoint memory) {
        return validatorLastUptimeCheckpoint[validationID];
    }
}
