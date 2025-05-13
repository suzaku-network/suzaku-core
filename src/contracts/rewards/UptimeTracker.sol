// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: Copyright 2024 ADDPHO

pragma solidity 0.8.25;

import {AvalancheL1Middleware} from "../middleware/AvalancheL1Middleware.sol";
import {IUptimeTracker, LastUptimeCheckpoint} from "../../interfaces/rewards/IUptimeTracker.sol";
import {BalancerValidatorManager} from
    "@suzaku/contracts-library/contracts/ValidatorManager/BalancerValidatorManager.sol";
import {Validator} from "@avalabs/icm-contracts/validator-manager/interfaces/IValidatorManager.sol";
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
    AvalancheL1Middleware private immutable l1Middleware;
    BalancerValidatorManager private immutable validatorManager;
    bytes32 private immutable l1ChainID;

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

    constructor(
        address payable l1Middleware_
    ) {
        l1Middleware = AvalancheL1Middleware(l1Middleware_);
        epochDuration = l1Middleware.EPOCH_DURATION();
        validatorManager = BalancerValidatorManager(l1Middleware.L1_VALIDATOR_MANAGER());
        l1ChainID = validatorManager.getL1ID();
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
        if (warpMessage.sourceChainID != l1ChainID) {
            revert InvalidWarpSourceChainID(warpMessage.sourceChainID);
        }
        if (warpMessage.originSenderAddress != address(0)) {
            revert InvalidWarpOriginSenderAddress(warpMessage.originSenderAddress);
        }

        // Unpack the uptime message
        (bytes32 validationID, uint256 uptime) = ValidatorMessages.unpackValidationUptimeMessage(warpMessage.payload);

        LastUptimeCheckpoint storage lastUptimeCheckpoint = validatorLastUptimeCheckpoint[validationID];

        // No timestamp means no initial checkpoint
        if (lastUptimeCheckpoint.timestamp == 0) {
            // Get validator details
            Validator memory validator = validatorManager.getValidator(validationID);
            validatorLastUptimeCheckpoint[validationID] =
                LastUptimeCheckpoint({remainingUptime: 0, attributedUptime: 0, timestamp: validator.startedAt});

            // Refresh the reference to the updated struct
            lastUptimeCheckpoint = validatorLastUptimeCheckpoint[validationID];
        }

        // Get last checkpoint epoch start
        uint48 lastUptimeEpoch = l1Middleware.getEpochAtTs(uint48(lastUptimeCheckpoint.timestamp));
        uint256 lastUptimeEpochStart = l1Middleware.getEpochStartTs(lastUptimeEpoch);

        // Get current epoch start
        uint48 currentEpoch = l1Middleware.getEpochAtTs(uint48(block.timestamp));
        uint256 currentEpochStart = l1Middleware.getEpochStartTs(currentEpoch);

        // Calculate the recorded uptime since the last checkpoint
        uint256 recordedUptime = lastUptimeCheckpoint.remainingUptime + (uptime - lastUptimeCheckpoint.attributedUptime);

        // Calculate the elapsed time between the last recorded epoch and the current epoch
        uint256 elapsedTime = currentEpochStart - lastUptimeEpochStart;

        // Determine how many full epochs have passed
        uint256 elapsedEpochs = elapsedTime / epochDuration;

        // The uptime to distribute across the elapsed epochs
        uint256 uptimeToDistribute = recordedUptime;

        uint256 remainingUptime = uptimeToDistribute > elapsedTime ? uptimeToDistribute - elapsedTime : 0;

        // If the recorded uptime is greater than the elapsed time, carry over the excess uptime else reset it
        validatorLastUptimeCheckpoint[validationID] = LastUptimeCheckpoint({
            remainingUptime: remainingUptime, // Store the leftover uptime for future epochs if any
            attributedUptime: uptime, // Update the last recorded uptime
            timestamp: currentEpochStart // Move the checkpoint forward
        });

        // Distribute the recorded uptime across multiple epochs
        if (elapsedEpochs >= 1) {
            uint256 uptimePerEpoch = uptimeToDistribute / elapsedEpochs;
            for (uint48 i = 0; i < elapsedEpochs; i++) {
                uint48 epoch = lastUptimeEpoch + i;
                validatorUptimePerEpoch[epoch][validationID] = uptimePerEpoch; // Assign uptime to each epoch
                isValidatorUptimeSet[epoch][validationID] = true; // Mark uptime as set for the epoch
            }
        }

        emit ValidatorUptimeComputed(validationID, lastUptimeEpoch, uptimeToDistribute, elapsedEpochs);
    }

    /**
     * @inheritdoc IUptimeTracker
     */
    function computeOperatorUptimeAt(address operator, uint48 epoch) external {
        bytes32[] memory operatorNodes = l1Middleware.getActiveNodesForEpoch(operator, epoch);
        uint256 numberOfValidators = operatorNodes.length;
        if (numberOfValidators == 0) revert UptimeTracker__NoValidators(operator, epoch);
        uint256 sumValidatorsUptime = 0;

        for (uint256 i = 0; i < numberOfValidators; i++) {
            if (isValidatorUptimeSet[epoch][operatorNodes[i]] == false) {
                revert UptimeTracker__ValidatorUptimeNotRecorded(epoch, operatorNodes[i]);
            }
            uint256 uptimeValidator = validatorUptimePerEpoch[epoch][operatorNodes[i]];
            sumValidatorsUptime += uptimeValidator;
        }

        operatorUptimePerEpoch[epoch][operator] = sumValidatorsUptime / numberOfValidators;
        isOperatorUptimeSet[epoch][operator] = true;

        emit OperatorUptimeComputed(operator, epoch, sumValidatorsUptime / numberOfValidators);
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
